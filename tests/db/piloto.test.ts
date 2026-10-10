import { beforeEach, describe, expect, it } from 'vitest'
import { como, crearBase, rpc, type Base } from './arnes'

const VERSION = '2026-10-10'

const organizadorValido = {
  p_nombre: '  Nico   Pérez ',
  p_whatsapp: '+56 9 1234 5678',
  p_correo: null,
  p_comuna: 'Viña del Mar',
  p_dia_hora: 'Jueves 21:00',
  p_cancha: 'Complejo X',
  p_jugadores_por_partido: 14,
  p_personas_en_grupo: 20,
  p_medios_pago: ['efectivo', 'transferencia'],
  p_lo_mas_molesto: 'Cobrar.\nPreguntar uno por uno.',
  p_consentimiento: true,
  p_consentimiento_version: VERSION,
  p_trampa: '',
  p_ms_llenado: 45000,
}

const canchaValida = {
  p_recinto: 'Complejo Deportivo Y',
  p_contacto_nombre: 'Ana',
  p_whatsapp: '912345678',
  p_correo: 'Ana@Ejemplo.cl',
  p_comuna: 'Valparaíso',
  p_cantidad_canchas: 3,
  p_tipos_cancha: ['baby', 'futbol7'],
  p_sistema_reservas: 'WhatsApp y cuaderno',
  p_grupos_fijos: 12,
  p_horas_dificiles: 'Lunes y martes a las 18:00',
  p_consentimiento: true,
  p_consentimiento_version: VERSION,
  p_trampa: '',
  p_ms_llenado: 30000,
}

const anon = (ip = '200.1.1.1') => ({ tipo: 'anon', ip }) as const

async function contar(db: Base, tabla: string) {
  const { rows } = await db.query<{ n: number }>(`select count(*)::int as n from public.${tabla}`)
  return rows[0].n
}

describe('formulario de organizadores', () => {
  let db: Base
  beforeEach(async () => {
    db = await crearBase()
  })

  it('guarda un envío válido, con texto limpio y celular normalizado', async () => {
    await como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_organizador', organizadorValido))
    const { rows } = await db.query<Record<string, unknown>>('select * from public.piloto_organizadores')
    expect(rows).toHaveLength(1)
    expect(rows[0].nombre).toBe('Nico Pérez')
    expect(rows[0].whatsapp).toBe('56912345678')
    expect(rows[0].consentimiento_version).toBe(VERSION)
    expect(rows[0].ip_hash).toMatch(/^[0-9a-f]{64}$/)
    expect(rows[0].ip_hash).not.toContain('200.1.1.1')
  })

  it('exige consentimiento vigente', async () => {
    await expect(
      como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_consentimiento: false })),
    ).rejects.toThrow('falta_consentimiento')
    await expect(
      como(db, anon(), (tx) =>
        rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_consentimiento_version: '2020-01-01' }),
      ),
    ).rejects.toThrow('consentimiento_desactualizado')
    expect(await contar(db, 'piloto_organizadores')).toBe(0)
  })

  it('exige al menos un contacto válido', async () => {
    await expect(
      como(db, anon(), (tx) =>
        rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_whatsapp: null, p_correo: null }),
      ),
    ).rejects.toThrow('falta_contacto')
    await expect(
      como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_whatsapp: '123' })),
    ).rejects.toThrow('whatsapp_invalido')
    await expect(
      como(db, anon(), (tx) =>
        rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_whatsapp: null, p_correo: 'no-es-correo' }),
      ),
    ).rejects.toThrow('correo_invalido')
  })

  it('rechaza datos fuera de rango con un error genérico', async () => {
    await expect(
      como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_nombre: 'x' })),
    ).rejects.toThrow('datos_invalidos')
    await expect(
      como(db, anon(), (tx) =>
        rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_medios_pago: ['bitcoin'] }),
      ),
    ).rejects.toThrow('datos_invalidos')
  })

  it('descarta en silencio el campo trampa y los envíos demasiado rápidos', async () => {
    await como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_trampa: 'http://spam' }))
    await como(db, anon('200.1.1.2'), (tx) =>
      rpc(tx, 'enviar_piloto_organizador', { ...organizadorValido, p_ms_llenado: 800 }),
    )
    expect(await contar(db, 'piloto_organizadores')).toBe(0)
  })

  it('limita a 5 envíos por IP por hora', async () => {
    for (let i = 0; i < 5; i++) {
      await como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_organizador', organizadorValido))
    }
    await expect(
      como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_organizador', organizadorValido)),
    ).rejects.toThrow('demasiados_envios')
    // Otra IP sigue pudiendo enviar.
    await como(db, anon('200.9.9.9'), (tx) => rpc(tx, 'enviar_piloto_organizador', organizadorValido))
    expect(await contar(db, 'piloto_organizadores')).toBe(6)
  })

  it('tiene un tope global por hora aunque cambien la IP', async () => {
    for (let i = 0; i < 60; i++) {
      await como(db, anon(`10.0.0.${i}`), (tx) => rpc(tx, 'enviar_piloto_organizador', organizadorValido))
    }
    await expect(
      como(db, anon('10.0.1.1'), (tx) => rpc(tx, 'enviar_piloto_organizador', organizadorValido)),
    ).rejects.toThrow('demasiados_envios')
    // El tope es por formulario: el de canchas sigue abierto.
    await como(db, anon('10.0.1.2'), (tx) => rpc(tx, 'enviar_piloto_cancha', canchaValida))
  })
})

