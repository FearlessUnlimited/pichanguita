import { beforeEach, describe, expect, it } from 'vitest'
import { como, crearBase, rpc, type Base } from './arnes'
import { anotar, escenario, inscripcionDe, type Escenario, type Usuario } from './escenario'

async function cargos(db: Base, grupoId: string) {
  const { rows } = await db.query<{ nombre: string; monto: number; concepto: string }>(
    `select m.nombre, c.monto, c.concepto from public.cargos c join public.miembros m on m.id = c.miembro_id
     where c.grupo_id = $1 and c.anulado_at is null order by m.nombre, c.concepto`,
    [grupoId],
  )
  return rows.map((r) => `${r.nombre}:${r.monto}:${r.concepto.replace(/ · \d\d\/\d\d$/, '').replace(/ \d\d\/\d\d$/, '')}`)
}

function cerrar(db: Base, quien: Usuario, partidoId: string) {
  return como(db, quien, (tx) => rpc<{ cerrar_partido: number }>(tx, 'cerrar_partido', { p_partido: partidoId })).then(
    (r) => r[0].cerrar_partido,
  )
}

function marcar(db: Base, quien: Usuario, inscripcionId: string, asistio: boolean) {
  return como(db, quien, (tx) => rpc(tx, 'marcar_asistencia', { p_inscripcion: inscripcionId, p_asistio: asistio }))
}

describe('cerrar el partido y cobrar', () => {
  let db: Base
  let e: Escenario

  async function preparar(opciones: Parameters<typeof escenario>[1]) {
    db = await crearBase()
    e = await escenario(db, { cupos: 4, jugadores: ['Pato', 'Feña', 'Seba', 'Tito'], ...opciones })
    for (const nombre of ['Pato', 'Feña', 'Seba', 'Tito']) {
      await anotar(db, e.jugadores[nombre].usuario, e.partidoId)
    }
    // Pato, Feña, Seba y Tito confirmados; Tito no llegó. Pato trajo a su primo, que quedó en la banca.
    await como(db, e.jugadores.Pato.usuario, (tx) =>
      rpc(tx, 'agregar_invitado', { p_partido: e.partidoId, p_nombre: 'Primo' }),
    )
    await marcar(db, e.organizador, (await inscripcionDe(db, e.partidoId, e.jugadores.Tito.miembroId)).id, false)
  }

  it('cuota fija: cobra a los asistentes; el ausente y la banca no pagan', async () => {
    await preparar({ cuota: 4000 })
    expect(await cerrar(db, e.organizador, e.partidoId)).toBe(3)
    expect(await cargos(db, e.grupoId)).toEqual(['Feña:4000:Partido', 'Pato:4000:Partido', 'Seba:4000:Partido'])
  })

  it('el invitado confirmado se le cobra a quien lo invitó', async () => {
    await preparar({ cuota: 4000 })
    await como(db, e.organizador, (tx) => rpc(tx, 'cambiar_cupos', { p_partido: e.partidoId, p_cupos: 5 }))
    const { rows } = await db.query<{ id: string }>("select id from public.inscripciones where invitado_nombre = 'Primo'")
    await como(db, e.jugadores.Pato.usuario, (tx) => rpc(tx, 'responder_oferta', { p_inscripcion: rows[0].id, p_acepta: true }))
    await cerrar(db, e.organizador, e.partidoId)
    expect(await cargos(db, e.grupoId)).toEqual([
      'Feña:4000:Partido',
      'Pato:4000:Invitado Primo',
      'Pato:4000:Partido',
      'Seba:4000:Partido',
    ])
  })

  it('con "cobrar ausentes" también paga el confirmado que no llegó', async () => {
    await preparar({ cuota: 4000 })
    await db.query('update public.grupos set cobrar_ausentes = true where id = $1', [e.grupoId])
    expect(await cerrar(db, e.organizador, e.partidoId)).toBe(4)
  })

  it('dividir: costo de la cancha ÷ asistentes, redondeado hacia arriba a $100', async () => {
    await preparar({ modoCobro: 'dividir', costoCancha: 50000 })
    await cerrar(db, e.organizador, e.partidoId)
    // 50.000 ÷ 3 = 16.666,67 → 16.700
    expect(await cargos(db, e.grupoId)).toEqual(['Feña:16700:Partido', 'Pato:16700:Partido', 'Seba:16700:Partido'])
  })

  it('no se cierra dos veces ni lo cierra un jugador', async () => {
    await preparar({ cuota: 4000 })
    await expect(cerrar(db, e.jugadores.Pato.usuario, e.partidoId)).rejects.toThrow('no_autorizado')
    await cerrar(db, e.organizador, e.partidoId)
    await expect(cerrar(db, e.organizador, e.partidoId)).rejects.toThrow('partido_cerrado')
    expect(await cargos(db, e.grupoId)).toHaveLength(3)
  })

  it('un partido olvidado se cierra solo 24 horas después del inicio', async () => {
    await preparar({ cuota: 4000 })
    await db.query("update public.partidos set inicio = now() - interval '23 hours' where id = $1", [e.partidoId])
    await db.query('select interno.cerrar_partidos_olvidados()')
    expect(await cargos(db, e.grupoId)).toHaveLength(0)
    await db.query("update public.partidos set inicio = now() - interval '24 hours' where id = $1", [e.partidoId])
    await db.query('select interno.cerrar_partidos_olvidados()')
    expect(await cargos(db, e.grupoId)).toHaveLength(3)
    const { rows } = await db.query<{ estado: string }>('select estado from public.partidos where id = $1', [e.partidoId])
    expect(rows[0].estado).toBe('cerrado')
  })
})

