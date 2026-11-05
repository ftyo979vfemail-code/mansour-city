-- Compound taxi system: schema + API functions for a self-hosted PostgreSQL.
-- Runs once, on the first start of an empty database (docker-entrypoint-initdb.d).
-- The API (PostgREST) connects as "authenticator" and acts as "web_anon",
-- which may only EXECUTE the taxi_* functions granted at the bottom. No table access.

\set ON_ERROR_STOP on

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- Nothing is callable by default; every API function is granted explicitly.
alter default privileges revoke execute on functions from public;
revoke create on schema public from public;

create table if not exists public.taxi_settings (k text primary key, v text not null);

create table if not exists public.taxi_cars (
  id uuid primary key default gen_random_uuid(),
  plate text not null,
  model text not null default '',
  year text not null default '',
  color text not null default '',
  driver_name text not null,
  driver_phone text not null default '',
  driver_code text not null unique,
  active boolean not null default true,
  last_lat double precision, last_lng double precision,
  last_speed double precision, last_acc double precision, last_heading double precision,
  battery int, last_seen timestamptz,
  gps_state text not null default 'never',
  created_at timestamptz not null default now()
);

create table if not exists public.taxi_trail (
  id bigserial primary key,
  car_id uuid not null references public.taxi_cars(id) on delete cascade,
  lat double precision not null, lng double precision not null,
  speed double precision, at timestamptz not null default now()
);
create index if not exists taxi_trail_car_at on public.taxi_trail(car_id, at desc);

create table if not exists public.taxi_events (
  id bigserial primary key,
  car_id uuid not null references public.taxi_cars(id) on delete cascade,
  kind text not null, at timestamptz not null default now()
);
create index if not exists taxi_events_at on public.taxi_events(at desc);

-- ---------- Admin ----------
create or replace function public.taxi_chk(p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare h text;
begin
  select v into h from taxi_settings where k='admin_pin';
  if h is null or crypt(coalesce(p_pin,''), h) <> h then raise exception 'رمز المدير غير صحيح'; end if;
end $$;

create or replace function public.taxi_admin_list(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(row_to_json(c) order by c.created_at) from taxi_cars c), '[]'::json);
end $$;

create or replace function public.taxi_admin_save(p_pin text, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare r taxi_cars; code text;
begin
  perform taxi_chk(p_pin);
  if coalesce(trim(p->>'plate'),'')='' or coalesce(trim(p->>'driver_name'),'')='' then
    raise exception 'رقم السيارة واسم السائق مطلوبان'; end if;
  if (p->>'id') is null then
    loop
      code := lpad((floor(random()*1000000))::int::text, 6, '0');
      exit when not exists (select 1 from taxi_cars where driver_code=code);
    end loop;
    insert into taxi_cars(plate,model,year,color,driver_name,driver_phone,driver_code)
    values (trim(p->>'plate'),coalesce(p->>'model',''),coalesce(p->>'year',''),coalesce(p->>'color',''),
            trim(p->>'driver_name'),coalesce(p->>'driver_phone',''),code)
    returning * into r;
  else
    update taxi_cars set plate=trim(p->>'plate'), model=coalesce(p->>'model',''), year=coalesce(p->>'year',''),
      color=coalesce(p->>'color',''), driver_name=trim(p->>'driver_name'), driver_phone=coalesce(p->>'driver_phone',''),
      active=coalesce((p->>'active')::boolean, active)
    where id=(p->>'id')::uuid returning * into r;
  end if;
  return row_to_json(r);
end $$;

create or replace function public.taxi_admin_delete(p_pin text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform taxi_chk(p_pin); delete from taxi_cars where id=p_id; end $$;

create or replace function public.taxi_admin_newcode(p_pin text, p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare code text;
begin
  perform taxi_chk(p_pin);
  loop
    code := lpad((floor(random()*1000000))::int::text, 6, '0');
    exit when not exists (select 1 from taxi_cars where driver_code=code);
  end loop;
  update taxi_cars set driver_code=code where id=p_id;
  return code;
end $$;

create or replace function public.taxi_admin_trail(p_pin text, p_id uuid, p_hours int default 12) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(json_build_array(lat,lng,extract(epoch from at)) order by at)
    from taxi_trail where car_id=p_id and at > now() - make_interval(hours => greatest(1,least(p_hours,72)))), '[]'::json);
end $$;

create or replace function public.taxi_admin_events(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x) from (
    select e.kind, e.at, c.plate, c.driver_name from taxi_events e join taxi_cars c on c.id=e.car_id
    order by e.at desc limit 60) x), '[]'::json);
