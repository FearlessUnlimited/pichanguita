-- Núcleo de la pichanga: grupos, horarios, miembros, partidos con banca, plata y registro de actividad.
--
-- Reglas de acceso:
-- - Los clientes solo leen, y solo lo que RLS les deja ver. No tienen permiso de escritura sobre ninguna tabla.
-- - Toda escritura pasa por una RPC security definer que valida quién llama y qué puede hacer. Las que tocan
--   cupos bloquean el partido (for update) para que dos personas no tomen el mismo último cupo.
-- - Las funciones que usan las políticas viven en el esquema "acceso", que la API no expone.

-- ---------------------------------------------------------------------------------------------------------
-- Utilidades internas
-- ---------------------------------------------------------------------------------------------------------

-- Texto aleatorio apto para URL (base64url sin relleno).
create function interno.token_aleatorio(p_bytes integer) returns text
language sql volatile set search_path = '' as $$
  select rtrim(translate(encode(extensions.gen_random_bytes(p_bytes), 'base64'), '+/', '-_'), '=')
$$;

create function interno.hash_token(p_token text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(p_token, 'sha256'), 'hex')
$$;

-- Nombre para comparar: sin tildes, sin mayúsculas y con espacios simples ("  José  Pérez" = "jose perez").
create function interno.normalizar_nombre(p_texto text) returns text
language sql immutable set search_path = '' as $$
  select lower(translate(interno.limpiar(p_texto),
    'ÁÀÄÂáàäâÉÈËÊéèëêÍÌÏÎíìïîÓÒÖÔóòöôÚÙÜÛúùüû',
    'AAAAaaaaEEEEeeeeIIIIiiiiOOOOooooUUUUuuuu'))
$$;

-- Lanza error si la clave se pasó del máximo en la ventana.
create function interno.limitar(p_clave text, p_maximo integer, p_ventana interval) returns void
language plpgsql volatile set search_path = '' as $$
begin
  if not interno.consumir_cupo(p_clave, p_maximo, p_ventana) then
    raise exception 'demasiadas_solicitudes' using errcode = 'P0001';
  end if;
end;
$$;

-- Usuario que llama. Error si no hay sesión.
create function interno.usuario() returns uuid
language plpgsql stable set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'sin_sesion' using errcode = 'P0001';
  end if;
  return v_uid;
end;
$$;

-- Usuario con cuenta (no anónimo). Los jugadores entran con sesión anónima; organizar exige cuenta.
create function interno.usuario_con_cuenta() returns uuid
language plpgsql stable set search_path = '' as $$
declare
  v_uid uuid := interno.usuario();
begin
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'requiere_cuenta' using errcode = 'P0001';
  end if;
  return v_uid;
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- Tablas
-- ---------------------------------------------------------------------------------------------------------

-- Banderas del futuro plan capitán. Hoy el plan "piloto" incluye todo: activar un plan pagado será un
-- cambio de datos, no de código.
create table public.planes (
  id text primary key,
  nombre text not null
);

create table public.plan_funciones (
  plan_id text not null references public.planes (id) on delete cascade,
  funcion text not null,
  primary key (plan_id, funcion)
);

insert into public.planes (id, nombre) values ('piloto', 'Piloto');
insert into public.plan_funciones (plan_id, funcion) values
  ('piloto', 'recordatorios_auto'),
  ('piloto', 'equipos_por_nivel'),
  ('piloto', 'estadisticas'),
  ('piloto', 'coorganizadores'),
  ('piloto', 'varios_grupos');