describe('pagos, saldos y caja', () => {
  let db: Base
  let e: Escenario
  let pato: { usuario: Usuario; miembroId: string }

  beforeEach(async () => {
    db = await crearBase()
    e = await escenario(db, { cuota: 4000, jugadores: ['Pato', 'Feña'] })
    pato = e.jugadores.Pato
    await anotar(db, pato.usuario, e.partidoId)
    await anotar(db, e.jugadores['Feña'].usuario, e.partidoId)
    await cerrar(db, e.organizador, e.partidoId)
  })

  function pagar(quien: Usuario, args: { id?: string; miembro?: string; monto?: number; medio?: string }) {
    return como(db, quien, (tx) =>
      rpc<{ id: string; estado: string }>(tx, 'registrar_pago', {
        p_id: args.id ?? crypto.randomUUID(),
        p_grupo: e.grupoId,
        p_miembro: args.miembro ?? pato.miembroId,
        p_monto: args.monto ?? 4000,
        p_medio: args.medio ?? 'transferencia',
      }),
    ).then((r) => r[0])
  }

  async function saldo(quien: Usuario, miembroId: string) {
    const filas = await como(db, quien, (tx) =>
      rpc<{ miembro_id: string; saldo: number }>(tx, 'saldos', { p_grupo: e.grupoId }),
    )
    return filas.find((f) => f.miembro_id === miembroId)?.saldo
  }

  it('el jugador informa "ya transferí" y queda debiendo hasta que el organizador confirma', async () => {
    const pago = await pagar(pato.usuario, {})
    expect(pago.estado).toBe('informado')
    expect(await saldo(pato.usuario, pato.miembroId)).toBe(-4000)
    await como(db, e.organizador, (tx) => rpc(tx, 'revisar_pago', { p_pago: pago.id, p_confirmar: true }))
    expect(await saldo(pato.usuario, pato.miembroId)).toBe(0)
  })

  it('el jugador solo informa transferencias propias; el efectivo lo marca el organizador y queda confirmado', async () => {
    await expect(pagar(pato.usuario, { medio: 'efectivo' })).rejects.toThrow('no_autorizado')
    await expect(pagar(pato.usuario, { miembro: e.jugadores['Feña'].miembroId })).rejects.toThrow('no_autorizado')
    expect((await pagar(e.organizador, { medio: 'efectivo' })).estado).toBe('confirmado')
    expect(await saldo(e.organizador, pato.miembroId)).toBe(0)
  })

  it('reenviar el mismo pago no lo duplica; el mismo id con otros datos es un error', async () => {
    const id = crypto.randomUUID()
    await pagar(e.organizador, { id, medio: 'efectivo' })
    await pagar(e.organizador, { id, medio: 'efectivo' })
    const { rows } = await db.query('select * from public.pagos')
    expect(rows).toHaveLength(1)
    await expect(pagar(e.organizador, { id, medio: 'efectivo', monto: 5000 })).rejects.toThrow('pago_duplicado')
  })

  it('un pago rechazado no cuenta', async () => {
    const pago = await pagar(pato.usuario, {})
    await expect(
      como(db, pato.usuario, (tx) => rpc(tx, 'revisar_pago', { p_pago: pago.id, p_confirmar: true })),
    ).rejects.toThrow('no_autorizado')
    await como(db, e.organizador, (tx) => rpc(tx, 'revisar_pago', { p_pago: pago.id, p_confirmar: false }))
    expect(await saldo(e.organizador, pato.miembroId)).toBe(-4000)
  })

  it('ajustes y anulaciones cambian el saldo', async () => {
    const [ajuste] = await como(db, e.organizador, (tx) =>
      rpc<{ id: string }>(tx, 'registrar_ajuste', {
        p_grupo: e.grupoId, p_miembro: pato.miembroId, p_monto: -1000, p_concepto: 'Trajo los petos',
      }),
    )
    expect(await saldo(e.organizador, pato.miembroId)).toBe(-3000)
    await como(db, e.organizador, (tx) => rpc(tx, 'anular_cargo', { p_cargo: ajuste.id }))
    expect(await saldo(e.organizador, pato.miembroId)).toBe(-4000)
  })

  it('caja = pagos confirmados + ingresos − gastos vigentes', async () => {
    await pagar(e.organizador, { medio: 'efectivo' })
    await pagar(e.organizador, { miembro: e.jugadores['Feña'].miembroId, medio: 'transferencia' })
    const movimiento = (tipo: string, monto: number) =>
      como(db, e.organizador, (tx) =>
        rpc<{ id: string }>(tx, 'registrar_movimiento', {
          p_id: crypto.randomUUID(), p_grupo: e.grupoId, p_tipo: tipo, p_monto: monto, p_concepto: tipo,
        }),
      ).then((r) => r[0])
    await movimiento('gasto', 6000)
    await movimiento('ingreso', 1500)
    const balon = await movimiento('gasto', 10000)
    await como(db, e.organizador, (tx) => rpc(tx, 'anular_movimiento', { p_movimiento: balon.id }))

    const [caja] = await como(db, e.organizador, (tx) => rpc(tx, 'caja', { p_grupo: e.grupoId }))
    expect(caja).toEqual({ pagos: 8000, ingresos: 1500, gastos: 6000, saldo: 3500 })
  })
})
