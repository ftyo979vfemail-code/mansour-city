-- Dispatchers: a person the office adds who logs in by scanning a QR code and can ONLY send
-- customer requests to drivers. He sees request name/pickup/destination and the drivers'
-- names, free/busy and distance — no prices, money, phones, map coordinates or settings.
create table if not exists public.taxi_dispatchers (
  id serial primary key,
  name text not null,
  token uuid not null unique default gen_random_uuid(),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  last_seen timestamptz
);
alter table public.taxi_dispatchers enable row level security;
revoke all on public.taxi_dispatchers from anon, authenticated;

create or replace function public.taxi_disp_who(p_token uuid) returns public.taxi_dispatchers
language plpgsql security definer set search_path = public as $$
declare d taxi_dispatchers;
begin
  select * into d from taxi_dispatchers where token = p_token and active;
  if d.id is null then raise exception 'الباركود ما يشتغل، اطلب باركود جديد من الإدارة'; end if;
  if d.last_seen is null or d.last_seen < now() - interval '1 minute' then update taxi_dispatchers set last_seen = now() where id = d.id; end if;
  return d;
end $$;

create or replace function public.taxi_disp_km(a1 double precision, o1 double precision, a2 double precision, o2 double precision) returns numeric
language sql immutable as $$
  select round((6371 * 2 * asin(sqrt(power(sin(radians(a2-a1)/2),2) + cos(radians(a1))*cos(radians(a2))*power(sin(radians(o2-o1)/2),2))))::numeric, 1);
$$;

create or replace function public.taxi_disp_state(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare d taxi_dispatchers := taxi_disp_who(p_token);
begin
  return json_build_object('name', d.name,
    'requests', coalesce((select json_agg(json_build_object(
        'id', t.id, 'status', t.status, 'customer_name', t.customer_name, 'pickup', t.pickup, 'dropoff', t.dropoff, 'note', t.note,
        'created_at', t.created_at, 'driver_name', c.driver_name,
        'dist', (select json_object_agg(k.id, taxi_disp_km(t.pickup_lat, t.pickup_lng, k.last_lat, k.last_lng))
                 from taxi_cars k where t.pickup_lat is not null and k.active and k.last_lat is not null)) order by t.created_at)
      from taxi_trips t left join taxi_cars c on c.id = t.car_id
      where t.customer_id is not null and (t.status = 'requested'
         or (t.status = 'rejected' and t.created_at > now() - interval '1 day')
         or (t.status = 'assigned' and t.created_at > now() - interval '3 hours'))), '[]'::json),
    'drivers', coalesce((select json_agg(json_build_object('id', k.id, 'driver_name', k.driver_name, 'plate', k.plate,
        'online', k.gps_state in ('ok','background') and k.last_seen > now() - interval '3 minutes',
        'busy', exists (select 1 from taxi_trips x where x.car_id = k.id and x.status in ('assigned','accepted','started'))) order by k.driver_name)
      from taxi_cars k where k.active), '[]'::json));
end $$;

create or replace function public.taxi_disp_send(p_token uuid, p_trip bigint, p_car uuid) returns void
language plpgsql security definer set search_path = public as $$
declare d taxi_dispatchers := taxi_disp_who(p_token); tr taxi_trips;
begin
  select * into tr from taxi_trips where id = p_trip for update;
  if tr.id is null or tr.customer_id is null then raise exception 'الطلب غير موجود'; end if;
  if tr.status not in ('requested','assigned','rejected') then raise exception 'هذا الطلب ما عاد ينتظر سائق'; end if;
  if not exists (select 1 from taxi_cars where id = p_car and active) then raise exception 'السائق غير موجود'; end if;
  if exists (select 1 from taxi_trips where car_id = p_car and status in ('assigned','accepted','started') and id <> p_trip) then
    raise exception 'هذا السائق عنده سفرة مفتوحة'; end if;
  update taxi_trips set car_id = p_car, status = 'assigned', accepted_at = null, ended_at = null, cancel_reason = null,
    dispatched_by = d.name || ' (موزّع)' where id = p_trip;
end $$;

-- admin side: manage dispatchers (any manager)
create or replace function public.taxi_admin_dispatchers(p_pin text, p_action text default 'list', p jsonb default '{}'::jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare nm text := left(trim(coalesce(p->>'name','')),40); did int := nullif(p->>'id','')::int; tok uuid;
begin
  perform taxi_chk(p_pin);
  if p_action = 'add' then
    if length(nm) < 2 then raise exception 'اكتب اسم الشخص'; end if;
    if (select count(*) from taxi_dispatchers) >= 30 then raise exception 'وصلت الحد'; end if;
    insert into taxi_dispatchers(name) values (nm) returning token into tok;
    return json_build_object('token', tok, 'name', nm);
  elsif p_action = 'newcode' then
    update taxi_dispatchers set token = gen_random_uuid(), active = true where id = did returning token, name into tok, nm;
    return json_build_object('token', tok, 'name', nm);
  elsif p_action = 'toggle' then
    update taxi_dispatchers set active = not active where id = did;
  elsif p_action = 'delete' then
    delete from taxi_dispatchers where id = did;
  elsif p_action = 'qr' then
    select token, name into tok, nm from taxi_dispatchers where id = did;
    return json_build_object('token', tok, 'name', nm);
  elsif p_action <> 'list' then raise exception 'إجراء غير معروف'; end if;
  return coalesce((select json_agg(json_build_object('id',x.id,'name',x.name,'active',x.active,'created_at',x.created_at,'last_seen',x.last_seen,
      'sent', (select count(*) from taxi_trips t where t.dispatched_by = x.name || ' (موزّع)')) order by x.id)
    from taxi_dispatchers x), '[]'::json);
end $$;

revoke all on function public.taxi_disp_who(uuid) from public, anon, authenticated;
grant execute on function public.taxi_disp_state(uuid), public.taxi_disp_send(uuid,bigint,uuid), public.taxi_admin_dispatchers(text,text,jsonb) to anon;
