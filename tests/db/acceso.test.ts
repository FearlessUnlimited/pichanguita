import { beforeAll, describe, expect, it } from 'vitest'
import { como, crearBase, crearUsuario, rpc, type Base, type Quien } from './arnes'
import { anotar, escenario, type Escenario, type Usuario } from './escenario'

const PRIVADAS = [
  'grupos',
  'grupo_datos_pago',
  'horarios',
  'miembros',
  'miembros_privado',
  'partidos',
  'inscripciones',
  'cargos',
  'pagos',
  'movimientos_caja',
  'actividad',
]

async function contar(db: Base, quien: Quien, tabla: string) {
  const [{ n }] = await como(db, quien, async (tx) => (await tx.query<{ n: number }>(`select count(*)::int as n from public.${tabla}`)).rows)
  return n
}

// Un grupo con plata registrada, un postulante y un intruso que organiza su propio grupo. Las pruebas solo
// leen, así que comparten la misma base.
describe('lo que cada uno puede leer', () => {
  let db: Base
  let e: Escenario
  let postulante: Usuario
  let intruso: Usuario

  beforeAll(async () => {
    db = await crearBase()
    e = await escenario(db, { cupos: 14, jugadores: ['Pato', 'Feña'] })
    const pato = e.jugadores.Pato
    await anotar(db, pato.usuario, e.partidoId)
    await anotar(db, e.jugadores['Feña'].usuario, e.partidoId)
    await como(db, e.organizador, async (tx) => {
      await rpc(tx, 'guardar_datos_pago', {
        p_grupo: e.grupoId, p_titular: 'Nico', p_rut: '11.111.111-1', p_banco: 'Banco', p_tipo_cuenta: 'Vista',
        p_numero_cuenta: '123', p_correo: 'nico@ejemplo.cl',
      })
      await rpc(tx, 'guardar_telefono', { p_miembro: e.jugadores['Feña'].miembroId, p_telefono: '912345678' })
      await rpc(tx, 'cerrar_partido', { p_partido: e.partidoId })
      await rpc(tx, 'registrar_pago', {
        p_id: crypto.randomUUID(), p_grupo: e.grupoId, p_miembro: e.jugadores['Feña'].miembroId,
        p_monto: 4000, p_medio: 'efectivo',
      })
      await rpc(tx, 'registrar_movimiento', {
        p_id: crypto.randomUUID(), p_grupo: e.grupoId, p_tipo: 'gasto', p_monto: 56000, p_concepto: 'Cancha',
      })
      await rpc(tx, 'actualizar_grupo', { p_grupo: e.grupoId, p_requiere_aprobacion: true })
    })
    await como(db, pato.usuario, (tx) =>
      rpc(tx, 'guardar_telefono', { p_miembro: pato.miembroId, p_telefono: '987654321' }),
    )
    postulante = await crearUsuario(db, { anonimo: true })
    await como(db, postulante, (tx) => rpc(tx, 'unirse', { p_codigo: e.codigo, p_nombre: 'Rodrigo' }))
    intruso = (await escenario(db)).organizador
  })

  it('sin sesión no se lee ninguna tabla privada, solo el directorio de canchas y los planes', async () => {
    for (const tabla of PRIVADAS) {
      await expect(contar(db, { tipo: 'anon' }, tabla), tabla).rejects.toThrow('permission denied')
    }
    await expect(contar(db, { tipo: 'anon' }, 'planes')).resolves.toBe(1)
    await expect(
      como(db, { tipo: 'anon' }, (tx) => tx.query('select id, nombre, comuna, verificada from public.canchas')),
    ).resolves.toBeTruthy()
  })

  it('el organizador de otro grupo no ve nada de este', async () => {
    const { rows } = await como(db, intruso, (tx) =>
      tx.query<{ id: string }>('select id from public.grupos where id = $1', [e.grupoId]),
    )
    expect(rows).toHaveLength(0)
    for (const tabla of PRIVADAS) {
      const columna = tabla === 'grupos' ? 'id' : 'grupo_id'
      const { rows: filas } = await como(db, intruso, (tx) =>
        tx.query(`select 1 from public.${tabla} where ${columna} = $1`, [e.grupoId]),
      )
      expect(filas, tabla).toHaveLength(0)
    }
  })

  it('un jugador ve el grupo, la lista y los datos de transferencia, pero no la plata ajena ni la actividad', async () => {
    const pato = e.jugadores.Pato.usuario
    expect(await contar(db, pato, 'grupos')).toBe(1)
    expect(await contar(db, pato, 'grupo_datos_pago')).toBe(1)
    expect(await contar(db, pato, 'horarios')).toBe(1)
    expect(await contar(db, pato, 'partidos')).toBe(1)
    expect(await contar(db, pato, 'inscripciones')).toBe(2)
    expect(await contar(db, pato, 'actividad')).toBe(0)
    expect(await contar(db, pato, 'movimientos_caja')).toBe(0)
    // Solo su propio cargo y su propio teléfono.
    const { rows: cargos } = await como(db, pato, (tx) => tx.query<{ miembro_id: string }>('select miembro_id from public.cargos'))
    expect(cargos).toEqual([{ miembro_id: e.jugadores.Pato.miembroId }])
    expect(await contar(db, pato, 'pagos')).toBe(0)
    const { rows: privados } = await como(db, pato, (tx) => tx.query<{ telefono: string }>('select telefono from public.miembros_privado'))
    expect(privados).toEqual([{ telefono: '56987654321' }])
  })

  it('un jugador ve a los miembros activos pero no a los postulantes', async () => {
    const { rows } = await como(db, e.jugadores.Pato.usuario, (tx) =>
      tx.query<{ nombre: string }>('select nombre from public.miembros order by nombre'),
    )
    expect(rows.map((r) => r.nombre)).toEqual(['Feña', 'Nico', 'Pato'])
    const { rows: delOrg } = await como(db, e.organizador, (tx) =>
      tx.query<{ nombre: string }>("select nombre from public.miembros where estado = 'pendiente'"),
    )
    expect(delOrg).toEqual([{ nombre: 'Rodrigo' }])
  })

  it('un postulante ve el grupo y a sí mismo, nada más', async () => {
    expect(await contar(db, postulante, 'grupos')).toBe(1)
    expect(await contar(db, postulante, 'miembros')).toBe(1)
    for (const tabla of ['horarios', 'partidos', 'inscripciones', 'grupo_datos_pago', 'cargos']) {
      expect(await contar(db, postulante, tabla), tabla).toBe(0)
    }
  })

  it('el organizador ve la plata de todos y la actividad', async () => {
    expect(await contar(db, e.organizador, 'cargos')).toBe(2)
    expect(await contar(db, e.organizador, 'pagos')).toBe(1)
    expect(await contar(db, e.organizador, 'movimientos_caja')).toBe(1)
    expect(await contar(db, e.organizador, 'miembros_privado')).toBe(2)
    expect(await contar(db, e.organizador, 'actividad')).toBeGreaterThan(0)
  })

  it('nadie lee qué usuario está detrás de cada miembro ni quién creó cada cancha', async () => {
    const pato = e.jugadores.Pato.usuario
    await expect(como(db, pato, (tx) => tx.query('select auth_user_id from public.miembros'))).rejects.toThrow(
      'permission denied',
    )
    await expect(como(db, pato, (tx) => tx.query('select * from public.miembros'))).rejects.toThrow('permission denied')
    await expect(
      como(db, pato, (tx) => tx.query('select id, nombre, rol, estado, tiene_celular from public.miembros')),
    ).resolves.toBeTruthy()
    await expect(como(db, pato, (tx) => tx.query('select creada_por from public.canchas'))).rejects.toThrow(
      'permission denied',
    )
  })

  it('"mis grupos" devuelve solo los del usuario', async () => {
    const filas = await como(db, e.jugadores.Pato.usuario, (tx) => rpc<{ grupo_id: string; rol: string }>(tx, 'mis_grupos'))
    expect(filas).toEqual([expect.objectContaining({ grupo_id: e.grupoId, rol: 'jugador', estado: 'activo' })])
  })

  it('nadie escribe directo en las tablas ni toca el esquema interno', async () => {
    const pato = e.jugadores.Pato.usuario
    const intentos = [
      `insert into public.inscripciones (partido_id, grupo_id, miembro_id, estado)
       values ('${e.partidoId}', '${e.grupoId}', '${e.jugadores.Pato.miembroId}', 'confirmado')`,
      `update public.partidos set cupos = 40`,
      `update public.grupos set deudas_visibles = true`,
      `delete from public.miembros`,
      `insert into public.pagos (id, grupo_id, miembro_id, monto, medio, estado)
       values (gen_random_uuid(), '${e.grupoId}', '${e.jugadores.Pato.miembroId}', 1, 'efectivo', 'confirmado')`,
      `select * from interno.enlaces_personales`,
      `select interno.generar_partidos()`,
    ]
    for (const sql of intentos) {
      await expect(como(db, pato, (tx) => tx.query(sql)), sql).rejects.toThrow('permission denied')
      await expect(como(db, e.organizador, (tx) => tx.query(sql)), sql).rejects.toThrow('permission denied')
    }
  })

  it('sin sesión solo se puede llamar a la vista del link del grupo', async () => {
    await expect(
      como(db, { tipo: 'anon' }, (tx) => rpc(tx, 'unirse', { p_codigo: e.codigo, p_nombre: 'Colado' })),
    ).rejects.toThrow('permission denied')
    await expect(como(db, { tipo: 'anon' }, (tx) => rpc(tx, 'mis_grupos'))).rejects.toThrow('permission denied')
    await expect(
      como(db, { tipo: 'anon' }, (tx) => rpc(tx, 'vista_invitacion', { p_codigo: e.codigo })),
    ).resolves.toHaveLength(1)
  })
})

