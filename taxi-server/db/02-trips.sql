-- Trips, office dispatch, cash handover and driver accountability.
-- Idea: every kilometre the car drives must belong to a trip. GPS movement without a trip
-- raises an alarm live, and the monthly statement puts recorded fares next to real driving.

alter table public.taxi_cars
  add column if not exists moving_since timestamptz,
  add column if not exists last_fast_at timestamptz,
  add column if not exists unlogged_flagged boolean not null default false;

create table if not exists public.taxi_trips (
  id bigserial primary key,
  car_id uuid references public.taxi_cars(id) on delete set null,
  source text not null default 'driver',          -- office | driver
  status text not null default 'assigned',        -- assigned | accepted | started | done | cancelled | rejected
  customer_phone text not null default '',
  pickup text not null default '',
  dropoff text not null default '',
  note text not null default '',
  fare int,
  km numeric(8,2),
  created_at timestamptz not null default now(),
  accepted_at timestamptz, started_at timestamptz, ended_at timestamptz,
  cancel_reason text
);
create index if not exists taxi_trips_car on public.taxi_trips(car_id, created_at desc);
create index if not exists taxi_trips_open on public.taxi_trips(status) where status in ('assigned','accepted','started');

create table if not exists public.taxi_cash (
  id bigserial primary key,
  car_id uuid not null references public.taxi_cars(id) on delete cascade,
  amount int not null check (amount > 0),
  note text not null default '',
  at timestamptz not null default now()
);
create index if not exists taxi_cash_car on public.taxi_cash(car_id, at desc);

-- metres between two points
create or replace function public.taxi_dist(a1 double precision, o1 double precision, a2 double precision, o2 double precision)
returns double precision language sql immutable as $$
  select 12742000 * asin(sqrt(power(sin(radians(a2-a1)/2),2) + cos(radians(a1))*cos(radians(a2))*power(sin(radians(o2-o1)/2),2)));
$$;

create or replace function public.taxi_setting_int(p_k text) returns int language sql stable as $$
  select nullif(regexp_replace(coalesce((select v from public.taxi_settings where k=p_k),''),'\D','','g'),'')::int;
$$;

-- Driving segments detected from the GPS trail, each marked as covered by a trip or not.
create or replace function public.taxi_moves(p_car uuid, p_from timestamptz, p_to timestamptz)
returns table(started_at timestamptz, ended_at timestamptz, km numeric, matched boolean)
language plpgsql stable set search_path = public as $$
declare
  p record; prev record; has_prev boolean := false;
  d double precision; dt double precision;
  in_move boolean := false; ms timestamptz; lm timestamptz; dist double precision := 0;
  covered double precision;
begin
  for p in select t.lat, t.lng, t.at from taxi_trail t where t.car_id=p_car and t.at >= p_from and t.at < p_to order by t.at loop
    if has_prev then
      d := taxi_dist(prev.lat, prev.lng, p.lat, p.lng);
      dt := greatest(extract(epoch from p.at - prev.at), 1);
      if dt > 300 then                               -- tracking gap: close any open segment
        if in_move and dist >= 300 then
          started_at := ms; ended_at := lm; km := round((dist/1000)::numeric, 2);
          select coalesce(sum(extract(epoch from least(coalesce(tr.ended_at, now()), lm) - greatest(coalesce(tr.accepted_at, tr.started_at), ms))),0)
            into covered from taxi_trips tr
            where tr.car_id=p_car and tr.status in ('accepted','started','done')
              and coalesce(tr.accepted_at, tr.started_at) < lm and coalesce(tr.ended_at, now()) > ms;
          matched := covered >= 0.5 * greatest(extract(epoch from lm - ms), 1);
          return next;
        end if;
        in_move := false; dist := 0;
      elsif d / dt > 2.5 and d > 15 then              -- moving faster than ~9 km/h
        if not in_move then in_move := true; ms := prev.at; dist := 0; end if;
        dist := dist + d; lm := p.at;
      elsif in_move and p.at - lm > interval '3 minutes' then
        if dist >= 300 then
          started_at := ms; ended_at := lm; km := round((dist/1000)::numeric, 2);
          select coalesce(sum(extract(epoch from least(coalesce(tr.ended_at, now()), lm) - greatest(coalesce(tr.accepted_at, tr.started_at), ms))),0)
            into covered from taxi_trips tr
            where tr.car_id=p_car and tr.status in ('accepted','started','done')
              and coalesce(tr.accepted_at, tr.started_at) < lm and coalesce(tr.ended_at, now()) > ms;
          matched := covered >= 0.5 * greatest(extract(epoch from lm - ms), 1);
          return next;
        end if;
        in_move := false; dist := 0;
      end if;
    end if;
    prev := p; has_prev := true;
  end loop;
  if in_move and dist >= 300 then
    started_at := ms; ended_at := lm; km := round((dist/1000)::numeric, 2);
    select coalesce(sum(extract(epoch from least(coalesce(tr.ended_at, now()), lm) - greatest(coalesce(tr.accepted_at, tr.started_at), ms))),0)
      into covered from taxi_trips tr
      where tr.car_id=p_car and tr.status in ('accepted','started','done')
        and coalesce(tr.accepted_at, tr.started_at) < lm and coalesce(tr.ended_at, now()) > ms;
    matched := covered >= 0.5 * greatest(extract(epoch from lm - ms), 1);
    return next;
  end if;