-- Directorio de canchas: crece con las que registran los organizadores; las curadas se marcan verificadas.
create table public.canchas (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (char_length(nombre) between 2 and 80),
  recinto text check (char_length(recinto) <= 120),
  direccion text check (char_length(direccion) <= 160),
  comuna text not null check (char_length(comuna) between 2 and 60),
  whatsapp text check (whatsapp ~ '^569[0-9]{8}$'),
  superficie text check (superficie in ('sintetico', 'pasto', 'tierra', 'baldosa', 'otro')),
  formatos text[] not null default '{}'
    check (formatos <@ array['baby', 'futbolito', 'futbol7', 'futbol11']::text[]),
  verificada boolean not null default false,
  creada_por uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.grupos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null check (char_length(nombre) between 2 and 60),
  formato text not null check (formato in ('baby', 'futbolito', 'futbol7', 'futbol11')),
  modalidad text not null default 'orden_llegada' check (modalidad in ('orden_llegada')),
  plan text not null default 'piloto' references public.planes (id),
  -- ~64 bits; va en el link del grupo y se puede rotar.
  codigo_invitacion text not null unique default interno.token_aleatorio(8),
  requiere_aprobacion boolean not null default false,
  deudas_visibles boolean not null default false,
  plazo_oferta_min integer not null default 120 check (plazo_oferta_min between 5 and 1440),
  cobrar_ausentes boolean not null default false,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

-- Datos de transferencia del organizador; los ven los miembros activos para pagarle.
create table public.grupo_datos_pago (
  grupo_id uuid primary key references public.grupos (id) on delete cascade,
  titular text check (char_length(titular) <= 80),
  rut text check (char_length(rut) <= 12),
  banco text check (char_length(banco) <= 60),
  tipo_cuenta text check (char_length(tipo_cuenta) <= 40),
  numero_cuenta text check (char_length(numero_cuenta) <= 30),
  correo text check (char_length(correo) <= 120),
  updated_at timestamptz not null default now()
);

-- La pichanga fija. Un grupo puede tener varias; la interfaz parte con una.
create table public.horarios (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  dia_semana smallint not null check (dia_semana between 1 and 7), -- 1 = lunes … 7 = domingo
  hora time not null, -- hora de Santiago
  duracion_min smallint not null default 60 check (duracion_min between 30 and 240),
  cancha_id uuid references public.canchas (id) on delete set null,
  cupos smallint not null check (cupos between 2 and 40),
  modo_cobro text not null default 'fija' check (modo_cobro in ('fija', 'dividir')),
  cuota integer not null default 0 check (cuota between 0 and 1000000),
  costo_cancha integer not null default 0 check (costo_cancha between 0 and 10000000),
  abre_horas_antes smallint not null default 144 check (abre_horas_antes between 1 and 168),
  activo boolean not null default true,
  created_at timestamptz not null default now()
);
create index horarios_grupo on public.horarios (grupo_id);

create table public.miembros (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  nombre text not null check (char_length(nombre) between 2 and 40),
  nombre_normalizado text not null,
  rol text not null default 'jugador' check (rol in ('organizador', 'coorganizador', 'jugador')),
  -- pendiente = postulante esperando aprobación.
  estado text not null default 'activo' check (estado in ('pendiente', 'activo', 'retirado', 'rechazado')),
  -- El celular vinculado (sesión anónima o cuenta). Nulo si lo agregó el organizador y aún no se vincula.
  -- Los clientes no pueden leer esta columna; ven solo "tiene_celular".
  auth_user_id uuid references auth.users (id) on delete set null,
  tiene_celular boolean generated always as (auth_user_id is not null) stored,
  created_at timestamptz not null default now()
);
create unique index miembros_nombre_vigente on public.miembros (grupo_id, nombre_normalizado)
  where estado in ('pendiente', 'activo');
create unique index miembros_usuario on public.miembros (grupo_id, auth_user_id)
  where auth_user_id is not null;
create index miembros_auth_user on public.miembros (auth_user_id);

-- Teléfono para avisos por wa.me y nivel para armar equipos: solo organizadores y el propio jugador.
create table public.miembros_privado (
  miembro_id uuid primary key references public.miembros (id) on delete cascade,
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  telefono text check (telefono ~ '^569[0-9]{8}$'),
  nivel smallint check (nivel between 1 and 5),
  updated_at timestamptz not null default now()
);

-- Links personales: solo el hash del token. Ningún cliente lee esta tabla.
create table interno.enlaces_personales (
  miembro_id uuid primary key references public.miembros (id) on delete cascade,
  token_hash text not null unique,
  vence_at timestamptz not null,
  creado_por uuid references public.miembros (id) on delete set null,
  created_at timestamptz not null default now()
);

-- La instancia de cada semana, con copia de las condiciones del horario en ese momento.
create table public.partidos (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  horario_id uuid references public.horarios (id) on delete set null,
  inicio timestamptz not null,
  duracion_min smallint not null,
  cancha_id uuid references public.canchas (id) on delete set null,
  cupos smallint not null check (cupos between 2 and 40),
  modo_cobro text not null check (modo_cobro in ('fija', 'dividir')),
  cuota integer not null default 0 check (cuota >= 0),
  costo_cancha integer not null default 0 check (costo_cancha >= 0),
  estado text not null default 'abierto' check (estado in ('abierto', 'cerrado', 'cancelado')),
  cerrado_at timestamptz,
  created_at timestamptz not null default now(),
  unique (horario_id, inicio)
);
create index partidos_grupo on public.partidos (grupo_id, inicio desc);
create index partidos_abiertos on public.partidos (inicio) where estado = 'abierto';

-- Ocupan cupo "confirmado" y "ofrecido". "orden" es la cola de llegada (clock_timestamp: dentro de una misma
-- transacción también avanza).
create table public.inscripciones (
  id uuid primary key default gen_random_uuid(),
  partido_id uuid not null references public.partidos (id) on delete cascade,
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  miembro_id uuid references public.miembros (id) on delete cascade,
  invitado_nombre text check (char_length(invitado_nombre) between 2 and 40),
  invitado_por uuid references public.miembros (id) on delete cascade,
  estado text not null check (estado in ('confirmado', 'ofrecido', 'banca', 'baja')),
  orden timestamptz not null default clock_timestamp(),
  oferta_vence_at timestamptz,
  asistio boolean,
  created_at timestamptz not null default now(),
  check (
    (miembro_id is not null and invitado_nombre is null and invitado_por is null)
    or (miembro_id is null and invitado_nombre is not null and invitado_por is not null)
  ),
  check ((estado = 'ofrecido') = (oferta_vence_at is not null))
);
create unique index inscripciones_miembro on public.inscripciones (partido_id, miembro_id)
  where miembro_id is not null;
create index inscripciones_cola on public.inscripciones (partido_id, estado, orden);
create index inscripciones_ofertas on public.inscripciones (oferta_vence_at) where estado = 'ofrecido';

-- Lo que debe cada uno: cuota por partido o ajuste manual (negativo = a favor). Se anulan, no se borran.
create table public.cargos (
  id uuid primary key default gen_random_uuid(),
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  miembro_id uuid not null references public.miembros (id) on delete cascade,
  partido_id uuid references public.partidos (id) on delete set null,
  inscripcion_id uuid references public.inscripciones (id) on delete set null,
  tipo text not null check (tipo in ('cuota', 'ajuste')),
  monto integer not null check (monto <> 0 and abs(monto) <= 10000000),
  concepto text not null check (char_length(concepto) between 1 and 120),
  creado_por uuid references public.miembros (id) on delete set null,
  anulado_at timestamptz,
  anulado_por uuid references public.miembros (id) on delete set null,
  created_at timestamptz not null default now(),
  check (tipo <> 'cuota' or monto > 0)
);
create unique index cargos_cuota_unica on public.cargos (inscripcion_id)
  where tipo = 'cuota' and anulado_at is null;
create index cargos_miembro on public.cargos (grupo_id, miembro_id);

-- El id lo genera el cliente: reintentar no duplica (base para el modo cancha sin señal).
create table public.pagos (
  id uuid primary key,
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  miembro_id uuid not null references public.miembros (id) on delete cascade,
  partido_id uuid references public.partidos (id) on delete set null,
  monto integer not null check (monto between 1 and 10000000),
  medio text not null check (medio in ('efectivo', 'transferencia')),
  -- informado = el jugador dijo "ya transferí" y espera al organizador.
  estado text not null check (estado in ('informado', 'confirmado', 'rechazado')),
  registrado_por uuid references public.miembros (id) on delete set null,
  revisado_por uuid references public.miembros (id) on delete set null,
  revisado_at timestamptz,
  created_at timestamptz not null default now()
);
create index pagos_miembro on public.pagos (grupo_id, miembro_id);

-- Gastos e ingresos del grupo (pago de la cancha, balón, petos, asado).
create table public.movimientos_caja (
  id uuid primary key,
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  tipo text not null check (tipo in ('gasto', 'ingreso')),
  monto integer not null check (monto between 1 and 10000000),
  concepto text not null check (char_length(concepto) between 1 and 120),
  partido_id uuid references public.partidos (id) on delete set null,
  registrado_por uuid references public.miembros (id) on delete set null,
  anulado_at timestamptz,
  anulado_por uuid references public.miembros (id) on delete set null,
  created_at timestamptz not null default now()
);
create index movimientos_grupo on public.movimientos_caja (grupo_id, created_at desc);

-- Todo lo sensible (vinculaciones, pagos, roles, ofertas de la banca): transparencia y base para deshacer.
create table public.actividad (
  id bigint generated always as identity primary key,
  grupo_id uuid not null references public.grupos (id) on delete cascade,
  tipo text not null,
  actor_miembro_id uuid references public.miembros (id) on delete set null,
  miembro_id uuid references public.miembros (id) on delete set null,
  datos jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index actividad_grupo on public.actividad (grupo_id, created_at desc);

create function interno.registrar(
  p_grupo uuid, p_tipo text, p_actor uuid, p_miembro uuid, p_datos jsonb default '{}'
) returns void
language sql volatile set search_path = '' as $$
  insert into public.actividad (grupo_id, tipo, actor_miembro_id, miembro_id, datos)
  values (p_grupo, p_tipo, p_actor, p_miembro, p_datos)
$$;

-- ---------------------------------------------------------------------------------------------------------
-- Acceso: funciones que usan las políticas (security definer para no recursar en RLS)
-- ---------------------------------------------------------------------------------------------------------

create schema acceso;
revoke all on schema acceso from public;
grant usage on schema acceso to authenticated;

create function acceso.es_activo(p_grupo uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.miembros
    where grupo_id = p_grupo and auth_user_id = auth.uid() and estado = 'activo'
  )
$$;

create function acceso.es_admin(p_grupo uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.miembros
    where grupo_id = p_grupo and auth_user_id = auth.uid() and estado = 'activo'
      and rol in ('organizador', 'coorganizador')
  )
$$;

-- Activo o postulante: el postulante ve el grupo para saber que espera aprobación.
create function acceso.es_miembro_o_postulante(p_grupo uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.miembros
    where grupo_id = p_grupo and auth_user_id = auth.uid() and estado in ('activo', 'pendiente')
  )
$$;

create function acceso.es_yo(p_miembro uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.miembros
    where id = p_miembro and auth_user_id = auth.uid() and estado = 'activo'
  )
$$;

-- Deudas, pagos y caja de todo el grupo: organizadores siempre; el resto si el grupo lo activó.
create function acceso.ve_plata(p_grupo uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select acceso.es_admin(p_grupo)
    or (acceso.es_activo(p_grupo) and exists (
      select 1 from public.grupos where id = p_grupo and deudas_visibles
    ))
$$;

revoke all on all functions in schema acceso from public;
grant execute on all functions in schema acceso to authenticated;

-- ---------------------------------------------------------------------------------------------------------
-- RLS y permisos
-- ---------------------------------------------------------------------------------------------------------

alter table public.planes enable row level security;
alter table public.plan_funciones enable row level security;
alter table public.canchas enable row level security;
alter table public.grupos enable row level security;
alter table public.grupo_datos_pago enable row level security;
alter table public.horarios enable row level security;
alter table public.miembros enable row level security;
alter table public.miembros_privado enable row level security;
alter table public.partidos enable row level security;
alter table public.inscripciones enable row level security;
alter table public.cargos enable row level security;
alter table public.pagos enable row level security;
alter table public.movimientos_caja enable row level security;
alter table public.actividad enable row level security;

create policy lectura on public.planes for select to anon, authenticated using (true);
create policy lectura on public.plan_funciones for select to anon, authenticated using (true);
create policy lectura on public.canchas for select to anon, authenticated using (true);
create policy lectura on public.grupos for select to authenticated
  using (acceso.es_miembro_o_postulante(id));
create policy lectura on public.grupo_datos_pago for select to authenticated
  using (acceso.es_activo(grupo_id));
create policy lectura on public.horarios for select to authenticated
  using (acceso.es_activo(grupo_id));
-- Postulantes y rechazados solo los ven los organizadores; cada uno se ve a sí mismo.
create policy lectura on public.miembros for select to authenticated
  using (
    auth_user_id = auth.uid()
    or acceso.es_admin(grupo_id)
    or (estado in ('activo', 'retirado') and acceso.es_activo(grupo_id))
  );
create policy lectura on public.miembros_privado for select to authenticated
  using (acceso.es_admin(grupo_id) or acceso.es_yo(miembro_id));
create policy lectura on public.partidos for select to authenticated
  using (acceso.es_activo(grupo_id));
create policy lectura on public.inscripciones for select to authenticated
  using (acceso.es_activo(grupo_id));
create policy lectura on public.cargos for select to authenticated
  using (acceso.ve_plata(grupo_id) or acceso.es_yo(miembro_id));
create policy lectura on public.pagos for select to authenticated
  using (acceso.ve_plata(grupo_id) or acceso.es_yo(miembro_id));
create policy lectura on public.movimientos_caja for select to authenticated
  using (acceso.ve_plata(grupo_id));
create policy lectura on public.actividad for select to authenticated
  using (acceso.es_admin(grupo_id));

-- Ningún cliente escribe directo en ninguna tabla, tampoco en las que se creen después.
revoke insert, update, delete, truncate, references, trigger on all tables in schema public from anon, authenticated;
alter default privileges in schema public
  revoke insert, update, delete, truncate, references, trigger on tables from anon, authenticated;

-- Anónimos sin sesión: solo el directorio de canchas y los planes.
revoke all on public.grupos, public.grupo_datos_pago, public.horarios, public.miembros, public.miembros_privado,
  public.partidos, public.inscripciones, public.cargos, public.pagos, public.movimientos_caja, public.actividad
  from anon;

-- Columnas que no se exponen: quién creó cada cancha y qué usuario está detrás de cada miembro.
revoke select on public.canchas from anon, authenticated;
grant select (id, nombre, recinto, direccion, comuna, whatsapp, superficie, formatos, verificada, created_at)
  on public.canchas to anon, authenticated;
revoke select on public.miembros from authenticated;
grant select (id, grupo_id, nombre, rol, estado, tiene_celular, created_at) on public.miembros to authenticated;

-- La lista se actualiza sola en el celular.
alter publication supabase_realtime add table public.partidos, public.inscripciones;

-- ---------------------------------------------------------------------------------------------------------
-- Funciones internas de la pichanga
-- ---------------------------------------------------------------------------------------------------------

-- Miembro activo del usuario en el grupo y si administra. Error si no es miembro activo.
create function interno.actor(p_grupo uuid, out miembro_id uuid, out es_admin boolean, out es_organizador boolean)
language plpgsql stable set search_path = '' as $$
begin
  select m.id, m.rol in ('organizador', 'coorganizador'), m.rol = 'organizador'
  into miembro_id, es_admin, es_organizador
  from public.miembros m
  where m.grupo_id = p_grupo and m.auth_user_id = interno.usuario() and m.estado = 'activo';
  if miembro_id is null then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
end;
$$;

create function interno.exigir_admin(p_grupo uuid) returns uuid
language plpgsql stable set search_path = '' as $$
declare
  v_actor record;
begin
  select * into v_actor from interno.actor(p_grupo);
  if not v_actor.es_admin then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  return v_actor.miembro_id;
end;
$$;

-- Próximo inicio estrictamente posterior a p_desde, para un día (1 = lunes) y una hora de Santiago.
-- Calcula la fecha en hora local y recién ahí la pasa a UTC, así respeta el horario de verano.
create function interno.proximo_inicio(p_dia integer, p_hora time, p_desde timestamptz)
returns timestamptz
language plpgsql stable set search_path = '' as $$
declare
  v_hoy date := (p_desde at time zone 'America/Santiago')::date;
  v_fecha date := v_hoy + ((p_dia - extract(isodow from v_hoy)::integer + 7) % 7);
  v_inicio timestamptz := (v_fecha + p_hora) at time zone 'America/Santiago';
begin
  if v_inicio <= p_desde then
    v_inicio := ((v_fecha + 7) + p_hora) at time zone 'America/Santiago';
  end if;
  return v_inicio;
end;
$$;

create function interno.crear_partido(p_horario uuid, p_inicio timestamptz) returns uuid
language plpgsql volatile set search_path = '' as $$
declare
  v_id uuid;
begin
  insert into public.partidos (grupo_id, horario_id, inicio, duracion_min, cancha_id, cupos, modo_cobro, cuota, costo_cancha)
  select h.grupo_id, h.id, p_inicio, h.duracion_min, h.cancha_id, h.cupos, h.modo_cobro, h.cuota, h.costo_cancha
  from public.horarios h
  where h.id = p_horario
  on conflict (horario_id, inicio) do nothing
  returning id into v_id;
  return v_id;
end;
$$;

-- Crea el partido de cada horario cuando se abre su inscripción. Lo corre pg_cron.
create function interno.generar_partidos(p_ahora timestamptz default now()) returns integer
language plpgsql volatile set search_path = '' as $$
declare
  v_horario record;
  v_inicio timestamptz;
  v_creados integer := 0;
begin
  for v_horario in
    select h.id, h.dia_semana, h.hora, h.abre_horas_antes
    from public.horarios h join public.grupos g on g.id = h.grupo_id
    where h.activo and g.activo
  loop
    v_inicio := interno.proximo_inicio(v_horario.dia_semana, v_horario.hora, p_ahora);
    if p_ahora >= v_inicio - make_interval(hours => v_horario.abre_horas_antes)
      and interno.crear_partido(v_horario.id, v_inicio) is not null then
      v_creados := v_creados + 1;
    end if;
  end loop;
  return v_creados;
end;
$$;

create function interno.ocupados(p_partido uuid) returns integer
language sql stable set search_path = '' as $$
  select count(*)::integer from public.inscripciones
  where partido_id = p_partido and estado in ('confirmado', 'ofrecido')
$$;

-- Bloquea el partido para el resto de la transacción. Todo cambio de cupos pasa por aquí.
create function interno.bloquear_partido(p_partido uuid) returns public.partidos
language plpgsql volatile set search_path = '' as $$
declare
  v_partido public.partidos;
begin
  select * into v_partido from public.partidos where id = p_partido for update;
  if not found then
    raise exception 'partido_no_existe' using errcode = 'P0001';
  end if;
  return v_partido;
end;
$$;

-- Regla de la banca. Con el partido bloqueado, ofrece cada cupo libre al primero de la banca por orden de
-- llegada, con plazo hasta mínimo(ahora + plazo del grupo, inicio del partido). p_excluir son las
-- inscripciones que acaban de rechazar o dejar vencer su oferta: no se les vuelve a ofrecer en esta pasada.
create function interno.promover_banca(p_partido uuid, p_excluir uuid[] default '{}') returns integer
language plpgsql volatile set search_path = '' as $$
declare
  v_partido public.partidos;
  v_plazo integer;
  v_libres integer;
  v_insc record;
  v_ofrecidas integer := 0;
begin
  select * into v_partido from public.partidos where id = p_partido;
  if v_partido.estado <> 'abierto' or v_partido.inicio <= now() then
    return 0;
  end if;
  select plazo_oferta_min into v_plazo from public.grupos where id = v_partido.grupo_id;
  v_libres := greatest(v_partido.cupos - interno.ocupados(p_partido), 0);

  for v_insc in
    select id, coalesce(miembro_id, invitado_por) as miembro_id
    from public.inscripciones
    where partido_id = p_partido and estado = 'banca' and id <> all (p_excluir)
    order by orden, created_at, id
    limit v_libres
  loop
    update public.inscripciones
    set estado = 'ofrecido',
        oferta_vence_at = least(now() + make_interval(mins => v_plazo), v_partido.inicio)
    where id = v_insc.id;
    perform interno.registrar(v_partido.grupo_id, 'oferta', null, v_insc.miembro_id,
      jsonb_build_object('partido_id', p_partido, 'inscripcion_id', v_insc.id));
    v_ofrecidas := v_ofrecidas + 1;
  end loop;
  return v_ofrecidas;
end;
$$;

-- Ofertas vencidas: vuelven al final de la banca y el cupo se ofrece al siguiente. Lo corre pg_cron.
create function interno.vencer_ofertas() returns integer
language plpgsql volatile set search_path = '' as $$
declare
  v_partido uuid;
  v_vencidas uuid[];
  v_total integer := 0;
begin
  for v_partido in
    select distinct partido_id from public.inscripciones where estado = 'ofrecido' and oferta_vence_at <= now()
  loop
    perform interno.bloquear_partido(v_partido);
    with vencidas as (
      update public.inscripciones
      set estado = 'banca', orden = clock_timestamp(), oferta_vence_at = null
      where partido_id = v_partido and estado = 'ofrecido' and oferta_vence_at <= now()
      returning id
    )
    select array_agg(id) into v_vencidas from vencidas;
    if v_vencidas is not null then
      v_total := v_total + cardinality(v_vencidas);
      perform interno.promover_banca(v_partido, v_vencidas);
    end if;
  end loop;
  return v_total;
end;
$$;

-- Puede actuar sobre la inscripción: es la suya, es su invitado o administra el grupo.
create function interno.exigir_puede_actuar(p_insc public.inscripciones, p_actor record) returns void
language plpgsql stable set search_path = '' as $$
begin
  -- coalesce: en una inscripción de miembro invitado_por es nulo, y "not (false or null)" es nulo, no verdadero.
  if not coalesce(
    p_actor.es_admin or p_insc.miembro_id = p_actor.miembro_id or p_insc.invitado_por = p_actor.miembro_id, false
  ) then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
end;
$$;

-- Cierra el partido y crea un cargo a cada asistente (a quien no se marcó ausente se le cuenta como
-- asistente). Los invitados se cargan a quien los invitó. Con cobrar_ausentes, también a los confirmados
-- que faltaron. Cuota fija, o costo de la cancha ÷ asistentes redondeado hacia arriba a $100.
create function interno.cerrar_partido(p_partido uuid, p_actor uuid) returns integer
language plpgsql volatile set search_path = '' as $$
declare
  v_partido public.partidos := interno.bloquear_partido(p_partido);
  v_cobrar_ausentes boolean;
  v_asistentes integer;
  v_cuota integer;
  v_fecha text;
  v_cargos integer := 0;
begin
  if v_partido.estado <> 'abierto' then
    return 0;
  end if;
  select cobrar_ausentes into v_cobrar_ausentes from public.grupos where id = v_partido.grupo_id;
  select count(*) into v_asistentes from public.inscripciones
  where partido_id = p_partido and estado = 'confirmado' and asistio is distinct from false;

  v_cuota := case
    when v_partido.modo_cobro = 'fija' then v_partido.cuota
    when v_asistentes > 0 then (ceil(v_partido.costo_cancha::numeric / v_asistentes / 100) * 100)::integer
    else 0
  end;
  v_fecha := to_char(v_partido.inicio at time zone 'America/Santiago', 'DD/MM');

  if v_cuota > 0 then
    insert into public.cargos (grupo_id, miembro_id, partido_id, inscripcion_id, tipo, monto, concepto, creado_por)
    select v_partido.grupo_id, coalesce(i.miembro_id, i.invitado_por), p_partido, i.id, 'cuota', v_cuota,
      case when i.miembro_id is null then 'Invitado ' || i.invitado_nombre || ' · ' || v_fecha
           else 'Partido ' || v_fecha end,
      p_actor
    from public.inscripciones i
    where i.partido_id = p_partido and i.estado = 'confirmado'
      and (i.asistio is distinct from false or v_cobrar_ausentes);
    get diagnostics v_cargos = row_count;
  end if;

  update public.inscripciones set estado = 'banca', oferta_vence_at = null
  where partido_id = p_partido and estado = 'ofrecido';
  update public.partidos set estado = 'cerrado', cerrado_at = now() where id = p_partido;
  perform interno.registrar(v_partido.grupo_id, 'partido_cerrado', p_actor, null,
    jsonb_build_object('partido_id', p_partido, 'cuota', v_cuota, 'asistentes', v_asistentes, 'cargos', v_cargos));
  return v_cargos;
end;
$$;

-- Partidos que nadie cerró: se cierran solos 24 horas después del inicio. Lo corre pg_cron.
create function interno.cerrar_partidos_olvidados() returns integer
language plpgsql volatile set search_path = '' as $$
declare
  v_partido uuid;
  v_total integer := 0;
begin
  for v_partido in
    select id from public.partidos where estado = 'abierto' and inicio + interval '24 hours' <= now()
  loop
    perform interno.cerrar_partido(v_partido, null);
    v_total := v_total + 1;
  end loop;
  return v_total;
end;
$$;

-- Sesiones anónimas de más de 30 días que no quedaron en ningún grupo. Lo corre pg_cron.
create function interno.limpiar_anonimos() returns integer
language plpgsql volatile set search_path = '' as $$
declare
  v_total integer;
begin
  delete from auth.users u
  where u.is_anonymous and u.created_at < now() - interval '30 days'
    and not exists (select 1 from public.miembros m where m.auth_user_id = u.id);
  get diagnostics v_total = row_count;
  return v_total;
end;
$$;

-- Da de baja las inscripciones de un miembro en los partidos abiertos que aún no empiezan.
create function interno.bajar_de_partidos_futuros(p_miembro uuid) returns void
language plpgsql volatile set search_path = '' as $$
declare
  v_insc record;
begin
  for v_insc in
    select i.id, i.partido_id, i.estado from public.inscripciones i
    join public.partidos p on p.id = i.partido_id
    where i.miembro_id = p_miembro and i.estado <> 'baja' and p.estado = 'abierto' and p.inicio > now()
  loop
    perform interno.bloquear_partido(v_insc.partido_id);
    update public.inscripciones set estado = 'baja', oferta_vence_at = null where id = v_insc.id;
    if v_insc.estado in ('confirmado', 'ofrecido') then
      perform interno.promover_banca(v_insc.partido_id);
    end if;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- RPC: lectura especial
-- ---------------------------------------------------------------------------------------------------------

-- Lo que muestra el link del grupo antes de anotarse: sin nombres de jugadores. Sirve sin sesión.
create function public.vista_invitacion(
  p_codigo text,
  out grupo_nombre text,
  out formato text,
  out requiere_aprobacion boolean,
  out dia_semana smallint,
  out hora time,
  out partido_inicio timestamptz,
  out cupos smallint,
  out ocupados integer,
  out cancha_nombre text,
  out cancha_comuna text
)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_grupo public.grupos;
  v_partido public.partidos;
  v_horario public.horarios;
begin
  perform interno.limitar('invitacion:ip:' || interno.hash_ip(), 120, interval '1 hour');
  select * into v_grupo from public.grupos g where g.codigo_invitacion = p_codigo and g.activo;
  if not found then
    raise exception 'codigo_invalido' using errcode = 'P0001';
  end if;
  select * into v_horario from public.horarios h
  where h.grupo_id = v_grupo.id and h.activo order by h.created_at limit 1;
  select * into v_partido from public.partidos p
  where p.grupo_id = v_grupo.id and p.estado = 'abierto' and p.inicio + make_interval(mins => p.duracion_min) > now()
  order by p.inicio limit 1;

  grupo_nombre := v_grupo.nombre;
  formato := v_grupo.formato;
  requiere_aprobacion := v_grupo.requiere_aprobacion;
  dia_semana := v_horario.dia_semana;
  hora := v_horario.hora;
  partido_inicio := v_partido.inicio;
  cupos := coalesce(v_partido.cupos, v_horario.cupos);
  ocupados := case when v_partido.id is null then 0 else interno.ocupados(v_partido.id) end;
  select c.nombre, c.comuna into cancha_nombre, cancha_comuna
  from public.canchas c where c.id = coalesce(v_partido.cancha_id, v_horario.cancha_id);
end;
$$;

-- Grupos del usuario, con su miembro y rol (los clientes no pueden leer auth_user_id).
create function public.mis_grupos()
returns table (grupo_id uuid, grupo_nombre text, miembro_id uuid, nombre text, rol text, estado text)
language sql stable security definer set search_path = '' as $$
  select g.id, g.nombre, m.id, m.nombre, m.rol, m.estado
  from public.miembros m join public.grupos g on g.id = m.grupo_id
  where m.auth_user_id = auth.uid() and m.estado in ('activo', 'pendiente') and g.activo
  order by g.created_at
$$;

create function public.grupo_tiene(p_grupo uuid, p_funcion text) returns boolean
language sql stable set search_path = '' as $$
  select exists (
    select 1 from public.grupos g
    join public.plan_funciones f on f.plan_id = g.plan
    where g.id = p_grupo and f.funcion = p_funcion
  )
$$;

-- Saldo de cada uno: pagos confirmados − cargos vigentes (negativo = debe). Los organizadores ven a todos;
-- el resto, solo el propio, salvo que el grupo haya activado las deudas visibles.
create function public.saldos(p_grupo uuid)
returns table (miembro_id uuid, nombre text, cargos integer, pagos integer, saldo integer)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_actor record;
  v_ve_todo boolean;
begin
  select * into v_actor from interno.actor(p_grupo);
  v_ve_todo := acceso.ve_plata(p_grupo);
  return query
  with c as (
    select c.miembro_id, sum(c.monto)::integer as total from public.cargos c
    where c.grupo_id = p_grupo and c.anulado_at is null group by c.miembro_id
  ), p as (
    select p.miembro_id, sum(p.monto)::integer as total from public.pagos p
    where p.grupo_id = p_grupo and p.estado = 'confirmado' group by p.miembro_id
  )
  select m.id, m.nombre, coalesce(c.total, 0), coalesce(p.total, 0), coalesce(p.total, 0) - coalesce(c.total, 0)
  from public.miembros m
  left join c on c.miembro_id = m.id
  left join p on p.miembro_id = m.id
  where m.grupo_id = p_grupo
    and (m.estado = 'activo' or c.total is not null or p.total is not null)
    and (v_ve_todo or m.id = v_actor.miembro_id)
  order by m.nombre;
end;
$$;

-- Caja del grupo = pagos confirmados + ingresos − gastos.
create function public.caja(p_grupo uuid, out pagos integer, out ingresos integer, out gastos integer, out saldo integer)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform interno.actor(p_grupo);
  if not acceso.ve_plata(p_grupo) then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  select coalesce(sum(monto), 0)::integer into pagos from public.pagos
  where grupo_id = p_grupo and estado = 'confirmado';
  select coalesce(sum(monto) filter (where tipo = 'ingreso'), 0)::integer,
         coalesce(sum(monto) filter (where tipo = 'gasto'), 0)::integer
  into ingresos, gastos
  from public.movimientos_caja where grupo_id = p_grupo and anulado_at is null;
  saldo := pagos + ingresos - gastos;
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- RPC: canchas, grupos y horarios
-- ---------------------------------------------------------------------------------------------------------

create function public.crear_cancha(
  p_nombre text,
  p_comuna text,
  p_recinto text default null,
  p_direccion text default null,
  p_whatsapp text default null,
  p_superficie text default null,
  p_formatos text[] default '{}'
) returns uuid
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := interno.usuario_con_cuenta();
  v_whatsapp text := interno.normalizar_celular_cl(p_whatsapp);
  v_id uuid;
begin
  perform interno.limitar('cancha:' || v_uid, 20, interval '1 day');
  if interno.limpiar(p_whatsapp) is not null and v_whatsapp is null then
    raise exception 'whatsapp_invalido' using errcode = 'P0001';
  end if;
  insert into public.canchas (nombre, recinto, direccion, comuna, whatsapp, superficie, formatos, creada_por)
  values (interno.limpiar(p_nombre), interno.limpiar(p_recinto), interno.limpiar(p_direccion),
    interno.limpiar(p_comuna), v_whatsapp, p_superficie, coalesce(p_formatos, '{}'), v_uid)
  returning id into v_id;
  return v_id;
exception
  when check_violation or not_null_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

-- Crea el grupo con su organizador, la pichanga fija y el primer partido (abierto de inmediato para poder
-- compartir el link). Exige cuenta: los jugadores anónimos no organizan.
create function public.crear_grupo(
  p_nombre text,
  p_formato text,
  p_nombre_organizador text,
  p_dia_semana integer,
  p_hora time,
  p_cupos integer,
  p_duracion_min integer default 60,
  p_cancha uuid default null,
  p_modo_cobro text default 'fija',
  p_cuota integer default 0,
  p_costo_cancha integer default 0,
  p_abre_horas_antes integer default 144
) returns public.grupos
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := interno.usuario_con_cuenta();
  v_grupo public.grupos;
  v_organizador uuid;
  v_horario uuid;
begin
  perform interno.limitar('crear_grupo:' || v_uid, 10, interval '1 day');
  insert into public.grupos (nombre, formato)
  values (interno.limpiar(p_nombre), p_formato)
  returning * into v_grupo;

  insert into public.miembros (grupo_id, nombre, nombre_normalizado, rol, auth_user_id)
  values (v_grupo.id, interno.limpiar(p_nombre_organizador), interno.normalizar_nombre(p_nombre_organizador),
    'organizador', v_uid)
  returning id into v_organizador;

  insert into public.horarios (grupo_id, dia_semana, hora, duracion_min, cancha_id, cupos, modo_cobro, cuota,
    costo_cancha, abre_horas_antes)
  values (v_grupo.id, p_dia_semana, p_hora, p_duracion_min, p_cancha, p_cupos, p_modo_cobro, p_cuota,
    p_costo_cancha, p_abre_horas_antes)
  returning id into v_horario;

  perform interno.crear_partido(v_horario, interno.proximo_inicio(p_dia_semana, p_hora, now()));
  perform interno.registrar(v_grupo.id, 'grupo_creado', v_organizador, v_organizador);
  return v_grupo;
exception
  when check_violation or not_null_violation or foreign_key_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

-- Ajustes del grupo. Un parámetro nulo deja el valor como está.
create function public.actualizar_grupo(
  p_grupo uuid,
  p_nombre text default null,
  p_requiere_aprobacion boolean default null,
  p_deudas_visibles boolean default null,
  p_plazo_oferta_min integer default null,
  p_cobrar_ausentes boolean default null
) returns public.grupos
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := interno.exigir_admin(p_grupo);
  v_grupo public.grupos;
begin
  update public.grupos set
    nombre = coalesce(interno.limpiar(p_nombre), nombre),
    requiere_aprobacion = coalesce(p_requiere_aprobacion, requiere_aprobacion),
    deudas_visibles = coalesce(p_deudas_visibles, deudas_visibles),
    plazo_oferta_min = coalesce(p_plazo_oferta_min, plazo_oferta_min),
    cobrar_ausentes = coalesce(p_cobrar_ausentes, cobrar_ausentes)
  where id = p_grupo
  returning * into v_grupo;
  perform interno.registrar(p_grupo, 'grupo_actualizado', v_actor, null);
  return v_grupo;
exception
  when check_violation or not_null_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

-- Nuevo código de invitación: el link anterior deja de servir.
create function public.rotar_codigo(p_grupo uuid) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := interno.exigir_admin(p_grupo);
  v_codigo text;
begin
  update public.grupos set codigo_invitacion = interno.token_aleatorio(8)
  where id = p_grupo returning codigo_invitacion into v_codigo;
  perform interno.registrar(p_grupo, 'codigo_rotado', v_actor, null);
  return v_codigo;
end;
$$;

create function public.guardar_datos_pago(
  p_grupo uuid,
  p_titular text,
  p_rut text,
  p_banco text,
  p_tipo_cuenta text,
  p_numero_cuenta text,
  p_correo text
) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := interno.exigir_admin(p_grupo);
  v_correo text := lower(interno.limpiar(p_correo));
begin
  if v_correo is not null and not interno.correo_valido(v_correo) then
    raise exception 'correo_invalido' using errcode = 'P0001';
  end if;
  insert into public.grupo_datos_pago (grupo_id, titular, rut, banco, tipo_cuenta, numero_cuenta, correo)
  values (p_grupo, interno.limpiar(p_titular), interno.limpiar(p_rut), interno.limpiar(p_banco),
    interno.limpiar(p_tipo_cuenta), interno.limpiar(p_numero_cuenta), v_correo)
  on conflict (grupo_id) do update set
    titular = excluded.titular, rut = excluded.rut, banco = excluded.banco, tipo_cuenta = excluded.tipo_cuenta,
    numero_cuenta = excluded.numero_cuenta, correo = excluded.correo, updated_at = now();
  perform interno.registrar(p_grupo, 'datos_pago_actualizados', v_actor, null);
exception
  when check_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

-- Cambia la pichanga fija; afecta a los partidos que se creen desde ahora. Un parámetro nulo deja el valor
-- como está.
create function public.actualizar_horario(
  p_horario uuid,
  p_dia_semana integer default null,
  p_hora time default null,
  p_duracion_min integer default null,
  p_cancha uuid default null,
  p_cupos integer default null,
  p_modo_cobro text default null,
  p_cuota integer default null,
  p_costo_cancha integer default null,
  p_abre_horas_antes integer default null,
  p_activo boolean default null
) returns public.horarios
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_horario public.horarios;
  v_actor uuid;
begin
  select * into v_horario from public.horarios where id = p_horario;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  v_actor := interno.exigir_admin(v_horario.grupo_id);
  update public.horarios set
    dia_semana = coalesce(p_dia_semana, dia_semana),
    hora = coalesce(p_hora, hora),
    duracion_min = coalesce(p_duracion_min, duracion_min),
    cancha_id = coalesce(p_cancha, cancha_id),
    cupos = coalesce(p_cupos, cupos),
    modo_cobro = coalesce(p_modo_cobro, modo_cobro),
    cuota = coalesce(p_cuota, cuota),
    costo_cancha = coalesce(p_costo_cancha, costo_cancha),
    abre_horas_antes = coalesce(p_abre_horas_antes, abre_horas_antes),
    activo = coalesce(p_activo, activo)
  where id = p_horario
  returning * into v_horario;
  perform interno.registrar(v_horario.grupo_id, 'horario_actualizado', v_actor, null);
  return v_horario;
exception
  when check_violation or not_null_violation or foreign_key_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- RPC: miembros e identidad sin cuenta
-- ---------------------------------------------------------------------------------------------------------

-- Anotarse en el grupo desde el link. Resultados:
--   unido / pendiente (espera aprobación) / ya_eras_miembro
--   nombre_sin_celular: ya hay alguien con ese nombre sin celular; la app pregunta "¿Eres tú?" y, si dice que
--     sí, se vuelve a llamar con p_es_yo = true → vinculado (queda registro y el organizador puede deshacer).
--   nombre_con_celular: ese nombre ya tiene otro celular; la app ofrece pedirle el link personal al organizador.
create function public.unirse(
  p_codigo text,
  p_nombre text,
  p_es_yo boolean default false,
  out resultado text,
  out grupo_id uuid,
  out miembro_id uuid
)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := interno.usuario();
  v_grupo public.grupos;
  v_propio public.miembros;
  v_igual public.miembros;
  v_nombre text := interno.limpiar(p_nombre);
begin
  perform interno.limitar('unirse:' || v_uid, 20, interval '1 hour');
  select * into v_grupo from public.grupos g where g.codigo_invitacion = p_codigo and g.activo;
  if not found then
    raise exception 'codigo_invalido' using errcode = 'P0001';
  end if;
  grupo_id := v_grupo.id;

  select * into v_propio from public.miembros m where m.grupo_id = v_grupo.id and m.auth_user_id = v_uid;
  if found then
    if v_propio.estado = 'activo' then
      resultado := 'ya_eras_miembro';
    elsif v_propio.estado = 'pendiente' then
      resultado := 'pendiente';
    else
      raise exception 'no_admitido' using errcode = 'P0001';
    end if;
    miembro_id := v_propio.id;
    return;
  end if;

  if v_nombre is null or char_length(v_nombre) not between 2 and 40 then
    raise exception 'nombre_invalido' using errcode = 'P0001';
  end if;

  select * into v_igual from public.miembros m
  where m.grupo_id = v_grupo.id and m.nombre_normalizado = interno.normalizar_nombre(v_nombre)
    and m.estado in ('pendiente', 'activo')
  for update;
  if found then
    -- Nadie se vincula por nombre a un organizador ni a quien ya tiene celular.
    if v_igual.auth_user_id is not null or v_igual.rol <> 'jugador' then
      resultado := 'nombre_con_celular';
    elsif p_es_yo is not true then
      resultado := 'nombre_sin_celular';
    else
      update public.miembros set auth_user_id = v_uid where id = v_igual.id;
      perform interno.registrar(v_grupo.id, 'vinculacion', v_igual.id, v_igual.id,
        jsonb_build_object('via', 'nombre'));
      resultado := 'vinculado';
      miembro_id := v_igual.id;
    end if;
    return;
  end if;

  perform interno.limitar('unirse_grupo:' || v_grupo.id, 60, interval '1 hour');
  insert into public.miembros (grupo_id, nombre, nombre_normalizado, estado, auth_user_id)
  values (v_grupo.id, v_nombre, interno.normalizar_nombre(v_nombre),
    case when v_grupo.requiere_aprobacion then 'pendiente' else 'activo' end, v_uid)
  returning id into miembro_id;
  resultado := case when v_grupo.requiere_aprobacion then 'pendiente' else 'unido' end;
  perform interno.registrar(v_grupo.id, case when v_grupo.requiere_aprobacion then 'postulacion' else 'union' end,
    miembro_id, miembro_id);
end;
$$;

-- El organizador agrega a mano (pegando la lista del WhatsApp). Omite nombres repetidos o inválidos y
-- devuelve los que agregó.
create function public.agregar_miembros(p_grupo uuid, p_nombres text[])
returns table (miembro_id uuid, nombre text)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := interno.exigir_admin(p_grupo);
  v_nombre text;
  v_id uuid;
begin
  if cardinality(p_nombres) > 100 then
    raise exception 'demasiados_nombres' using errcode = 'P0001';
  end if;
  foreach v_nombre in array coalesce(p_nombres, '{}') loop
    v_nombre := interno.limpiar(v_nombre);
    continue when v_nombre is null or char_length(v_nombre) not between 2 and 40;
    insert into public.miembros (grupo_id, nombre, nombre_normalizado)
    values (p_grupo, v_nombre, interno.normalizar_nombre(v_nombre))
    on conflict (grupo_id, nombre_normalizado) where estado in ('pendiente', 'activo') do nothing
    returning id into v_id;
    if v_id is not null then
      perform interno.registrar(p_grupo, 'miembro_agregado', v_actor, v_id);
      miembro_id := v_id;
      nombre := v_nombre;
      return next;
    end if;
  end loop;
end;
$$;

-- Busca un miembro del grupo y exige que quien llama lo administre.
create function interno.miembro_administrado(p_miembro uuid, out miembro public.miembros, out actor uuid)
language plpgsql stable set search_path = '' as $$
begin
  select * into miembro from public.miembros where id = p_miembro;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  actor := interno.exigir_admin(miembro.grupo_id);
end;
$$;

create function public.responder_postulante(p_miembro uuid, p_aprobar boolean) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v record;
begin
  select * into v from interno.miembro_administrado(p_miembro);
  if (v.miembro).estado <> 'pendiente' then
    raise exception 'no_es_postulante' using errcode = 'P0001';
  end if;
  if p_aprobar is null then
    raise exception 'datos_invalidos' using errcode = 'P0001';
  end if;
  update public.miembros set estado = case when p_aprobar then 'activo' else 'rechazado' end where id = p_miembro;
  perform interno.registrar((v.miembro).grupo_id, case when p_aprobar then 'postulante_aprobado' else 'postulante_rechazado' end,
    v.actor, p_miembro);
end;
$$;

-- Solo el organizador cambia roles, y no el suyo propio.
create function public.cambiar_rol(p_miembro uuid, p_rol text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_miembro public.miembros;
  v_actor record;
begin
  select * into v_miembro from public.miembros where id = p_miembro;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  select * into v_actor from interno.actor(v_miembro.grupo_id);
  if not v_actor.es_organizador or v_actor.miembro_id = p_miembro then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  if v_miembro.estado <> 'activo' then
    raise exception 'miembro_invalido' using errcode = 'P0001';
  end if;
  if p_rol not in ('organizador', 'coorganizador', 'jugador') then
    raise exception 'datos_invalidos' using errcode = 'P0001';
  end if;
  update public.miembros set rol = p_rol where id = p_miembro;
  perform interno.registrar(v_miembro.grupo_id, 'rol_cambiado', v_actor.miembro_id, p_miembro,
    jsonb_build_object('antes', v_miembro.rol, 'despues', p_rol));
end;
$$;

-- Quita al miembro del grupo: no puede volver a entrar con ese celular y sale de los próximos partidos.
create function public.quitar_miembro(p_miembro uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_miembro public.miembros;
  v_actor record;
begin
  select * into v_miembro from public.miembros where id = p_miembro;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  select * into v_actor from interno.actor(v_miembro.grupo_id);
  if not v_actor.es_admin or v_actor.miembro_id = p_miembro
    or (v_miembro.rol <> 'jugador' and not v_actor.es_organizador) then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  update public.miembros set estado = 'retirado' where id = p_miembro;
  perform interno.bajar_de_partidos_futuros(p_miembro);
  perform interno.registrar(v_miembro.grupo_id, 'miembro_quitado', v_actor.miembro_id, p_miembro);
end;
$$;

-- Deshace una vinculación (por nombre o por link personal): el celular deja de ser ese jugador.
create function public.desvincular(p_miembro uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v record;
begin
  select * into v from interno.miembro_administrado(p_miembro);
  if (v.miembro).rol <> 'jugador' then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  update public.miembros set auth_user_id = null where id = p_miembro;
  perform interno.registrar((v.miembro).grupo_id, 'desvinculacion', v.actor, p_miembro);
end;
$$;

-- Borra los datos personales del jugador (ley 21.719): queda como "Jugador borrado" en el historial.
create function public.borrar_miembro(p_miembro uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v record;
begin
  select * into v from interno.miembro_administrado(p_miembro);
  if (v.miembro).rol <> 'jugador' then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  update public.miembros
  set nombre = 'Jugador borrado', nombre_normalizado = 'jugador borrado ' || id, estado = 'retirado',
      auth_user_id = null
  where id = p_miembro;
  delete from public.miembros_privado where miembro_id = p_miembro;
  delete from interno.enlaces_personales where miembro_id = p_miembro;
  perform interno.bajar_de_partidos_futuros(p_miembro);
  perform interno.registrar((v.miembro).grupo_id, 'miembro_borrado', v.actor, p_miembro);
end;
$$;

-- Link personal: 128 bits, se guarda solo el hash, vence en 30 días y sirve una sola vez.
-- Generar uno nuevo invalida el anterior. Devuelve el token, que solo se ve en este momento.
create function public.generar_link_personal(p_miembro uuid) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  v record;
  v_token text := interno.token_aleatorio(16);
begin
  select * into v from interno.miembro_administrado(p_miembro);
  if (v.miembro).estado <> 'activo' then
    raise exception 'miembro_invalido' using errcode = 'P0001';
  end if;
  insert into interno.enlaces_personales (miembro_id, token_hash, vence_at, creado_por)
  values (p_miembro, interno.hash_token(v_token), now() + interval '30 days', v.actor)
  on conflict (miembro_id) do update set
    token_hash = excluded.token_hash, vence_at = excluded.vence_at, creado_por = excluded.creado_por,
    created_at = now();
  perform interno.registrar((v.miembro).grupo_id, 'link_personal_generado', v.actor, p_miembro);
  return v_token;
end;
$$;

-- Usa el link personal: este celular pasa a ser ese jugador y el anterior queda desvinculado. Si este
-- celular ya era otro miembro del grupo, ese otro queda sin celular.
create function public.usar_link_personal(p_token text, out grupo_id uuid, out miembro_id uuid)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := interno.usuario();
  v_enlace interno.enlaces_personales;
  v_miembro public.miembros;
begin
  perform interno.limitar('link_personal:' || v_uid, 10, interval '1 hour');
  select * into v_enlace from interno.enlaces_personales e
  where e.token_hash = interno.hash_token(p_token) and e.vence_at > now()
  for update;
  if not found then
    raise exception 'link_invalido' using errcode = 'P0001';
  end if;
  select * into v_miembro from public.miembros m where m.id = v_enlace.miembro_id for update;
  if v_miembro.estado <> 'activo' then
    raise exception 'link_invalido' using errcode = 'P0001';
  end if;

  update public.miembros m set auth_user_id = null
  where m.grupo_id = v_miembro.grupo_id and m.auth_user_id = v_uid and m.id <> v_miembro.id;
  update public.miembros m set auth_user_id = v_uid where m.id = v_miembro.id;
  delete from interno.enlaces_personales e where e.miembro_id = v_miembro.id;
  perform interno.registrar(v_miembro.grupo_id, 'vinculacion', v_miembro.id, v_miembro.id,
    jsonb_build_object('via', 'link_personal', 'tenia_celular', v_miembro.auth_user_id is not null));
  grupo_id := v_miembro.grupo_id;
  miembro_id := v_miembro.id;
end;
$$;

-- Teléfono para avisos: el propio jugador o un organizador.
create function public.guardar_telefono(p_miembro uuid, p_telefono text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_miembro public.miembros;
  v_actor record;
  v_telefono text := interno.normalizar_celular_cl(p_telefono);
begin
  select * into v_miembro from public.miembros where id = p_miembro;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  select * into v_actor from interno.actor(v_miembro.grupo_id);
  if not v_actor.es_admin and v_actor.miembro_id <> p_miembro then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  if interno.limpiar(p_telefono) is not null and v_telefono is null then
    raise exception 'whatsapp_invalido' using errcode = 'P0001';
  end if;
  insert into public.miembros_privado (miembro_id, grupo_id, telefono)
  values (p_miembro, v_miembro.grupo_id, v_telefono)
  on conflict (miembro_id) do update set telefono = excluded.telefono, updated_at = now();
end;
$$;

create function public.guardar_nivel(p_miembro uuid, p_nivel integer) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v record;
begin
  select * into v from interno.miembro_administrado(p_miembro);
  insert into public.miembros_privado (miembro_id, grupo_id, nivel)
  values (p_miembro, (v.miembro).grupo_id, p_nivel)
  on conflict (miembro_id) do update set nivel = excluded.nivel, updated_at = now();
exception
  when check_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- RPC: partido de la semana y banca
-- ---------------------------------------------------------------------------------------------------------

-- "Voy". Sin p_miembro se anota quien llama; un organizador puede anotar a cualquiera del grupo.
-- Si hay cupo queda confirmado; si no, al final de la banca. Si tenía una oferta, la acepta.
create function public.anotarse(p_partido uuid, p_miembro uuid default null) returns public.inscripciones
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_partido public.partidos := interno.bloquear_partido(p_partido);
  v_actor record;
  v_miembro uuid;
  v_insc public.inscripciones;
  v_existe boolean;
  v_estado text;
begin
  select * into v_actor from interno.actor(v_partido.grupo_id);
  v_miembro := coalesce(p_miembro, v_actor.miembro_id);
  if v_miembro <> v_actor.miembro_id and not v_actor.es_admin then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  if v_partido.estado <> 'abierto' then
    raise exception 'partido_cerrado' using errcode = 'P0001';
  end if;
  if v_partido.inicio <= now() and not v_actor.es_admin then
    raise exception 'partido_empezado' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.miembros where id = v_miembro and grupo_id = v_partido.grupo_id and estado = 'activo'
  ) then
    raise exception 'miembro_invalido' using errcode = 'P0001';
  end if;
  perform interno.limitar('anotarse:' || auth.uid(), 120, interval '1 hour');

  select * into v_insc from public.inscripciones where partido_id = p_partido and miembro_id = v_miembro;
  v_existe := found;
  if v_existe and v_insc.estado = 'confirmado' then
    return v_insc;
  end if;
  if v_existe and v_insc.estado = 'ofrecido' then
    update public.inscripciones set estado = 'confirmado', oferta_vence_at = null
    where id = v_insc.id returning * into v_insc;
    return v_insc;
  end if;

  v_estado := case when interno.ocupados(p_partido) < v_partido.cupos then 'confirmado' else 'banca' end;
  if not v_existe then
    insert into public.inscripciones (partido_id, grupo_id, miembro_id, estado)
    values (p_partido, v_partido.grupo_id, v_miembro, v_estado)
    returning * into v_insc;
  elsif v_insc.estado = 'baja' then
    update public.inscripciones set estado = v_estado, orden = clock_timestamp(), asistio = null
    where id = v_insc.id returning * into v_insc;
  elsif v_estado = 'confirmado' then
    -- Estaba en la banca y hay un cupo libre (nadie antes que él lo esperaba).
    update public.inscripciones set estado = 'confirmado' where id = v_insc.id returning * into v_insc;
  end if;
  return v_insc;
end;
$$;

-- "No voy". Si liberaba un cupo, se ofrece al primero de la banca.
create function public.bajarse(p_inscripcion uuid) returns public.inscripciones
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_insc public.inscripciones;
  v_partido public.partidos;
  v_actor record;
begin
  select * into v_insc from public.inscripciones where id = p_inscripcion;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  v_partido := interno.bloquear_partido(v_insc.partido_id);
  select * into v_insc from public.inscripciones where id = p_inscripcion;
  select * into v_actor from interno.actor(v_partido.grupo_id);
  perform interno.exigir_puede_actuar(v_insc, v_actor);
  if v_partido.estado <> 'abierto' then
    raise exception 'partido_cerrado' using errcode = 'P0001';
  end if;
  if v_insc.estado = 'baja' then
    return v_insc;
  end if;
  update public.inscripciones set estado = 'baja', oferta_vence_at = null
  where id = p_inscripcion returning * into v_insc;
  perform interno.promover_banca(v_partido.id);
  return v_insc;
end;
$$;

-- Acepta o rechaza el cupo ofrecido. Si rechaza (o la oferta ya venció), vuelve al final de la banca y el
-- cupo pasa al siguiente. Devuelve la inscripción: su estado dice cómo quedó.
create function public.responder_oferta(p_inscripcion uuid, p_acepta boolean) returns public.inscripciones
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_insc public.inscripciones;
  v_partido public.partidos;
  v_actor record;
begin
  select * into v_insc from public.inscripciones where id = p_inscripcion;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  v_partido := interno.bloquear_partido(v_insc.partido_id);
  select * into v_insc from public.inscripciones where id = p_inscripcion;
  select * into v_actor from interno.actor(v_partido.grupo_id);
  perform interno.exigir_puede_actuar(v_insc, v_actor);
  if v_insc.estado <> 'ofrecido' then
    raise exception 'sin_oferta' using errcode = 'P0001';
  end if;

  if p_acepta is null then
    raise exception 'datos_invalidos' using errcode = 'P0001';
  end if;
  if p_acepta and v_insc.oferta_vence_at > now() and v_partido.estado = 'abierto' then
    update public.inscripciones set estado = 'confirmado', oferta_vence_at = null
    where id = p_inscripcion returning * into v_insc;
  else
    update public.inscripciones set estado = 'banca', orden = clock_timestamp(), oferta_vence_at = null
    where id = p_inscripcion returning * into v_insc;
    perform interno.promover_banca(v_partido.id, array[p_inscripcion]);
  end if;
  return v_insc;
end;
$$;

-- Invitado de un miembro: ocupa cupo por orden de llegada como cualquiera, y su cuota se le carga a quien
-- lo invitó. Un jugador puede traer hasta 3 por partido.
create function public.agregar_invitado(p_partido uuid, p_nombre text, p_invitado_por uuid default null)
returns public.inscripciones
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_partido public.partidos := interno.bloquear_partido(p_partido);
  v_actor record;
  v_anfitrion uuid;
  v_nombre text := interno.limpiar(p_nombre);
  v_insc public.inscripciones;
begin
  select * into v_actor from interno.actor(v_partido.grupo_id);
  v_anfitrion := coalesce(p_invitado_por, v_actor.miembro_id);
  if v_anfitrion <> v_actor.miembro_id and not v_actor.es_admin then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  if v_partido.estado <> 'abierto' then
    raise exception 'partido_cerrado' using errcode = 'P0001';
  end if;
  if v_partido.inicio <= now() and not v_actor.es_admin then
    raise exception 'partido_empezado' using errcode = 'P0001';
  end if;
  if not exists (
    select 1 from public.miembros where id = v_anfitrion and grupo_id = v_partido.grupo_id and estado = 'activo'
  ) then
    raise exception 'miembro_invalido' using errcode = 'P0001';
  end if;
  if v_nombre is null or char_length(v_nombre) not between 2 and 40 then
    raise exception 'nombre_invalido' using errcode = 'P0001';
  end if;
  if not v_actor.es_admin and (
    select count(*) from public.inscripciones
    where partido_id = p_partido and invitado_por = v_anfitrion and estado <> 'baja'
  ) >= 3 then
    raise exception 'demasiados_invitados' using errcode = 'P0001';
  end if;

  insert into public.inscripciones (partido_id, grupo_id, invitado_nombre, invitado_por, estado)
  values (p_partido, v_partido.grupo_id, v_nombre, v_anfitrion,
    case when interno.ocupados(p_partido) < v_partido.cupos then 'confirmado' else 'banca' end)
  returning * into v_insc;
  return v_insc;
end;
$$;

-- Cambia los cupos de este partido. Al subir se ofrece a la banca; no se puede bajar de los ocupados.
create function public.cambiar_cupos(p_partido uuid, p_cupos integer) returns public.partidos
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_partido public.partidos := interno.bloquear_partido(p_partido);
  v_actor uuid := interno.exigir_admin(v_partido.grupo_id);
begin
  if v_partido.estado <> 'abierto' then
    raise exception 'partido_cerrado' using errcode = 'P0001';
  end if;
  if p_cupos < interno.ocupados(p_partido) then
    raise exception 'cupos_ocupados' using errcode = 'P0001';
  end if;
  update public.partidos set cupos = p_cupos where id = p_partido returning * into v_partido;
  perform interno.promover_banca(p_partido);
  perform interno.registrar(v_partido.grupo_id, 'cupos_cambiados', v_actor, null,
    jsonb_build_object('partido_id', p_partido, 'cupos', p_cupos));
  return v_partido;
exception
  when check_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

-- Modo cancha: llegó o no llegó.
create function public.marcar_asistencia(p_inscripcion uuid, p_asistio boolean) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_insc public.inscripciones;
  v_partido public.partidos;
begin
  select * into v_insc from public.inscripciones where id = p_inscripcion;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  v_partido := interno.bloquear_partido(v_insc.partido_id);
  perform interno.exigir_admin(v_partido.grupo_id);
  if v_partido.estado <> 'abierto' then
    raise exception 'partido_cerrado' using errcode = 'P0001';
  end if;
  if v_insc.estado <> 'confirmado' then
    raise exception 'no_confirmado' using errcode = 'P0001';
  end if;
  update public.inscripciones set asistio = p_asistio where id = p_inscripcion;
end;
$$;

create function public.cerrar_partido(p_partido uuid) returns integer
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_partido public.partidos := interno.bloquear_partido(p_partido);
  v_actor uuid := interno.exigir_admin(v_partido.grupo_id);
begin
  if v_partido.estado <> 'abierto' then
    raise exception 'partido_cerrado' using errcode = 'P0001';
  end if;
  return interno.cerrar_partido(p_partido, v_actor);
end;
$$;

create function public.cancelar_partido(p_partido uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_partido public.partidos := interno.bloquear_partido(p_partido);
  v_actor uuid := interno.exigir_admin(v_partido.grupo_id);
begin
  if v_partido.estado <> 'abierto' then
    raise exception 'partido_cerrado' using errcode = 'P0001';
  end if;
  update public.inscripciones set estado = 'banca', oferta_vence_at = null
  where partido_id = p_partido and estado = 'ofrecido';
  update public.partidos set estado = 'cancelado', cerrado_at = now() where id = p_partido;
  perform interno.registrar(v_partido.grupo_id, 'partido_cancelado', v_actor, null,
    jsonb_build_object('partido_id', p_partido));
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- RPC: plata
-- ---------------------------------------------------------------------------------------------------------

-- El organizador registra efectivo o transferencias (quedan confirmados). El jugador solo informa "ya
-- transferí" por sí mismo (queda esperando confirmación). El id lo pone el cliente: repetir el mismo envío
-- no duplica el pago.
create function public.registrar_pago(
  p_id uuid,
  p_grupo uuid,
  p_miembro uuid,
  p_monto integer,
  p_medio text,
  p_partido uuid default null
) returns public.pagos
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor record;
  v_pago public.pagos;
begin
  select * into v_actor from interno.actor(p_grupo);
  select * into v_pago from public.pagos where id = p_id;
  if found then
    if v_pago.grupo_id is distinct from p_grupo or v_pago.miembro_id is distinct from p_miembro
      or v_pago.monto is distinct from p_monto or v_pago.medio is distinct from p_medio then
      raise exception 'pago_duplicado' using errcode = 'P0001';
    end if;
    return v_pago;
  end if;

  if not v_actor.es_admin then
    if p_miembro is distinct from v_actor.miembro_id or p_medio is distinct from 'transferencia' then
      raise exception 'no_autorizado' using errcode = 'P0001';
    end if;
    perform interno.limitar('pago:' || auth.uid(), 20, interval '1 hour');
  end if;
  if not exists (select 1 from public.miembros where id = p_miembro and grupo_id = p_grupo) then
    raise exception 'miembro_invalido' using errcode = 'P0001';
  end if;
  if p_partido is not null and not exists (select 1 from public.partidos where id = p_partido and grupo_id = p_grupo) then
    raise exception 'datos_invalidos' using errcode = 'P0001';
  end if;

  insert into public.pagos (id, grupo_id, miembro_id, partido_id, monto, medio, estado, registrado_por,
    revisado_por, revisado_at)
  values (p_id, p_grupo, p_miembro, p_partido, p_monto, p_medio,
    case when v_actor.es_admin then 'confirmado' else 'informado' end, v_actor.miembro_id,
    case when v_actor.es_admin then v_actor.miembro_id end, case when v_actor.es_admin then now() end)
  on conflict (id) do nothing
  returning * into v_pago;
  if v_pago.id is null then
    select * into v_pago from public.pagos where id = p_id;
    return v_pago;
  end if;
  perform interno.registrar(p_grupo, 'pago_registrado', v_actor.miembro_id, p_miembro,
    jsonb_build_object('pago_id', p_id, 'monto', p_monto, 'medio', p_medio, 'estado', v_pago.estado));
  return v_pago;
exception
  when check_violation or not_null_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

-- El organizador confirma o rechaza un pago (también sirve para corregir uno ya confirmado).
create function public.revisar_pago(p_pago uuid, p_confirmar boolean) returns public.pagos
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_pago public.pagos;
  v_actor uuid;
begin
  select * into v_pago from public.pagos where id = p_pago for update;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  v_actor := interno.exigir_admin(v_pago.grupo_id);
  if p_confirmar is null then
    raise exception 'datos_invalidos' using errcode = 'P0001';
  end if;
  update public.pagos
  set estado = case when p_confirmar then 'confirmado' else 'rechazado' end, revisado_por = v_actor, revisado_at = now()
  where id = p_pago returning * into v_pago;
  perform interno.registrar(v_pago.grupo_id, case when p_confirmar then 'pago_confirmado' else 'pago_rechazado' end,
    v_actor, v_pago.miembro_id, jsonb_build_object('pago_id', p_pago, 'monto', v_pago.monto));
  return v_pago;
end;
$$;

-- Ajuste manual del saldo de un jugador (positivo = debe más; negativo = a favor).
create function public.registrar_ajuste(p_grupo uuid, p_miembro uuid, p_monto integer, p_concepto text)
returns public.cargos
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := interno.exigir_admin(p_grupo);
  v_cargo public.cargos;
begin
  if not exists (select 1 from public.miembros where id = p_miembro and grupo_id = p_grupo) then
    raise exception 'miembro_invalido' using errcode = 'P0001';
  end if;
  insert into public.cargos (grupo_id, miembro_id, tipo, monto, concepto, creado_por)
  values (p_grupo, p_miembro, 'ajuste', p_monto, interno.limpiar(p_concepto), v_actor)
  returning * into v_cargo;
  perform interno.registrar(p_grupo, 'ajuste', v_actor, p_miembro,
    jsonb_build_object('cargo_id', v_cargo.id, 'monto', p_monto));
  return v_cargo;
exception
  when check_violation or not_null_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

create function public.anular_cargo(p_cargo uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_cargo public.cargos;
  v_actor uuid;
begin
  select * into v_cargo from public.cargos where id = p_cargo for update;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  v_actor := interno.exigir_admin(v_cargo.grupo_id);
  if v_cargo.anulado_at is not null then
    return;
  end if;
  update public.cargos set anulado_at = now(), anulado_por = v_actor where id = p_cargo;
  perform interno.registrar(v_cargo.grupo_id, 'cargo_anulado', v_actor, v_cargo.miembro_id,
    jsonb_build_object('cargo_id', p_cargo, 'monto', v_cargo.monto));
end;
$$;

create function public.registrar_movimiento(
  p_id uuid,
  p_grupo uuid,
  p_tipo text,
  p_monto integer,
  p_concepto text,
  p_partido uuid default null
) returns public.movimientos_caja
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_actor uuid := interno.exigir_admin(p_grupo);
  v_mov public.movimientos_caja;
begin
  if p_partido is not null and not exists (select 1 from public.partidos where id = p_partido and grupo_id = p_grupo) then
    raise exception 'datos_invalidos' using errcode = 'P0001';
  end if;
  insert into public.movimientos_caja (id, grupo_id, tipo, monto, concepto, partido_id, registrado_por)
  values (p_id, p_grupo, p_tipo, p_monto, interno.limpiar(p_concepto), p_partido, v_actor)
  on conflict (id) do nothing
  returning * into v_mov;
  if v_mov.id is null then
    select * into v_mov from public.movimientos_caja where id = p_id;
    if v_mov.grupo_id is distinct from p_grupo or v_mov.tipo is distinct from p_tipo
      or v_mov.monto is distinct from p_monto then
      raise exception 'movimiento_duplicado' using errcode = 'P0001';
    end if;
    return v_mov;
  end if;
  perform interno.registrar(p_grupo, 'movimiento_caja', v_actor, null,
    jsonb_build_object('movimiento_id', p_id, 'tipo', p_tipo, 'monto', p_monto));
  return v_mov;
exception
  when check_violation or not_null_violation then
    raise exception 'datos_invalidos' using errcode = 'P0001';
end;
$$;

create function public.anular_movimiento(p_movimiento uuid) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_mov public.movimientos_caja;
  v_actor uuid;
begin
  select * into v_mov from public.movimientos_caja where id = p_movimiento for update;
  if not found then
    raise exception 'no_autorizado' using errcode = 'P0001';
  end if;
  v_actor := interno.exigir_admin(v_mov.grupo_id);
  if v_mov.anulado_at is not null then
    return;
  end if;
  update public.movimientos_caja set anulado_at = now(), anulado_por = v_actor where id = p_movimiento;
  perform interno.registrar(v_mov.grupo_id, 'movimiento_anulado', v_actor, null,
    jsonb_build_object('movimiento_id', p_movimiento, 'monto', v_mov.monto));
end;
$$;

-- ---------------------------------------------------------------------------------------------------------
-- Permisos de las funciones públicas: todas exigen sesión salvo la vista del link del grupo.
-- (Supabase da execute a anon por defecto sobre las funciones de public.)
-- ---------------------------------------------------------------------------------------------------------

do $$
declare
  v_funcion record;
begin
  for v_funcion in
    select p.oid::regprocedure as firma, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname not in ('enviar_piloto_organizador', 'enviar_piloto_cancha')
  loop
    execute format('revoke all on function %s from public, anon', v_funcion.firma);
    execute format('grant execute on function %s to %s', v_funcion.firma,
      case when v_funcion.proname = 'vista_invitacion' then 'anon, authenticated' else 'authenticated' end);
  end loop;
end;
$$;