describe('formulario de canchas', () => {
  let db: Base
  beforeEach(async () => {
    db = await crearBase()
  })

  it('guarda un envío válido', async () => {
    await como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_cancha', canchaValida))
    const { rows } = await db.query<Record<string, unknown>>('select * from public.piloto_canchas')
    expect(rows[0].whatsapp).toBe('56912345678')
    expect(rows[0].correo).toBe('ana@ejemplo.cl')
    expect(rows[0].tipos_cancha).toEqual(['baby', 'futbol7'])
  })

  it('exige WhatsApp', async () => {
    await expect(
      como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_cancha', { ...canchaValida, p_whatsapp: '' })),
    ).rejects.toThrow('whatsapp_invalido')
  })
})

describe('nadie de afuera lee ni escribe directo', () => {
  let db: Base
  beforeEach(async () => {
    db = await crearBase()
    await como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_organizador', organizadorValido))
    await como(db, anon(), (tx) => rpc(tx, 'enviar_piloto_cancha', canchaValida))
  })

  for (const rol of ['anon', 'usuario'] as const) {
    const quien = rol === 'anon' ? anon() : ({ tipo: 'usuario', id: crypto.randomUUID() } as const)

    for (const tabla of ['piloto_organizadores', 'piloto_canchas']) {
      it(`${rol} no puede leer ${tabla}`, async () => {
        await expect(como(db, quien, (tx) => tx.query(`select * from public.${tabla}`))).rejects.toThrow(
          /permission denied/,
        )
      })

      it(`${rol} no puede insertar, modificar ni borrar en ${tabla}`, async () => {
        await expect(
          como(db, quien, (tx) => tx.query(`insert into public.${tabla} default values`)),
        ).rejects.toThrow(/permission denied/)
        await expect(como(db, quien, (tx) => tx.query(`update public.${tabla} set comuna = 'x'`))).rejects.toThrow(
          /permission denied/,
        )
        await expect(como(db, quien, (tx) => tx.query(`delete from public.${tabla}`))).rejects.toThrow(
          /permission denied/,
        )
      })
    }

    it(`${rol} no puede usar el esquema interno`, async () => {
      await expect(como(db, quien, (tx) => tx.query('select * from interno.config'))).rejects.toThrow(
        /permission denied/,
      )
      await expect(
        como(db, quien, (tx) => tx.query("select interno.consumir_cupo('x', 1, interval '1 hour')")),
      ).rejects.toThrow(/permission denied/)
    })
  }
})
