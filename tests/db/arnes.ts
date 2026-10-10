import { readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { expect } from 'vitest'
import { PGlite, type PGliteInterface, type Transaction } from '@electric-sql/pglite'
import { pgcrypto } from '@electric-sql/pglite/contrib/pgcrypto'

const MIGRACIONES = fileURLToPath(new URL('../../supabase/migrations/', import.meta.url))

// Lo mínimo de Supabase para que las migraciones y las políticas RLS se comporten como allá:
// roles, esquema auth con auth.uid() leyendo request.jwt.claims, pgcrypto en el esquema extensions
// y los mismos permisos por defecto que Supabase da a anon y authenticated sobre public
// (por eso lo que protege los datos en estas pruebas es RLS, igual que en producción).
const PREAMBULO = `
create role anon nologin noinherit;
create role authenticated nologin noinherit;
create role service_role nologin noinherit bypassrls;

create schema extensions;
create extension pgcrypto with schema extensions;
grant usage on schema extensions to anon, authenticated, service_role;

create schema auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  is_anonymous boolean not null default false,
  created_at timestamptz not null default now()
);
create function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(auth.jwt() ->> 'sub', '')::uuid
$$;
create function auth.role() returns text language sql stable as $$
  select auth.jwt() ->> 'role'
$$;
grant usage on schema auth to anon, authenticated, service_role;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create publication supabase_realtime;
`

export type Base = PGliteInterface

// Migrar cuesta varios segundos; clonar una base ya migrada, menos de uno. Cada archivo de pruebas
// migra una sola vez y cada prueba parte de un clon limpio.
// Cada base reserva su propia memoria de WebAssembly, así que hay que cerrarlas: setup.ts cierra las
// creadas dentro de una prueba al terminarla, y las creadas en beforeAll (compartidas) al terminar el archivo.
let plantilla: Promise<PGlite> | undefined
const abiertas = { porPrueba: [] as Base[], porArchivo: [] as Base[] }

export async function crearBase(): Promise<Base> {
  plantilla ??= migrar()
  const db = await (await plantilla).clone()
  const enPrueba = expect.getState().currentTestName !== undefined
  abiertas[enPrueba ? 'porPrueba' : 'porArchivo'].push(db)
  return db
}

export async function cerrarBases(alcance: 'prueba' | 'archivo') {
  const lista = alcance === 'prueba' ? abiertas.porPrueba : abiertas.porArchivo
  const cerrar = lista.splice(0)
  if (alcance === 'archivo') {
    cerrar.push(...abiertas.porPrueba.splice(0))
    if (plantilla) cerrar.push(await plantilla)
    plantilla = undefined
  }
  await Promise.all(cerrar.map((db) => db.close()))
}

async function migrar(): Promise<PGlite> {
  const db = new PGlite({ extensions: { pgcrypto } })
  await db.exec(PREAMBULO)
  const archivos = readdirSync(MIGRACIONES)
    .filter((f) => f.endsWith('.sql') && !f.endsWith('_cron.sql')) // pg_cron solo existe en Supabase
    .sort()
  for (const archivo of archivos) {
    try {
      await db.exec(readFileSync(MIGRACIONES + archivo, 'utf8'))
    } catch (e) {
      throw new Error(`Falló la migración ${archivo}: ${(e as Error).message}`)
    }
  }
  return db
}

export type Quien =
  | { tipo: 'anon'; ip?: string }
  | { tipo: 'usuario'; id: string; anonimo?: boolean; ip?: string }

/** Crea un usuario en auth.users y lo devuelve listo para usar con `como`. */
export async function crearUsuario(db: Base, opciones: { anonimo?: boolean; email?: string } = {}) {
  const { rows } = await db.query<{ id: string }>(
    'insert into auth.users (email, is_anonymous) values ($1, $2) returning id',
    [opciones.email ?? null, opciones.anonimo ?? false],
  )
  return { tipo: 'usuario', id: rows[0].id, anonimo: opciones.anonimo ?? false } as const
}

/**
 * Ejecuta `fn` dentro de una transacción con el rol y los claims que PostgREST pondría
 * para esa persona. La transacción se confirma si `fn` termina bien.
 */
export async function como<T>(db: Base, quien: Quien, fn: (tx: Transaction) => Promise<T>): Promise<T> {
  return db.transaction(async (tx) => {
    const claims =
      quien.tipo === 'anon'
        ? { role: 'anon' }
        : { role: 'authenticated', sub: quien.id, is_anonymous: quien.anonimo ?? false }
    const headers = { 'x-forwarded-for': quien.ip ?? '200.1.1.1' }
    await tx.query("select set_config('request.jwt.claims', $1, true)", [JSON.stringify(claims)])
    await tx.query("select set_config('request.headers', $1, true)", [JSON.stringify(headers)])
    await tx.exec(`set local role ${quien.tipo === 'anon' ? 'anon' : 'authenticated'}`)
    return fn(tx)
  })
}

/** Llama una RPC como lo haría supabase-js (`select * from fn(args nombrados)`). */
export async function rpc<T = Record<string, unknown>>(
  tx: Transaction,
  funcion: string,
  args: Record<string, unknown> = {},
): Promise<T[]> {
  const nombres = Object.keys(args)
  const params = nombres.map((n, i) => `${n} => $${i + 1}`).join(', ')
  const { rows } = await tx.query<T>(`select * from public.${funcion}(${params})`, Object.values(args))
  return rows
}
