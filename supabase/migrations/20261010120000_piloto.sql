-- Formularios de las páginas públicas "Pichanguita para organizadores" y "Pichanguita para canchas".
-- Nadie anónimo lee ni escribe estas tablas directo: RLS activo sin políticas y sin permisos de tabla.
-- La única entrada es la RPC de cada formulario, que valida, exige consentimiento y limita el spam.
-- Las respuestas se leen desde el panel de Supabase.

create table public.piloto_organizadores (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (char_length(nombre) between 2 and 80),
  whatsapp text check (whatsapp ~ '^569[0-9]{8}$'),
  correo text check (char_length(correo) <= 120),
  comuna text not null check (char_length(comuna) between 2 and 60),
  dia_hora text check (char_length(dia_hora) <= 80),
  cancha text check (char_length(cancha) <= 120),
  jugadores_por_partido smallint check (jugadores_por_partido between 2 and 40),
  personas_en_grupo smallint check (personas_en_grupo between 2 and 300),
  medios_pago text[] not null default '{}'
    check (medios_pago <@ array['efectivo', 'transferencia', 'otro']::text[]),
  lo_mas_molesto text check (char_length(lo_mas_molesto) <= 1500),
  consentimiento_version text not null,
  consentimiento_at timestamptz not null default now(),
  ip_hash text not null,
  created_at timestamptz not null default now(),
  check (whatsapp is not null or correo is not null)
);

create table public.piloto_canchas (
  id uuid primary key default gen_random_uuid(),
  recinto text not null check (char_length(recinto) between 2 and 120),
  contacto_nombre text not null check (char_length(contacto_nombre) between 2 and 80),
  whatsapp text not null check (whatsapp ~ '^569[0-9]{8}$'),
  correo text check (char_length(correo) <= 120),
  comuna text not null check (char_length(comuna) between 2 and 60),
  cantidad_canchas smallint check (cantidad_canchas between 1 and 100),
  tipos_cancha text[] not null default '{}'
    check (tipos_cancha <@ array['baby', 'futbolito', 'futbol7', 'futbol11', 'otro']::text[]),
  sistema_reservas text check (char_length(sistema_reservas) <= 200),
  grupos_fijos smallint check (grupos_fijos between 0 and 1000),
  horas_dificiles text check (char_length(horas_dificiles) <= 1500),
  consentimiento_version text not null,
  consentimiento_at timestamptz not null default now(),
  ip_hash text not null,
  created_at timestamptz not null default now()
);

alter table public.piloto_organizadores enable row level security;
alter table public.piloto_canchas enable row level security;
revoke all on table public.piloto_organizadores, public.piloto_canchas from anon, authenticated;

-- Versión vigente del texto de consentimiento (debe coincidir con /privacidad/).
create function interno.version_consentimiento() returns text
language sql immutable set search_path = '' as $$ select '2026-10-10' $$;

-- Barreras comunes contra spam. Devuelve false si el envío debe descartarse en silencio
-- (campo trampa lleno o llenado inhumanamente rápido), y lanza error si se pasó del límite.
create function interno.filtrar_envio(p_tipo text, p_trampa text, p_ms_llenado integer)
returns boolean
language plpgsql volatile set search_path = '' as $$
begin
  -- Tope global por formulario: protección firme aunque falsifiquen la IP.
  if not interno.consumir_cupo('piloto:' || p_tipo || ':global', 60, interval '1 hour') then
    raise exception 'demasiados_envios' using errcode = 'P0001';
  end if;
  if not interno.consumir_cupo('piloto:' || p_tipo || ':ip:' || interno.hash_ip(), 5, interval '1 hour') then
    raise exception 'demasiados_envios' using errcode = 'P0001';
  end if;
  if interno.limpiar(p_trampa) is not null or coalesce(p_ms_llenado, 0) < 3000 then
    return false;
  end if;
  return true;
end;
$$;

create function interno.exigir_consentimiento(p_consentimiento boolean, p_version text)
returns void
language plpgsql stable set search_path = '' as $$
begin
  if p_consentimiento is distinct from true then
    raise exception 'falta_consentimiento' using errcode = 'P0001';
  end if;
  if p_version is distinct from interno.version_consentimiento() then
    raise exception 'consentimiento_desactualizado' using errcode = 'P0001';
  end if;
