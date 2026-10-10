import { como, crearUsuario, rpc, type Base, type Quien } from './arnes'

export type Usuario = Extract<Quien, { tipo: 'usuario' }>

export interface Jugador {
  usuario: Usuario
  miembroId: string
}

export interface Escenario {
  organizador: Usuario
  organizadorId: string
  grupoId: string
  codigo: string
  partidoId: string
  jugadores: Record<string, Jugador>
}

interface Opciones {
  cupos?: number
  jugadores?: string[]
  requiereAprobacion?: boolean
  modoCobro?: 'fija' | 'dividir'
  cuota?: number
  costoCancha?: number
  plazoOfertaMin?: number
}

/**
 * Grupo con su organizador, el partido de la semana dentro de 3 días (para que las pruebas no dependan del
 * día en que corren) y jugadores con sesión anónima que se unieron por el link.
 */
export async function escenario(db: Base, opciones: Opciones = {}): Promise<Escenario> {
  const organizador = await crearUsuario(db, { email: 'nico@ejemplo.cl' })
  const [grupo] = await como(db, organizador, (tx) =>
    rpc<{ id: string; codigo_invitacion: string }>(tx, 'crear_grupo', {
      p_nombre: 'Pichanga de los jueves',
      p_formato: 'futbol7',
      p_nombre_organizador: 'Nico',
      p_dia_semana: 4,
      p_hora: '21:00',
      p_cupos: opciones.cupos ?? 14,
      p_modo_cobro: opciones.modoCobro ?? 'fija',
      p_cuota: opciones.cuota ?? 4000,
      p_costo_cancha: opciones.costoCancha ?? 0,
    }),
  )
  await db.query(
    `update public.grupos set requiere_aprobacion = $2, plazo_oferta_min = $3 where id = $1`,
    [grupo.id, opciones.requiereAprobacion ?? false, opciones.plazoOfertaMin ?? 120],
  )
  const { rows: partidos } = await db.query<{ id: string }>(
    `update public.partidos set inicio = date_trunc('minute', now()) + interval '3 days'
     where grupo_id = $1 returning id`,
    [grupo.id],
  )
  const { rows: org } = await db.query<{ id: string }>(
    `select id from public.miembros where grupo_id = $1 and rol = 'organizador'`,
    [grupo.id],
  )

  const jugadores: Record<string, Jugador> = {}
  for (const nombre of opciones.jugadores ?? []) {
    jugadores[nombre] = await unir(db, grupo.codigo_invitacion, nombre)
  }

  return {
    organizador,
    organizadorId: org[0].id,
    grupoId: grupo.id,
    codigo: grupo.codigo_invitacion,
    partidoId: partidos[0].id,
    jugadores,
  }
}

/** Un celular nuevo (sesión anónima) que se une al grupo con ese nombre. */
export async function unir(db: Base, codigo: string, nombre: string): Promise<Jugador> {
  const usuario = await crearUsuario(db, { anonimo: true })
  const [r] = await como(db, usuario, (tx) =>
    rpc<{ resultado: string; miembro_id: string }>(tx, 'unirse', { p_codigo: codigo, p_nombre: nombre }),
  )
  if (r.resultado !== 'unido' && r.resultado !== 'pendiente') {
    throw new Error(`No se pudo unir a ${nombre}: ${r.resultado}`)
  }
  return { usuario, miembroId: r.miembro_id }
}

export interface Inscripcion {
  id: string
  miembro_id: string | null
  invitado_nombre: string | null
  estado: 'confirmado' | 'ofrecido' | 'banca' | 'baja'
  oferta_vence_at: Date | null
}

export async function anotar(db: Base, quien: Usuario, partidoId: string, miembroId?: string) {
  const [i] = await como(db, quien, (tx) =>
    rpc<Inscripcion>(tx, 'anotarse', { p_partido: partidoId, ...(miembroId ? { p_miembro: miembroId } : {}) }),
  )
  return i
}

/** Estado de la lista, en orden de llegada, como nombre → estado. */
export async function lista(db: Base, partidoId: string) {
  const { rows } = await db.query<{ nombre: string; estado: string }>(
    `select coalesce(m.nombre, i.invitado_nombre) as nombre, i.estado
     from public.inscripciones i left join public.miembros m on m.id = i.miembro_id
     where i.partido_id = $1 order by i.orden, i.created_at, i.id`,
    [partidoId],
  )
  return rows.map((r) => `${r.nombre}:${r.estado}`)
}

export async function inscripcionDe(db: Base, partidoId: string, miembroId: string) {
  const { rows } = await db.query<Inscripcion>(
    `select * from public.inscripciones where partido_id = $1 and miembro_id = $2`,
    [partidoId, miembroId],
  )
  return rows[0]
}