end $$;

create or replace function public.taxi_trip_json(t taxi_trips) returns json language sql stable as $$
  select json_build_object('id',t.id,'status',t.status,'source',t.source,'pickup',t.pickup,'dropoff',t.dropoff,
    'customer_phone',t.customer_phone,'note',t.note,'fare',t.fare,'km',t.km,'created_at',t.created_at,
    'accepted_at',t.accepted_at,'started_at',t.started_at,'ended_at',t.ended_at);
$$;

-- ---------- Ping: now returns the driver's open trip, and catches driving without a trip ----------
create or replace function public.taxi_ping_v2(p_code text, p_lat double precision, p_lng double precision,
  p_speed double precision, p_acc double precision, p_heading double precision, p_battery int) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_cars; t taxi_trail; spd double precision; open_trip taxi_trips; legit boolean;
begin
  select * into c from taxi_cars where driver_code=trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  if p_lat is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then raise exception 'إحداثيات غير صالحة'; end if;
  if c.gps_state in ('stopped','never') then insert into taxi_events(car_id,kind) values (c.id, 'started');
  elsif c.gps_state <> 'ok' then insert into taxi_events(car_id,kind) values (c.id, 'gps_on'); end if;

  spd := p_speed;
  if spd is null and c.last_lat is not null and c.last_seen > now() - interval '2 minutes' then
    spd := taxi_dist(c.last_lat, c.last_lng, p_lat, p_lng) / greatest(extract(epoch from now() - c.last_seen), 1);
  end if;

  select * into open_trip from taxi_trips where car_id=c.id and status in ('assigned','accepted','started') order by id desc limit 1;
  legit := open_trip.id is not null and open_trip.status in ('accepted','started');

  if legit then
    c.moving_since := null; c.unlogged_flagged := false;
  elsif coalesce(spd,0) > 4 and coalesce(p_acc, 0) < 60 then          -- faster than ~15 km/h with no trip
    c.last_fast_at := now();
    if c.moving_since is null then c.moving_since := now(); end if;
    if not c.unlogged_flagged and now() - c.moving_since > interval '90 seconds' then
      insert into taxi_events(car_id,kind) values (c.id,'unlogged');
      c.unlogged_flagged := true;
    end if;
  elsif c.last_fast_at is null or c.last_fast_at < now() - interval '3 minutes' then
    c.moving_since := null; c.unlogged_flagged := false;
  end if;

  update taxi_cars set last_lat=p_lat,last_lng=p_lng,last_speed=coalesce(p_speed,spd),last_acc=p_acc,last_heading=p_heading,
    battery=coalesce(p_battery,battery), last_seen=now(), gps_state='ok',
    moving_since=c.moving_since, last_fast_at=c.last_fast_at, unlogged_flagged=c.unlogged_flagged
  where id=c.id;

  select * into t from taxi_trail where car_id=c.id order by at desc limit 1;
  if t.id is null or t.at < now() - interval '45 seconds'
     or (abs(t.lat-p_lat)+abs(t.lng-p_lng)) > 0.00012 then
    insert into taxi_trail(car_id,lat,lng,speed) values (c.id,p_lat,p_lng,p_speed);
  end if;

  return json_build_object('trip', case when open_trip.id is null then null else taxi_trip_json(open_trip) end);