end;
$$;

create function public.enviar_piloto_organizador(
  p_nombre text,
  p_whatsapp text,
  p_correo text,
  p_comuna text,
  p_dia_hora text,
  p_cancha text,
  p_jugadores_por_partido integer,
  p_personas_en_grupo integer,
  p_medios_pago text[],
  p_lo_mas_molesto text,
  p_consentimiento boolean,
  p_consentimiento_version text,
  p_trampa text default null,
  p_ms_llenado integer default null
) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_whatsapp text := interno.normalizar_celular_cl(p_whatsapp);
  v_correo text := lower(interno.limpiar(p_correo));
begin
  perform interno.exigir_consentimiento(p_consentimiento, p_consentimiento_version);
  if not interno.filtrar_envio('organizador', p_trampa, p_ms_llenado) then
    return;
  end if;
  if interno.limpiar(p_whatsapp) is not null and v_whatsapp is null then
    raise exception 'whatsapp_invalido' using errcode = 'P0001';
  end if;
  if v_correo is not null and not interno.correo_valido(v_correo) then
    raise exception 'correo_invalido' using errcode = 'P0001';
  end if;
  if v_whatsapp is null and v_correo is null then
    raise exception 'falta_contacto' using errcode = 'P0001';
  end if;

  insert into public.piloto_organizadores (
    nombre, whatsapp, correo, comuna, dia_hora, cancha, jugadores_por_partido, personas_en_grupo,
    medios_pago, lo_mas_molesto, consentimiento_version, ip_hash
  ) values (
    interno.limpiar(p_nombre), v_whatsapp, v_correo, interno.limpiar(p_comuna),
    interno.limpiar(p_dia_hora), interno.limpiar(p_cancha), p_jugadores_por_partido, p_personas_en_grupo,
    coalesce(p_medios_pago, '{}'), nullif(trim(coalesce(p_lo_mas_molesto, '')), ''),
    p_consentimiento_version, interno.hash_ip()
  );
exception
  when check_violation or not_null_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

create function public.enviar_piloto_cancha(
  p_recinto text,
  p_contacto_nombre text,
  p_whatsapp text,
  p_correo text,
  p_comuna text,
  p_cantidad_canchas integer,
  p_tipos_cancha text[],
  p_sistema_reservas text,
  p_grupos_fijos integer,
  p_horas_dificiles text,
  p_consentimiento boolean,
  p_consentimiento_version text,
  p_trampa text default null,
  p_ms_llenado integer default null
) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_whatsapp text := interno.normalizar_celular_cl(p_whatsapp);
  v_correo text := lower(interno.limpiar(p_correo));
begin
  perform interno.exigir_consentimiento(p_consentimiento, p_consentimiento_version);
  if not interno.filtrar_envio('cancha', p_trampa, p_ms_llenado) then
    return;
  end if;
  if v_whatsapp is null then
    raise exception 'whatsapp_invalido' using errcode = 'P0001';
  end if;
  if v_correo is not null and not interno.correo_valido(v_correo) then
    raise exception 'correo_invalido' using errcode = 'P0001';
  end if;

  insert into public.piloto_canchas (
    recinto, contacto_nombre, whatsapp, correo, comuna, cantidad_canchas, tipos_cancha,
    sistema_reservas, grupos_fijos, horas_dificiles, consentimiento_version, ip_hash
  ) values (
    interno.limpiar(p_recinto), interno.limpiar(p_contacto_nombre), v_whatsapp, v_correo,
    interno.limpiar(p_comuna), p_cantidad_canchas, coalesce(p_tipos_cancha, '{}'),
    interno.limpiar(p_sistema_reservas), p_grupos_fijos,
    nullif(trim(coalesce(p_horas_dificiles, '')), ''),
    p_consentimiento_version, interno.hash_ip()
  );
exception
  when check_violation or not_null_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

revoke all on function public.enviar_piloto_organizador from public;
revoke all on function public.enviar_piloto_cancha from public;
grant execute on function public.enviar_piloto_organizador to anon, authenticated;
grant execute on function public.enviar_piloto_cancha to anon, authenticated;
