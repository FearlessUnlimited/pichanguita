import { beforeEach, describe, expect, it } from 'vitest'
import { como, crearBase, crearUsuario, rpc, type Base } from './arnes'
import { anotar, escenario, inscripcionDe, lista, unir, type Escenario, type Usuario } from './escenario'

type Union = { resultado: string; grupo_id: string; miembro_id: string | null }

function unirse(db: Base, quien: Usuario, codigo: string, nombre: string, esYo = false) {
  return como(db, quien, (tx) =>
    rpc<Union>(tx, 'unirse', { p_codigo: codigo, p_nombre: nombre, p_es_yo: esYo }),
  ).then((r) => r[0])
}

async function miembro(db: Base, id: string) {
  const { rows } = await db.query<{ nombre: string; estado: string; rol: string; auth_user_id: string | null }>(
    'select nombre, estado, rol, auth_user_id from public.miembros where id = $1',
    [id],
  )
  return rows[0]
}

async function actividad(db: Base, grupoId: string, tipo: string) {
  const { rows } = await db.query<{ miembro_id: string; datos: Record<string, unknown> }>(
    'select miembro_id, datos from public.actividad where grupo_id = $1 and tipo = $2 order by id',
    [grupoId, tipo],
  )
  return rows
}

describe('crear el grupo', () => {
  let db: Base
  beforeEach(async () => {
    db = await crearBase()
  })

  const grupo = {
    p_nombre: 'Los del jueves',
    p_formato: 'futbol7',
    p_nombre_organizador: 'Nico',
    p_dia_semana: 4,
    p_hora: '21:00',
    p_cupos: 14,
    p_cuota: 4000,
  }

  it('deja al creador como organizador, con la pichanga fija y el primer partido abierto', async () => {
    const org = await crearUsuario(db, { email: 'nico@ejemplo.cl' })
    const [g] = await como(db, org, (tx) => rpc<{ id: string; codigo_invitacion: string }>(tx, 'crear_grupo', grupo))
    expect(g.codigo_invitacion).toMatch(/^[A-Za-z0-9_-]{11}$/)
    const { rows } = await db.query<{ rol: string; inicio: Date; estado: string }>(
      `select m.rol, p.inicio, p.estado from public.miembros m join public.partidos p on p.grupo_id = m.grupo_id
       where m.grupo_id = $1`,
      [g.id],
    )
    expect(rows).toHaveLength(1)
    expect(rows[0].rol).toBe('organizador')
    expect(rows[0].estado).toBe('abierto')
    expect(rows[0].inicio.getTime()).toBeGreaterThan(Date.now() - 60_000)
  })

  it('exige cuenta: un celular con sesión anónima no organiza y sin sesión ni siquiera puede llamar', async () => {
    const anonimo = await crearUsuario(db, { anonimo: true })
    await expect(como(db, anonimo, (tx) => rpc(tx, 'crear_grupo', grupo))).rejects.toThrow('requiere_cuenta')
    await expect(como(db, { tipo: 'anon' }, (tx) => rpc(tx, 'crear_grupo', grupo))).rejects.toThrow(
      'permission denied',
    )
  })

  it('rechaza datos inválidos', async () => {
    const org = await crearUsuario(db, { email: 'nico@ejemplo.cl' })
    await expect(como(db, org, (tx) => rpc(tx, 'crear_grupo', { ...grupo, p_cupos: 1 }))).rejects.toThrow(
      'datos_invalidos',
    )
    await expect(como(db, org, (tx) => rpc(tx, 'crear_grupo', { ...grupo, p_formato: 'tenis' }))).rejects.toThrow(
      'datos_invalidos',
    )
  })
})

describe('link del grupo antes de anotarse', () => {
  let db: Base
  let e: Escenario
  beforeEach(async () => {
    db = await crearBase()
    e = await escenario(db, { cupos: 14, jugadores: ['Pato', 'Feña'] })
    await anotar(db, e.jugadores.Pato.usuario, e.partidoId)
    await anotar(db, e.jugadores['Feña'].usuario, e.partidoId)
  })

  it('muestra grupo, día, hora y cupos ocupados sin nombres de jugadores, aun sin sesión', async () => {
    const [v] = await como(db, { tipo: 'anon' }, (tx) => rpc(tx, 'vista_invitacion', { p_codigo: e.codigo }))
    expect(v).toMatchObject({ grupo_nombre: 'Pichanga de los jueves', dia_semana: 4, hora: '21:00:00', cupos: 14, ocupados: 2 })
    expect(JSON.stringify(v)).not.toMatch(/Pato|Feña|Nico/)
  })

  it('un código que no existe no revela nada', async () => {
    await expect(
      como(db, { tipo: 'anon' }, (tx) => rpc(tx, 'vista_invitacion', { p_codigo: 'no-existe' })),
    ).rejects.toThrow('codigo_invalido')
  })

  it('rotar el código deja inservible el link anterior', async () => {
    const [{ rotar_codigo: nuevo }] = await como(db, e.organizador, (tx) =>
      rpc<{ rotar_codigo: string }>(tx, 'rotar_codigo', { p_grupo: e.grupoId }),
    )
    expect(nuevo).not.toBe(e.codigo)
    await expect(unir(db, e.codigo, 'Seba')).rejects.toThrow('codigo_invalido')
    await expect(unir(db, nuevo, 'Seba')).resolves.toBeTruthy()
  })
})