end $$;

-- older apps keep calling the void version
create or replace function public.taxi_ping(p_code text, p_lat double precision, p_lng double precision,
  p_speed double precision, p_acc double precision, p_heading double precision, p_battery int) returns void
language plpgsql security definer set search_path = public as $$
begin perform taxi_ping_v2(p_code,p_lat,p_lng,p_speed,p_acc,p_heading,p_battery); end $$;

-- ---------- Driver ----------
create or replace function public.taxi_driver_state(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_cars; open_trip taxi_trips;
begin
  select * into c from taxi_cars where driver_code=trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  select * into open_trip from taxi_trips where car_id=c.id and status in ('assigned','accepted','started') order by id desc limit 1;
  return json_build_object(
    'trip', case when open_trip.id is null then null else taxi_trip_json(open_trip) end,
    'today_trips', (select count(*) from taxi_trips where car_id=c.id and status='done' and ended_at >= date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad'),
    'today_fares', (select coalesce(sum(fare),0) from taxi_trips where car_id=c.id and status='done' and ended_at >= date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad'),
    'fare_base', taxi_setting_int('fare_base'));
end $$;

create or replace function public.taxi_driver_trip(p_code text, p_action text, p jsonb default '{}'::jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_cars; tr taxi_trips; f int;
begin
  select * into c from taxi_cars where driver_code=trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  select * into tr from taxi_trips where car_id=c.id and status in ('assigned','accepted','started') order by id desc limit 1;

  if p_action = 'accept' then
    if tr.status is distinct from 'assigned' then raise exception 'ماكو سفرة بانتظار القبول'; end if;
    update taxi_trips set status='accepted', accepted_at=now() where id=tr.id returning * into tr;
  elsif p_action = 'reject' then
    if tr.status is distinct from 'assigned' then raise exception 'ماكو سفرة بانتظار القبول'; end if;
    update taxi_trips set status='rejected', ended_at=now(), cancel_reason=left(coalesce(p->>'reason',''),120) where id=tr.id returning * into tr;
    insert into taxi_events(car_id,kind) values (c.id,'rejected');
  elsif p_action = 'start' then
    if c.gps_state not in ('ok','background') then raise exception 'شغّل التتبع أولًا'; end if;
    if tr.status = 'started' then raise exception 'عندك سفرة شغّالة'; end if;
    if tr.status = 'assigned' then raise exception 'اقبل سفرة المكتب أولًا'; end if;
    if tr.status = 'accepted' then
      update taxi_trips set status='started', started_at=now() where id=tr.id returning * into tr;
    else
      insert into taxi_trips(car_id,source,status,pickup,dropoff,accepted_at,started_at)
      values (c.id,'driver','started',left(coalesce(p->>'pickup',''),120),left(coalesce(p->>'dropoff',''),120),now(),now())
      returning * into tr;
    end if;
    update taxi_cars set moving_since=null, unlogged_flagged=false where id=c.id;
  elsif p_action = 'end' then
    if tr.status is distinct from 'started' then raise exception 'ماكو سفرة شغّالة'; end if;
    f := nullif(regexp_replace(coalesce(p->>'fare',''),'\D','','g'),'')::int;
    if f is null or f <= 0 then raise exception 'اكتب مبلغ الأجرة'; end if;
    if f > 1000000 then raise exception 'المبلغ كبير، تأكد منه'; end if;
    update taxi_trips set status='done', ended_at=now(), fare=f,
      dropoff = case when coalesce(p->>'dropoff','')<>'' then left(p->>'dropoff',120) else dropoff end,
      km = (select round((coalesce(sum(m.km),0))::numeric,2) from taxi_moves(c.id, coalesce(tr.accepted_at,tr.started_at), now()+interval '1 second') m)
    where id=tr.id returning * into tr;
  else
    raise exception 'إجراء غير معروف';
  end if;
  return taxi_trip_json(tr);
end $$;

-- ---------- Admin: trips ----------
create or replace function public.taxi_admin_trip_create(p_pin text, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare tr taxi_trips; car uuid;
begin
  perform taxi_chk(p_pin);
  car := nullif(p->>'car_id','')::uuid;
  if car is null then raise exception 'اختر السائق'; end if;
  if exists (select 1 from taxi_trips where car_id=car and status in ('assigned','accepted','started')) then
    raise exception 'هذا السائق عنده سفرة مفتوحة'; end if;
  insert into taxi_trips(car_id,source,status,customer_phone,pickup,dropoff,note)
  values (car,'office','assigned',
          left(coalesce(p->>'customer_phone',''),30),left(coalesce(p->>'pickup',''),120),left(coalesce(p->>'dropoff',''),120),left(coalesce(p->>'note',''),200))
  returning * into tr;
  return taxi_trip_json(tr);
end $$;

create or replace function public.taxi_admin_trip_action(p_pin text, p_id bigint, p_action text, p_car uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare tr taxi_trips;
begin
  perform taxi_chk(p_pin);
  select * into tr from taxi_trips where id=p_id;
  if tr.id is null then raise exception 'السفرة غير موجودة'; end if;
  if p_action = 'cancel' then
    if tr.status not in ('assigned','accepted','started') then raise exception 'السفرة منتهية'; end if;
    update taxi_trips set status='cancelled', ended_at=now(), cancel_reason='ألغاها المكتب' where id=p_id;
  elsif p_action = 'reassign' then
    if p_car is null then raise exception 'اختر السائق'; end if;
    if exists (select 1 from taxi_trips where car_id=p_car and status in ('assigned','accepted','started') and id<>p_id) then
      raise exception 'هذا السائق عنده سفرة مفتوحة'; end if;
    if tr.status in ('assigned','rejected') then
      update taxi_trips set car_id=p_car, status='assigned', accepted_at=null, ended_at=null, cancel_reason=null where id=p_id;
    else raise exception 'ما ينفع تحويل سفرة بدأت'; end if;
  else raise exception 'إجراء غير معروف'; end if;
end $$;

create or replace function public.taxi_admin_trips(p_pin text, p_day date default null) returns json
language plpgsql security definer set search_path = public as $$
declare d date := coalesce(p_day, (now() at time zone 'Asia/Baghdad')::date);
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select t.*, c.plate, c.driver_name from taxi_trips t left join taxi_cars c on c.id=t.car_id
    where (t.created_at at time zone 'Asia/Baghdad')::date = d
       or (t.status in ('assigned','accepted','started'))) x), '[]'::json);
end $$;

-- ---------- Admin: cash ----------
create or replace function public.taxi_admin_cash(p_pin text, p_action text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a int;
begin
  perform taxi_chk(p_pin);
  if p_action = 'add' then
    a := nullif(regexp_replace(coalesce(p->>'amount',''),'\D','','g'),'')::int;
    if a is null or a <= 0 then raise exception 'اكتب المبلغ'; end if;
    insert into taxi_cash(car_id,amount,note) values ((p->>'car_id')::uuid, a, left(coalesce(p->>'note',''),120));
  elsif p_action = 'delete' then
    delete from taxi_cash where id=(p->>'id')::bigint and at > now() - interval '48 hours';
    if not found then raise exception 'ما ينحذف (أقدم من 48 ساعة)'; end if;
  else raise exception 'إجراء غير معروف'; end if;
end $$;

-- ---------- Admin: monthly statement per driver ----------
create or replace function public.taxi_admin_statement(p_pin text, p_month date default null) returns json
language plpgsql security definer set search_path = public as $$
declare m0 timestamptz; m1 timestamptz; base int := taxi_setting_int('fare_base'); perkm int := taxi_setting_int('fare_per_km'); out json;
begin
  perform taxi_chk(p_pin);
  m0 := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Baghdad')::date))::timestamp at time zone 'Asia/Baghdad';
  m1 := (date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Baghdad')::date)) + interval '1 month')::timestamp at time zone 'Asia/Baghdad';
  select json_agg(r order by r.fares desc) into out from (
    select c.id, c.plate, c.driver_name, c.model,
      (select count(*) from taxi_trips t where t.car_id=c.id and t.status='done' and t.ended_at>=m0 and t.ended_at<m1) as trips,
      (select coalesce(sum(fare),0) from taxi_trips t where t.car_id=c.id and t.status='done' and t.ended_at>=m0 and t.ended_at<m1) as fares,
      (select count(*) from taxi_trips t where t.car_id=c.id and t.status='rejected' and t.created_at>=m0 and t.created_at<m1) as rejected,
      (select coalesce(sum(amount),0) from taxi_cash k where k.car_id=c.id and k.at>=m0 and k.at<m1) as paid,
      mv.km_total, mv.moves, mv.unlogged, mv.unlogged_km,
      (select round(coalesce(sum(least(extract(epoch from g.gap),120)),0)/3600.0,1) from (
         select at - lag(at) over (order by at) as gap from taxi_trail tt where tt.car_id=c.id and tt.at>=m0 and tt.at<m1) g) as online_hours,
      (select count(*) from taxi_events e where e.car_id=c.id and e.kind in ('off','denied','closed','lost') and e.at>=m0 and e.at<m1) as cutoffs,
      base as fare_base, perkm as fare_per_km
    from taxi_cars c
    cross join lateral (
      select round(coalesce(sum(m.km),0),1) as km_total, count(*) as moves,
             count(*) filter (where not m.matched) as unlogged,
             round(coalesce(sum(m.km) filter (where not m.matched),0),1) as unlogged_km
      from taxi_moves(c.id, m0, m1) m) mv
  ) r;
  return coalesce(out,'[]'::json);
end $$;

create or replace function public.taxi_admin_driver_detail(p_pin text, p_car uuid, p_month date default null) returns json
language plpgsql security definer set search_path = public as $$
declare m0 timestamptz; m1 timestamptz;
begin
  perform taxi_chk(p_pin);
  m0 := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Baghdad')::date))::timestamp at time zone 'Asia/Baghdad';
  m1 := (date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Baghdad')::date)) + interval '1 month')::timestamp at time zone 'Asia/Baghdad';
  return json_build_object(
    'moves', coalesce((select json_agg(m order by m.started_at desc) from taxi_moves(p_car, m0, m1) m where not m.matched), '[]'::json),
    'trips', coalesce((select json_agg(taxi_trip_json(t) order by t.created_at desc) from taxi_trips t where t.car_id=p_car and t.created_at>=m0 and t.created_at<m1), '[]'::json),
    'cash',  coalesce((select json_agg(k order by k.at desc) from taxi_cash k where k.car_id=p_car and k.at>=m0 and k.at<m1), '[]'::json));
end $$;

create or replace function public.taxi_admin_trail_range(p_pin text, p_car uuid, p_from timestamptz, p_to timestamptz) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(json_build_array(lat,lng,extract(epoch from at)) order by at)
    from taxi_trail where car_id=p_car and at >= p_from - interval '1 minute' and at <= p_to + interval '1 minute'), '[]'::json);
end $$;

-- fares are settings the manager edits
create or replace function public.taxi_admin_fares(p_pin text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare f text;
begin
  perform taxi_chk(p_pin);
  foreach f in array array['fare_base','fare_per_km'] loop
    if p ? f then
      if coalesce(regexp_replace(p->>f,'\D','','g'),'') = '' then delete from taxi_settings s where s.k = f;
      else insert into taxi_settings as s(k,v) values (f, regexp_replace(p->>f,'\D','','g')) on conflict (k) do update set v = excluded.v; end if;
    end if;
  end loop;
end $$;

-- list for the live map now carries each car's open trip
create or replace function public.taxi_admin_list(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x order by x.created_at) from (
    select c.*, (select taxi_trip_json(t) from taxi_trips t where t.car_id=c.id and t.status in ('assigned','accepted','started') order by t.id desc limit 1) as trip
    from taxi_cars c) x), '[]'::json);
end $$;

create or replace function public.taxi_public_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'cars',    (select count(*) from taxi_cars where active),
    'online',  (select count(*) from taxi_cars where active and gps_state in ('ok','background') and last_seen > now() - interval '3 minutes'),
    'phone',   (select v from taxi_settings where k='contact_phone'),
    'whatsapp',(select v from taxi_settings where k='contact_whatsapp'),
    'hours',   (select v from taxi_settings where k='contact_hours'),
    'fare_base', taxi_setting_int('fare_base'),
    'fare_per_km', taxi_setting_int('fare_per_km'));
$$;
