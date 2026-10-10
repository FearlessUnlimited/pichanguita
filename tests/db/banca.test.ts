import { beforeEach, describe, expect, it } from 'vitest'
import { como, crearBase, rpc, type Base } from './arnes'
import { anotar, escenario, inscripcionDe, lista, type Escenario, type Inscripcion, type Usuario } from './escenario'

function bajarse(db: Base, quien: Usuario, inscripcionId: string) {
  return como(db, quien, (tx) => rpc<Inscripcion>(tx, 'bajarse', { p_inscripcion: inscripcionId })).then((r) => r[0])
}

function responder(db: Base, quien: Usuario, inscripcionId: string, acepta: boolean) {
  return como(db, quien, (tx) =>
    rpc<Inscripcion>(tx, 'responder_oferta', { p_inscripcion: inscripcionId, p_acepta: acepta }),
  ).then((r) => r[0])
}

async function vencerOfertas(db: Base) {
  await db.query("update public.inscripciones set oferta_vence_at = now() - interval '1 minute' where estado = 'ofrecido'")
  const { rows } = await db.query<{ n: number }>('select interno.vencer_ofertas() as n')
  return rows[0].n
}

async function ocupados(db: Base, partidoId: string) {
  const { rows } = await db.query<{ n: number; cupos: number }>(
    `select count(*) filter (where i.estado in ('confirmado', 'ofrecido'))::int as n, p.cupos
     from public.partidos p left join public.inscripciones i on i.partido_id = p.id
     where p.id = $1 group by p.cupos`,
    [partidoId],
  )
  return rows[0]
}

