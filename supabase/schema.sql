-- =====================================================================
--  Konekt Sales · esquema de base de datos
--  Pégalo completo en el SQL Editor de Supabase y ejecútalo una vez.
--  Es idempotente: se puede volver a correr sin romper nada.
--
--  Modelo de permisos:
--    vendedor  -> ve y edita únicamente sus propios prospectos
--    gerente   -> ve y edita todo el equipo
--    admin     -> ve, edita y borra todo
--  Las reglas se aplican con RLS dentro de Postgres, no en la aplicación:
--  aunque alguien use la anon key desde la consola del navegador, no puede
--  leer prospectos de otro vendedor.
-- =====================================================================

-- ---------------------------------------------------------------------
--  1 · PERFILES  (extiende auth.users con nombre y rol)
-- ---------------------------------------------------------------------
create table if not exists public.perfiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  nombre      text not null default '',
  rol         text not null default 'vendedor'
              check (rol in ('vendedor','gerente','admin')),
  activo      boolean not null default true,
  creado_at   timestamptz not null default now()
);

-- Al registrarse un usuario en Supabase Auth se le crea su perfil solo.
create or replace function public.crear_perfil()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.perfiles (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists al_crear_usuario on auth.users;
create trigger al_crear_usuario
  after insert on auth.users
  for each row execute function public.crear_perfil();

-- Lee el rol saltando RLS. Sin SECURITY DEFINER las políticas que consultan
-- perfiles se llamarían a sí mismas y Postgres aborta por recursión infinita.
create or replace function public.mi_rol()
returns text
language sql
stable
security definer
set search_path = public
as $$ select rol from public.perfiles where id = auth.uid() $$;

create or replace function public.ve_todo()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select coalesce(public.mi_rol() in ('gerente','admin'), false) $$;

create or replace function public.es_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select coalesce(public.mi_rol() = 'admin', false) $$;

-- ---------------------------------------------------------------------
--  2 · PROSPECTOS
-- ---------------------------------------------------------------------
create table if not exists public.leads (
  id            uuid primary key default gen_random_uuid(),
  vendedor_id   uuid not null default auth.uid() references public.perfiles(id) on delete restrict,
  nombre        text not null,
  empresa       text not null default '',
  giro          text default '',
  tel           text default '',
  email         text default '',
  fuente        text default 'Directo',
  servicio      text default '',
  necesidad     text default '',
  etapa         text not null default 'nuevo'
                check (etapa in ('nuevo','contactado','calificado','cotizacion','negociacion','ganado','perdido')),
  valor         numeric(12,2) not null default 0,
  prob          smallint not null default 0 check (prob between 0 and 100),
  interes       text default 'medio' check (interes in ('alto','medio','bajo')),
  prox_accion   text default '',
  seguimiento   date,
  presupuesto   text default '',
  objecion      text default '',
  notas         text default '',
  entrada       date not null default current_date,
  creado_at     timestamptz not null default now(),
  actualizado_at timestamptz not null default now()
);

create index if not exists leads_vendedor_idx on public.leads(vendedor_id);
create index if not exists leads_etapa_idx    on public.leads(etapa);
create index if not exists leads_seguim_idx   on public.leads(seguimiento);

-- Mantiene actualizado_at sin que la app tenga que acordarse.
create or replace function public.tocar_actualizado()
returns trigger language plpgsql as $$
begin new.actualizado_at = now(); return new; end;
$$;

drop trigger if exists leads_touch on public.leads;
create trigger leads_touch before update on public.leads
  for each row execute function public.tocar_actualizado();

-- ---------------------------------------------------------------------
--  3 · HISTORIAL DE ETAPAS  (sin esto el panel del admin no mide nada real)
-- ---------------------------------------------------------------------
create table if not exists public.lead_etapa_log (
  id            bigint generated always as identity primary key,
  lead_id       uuid not null references public.leads(id) on delete cascade,
  etapa_origen  text,
  etapa_destino text not null,
  usuario_id    uuid default auth.uid() references public.perfiles(id) on delete set null,
  creado_at     timestamptz not null default now()
);
create index if not exists etapa_log_lead_idx on public.lead_etapa_log(lead_id, creado_at desc);

-- Cada cambio de etapa se registra solo, venga de donde venga.
create or replace function public.registrar_etapa()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.lead_etapa_log(lead_id, etapa_origen, etapa_destino)
    values (new.id, null, new.etapa);
  elsif new.etapa is distinct from old.etapa then
    insert into public.lead_etapa_log(lead_id, etapa_origen, etapa_destino)
    values (new.id, old.etapa, new.etapa);
  end if;
  return new;
end;
$$;

drop trigger if exists leads_etapa_log on public.leads;
create trigger leads_etapa_log after insert or update of etapa on public.leads
  for each row execute function public.registrar_etapa();

-- ---------------------------------------------------------------------
--  4 · ACTIVIDADES  (el timeline de la ficha)
-- ---------------------------------------------------------------------
create table if not exists public.actividades (
  id          bigint generated always as identity primary key,
  lead_id     uuid not null references public.leads(id) on delete cascade,
  usuario_id  uuid default auth.uid() references public.perfiles(id) on delete set null,
  titulo      text not null,
  detalle     text default '',
  tipo        text default 'nota'
              check (tipo in ('nota','llamada','correo','whatsapp','reunion','demo','propuesta','sistema')),
  ocurrio_at  timestamptz not null default now()
);
create index if not exists actividades_lead_idx on public.actividades(lead_id, ocurrio_at desc);

-- ---------------------------------------------------------------------
--  5 · CLIENTES Y PAGOS  (un lead ganado se vuelve cliente)
-- ---------------------------------------------------------------------
create table if not exists public.clientes (
  id            uuid primary key default gen_random_uuid(),
  lead_id       uuid not null unique references public.leads(id) on delete cascade,
  fecha_cierre  date not null default current_date,
  servicio      text default '',
  precio        numeric(12,2) not null default 0,
  descuento     numeric(12,2) not null default 0,
  aplica_iva    boolean not null default true,
  forma_pago    text default '',
  inicio        text default 'Por definir',
  entrega       text default 'Por definir',
  estado        text default 'Por iniciar'
                check (estado in ('Por iniciar','En desarrollo','En pruebas','Entregado','Pausado')),
  creado_at     timestamptz not null default now()
);

create table if not exists public.pagos (
  id          bigint generated always as identity primary key,
  cliente_id  uuid not null references public.clientes(id) on delete cascade,
  numero      smallint not null,
  concepto    text default '',
  porcentaje  numeric(5,2) not null default 0,
  monto       numeric(12,2) not null default 0,
  estado      text not null default 'pend' check (estado in ('pend','ok','vencido')),
  vence_at    date,
  pagado_at   date,
  unique (cliente_id, numero)
);
create index if not exists pagos_cliente_idx on public.pagos(cliente_id, numero);

create table if not exists public.recurrentes (
  id            uuid primary key default gen_random_uuid(),
  cliente_id    uuid not null references public.clientes(id) on delete cascade,
  servicio      text not null default '',
  mensualidad   numeric(12,2) not null default 0,
  renovacion    text default 'Mensual' check (renovacion in ('Mensual','Trimestral','Anual')),
  prox_cobro    date,
  ultimo_cobro  date,
  estado        text default 'ok' check (estado in ('ok','pendiente','cancelado')),
  contrato      boolean not null default false
);
create index if not exists recurrentes_cliente_idx on public.recurrentes(cliente_id);

-- ---------------------------------------------------------------------
--  6 · DOCUMENTOS Y PLANTILLAS
-- ---------------------------------------------------------------------
-- Folios consecutivos por serie. La secuencia evita que dos vendedores
-- generen CA-042 al mismo tiempo.
create table if not exists public.folios (
  serie        text primary key,
  consecutivo  integer not null default 0
);
insert into public.folios(serie, consecutivo) values ('CA', 0)
  on conflict (serie) do nothing;

create or replace function public.siguiente_folio(p_serie text default 'CA')
returns text language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  update public.folios set consecutivo = consecutivo + 1
    where serie = p_serie returning consecutivo into n;
  if n is null then
    insert into public.folios(serie, consecutivo) values (p_serie, 1) returning consecutivo into n;
  end if;
  return p_serie || '-' || lpad(n::text, 3, '0');
end;
$$;

create table if not exists public.documentos (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid references public.leads(id) on delete cascade,
  tipo        text not null check (tipo in ('propuesta','cotizacion')),
  folio       text,
  version     integer not null default 1,
  payload     jsonb not null,          -- el objeto `state` del generador, tal cual
  pdf_key     text,                    -- ruta en el bucket cuando exista el PDF
  creado_por  uuid default auth.uid() references public.perfiles(id) on delete set null,
  creado_at   timestamptz not null default now()
);
create index if not exists documentos_lead_idx on public.documentos(lead_id, creado_at desc);

create table if not exists public.plantillas (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null,
  alcance    text not null default 'personal' check (alcance in ('personal','equipo')),
  payload    jsonb not null,
  dueno_id   uuid not null default auth.uid() references public.perfiles(id) on delete cascade,
  creado_at  timestamptz not null default now(),
  unique (dueno_id, nombre)
);

-- ---------------------------------------------------------------------
--  7 · TAREAS Y CALENDARIO
-- ---------------------------------------------------------------------
create table if not exists public.tareas (
  id          bigint generated always as identity primary key,
  usuario_id  uuid not null default auth.uid() references public.perfiles(id) on delete cascade,
  lead_id     uuid references public.leads(id) on delete set null,
  titulo      text not null,
  tipo        text not null default 'task' check (tipo in ('call','demo','follow','task')),
  vence_at    timestamptz not null default now(),
  hecha_at    timestamptz,
  creado_at   timestamptz not null default now()
);
create index if not exists tareas_usuario_idx on public.tareas(usuario_id, vence_at);

create table if not exists public.eventos (
  id          bigint generated always as identity primary key,
  usuario_id  uuid not null default auth.uid() references public.perfiles(id) on delete cascade,
  lead_id     uuid references public.leads(id) on delete set null,
  titulo      text not null,
  tipo        text not null default 'call' check (tipo in ('call','demo','follow','pay')),
  inicio      timestamptz not null,
  fin         timestamptz,
  id_externo  text,                    -- para sincronizar con Google Calendar después
  creado_at   timestamptz not null default now()
);
create index if not exists eventos_usuario_idx on public.eventos(usuario_id, inicio);

-- ---------------------------------------------------------------------
--  8 · KONEKT AI  (caché de análisis por prospecto)
-- ---------------------------------------------------------------------
-- hash_entrada evita volver a pagar una llamada a Claude cuando el prospecto
-- no ha cambiado. Si el hash coincide, se lee de aquí.
create table if not exists public.ai_insights (
  id            bigint generated always as identity primary key,
  lead_id       uuid not null references public.leads(id) on delete cascade,
  resumen       text default '',
  interes       text default '',
  intencion     text default '',
  objecion      text default '',
  presupuesto   text default '',
  accion        text default '',
  prob          smallint,
  modelo        text,
  hash_entrada  text not null,
  generado_at   timestamptz not null default now(),
  unique (lead_id, hash_entrada)
);
create index if not exists ai_lead_idx on public.ai_insights(lead_id, generado_at desc);

-- =====================================================================
--  9 · ROW LEVEL SECURITY
-- =====================================================================
alter table public.perfiles       enable row level security;
alter table public.leads          enable row level security;
alter table public.lead_etapa_log enable row level security;
alter table public.actividades    enable row level security;
alter table public.clientes       enable row level security;
alter table public.pagos          enable row level security;
alter table public.recurrentes    enable row level security;
alter table public.documentos     enable row level security;
alter table public.plantillas     enable row level security;
alter table public.tareas         enable row level security;
alter table public.eventos        enable row level security;
alter table public.ai_insights    enable row level security;
alter table public.folios         enable row level security;

-- ---- perfiles -------------------------------------------------------
drop policy if exists perfiles_ver on public.perfiles;
create policy perfiles_ver on public.perfiles for select
  using (id = auth.uid() or public.ve_todo());

drop policy if exists perfiles_editar_propio on public.perfiles;
create policy perfiles_editar_propio on public.perfiles for update
  using (id = auth.uid() or public.es_admin())
  with check (id = auth.uid() or public.es_admin());

-- ---- leads ----------------------------------------------------------
drop policy if exists leads_ver on public.leads;
create policy leads_ver on public.leads for select
  using (vendedor_id = auth.uid() or public.ve_todo());

drop policy if exists leads_crear on public.leads;
create policy leads_crear on public.leads for insert
  with check (vendedor_id = auth.uid() or public.ve_todo());

drop policy if exists leads_editar on public.leads;
create policy leads_editar on public.leads for update
  using (vendedor_id = auth.uid() or public.ve_todo())
  with check (vendedor_id = auth.uid() or public.ve_todo());

drop policy if exists leads_borrar on public.leads;
create policy leads_borrar on public.leads for delete
  using (vendedor_id = auth.uid() or public.es_admin());

-- ---- tablas hijas del lead ------------------------------------------
-- Todas heredan el permiso del prospecto al que cuelgan.
do $$
declare t text;
begin
  foreach t in array array['lead_etapa_log','actividades','documentos','ai_insights']
  loop
    execute format($f$
      drop policy if exists %1$s_todo on public.%1$s;
      create policy %1$s_todo on public.%1$s for all
        using (exists (select 1 from public.leads l
                        where l.id = %1$s.lead_id
                          and (l.vendedor_id = auth.uid() or public.ve_todo())))
        with check (exists (select 1 from public.leads l
                        where l.id = %1$s.lead_id
                          and (l.vendedor_id = auth.uid() or public.ve_todo())));
    $f$, t);
  end loop;
end $$;

-- ---- clientes (cuelgan del lead) ------------------------------------
drop policy if exists clientes_todo on public.clientes;
create policy clientes_todo on public.clientes for all
  using (exists (select 1 from public.leads l
                  where l.id = clientes.lead_id
                    and (l.vendedor_id = auth.uid() or public.ve_todo())))
  with check (exists (select 1 from public.leads l
                  where l.id = clientes.lead_id
                    and (l.vendedor_id = auth.uid() or public.ve_todo())));

-- ---- pagos y recurrentes (cuelgan del cliente) ----------------------
drop policy if exists pagos_todo on public.pagos;
create policy pagos_todo on public.pagos for all
  using (exists (select 1 from public.clientes c join public.leads l on l.id = c.lead_id
                  where c.id = pagos.cliente_id
                    and (l.vendedor_id = auth.uid() or public.ve_todo())))
  with check (exists (select 1 from public.clientes c join public.leads l on l.id = c.lead_id
                  where c.id = pagos.cliente_id
                    and (l.vendedor_id = auth.uid() or public.ve_todo())));

drop policy if exists recurrentes_todo on public.recurrentes;
create policy recurrentes_todo on public.recurrentes for all
  using (exists (select 1 from public.clientes c join public.leads l on l.id = c.lead_id
                  where c.id = recurrentes.cliente_id
                    and (l.vendedor_id = auth.uid() or public.ve_todo())))
  with check (exists (select 1 from public.clientes c join public.leads l on l.id = c.lead_id
                  where c.id = recurrentes.cliente_id
                    and (l.vendedor_id = auth.uid() or public.ve_todo())));

-- ---- tareas y eventos (son del usuario) -----------------------------
drop policy if exists tareas_todo on public.tareas;
create policy tareas_todo on public.tareas for all
  using (usuario_id = auth.uid() or public.ve_todo())
  with check (usuario_id = auth.uid() or public.ve_todo());

drop policy if exists eventos_todo on public.eventos;
create policy eventos_todo on public.eventos for all
  using (usuario_id = auth.uid() or public.ve_todo())
  with check (usuario_id = auth.uid() or public.ve_todo());

-- ---- plantillas: las propias, más las que el equipo comparte --------
drop policy if exists plantillas_ver on public.plantillas;
create policy plantillas_ver on public.plantillas for select
  using (dueno_id = auth.uid() or alcance = 'equipo');

drop policy if exists plantillas_escribir on public.plantillas;
create policy plantillas_escribir on public.plantillas for all
  using (dueno_id = auth.uid() or public.es_admin())
  with check (dueno_id = auth.uid() or public.es_admin());

-- ---- folios: cualquiera autenticado puede leer; solo la función escribe
drop policy if exists folios_ver on public.folios;
create policy folios_ver on public.folios for select
  using (auth.uid() is not null);

-- =====================================================================
--  10 · DESPUÉS DE CORRER ESTO
-- =====================================================================
--  a) Crea tu usuario en  Authentication → Users → Add user
--  b) Vuelve aquí y hazte admin:
--
--       update public.perfiles
--          set rol = 'admin', nombre = 'Tu Nombre'
--        where id = (select id from auth.users where email = 'tu@correo.com');
--
--  c) Copia Project URL y anon key desde Project Settings → API
--     y pégalas en  public/konekt-config.js
-- =====================================================================
