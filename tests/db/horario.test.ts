import { beforeEach, describe, expect, it } from 'vitest'
import { crearBase, type Base } from './arnes'
import { escenario } from './escenario'

async function proximoInicio(db: Base, dia: number, hora: string, desde: string) {
  const { rows } = await db.query<{ inicio: Date }>(
    'select interno.proximo_inicio($1, $2::time, $3::timestamptz) as inicio',
    [dia, hora, desde],
  )
  return rows[0].inicio.toISOString()
}

describe('próximo inicio de la pichanga fija (hora de Santiago)', () => {
  let db: Base
  beforeEach(async () => {
    db = await crearBase()
  })

  it('toma el próximo jueves a las 21:00 en horario de verano (UTC−3)', async () => {
    // Miércoles 7 de octubre de 2026 al mediodía en Santiago.
    expect(await proximoInicio(db, 4, '21:00', '2026-10-07 12:00-03')).toBe('2026-10-09T00:00:00.000Z')
  })

  it('el mismo día sirve si todavía no llega la hora, y si ya pasó salta a la semana siguiente', async () => {
    expect(await proximoInicio(db, 4, '21:00', '2026-10-08 20:59-03')).toBe('2026-10-09T00:00:00.000Z')
    expect(await proximoInicio(db, 4, '21:00', '2026-10-08 21:00-03')).toBe('2026-10-16T00:00:00.000Z')
  })

  it('respeta el fin del horario de verano (primer domingo de abril pasa a UTC−4)', async () => {
    expect(await proximoInicio(db, 4, '21:00', '2027-03-31 12:00-03')).toBe('2027-04-02T00:00:00.000Z')
    expect(await proximoInicio(db, 4, '21:00', '2027-04-02 12:00-03')).toBe('2027-04-09T01:00:00.000Z')
  })

  it('domingo es el día 7', async () => {
    // Viernes 9 de octubre de 2026 → domingo 11 a las 10:00.
    expect(await proximoInicio(db, 7, '10:00', '2026-10-09 12:00-03')).toBe('2026-10-11T13:00:00.000Z')
  })
})

describe('generar los partidos de cada semana', () => {
  let db: Base
  let grupoId: string
  beforeEach(async () => {
    db = await crearBase()
    ;({ grupoId } = await escenario(db))
    await db.query('delete from public.partidos where grupo_id = $1', [grupoId])
  })

  async function partidos() {
    const { rows } = await db.query<{ inicio: Date; cupos: number; cuota: number; estado: string }>(
      'select inicio, cupos, cuota, estado from public.partidos where grupo_id = $1 order by inicio',
      [grupoId],
    )
    return rows
  }

  async function generar(ahora: string) {
    const { rows } = await db.query<{ n: number }>('select interno.generar_partidos($1::timestamptz) as n', [ahora])
    return rows[0].n
  }

  it('crea el partido recién cuando se abre la inscripción (144 horas antes por defecto)', async () => {
    // El jueves 8 ya pasó; el próximo es el jueves 15 a las 21:00, que se abre el viernes 9 a las 21:00.
    expect(await generar('2026-10-09 20:59-03')).toBe(0)
    expect(await generar('2026-10-09 21:00-03')).toBe(1)
    const [p] = await partidos()
    expect(p.inicio.toISOString()).toBe('2026-10-16T00:00:00.000Z')
    expect(p).toMatchObject({ cupos: 14, cuota: 4000, estado: 'abierto' })
  })

  it('no duplica el partido si la tarea corre varias veces', async () => {
    expect(await generar('2026-10-10 10:00-03')).toBe(1)
    expect(await generar('2026-10-10 10:10-03')).toBe(0)
    expect(await partidos()).toHaveLength(1)
  })

  it('copia las condiciones del horario vigente y se salta los horarios o grupos inactivos', async () => {
    await db.query('update public.horarios set cupos = 10, cuota = 5000 where grupo_id = $1', [grupoId])
    expect(await generar('2026-10-10 10:00-03')).toBe(1)
    expect((await partidos())[0]).toMatchObject({ cupos: 10, cuota: 5000 })

    await db.query('delete from public.partidos where grupo_id = $1', [grupoId])
    await db.query('update public.horarios set activo = false where grupo_id = $1', [grupoId])
    expect(await generar('2026-10-10 10:00-03')).toBe(0)
    await db.query('update public.horarios set activo = true where grupo_id = $1', [grupoId])
    await db.query('update public.grupos set activo = false where id = $1', [grupoId])
    expect(await generar('2026-10-10 10:00-03')).toBe(0)
  })
})