describe('banca por orden de llegada', () => {
  let db: Base
  let e: Escenario
  // Cupos 3: Nico, Pato y Feña juegan; Seba y Tito quedan en la banca, en ese orden.
  beforeEach(async () => {
    db = await crearBase()
    e = await escenario(db, { cupos: 3, jugadores: ['Pato', 'Feña', 'Seba', 'Tito'] })
    await anotar(db, e.organizador, e.partidoId)
    for (const nombre of ['Pato', 'Feña', 'Seba', 'Tito']) {
      await anotar(db, e.jugadores[nombre].usuario, e.partidoId)
    }
  })

  const insc = (nombre: string) => inscripcionDe(db, e.partidoId, e.jugadores[nombre].miembroId)

  it('llena los cupos y el resto queda en la banca, en orden', async () => {
    expect(await lista(db, e.partidoId)).toEqual([
      'Nico:confirmado',
      'Pato:confirmado',
      'Feña:confirmado',
      'Seba:banca',
      'Tito:banca',
    ])
  })

  it('anotarse dos veces no cambia nada', async () => {
    await anotar(db, e.jugadores.Pato.usuario, e.partidoId)
    await anotar(db, e.jugadores.Seba.usuario, e.partidoId)
    expect(await lista(db, e.partidoId)).toEqual([
      'Nico:confirmado',
      'Pato:confirmado',
      'Feña:confirmado',
      'Seba:banca',
      'Tito:banca',
    ])
  })

  it('si alguien se baja, el cupo se ofrece al primero de la banca con el plazo del grupo', async () => {
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    expect(await lista(db, e.partidoId)).toEqual([
      'Nico:confirmado',
      'Pato:baja',
      'Feña:confirmado',
      'Seba:ofrecido',
      'Tito:banca',
    ])
    const vence = (await insc('Seba')).oferta_vence_at!.getTime()
    expect(vence - Date.now()).toBeGreaterThan(119 * 60_000)
    expect(vence - Date.now()).toBeLessThan(121 * 60_000)
    const { rows } = await db.query("select miembro_id from public.actividad where tipo = 'oferta'")
    expect(rows).toEqual([{ miembro_id: e.jugadores.Seba.miembroId }])
  })

  it('el plazo de la oferta nunca pasa del inicio del partido', async () => {
    await db.query("update public.partidos set inicio = now() + interval '30 minutes' where id = $1", [e.partidoId])
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    const { rows } = await db.query<{ igual: boolean }>(
      `select i.oferta_vence_at = p.inicio as igual from public.inscripciones i
       join public.partidos p on p.id = i.partido_id where i.estado = 'ofrecido'`,
    )
    expect(rows).toEqual([{ igual: true }])
  })

  it('aceptar la oferta confirma; "Voy" con una oferta pendiente también', async () => {
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    expect((await responder(db, e.jugadores.Seba.usuario, (await insc('Seba')).id, true)).estado).toBe('confirmado')

    await bajarse(db, e.jugadores['Feña'].usuario, (await insc('Feña')).id)
    expect((await anotar(db, e.jugadores.Tito.usuario, e.partidoId)).estado).toBe('confirmado')
  })

  it('rechazar la oferta vuelve al final de la banca y el cupo pasa al siguiente', async () => {
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    await responder(db, e.jugadores.Seba.usuario, (await insc('Seba')).id, false)
    expect(await lista(db, e.partidoId)).toEqual([
      'Nico:confirmado',
      'Pato:baja',
      'Feña:confirmado',
      'Tito:ofrecido',
      'Seba:banca',
    ])
  })

  it('una oferta vencida vuelve al final de la banca y el cupo pasa al siguiente', async () => {
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    expect(await vencerOfertas(db)).toBe(1)
    expect(await lista(db, e.partidoId)).toEqual([
      'Nico:confirmado',
      'Pato:baja',
      'Feña:confirmado',
      'Tito:ofrecido',
      'Seba:banca',
    ])
    // Vence también la de Tito: ahora le toca de nuevo a Seba, que quedó primero.
    expect(await vencerOfertas(db)).toBe(1)
    expect(await lista(db, e.partidoId)).toEqual([
      'Nico:confirmado',
      'Pato:baja',
      'Feña:confirmado',
      'Seba:ofrecido',
      'Tito:banca',
    ])
  })

  it('aceptar una oferta que ya venció no confirma: vuelve a la banca', async () => {
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    await db.query("update public.inscripciones set oferta_vence_at = now() - interval '1 second' where estado = 'ofrecido'")
    expect((await responder(db, e.jugadores.Seba.usuario, (await insc('Seba')).id, true)).estado).toBe('banca')
    expect((await insc('Tito')).estado).toBe('ofrecido')
  })

  it('si el único de la banca rechaza, el cupo queda libre y puede tomarlo después o tomarlo otro', async () => {
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    await responder(db, e.jugadores.Seba.usuario, (await insc('Seba')).id, true)
    await bajarse(db, e.jugadores['Feña'].usuario, (await insc('Feña')).id)
    await responder(db, e.jugadores.Tito.usuario, (await insc('Tito')).id, false)
    expect((await insc('Tito')).estado).toBe('banca')
    expect(await ocupados(db, e.partidoId)).toEqual({ n: 2, cupos: 3 })

    expect((await anotar(db, e.jugadores.Tito.usuario, e.partidoId)).estado).toBe('confirmado')
  })

  it('volver a anotarse después de bajarse va al final de la cola', async () => {
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    await responder(db, e.jugadores.Seba.usuario, (await insc('Seba')).id, true)
    expect((await anotar(db, e.jugadores.Pato.usuario, e.partidoId)).estado).toBe('banca')
    expect(await lista(db, e.partidoId)).toEqual([
      'Nico:confirmado',
      'Feña:confirmado',
      'Seba:confirmado',
      'Tito:banca',
      'Pato:banca',
    ])
  })

  it('un jugador solo responde y se baja por sí mismo; el organizador puede por cualquiera', async () => {
    const pato = e.jugadores.Pato.usuario
    await expect(bajarse(db, pato, (await insc('Feña')).id)).rejects.toThrow('no_autorizado')
    await expect(anotar(db, pato, e.partidoId, e.jugadores.Seba.miembroId)).rejects.toThrow('no_autorizado')

    await bajarse(db, e.organizador, (await insc('Feña')).id)
    await expect(responder(db, pato, (await insc('Seba')).id, true)).rejects.toThrow('no_autorizado')
    expect((await responder(db, e.organizador, (await insc('Seba')).id, true)).estado).toBe('confirmado')
  })

  it('subir los cupos ofrece a la banca; bajarlos por debajo de los ocupados no se puede', async () => {
    await como(db, e.organizador, (tx) => rpc(tx, 'cambiar_cupos', { p_partido: e.partidoId, p_cupos: 5 }))
    expect((await insc('Seba')).estado).toBe('ofrecido')
    expect((await insc('Tito')).estado).toBe('ofrecido')
    await expect(
      como(db, e.organizador, (tx) => rpc(tx, 'cambiar_cupos', { p_partido: e.partidoId, p_cupos: 4 })),
    ).rejects.toThrow('cupos_ocupados')
    await expect(
      como(db, e.jugadores.Pato.usuario, (tx) => rpc(tx, 'cambiar_cupos', { p_partido: e.partidoId, p_cupos: 6 })),
    ).rejects.toThrow('no_autorizado')
  })

  it('después del inicio el jugador ya no se anota y no se ofrecen cupos; el organizador sí puede anotar', async () => {
    await db.query("update public.partidos set inicio = now() - interval '10 minutes' where id = $1", [e.partidoId])
    await bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)
    expect((await insc('Seba')).estado).toBe('banca')
    await expect(anotar(db, e.jugadores.Pato.usuario, e.partidoId)).rejects.toThrow('partido_empezado')
    expect((await anotar(db, e.organizador, e.partidoId, e.jugadores.Seba.miembroId)).estado).toBe('confirmado')
  })

  it('un partido cerrado o cancelado no acepta cambios', async () => {
    await como(db, e.organizador, (tx) => rpc(tx, 'cancelar_partido', { p_partido: e.partidoId }))
    await expect(anotar(db, e.jugadores.Seba.usuario, e.partidoId)).rejects.toThrow('partido_cerrado')
    await expect(bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id)).rejects.toThrow('partido_cerrado')
  })

  it('nunca hay más ocupados que cupos', async () => {
    const pasos: Array<() => Promise<unknown>> = [
      async () => bajarse(db, e.jugadores.Pato.usuario, (await insc('Pato')).id),
      async () => anotar(db, e.jugadores.Pato.usuario, e.partidoId),
      async () => responder(db, e.jugadores.Seba.usuario, (await insc('Seba')).id, true),
      async () => bajarse(db, e.jugadores['Feña'].usuario, (await insc('Feña')).id),
      async () => anotar(db, e.jugadores['Feña'].usuario, e.partidoId),
      async () => vencerOfertas(db),
      async () => vencerOfertas(db),
    ]
    for (const paso of pasos) {
      await paso()
      const { n, cupos } = await ocupados(db, e.partidoId)
      expect(n).toBeLessThanOrEqual(cupos)
    }
  })
})