describe('anotarse en el grupo con el nombre', () => {
  let db: Base
  let e: Escenario
  beforeEach(async () => {
    db = await crearBase()
    e = await escenario(db, { jugadores: ['Pato'] })
  })

  it('un nombre nuevo entra como jugador activo, y repetir no crea otro miembro', async () => {
    const yo = await crearUsuario(db, { anonimo: true })
    const r1 = await unirse(db, yo, e.codigo, 'Seba')
    expect(r1.resultado).toBe('unido')
    const r2 = await unirse(db, yo, e.codigo, 'Otro nombre')
    expect(r2).toMatchObject({ resultado: 'ya_eras_miembro', miembro_id: r1.miembro_id })
    expect(await miembro(db, r1.miembro_id!)).toMatchObject({ nombre: 'Seba', rol: 'jugador', estado: 'activo' })
  })

  it('valida el nombre', async () => {
    const yo = await crearUsuario(db, { anonimo: true })
    await expect(unirse(db, yo, e.codigo, ' x ')).rejects.toThrow('nombre_invalido')
  })

  it('"¿Eres tú?": un nombre agregado por el organizador, sin celular, se vincula solo si confirma', async () => {
    const [{ miembro_id: jose }] = await como(db, e.organizador, (tx) =>
      rpc<{ miembro_id: string }>(tx, 'agregar_miembros', { p_grupo: e.grupoId, p_nombres: ['José Pérez'] }),
    )
    const yo = await crearUsuario(db, { anonimo: true })
    // Sin tildes, con mayúsculas y espacios de más: es el mismo nombre.
    expect(await unirse(db, yo, e.codigo, '  JOSE   perez ')).toMatchObject({ resultado: 'nombre_sin_celular', miembro_id: null })
    // Sin una confirmación explícita (true), nunca vincula.
    const [sinRespuesta] = await como(db, yo, (tx) =>
      rpc<Union>(tx, 'unirse', { p_codigo: e.codigo, p_nombre: 'José Pérez', p_es_yo: null }),
    )
    expect(sinRespuesta.resultado).toBe('nombre_sin_celular')
    expect((await miembro(db, jose)).auth_user_id).toBeNull()

    expect(await unirse(db, yo, e.codigo, 'jose perez', true)).toMatchObject({ resultado: 'vinculado', miembro_id: jose })
    expect((await miembro(db, jose)).auth_user_id).toBe(yo.id)
    expect(await actividad(db, e.grupoId, 'vinculacion')).toEqual([
      { miembro_id: jose, datos: { via: 'nombre' } },
    ])

    // Ya tiene celular: otro con el mismo nombre no puede quedarse con él.
    const otro = await crearUsuario(db, { anonimo: true })
    expect(await unirse(db, otro, e.codigo, 'José Pérez', true)).toMatchObject({ resultado: 'nombre_con_celular' })
  })

  it('nadie se vincula por nombre a un organizador', async () => {
    const yo = await crearUsuario(db, { anonimo: true })
    expect(await unirse(db, yo, e.codigo, 'nico', true)).toMatchObject({ resultado: 'nombre_con_celular' })
  })

  it('el organizador deshace una vinculación y ese celular deja de actuar como el jugador', async () => {
    await como(db, e.organizador, (tx) => rpc(tx, 'desvincular', { p_miembro: e.jugadores.Pato.miembroId }))
    expect((await miembro(db, e.jugadores.Pato.miembroId)).auth_user_id).toBeNull()
    await expect(anotar(db, e.jugadores.Pato.usuario, e.partidoId)).rejects.toThrow('no_autorizado')
    expect(await actividad(db, e.grupoId, 'desvinculacion')).toHaveLength(1)
  })

  it('con aprobación activada queda como postulante hasta que el organizador lo acepte', async () => {
    await como(db, e.organizador, (tx) => rpc(tx, 'actualizar_grupo', { p_grupo: e.grupoId, p_requiere_aprobacion: true }))
    const yo = await crearUsuario(db, { anonimo: true })
    const r = await unirse(db, yo, e.codigo, 'Rodrigo')
    expect(r.resultado).toBe('pendiente')
    await expect(anotar(db, yo, e.partidoId)).rejects.toThrow('no_autorizado')

    await como(db, e.organizador, (tx) => rpc(tx, 'responder_postulante', { p_miembro: r.miembro_id, p_aprobar: true }))
    expect((await anotar(db, yo, e.partidoId)).estado).toBe('confirmado')
  })

  it('un postulante rechazado o un jugador quitado no vuelve a entrar desde el mismo celular', async () => {
    await como(db, e.organizador, (tx) => rpc(tx, 'quitar_miembro', { p_miembro: e.jugadores.Pato.miembroId }))
    await expect(unirse(db, e.jugadores.Pato.usuario, e.codigo, 'Pato')).rejects.toThrow('no_admitido')

    await como(db, e.organizador, (tx) => rpc(tx, 'actualizar_grupo', { p_grupo: e.grupoId, p_requiere_aprobacion: true }))
    const yo = await crearUsuario(db, { anonimo: true })
    const r = await unirse(db, yo, e.codigo, 'Tito')
    await como(db, e.organizador, (tx) => rpc(tx, 'responder_postulante', { p_miembro: r.miembro_id, p_aprobar: false }))
    await expect(unirse(db, yo, e.codigo, 'Tito')).rejects.toThrow('no_admitido')
  })

  it('quitar a un jugador lo saca del próximo partido y su cupo pasa a la banca', async () => {
    await db.query('update public.partidos set cupos = 2 where id = $1', [e.partidoId])
    const seba = await unir(db, e.codigo, 'Seba')
    await anotar(db, e.organizador, e.partidoId)
    await anotar(db, e.jugadores.Pato.usuario, e.partidoId)
    await anotar(db, seba.usuario, e.partidoId)
    await como(db, e.organizador, (tx) => rpc(tx, 'quitar_miembro', { p_miembro: e.jugadores.Pato.miembroId }))
    expect(await lista(db, e.partidoId)).toEqual(['Nico:confirmado', 'Pato:baja', 'Seba:ofrecido'])
  })

  it('agregar a mano omite repetidos e inválidos', async () => {
    const agregados = await como(db, e.organizador, (tx) =>
      rpc<{ nombre: string }>(tx, 'agregar_miembros', {
        p_grupo: e.grupoId,
        p_nombres: ['Feña', 'pato', 'Feña', '', 'Tito'],
      }),
    )
    expect(agregados.map((a) => a.nombre)).toEqual(['Feña', 'Tito'])
  })

  it('un jugador no puede usar las funciones del organizador', async () => {
    const pato = e.jugadores.Pato.usuario
    await expect(
      como(db, pato, (tx) => rpc(tx, 'agregar_miembros', { p_grupo: e.grupoId, p_nombres: ['X Y'] })),
    ).rejects.toThrow('no_autorizado')
    await expect(como(db, pato, (tx) => rpc(tx, 'rotar_codigo', { p_grupo: e.grupoId }))).rejects.toThrow('no_autorizado')
    await expect(
      como(db, pato, (tx) => rpc(tx, 'actualizar_grupo', { p_grupo: e.grupoId, p_deudas_visibles: true })),
    ).rejects.toThrow('no_autorizado')
  })
})

