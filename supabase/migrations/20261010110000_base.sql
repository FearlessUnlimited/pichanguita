-- Utilidades comunes.
-- El esquema "interno" no está expuesto por la API (PostgREST solo publica "public") y anon/authenticated
-- no tienen permiso de uso sobre él: aquí van las funciones y tablas que nunca debe tocar un cliente.

create schema if not exists interno;
revoke all on schema interno from public;

-- Configuración privada: sal para hashear IPs (así no se guardan IPs en claro).
create table interno.config (
  clave text primary key,
  valor text not null
);
insert into interno.config (clave, valor)
values ('sal_ip', encode(extensions.gen_random_bytes(32), 'hex'));

-- IP del cliente según Supabase: primer valor de x-forwarded-for. Se puede falsificar,
-- así que los límites por IP son una primera barrera; los topes globales son la protección firme.
create function interno.ip_cliente() returns text
language sql stable set search_path = '' as $$
  select nullif(trim(split_part(
    coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-forwarded-for', ''),
    ',', 1)), '')
$$;

create function interno.hash_ip() returns text
language sql stable set search_path = '' as $$
  select encode(extensions.digest(
    coalesce(interno.ip_cliente(), 'sin-ip') || (select valor from interno.config where clave = 'sal_ip'),
    'sha256'), 'hex')
$$;

-- Contador por ventana de tiempo. Devuelve true si todavía hay cupo para esta clave en la ventana actual.
create table interno.limites_envio (
  clave text not null,
  ventana timestamptz not null,
  conteo integer not null default 0,
  primary key (clave, ventana)
);

create function interno.consumir_cupo(p_clave text, p_maximo integer, p_ventana interval)
returns boolean
language plpgsql volatile set search_path = '' as $$
declare
  v_ventana timestamptz := date_bin(p_ventana, now(), timestamptz '2000-01-01');
  v_conteo integer;
begin
  insert into interno.limites_envio as l (clave, ventana, conteo)
  values (p_clave, v_ventana, 1)
  on conflict (clave, ventana) do update set conteo = l.conteo + 1
  returning l.conteo into v_conteo;
  return v_conteo <= p_maximo;
end;
$$;

-- Teléfono chileno a formato wa.me (569XXXXXXXX). Acepta "+56 9 1234 5678", "912345678", "12345678"
-- (sin el 9 inicial) y "56912345678". Devuelve null si no es un celular chileno válido.
create function interno.normalizar_celular_cl(p_texto text) returns text
language sql immutable set search_path = '' as $$
  select case
    when d ~ '^569[0-9]{8}$' then d
    when d ~ '^9[0-9]{8}$' then '56' || d
    when d ~ '^[0-9]{8}$' then '569' || d
    else null
  end
  from (select regexp_replace(coalesce(p_texto, ''), '[^0-9]', '', 'g') as d) t
$$;

create function interno.correo_valido(p_texto text) returns boolean
language sql immutable set search_path = '' as $$
  select p_texto ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' and char_length(p_texto) <= 120
$$;

-- Limpia texto libre: quita espacios sobrantes y devuelve null si queda vacío.
create function interno.limpiar(p_texto text) returns text
language sql immutable set search_path = '' as $$
  select nullif(regexp_replace(trim(coalesce(p_texto, '')), '\s+', ' ', 'g'), '')
$$;