describe('invitados', () => {
  let db: Base
  let e: Escenario
  beforeEach(async () => {
    db = await crearBase()
    e = await escenario(db, { cupos: 3, jugadores: ['Pato', 'Feña'] })
    await anotar(db, e.jugadores.Pato.usuario, e.partidoId)
  })

  function invitar(quien: Usuario, nombre: string, invitadoPor?: string) {
    return como(db, quien, (tx) =>
      rpc<Inscripcion>(tx, 'agregar_invitado', {
        p_partido: e.partidoId,
        p_nombre: nombre,
        ...(invitadoPor ? { p_invitado_por: invitadoPor } : {}),
      }),
    ).then((r) => r[0])
  }

  it('ocupan cupo por orden de llegada como cualquiera', async () => {
    await invitar(e.jugadores.Pato.usuario, 'Primo de Pato')
    await anotar(db, e.jugadores['Feña'].usuario, e.partidoId)
    await invitar(e.jugadores.Pato.usuario, 'Amigo de Pato')
    expect(await lista(db, e.partidoId)).toEqual([
      'Pato:confirmado',
      'Primo de Pato:confirmado',
      'Feña:confirmado',
      'Amigo de Pato:banca',
    ])
  })

  it('un jugador trae hasta 3 y solo da de baja a los suyos', async () => {
    const primo = await invitar(e.jugadores.Pato.usuario, 'Invitado Uno')
    await invitar(e.jugadores.Pato.usuario, 'Invitado Dos')
    await invitar(e.jugadores.Pato.usuario, 'Invitado Tres')
    await expect(invitar(e.jugadores.Pato.usuario, 'Invitado Cuatro')).rejects.toThrow('demasiados_invitados')
    await expect(bajarse(db, e.jugadores['Feña'].usuario, primo.id)).rejects.toThrow('no_autorizado')
    expect((await bajarse(db, e.jugadores.Pato.usuario, primo.id)).estado).toBe('baja')
  })

  it('un jugador no invita a nombre de otro', async () => {
    await expect(
      invitar(e.jugadores.Pato.usuario, 'Colado', e.jugadores['Feña'].miembroId),
    ).rejects.toThrow('no_autorizado')
  })
})
