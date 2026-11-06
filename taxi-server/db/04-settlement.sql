-- Weekly settlement (Saturday to Friday): each driver hands over the fares of his recorded trips,
-- and gets paid his share of them. A trip that was never recorded earns the driver nothing.

alter table public.taxi_trips add column if not exists settlement_id bigint;

create table if not exists public.taxi_settlements (
  id bigserial primary key,
  car_id uuid not null references public.taxi_cars(id) on delete cascade,
  week_start date not null,
  trips int not null default 0,
  fares int not null default 0,
  share int not null default 0,
  collected int not null default 0,
  paid_out int not null default 0,
  note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists taxi_settlements_car on public.taxi_settlements(car_id, week_start desc);

-- Saturday that starts the week holding day d
create or replace function public.taxi_week_start(d date) returns date language sql immutable as $$
  select d - ((extract(dow from d)::int + 1) % 7);
$$;

-- driver's share of a set of trips, from the manager's settings (percentage and/or fixed per trip)
create or replace function public.taxi_share(p_trips int, p_fares int) returns int language sql stable as $$
  select coalesce(round(p_fares * coalesce(taxi_setting_int('driver_share_pct'),0) / 100.0)::int, 0)
       + p_trips * coalesce(taxi_setting_int('driver_per_trip'), 0);
$$;

create or replace function public.taxi_admin_week(p_pin text, p_day date default null) returns json
language plpgsql security definer set search_path = public as $$
declare ws date := taxi_week_start(coalesce(p_day, (now() at time zone 'Asia/Baghdad')::date));
        w0 timestamptz := ws::timestamp at time zone 'Asia/Baghdad';
        w1 timestamptz := (ws + 7)::timestamp at time zone 'Asia/Baghdad';
        rows json;
begin
  perform taxi_chk(p_pin);
  select json_agg(r order by r.driver_name) into rows from (
    select c.id, c.plate, c.driver_name, c.active,
      u.trips, u.fares, taxi_share(u.trips::int, u.fares::int) as share,
      s.trips as settled_trips, s.fares as settled_fares, s.share as settled_share, s.collected, s.paid_out, s.ids as settlement_ids,
      mv.unlogged, mv.unlogged_km
    from taxi_cars c
    cross join lateral (select count(*) trips, coalesce(sum(fare),0) fares from taxi_trips t
                        where t.car_id=c.id and t.status='done' and t.settlement_id is null and t.ended_at>=w0 and t.ended_at<w1) u
    cross join lateral (select coalesce(sum(trips),0) trips, coalesce(sum(fares),0) fares, coalesce(sum(share),0) share,
                               coalesce(sum(collected),0) collected, coalesce(sum(paid_out),0) paid_out,
                               coalesce(json_agg(id order by id) filter (where id is not null), '[]'::json) ids
                        from taxi_settlements x where x.car_id=c.id and x.week_start=ws) s
    cross join lateral (select count(*) filter (where not m.matched) unlogged,
                               round(coalesce(sum(m.km) filter (where not m.matched),0),1) unlogged_km
                        from taxi_moves(c.id, w0, least(w1, now())) m) mv
    where c.active or u.trips > 0 or s.trips > 0
  ) r;
  return json_build_object('week_start', ws, 'week_end', ws + 6,
    'share_pct', taxi_setting_int('driver_share_pct'), 'per_trip', taxi_setting_int('driver_per_trip'),
    'rows', coalesce(rows, '[]'::json));
end $$;

create or replace function public.taxi_admin_settle(p_pin text, p_car uuid, p_week date, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare ws date := taxi_week_start(p_week);
        w0 timestamptz := ws::timestamp at time zone 'Asia/Baghdad';
        w1 timestamptz := (ws + 7)::timestamp at time zone 'Asia/Baghdad';
        n int; f int; sh int; col int; pay int; st taxi_settlements; c taxi_cars;
begin
  perform taxi_chk(p_pin);
  select * into c from taxi_cars where id=p_car;
  if c.id is null then raise exception 'السيارة غير موجودة'; end if;
  select count(*), coalesce(sum(fare),0) into n, f from taxi_trips
    where car_id=p_car and status='done' and settlement_id is null and ended_at>=w0 and ended_at<w1;
  sh := taxi_share(n, f);
  col := coalesce(nullif(regexp_replace(coalesce(p->>'collected',''),'\D','','g'),'')::int, f);
  pay := coalesce(nullif(regexp_replace(coalesce(p->>'paid_out',''),'\D','','g'),'')::int, sh);
  if n = 0 and col = 0 and pay = 0 then raise exception 'ماكو سفرات غير مسوّاة بهذا الأسبوع'; end if;
  insert into taxi_settlements(car_id,week_start,trips,fares,share,collected,paid_out,note)
  values (p_car, ws, n, f, sh, col, pay, left(coalesce(p->>'note',''),200)) returning * into st;
  update taxi_trips set settlement_id=st.id
    where car_id=p_car and status='done' and settlement_id is null and ended_at>=w0 and ended_at<w1;
  if col > 0 then
    insert into taxi_cash(car_id,amount,note,at) values (p_car, col, 'تسوية أسبوع ' || to_char(ws,'YYYY/MM/DD'), now());
  end if;
  return json_build_object('id',st.id,'week_start',ws,'week_end',ws+6,'plate',c.plate,'driver_name',c.driver_name,
    'trips',n,'fares',f,'share',sh,'collected',col,'paid_out',pay,'note',st.note,'created_at',st.created_at,
    'trip_list', coalesce((select json_agg(json_build_object('ended_at',t.ended_at,'pickup',t.pickup,'dropoff',t.dropoff,'fare',t.fare) order by t.ended_at)
                           from taxi_trips t where t.settlement_id=st.id), '[]'::json));
end $$;

create or replace function public.taxi_admin_settlement(p_pin text, p_id bigint) returns json
language plpgsql security definer set search_path = public as $$
declare st taxi_settlements; c taxi_cars;
begin
  perform taxi_chk(p_pin);
  select * into st from taxi_settlements where id=p_id;
  if st.id is null then raise exception 'التسوية غير موجودة'; end if;
  select * into c from taxi_cars where id=st.car_id;
  return json_build_object('id',st.id,'week_start',st.week_start,'week_end',st.week_start+6,'plate',c.plate,'driver_name',c.driver_name,
    'trips',st.trips,'fares',st.fares,'share',st.share,'collected',st.collected,'paid_out',st.paid_out,'note',st.note,'created_at',st.created_at,
    'trip_list', coalesce((select json_agg(json_build_object('ended_at',t.ended_at,'pickup',t.pickup,'dropoff',t.dropoff,'fare',t.fare) order by t.ended_at)
                           from taxi_trips t where t.settlement_id=st.id), '[]'::json));
end $$;

-- share settings live with the fares
create or replace function public.taxi_admin_fares(p_pin text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare f text;
begin
  perform taxi_chk(p_pin);
  foreach f in array array['fare_base','fare_per_km','driver_share_pct','driver_per_trip'] loop
    if p ? f then
      if coalesce(regexp_replace(p->>f,'\D','','g'),'') = '' then delete from taxi_settings s where s.k = f;
      else
        if f = 'driver_share_pct' and regexp_replace(p->>f,'\D','','g')::int > 100 then raise exception 'النسبة لازم تكون بين 0 و 100'; end if;
        insert into taxi_settings as s(k,v) values (f, regexp_replace(p->>f,'\D','','g')) on conflict (k) do update set v = excluded.v;
      end if;
    end if;
  end loop;
end $$;

create or replace function public.taxi_admin_shares(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return json_build_object('driver_share_pct', taxi_setting_int('driver_share_pct'), 'driver_per_trip', taxi_setting_int('driver_per_trip'));
end $$;

-- the driver sees what his recorded trips earned him this week
create or replace function public.taxi_driver_state(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_cars; open_trip taxi_trips; ws date := taxi_week_start((now() at time zone 'Asia/Baghdad')::date);
        wn int; wf int;
begin
  select * into c from taxi_cars where driver_code=trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  select * into open_trip from taxi_trips where car_id=c.id and status in ('assigned','accepted','started') order by id desc limit 1;
  select count(*), coalesce(sum(fare),0) into wn, wf from taxi_trips
    where car_id=c.id and status='done' and ended_at >= ws::timestamp at time zone 'Asia/Baghdad';
  return json_build_object(
    'trip', case when open_trip.id is null then null else taxi_trip_json(open_trip) end,
    'today_trips', (select count(*) from taxi_trips where car_id=c.id and status='done' and ended_at >= date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad'),
    'today_fares', (select coalesce(sum(fare),0) from taxi_trips where car_id=c.id and status='done' and ended_at >= date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad'),
    'week_trips', wn, 'week_fares', wf, 'week_share', taxi_share(wn, wf),
    'fare_base', taxi_setting_int('fare_base'),
    'gps_state', c.gps_state, 'last_seen', c.last_seen);
end $$;