describe('roles', () => {
  let db: Base
  let e: Escenario
  beforeEach(async () => {
    db = await crearBase()
    e = await escenario(db, { jugadores: ['Pato', 'Feña'] })
  })

  it('el organizador nombra co-organizadores, que administran pero no cambian roles', async () => {
    const pato = e.jugadores.Pato
    await como(db, e.organizador, (tx) => rpc(tx, 'cambiar_rol', { p_miembro: pato.miembroId, p_rol: 'coorganizador' }))
    await expect(
      como(db, pato.usuario, (tx) => rpc(tx, 'agregar_miembros', { p_grupo: e.grupoId, p_nombres: ['Tito'] })),
    ).resolves.toHaveLength(1)
    await expect(
      como(db, pato.usuario, (tx) =>
        rpc(tx, 'cambiar_rol', { p_miembro: e.jugadores['Feña'].miembroId, p_rol: 'coorganizador' }),
      ),
    ).rejects.toThrow('no_autorizado')
    // Un co-organizador no puede quitar al organizador.
    await expect(
      como(db, pato.usuario, (tx) => rpc(tx, 'quitar_miembro', { p_miembro: e.organizadorId })),
    ).rejects.toThrow('no_autorizado')
  })

  it('el organizador no cambia su propio rol', async () => {
    await expect(
      como(db, e.organizador, (tx) => rpc(tx, 'cambiar_rol', { p_miembro: e.organizadorId, p_rol: 'jugador' })),
    ).rejects.toThrow('no_autorizado')
  })
})