describe('deudas visibles para todo el grupo', () => {
  it('apagado por defecto; al activarlo todos ven cargos, pagos, saldos y caja', async () => {
    const db = await crearBase()
    const e = await escenario(db, { jugadores: ['Pato', 'Feña'] })
    await anotar(db, e.jugadores.Pato.usuario, e.partidoId)
    await anotar(db, e.jugadores['Feña'].usuario, e.partidoId)
    await como(db, e.organizador, (tx) => rpc(tx, 'cerrar_partido', { p_partido: e.partidoId }))
    const pato = e.jugadores.Pato.usuario

    expect(await como(db, pato, (tx) => rpc(tx, 'saldos', { p_grupo: e.grupoId }))).toHaveLength(1)
    await expect(como(db, pato, (tx) => rpc(tx, 'caja', { p_grupo: e.grupoId }))).rejects.toThrow('no_autorizado')

    await como(db, e.organizador, (tx) => rpc(tx, 'actualizar_grupo', { p_grupo: e.grupoId, p_deudas_visibles: true }))
    expect(await contar(db, pato, 'cargos')).toBe(2)
    expect(await como(db, pato, (tx) => rpc(tx, 'saldos', { p_grupo: e.grupoId }))).toHaveLength(3)
    await expect(como(db, pato, (tx) => rpc(tx, 'caja', { p_grupo: e.grupoId }))).resolves.toHaveLength(1)
  })
})