end $$;

create or replace function public.taxi_admin_setpin(p_pin text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform taxi_chk(p_pin);
  if length(coalesce(p_new,'')) < 4 then raise exception 'الرمز الجديد قصير'; end if;
  update taxi_settings set v=crypt(p_new, gen_salt('bf')) where k='admin_pin';
end $$;

create or replace function public.taxi_export(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return json_build_object(
    'settings', (select coalesce(json_agg(s),'[]'::json) from taxi_settings s),
    'cars',     (select coalesce(json_agg(c),'[]'::json) from taxi_cars c),
    'trail',    (select coalesce(json_agg(t),'[]'::json) from (select * from taxi_trail where at > now() - interval '30 days') t),
    'events',   (select coalesce(json_agg(e),'[]'::json) from (select * from taxi_events where at > now() - interval '90 days') e));
end $$;

-- ---------- Driver ----------
create or replace function public.taxi_driver_login(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare r json;
begin
  select json_build_object('plate',plate,'model',model,'year',year,'color',color,'driver_name',driver_name)
    into r from taxi_cars where driver_code=trim(p_code) and active;
  if r is null then raise exception 'رمز السائق غير صحيح أو السيارة موقوفة'; end if;
  return r;
end $$;

create or replace function public.taxi_ping(p_code text, p_lat double precision, p_lng double precision,
  p_speed double precision, p_acc double precision, p_heading double precision, p_battery int) returns void
language plpgsql security definer set search_path = public as $$
declare c taxi_cars; t taxi_trail;
begin
  select * into c from taxi_cars where driver_code=trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  if p_lat is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'إحداثيات غير صالحة'; end if;
  if c.gps_state in ('stopped','never') then insert into taxi_events(car_id,kind) values (c.id, 'started');
  elsif c.gps_state <> 'ok' then insert into taxi_events(car_id,kind) values (c.id, 'gps_on'); end if;
  update taxi_cars set last_lat=p_lat,last_lng=p_lng,last_speed=p_speed,last_acc=p_acc,last_heading=p_heading,
    battery=coalesce(p_battery,battery), last_seen=now(), gps_state='ok' where id=c.id;
  select * into t from taxi_trail where car_id=c.id order by at desc limit 1;
  if t.id is null or t.at < now() - interval '45 seconds'
     or (abs(t.lat-p_lat)+abs(t.lng-p_lng)) > 0.00012 then
    insert into taxi_trail(car_id,lat,lng,speed) values (c.id,p_lat,p_lng,p_speed);
  end if;
end $$;

create or replace function public.taxi_gps_state(p_code text, p_state text) returns void
language plpgsql security definer set search_path = public as $$
declare c taxi_cars;
begin
  if p_state not in ('off','denied','background','closed','stopped') then raise exception 'حالة غير معروفة'; end if;
  select * into c from taxi_cars where driver_code=trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  if c.gps_state = 'stopped' and p_state in ('closed','background') then return; end if;
  if c.gps_state = 'lost' and p_state = 'closed' then return; end if;
  if c.gps_state <> p_state then
    insert into taxi_events(car_id,kind) values (c.id, p_state);
    update taxi_cars set gps_state=p_state where id=c.id;
  end if;
end $$;

create or replace function public.taxi_admin_alerts(p_pin text, p_after bigint default 0) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  if coalesce(p_after,0) <= 0 then
    return json_build_object('last', (select coalesce(max(id),0) from taxi_events), 'events', '[]'::json);
  end if;
  return json_build_object(
    'last', (select coalesce(max(id),p_after) from taxi_events),
    'events', coalesce((select json_agg(x order by x.id) from (
       select e.id, e.kind, e.at, c.plate, c.driver_name, c.driver_phone
       from taxi_events e join taxi_cars c on c.id=e.car_id
       where e.id > p_after order by e.id limit 50) x), '[]'::json));
end $$;

create or replace function public.taxi_public_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'cars',    (select count(*) from taxi_cars where active),
    'online',  (select count(*) from taxi_cars where active and gps_state in ('ok','background') and last_seen > now() - interval '3 minutes'),
    'phone',   (select v from taxi_settings where k='contact_phone'),
    'whatsapp',(select v from taxi_settings where k='contact_whatsapp'),
    'hours',   (select v from taxi_settings where k='contact_hours'));
$$;

create or replace function public.taxi_admin_contact(p_pin text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare f text;
begin
  perform taxi_chk(p_pin);
  foreach f in array array['contact_phone','contact_whatsapp','contact_hours'] loop
    if p ? f then
      if coalesce(trim(p->>f),'') = '' then delete from taxi_settings s where s.k = f;
      else insert into taxi_settings as s(k,v) values (f, left(trim(p->>f),80)) on conflict (k) do update set v = excluded.v; end if;
    end if;
  end loop;
end $$;

-- ---------- Server-side only (never granted to the API) ----------
-- A phone that stops sending (battery dead, app force-stopped, no signal) is marked "lost" after 2 minutes.
create or replace function public.taxi_mark_lost() returns void
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in update taxi_cars set gps_state='lost'
           where active and gps_state in ('ok','background') and last_seen < now() - interval '2 minutes'
           returning id loop
    insert into taxi_events(car_id,kind) values (r.id,'lost');
  end loop;
end $$;

create or replace function public.taxi_set_admin_pin(p_new text) returns void
language plpgsql set search_path = public, extensions as $$
begin
  insert into taxi_settings(k,v) values ('admin_pin', crypt(p_new, gen_salt('bf')))
  on conflict (k) do update set v = excluded.v;
end $$;

create or replace function public.taxi_import(j json) returns text
language plpgsql set search_path = public as $$
declare nc int; nt int; ne int;
begin
  insert into taxi_settings select * from json_populate_recordset(null::taxi_settings, j->'settings')
    on conflict (k) do update set v = excluded.v;
  insert into taxi_cars select * from json_populate_recordset(null::taxi_cars, j->'cars') on conflict (id) do nothing;
  get diagnostics nc = row_count;
  insert into taxi_trail select * from json_populate_recordset(null::taxi_trail, j->'trail') on conflict (id) do nothing;
  get diagnostics nt = row_count;
  insert into taxi_events select * from json_populate_recordset(null::taxi_events, j->'events') on conflict (id) do nothing;
  get diagnostics ne = row_count;
  perform setval('taxi_trail_id_seq', greatest(1, (select coalesce(max(id),1) from taxi_trail)));
  perform setval('taxi_events_id_seq', greatest(1, (select coalesce(max(id),1) from taxi_events)));
  return format('%s سيارة، %s نقطة مسار، %s حدث', nc, nt, ne);
end $$;

-- Old trail points pile up fast (one every ~45 s per car). Keep 90 days.
create or replace function public.taxi_cleanup() returns void
language sql as $$
  delete from public.taxi_trail where at < now() - interval '90 days';
  delete from public.taxi_events where at < now() - interval '365 days';
$$;

-- ---------- API grants ----------
grant usage on schema public to web_anon;
grant execute on function
  public.taxi_admin_list(text), public.taxi_admin_save(text,jsonb), public.taxi_admin_delete(text,uuid),
  public.taxi_admin_newcode(text,uuid), public.taxi_admin_trail(text,uuid,int), public.taxi_admin_events(text),
  public.taxi_admin_setpin(text,text), public.taxi_export(text), public.taxi_driver_login(text),
  public.taxi_admin_alerts(text,bigint),
  public.taxi_public_info(), public.taxi_admin_contact(text,jsonb),
  public.taxi_ping(text,double precision,double precision,double precision,double precision,double precision,int),
  public.taxi_gps_state(text,text)
to web_anon;