describe('link personal', () => {
  let db: Base
  let e: Escenario
  let jose: string
  beforeEach(async () => {
    db = await crearBase()
    e = await escenario(db, { jugadores: ['Pato'] })
    ;[{ miembro_id: jose }] = await como(db, e.organizador, (tx) =>
      rpc<{ miembro_id: string }>(tx, 'agregar_miembros', { p_grupo: e.grupoId, p_nombres: ['José'] }),
    )
  })

  async function generar(miembroId: string) {
    const [{ generar_link_personal: token }] = await como(db, e.organizador, (tx) =>
      rpc<{ generar_link_personal: string }>(tx, 'generar_link_personal', { p_miembro: miembroId }),
    )
    return token
  }

  function usar(quien: Usuario, token: string) {
    return como(db, quien, (tx) => rpc<{ miembro_id: string }>(tx, 'usar_link_personal', { p_token: token }))
  }

  it('vincula el celular y sirve una sola vez; en la base queda solo el hash', async () => {
    const token = await generar(jose)
    expect(token).toMatch(/^[A-Za-z0-9_-]{22}$/)
    const { rows } = await db.query<{ token_hash: string }>('select token_hash from interno.enlaces_personales')
    expect(rows[0].token_hash).not.toContain(token)

    const celular = await crearUsuario(db, { anonimo: true })
    expect((await usar(celular, token))[0].miembro_id).toBe(jose)
    expect((await miembro(db, jose)).auth_user_id).toBe(celular.id)
    await expect(usar(celular, token)).rejects.toThrow('link_invalido')
  })

  it('al cambiar de celular, el anterior queda desvinculado', async () => {
    const pato = e.jugadores.Pato
    const nuevo = await crearUsuario(db, { anonimo: true })
    await usar(nuevo, await generar(pato.miembroId))
    expect((await miembro(db, pato.miembroId)).auth_user_id).toBe(nuevo.id)
    await expect(anotar(db, pato.usuario, e.partidoId)).rejects.toThrow('no_autorizado')
    expect((await anotar(db, nuevo, e.partidoId)).estado).toBe('confirmado')
    const [registro] = await actividad(db, e.grupoId, 'vinculacion')
    expect(registro.datos).toEqual({ via: 'link_personal', tenia_celular: true })
  })

  it('si el celular ya era otro miembro del grupo, ese otro queda sin celular', async () => {
    const pato = e.jugadores.Pato
    await usar(pato.usuario, await generar(jose))
    expect((await miembro(db, jose)).auth_user_id).toBe(pato.usuario.id)
    expect((await miembro(db, pato.miembroId)).auth_user_id).toBeNull()
  })

  it('un link vencido o reemplazado no sirve', async () => {
    const viejo = await generar(jose)
    const nuevo = await generar(jose)
    const celular = await crearUsuario(db, { anonimo: true })
    await expect(usar(celular, viejo)).rejects.toThrow('link_invalido')
    await db.query("update interno.enlaces_personales set vence_at = now() - interval '1 minute'")
    await expect(usar(celular, nuevo)).rejects.toThrow('link_invalido')
  })

  it('solo el organizador genera links', async () => {
    await expect(
      como(db, e.jugadores.Pato.usuario, (tx) => rpc(tx, 'generar_link_personal', { p_miembro: jose })),
    ).rejects.toThrow('no_autorizado')
  })
})

describe('borrar los datos de un jugador', () => {
  it('queda como "Jugador borrado", sin celular ni teléfono, y sale de los próximos partidos', async () => {
    const db = await crearBase()
    const e = await escenario(db, { jugadores: ['Pato'] })
    const pato = e.jugadores.Pato
    await como(db, pato.usuario, (tx) => rpc(tx, 'guardar_telefono', { p_miembro: pato.miembroId, p_telefono: '9 1234 5678' }))
    await anotar(db, pato.usuario, e.partidoId)

    await como(db, e.organizador, (tx) => rpc(tx, 'borrar_miembro', { p_miembro: pato.miembroId }))
    expect(await miembro(db, pato.miembroId)).toMatchObject({ nombre: 'Jugador borrado', estado: 'retirado', auth_user_id: null })
    const { rows } = await db.query('select * from public.miembros_privado where miembro_id = $1', [pato.miembroId])
    expect(rows).toHaveLength(0)
    expect((await inscripcionDe(db, e.partidoId, pato.miembroId)).estado).toBe('baja')
    // El nombre queda libre para otra persona.
    await expect(unir(db, e.codigo, 'Pato')).resolves.toBeTruthy()
  })
})
