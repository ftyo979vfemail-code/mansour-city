-- Loyalty points: 1 point = 1 dinar. Every completed ride earns points; at 5000 points the
-- customer can make a ride free (up to 5000 IQD; above that he pays only the difference).
-- The company bears the points: the driver keeps his share on the full fare and simply
-- collects (fare - points_used) in cash.

create table if not exists public.taxi_points (
  id bigserial primary key,
  customer_id bigint not null references public.taxi_customers(id) on delete cascade,
  delta int not null,
  reason text not null,              -- welcome | trip | redeem | refund | gift
  trip_id bigint references public.taxi_trips(id) on delete set null,
  note text,
  at timestamptz not null default now()
);
create index if not exists taxi_points_c on public.taxi_points(customer_id);
create unique index if not exists taxi_points_trip_once on public.taxi_points(trip_id, reason) where trip_id is not null and reason in ('trip','redeem');
alter table public.taxi_points enable row level security;
revoke all on public.taxi_points from anon, authenticated;

alter table public.taxi_trips add column if not exists points_used int not null default 0;
alter table public.taxi_settlements add column if not exists points int not null default 0;

insert into public.taxi_settings(k,v) values ('points_per_trip','250'),('points_welcome','500'),('points_redeem','5000')
  on conflict (k) do nothing;

create or replace function public.taxi_points_balance(p_c bigint) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(delta),0)::int from taxi_points where customer_id = p_c;
$$;

create or replace function public.taxi_points_json(p_c bigint) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('balance', taxi_points_balance(p_c),
    'redeem', coalesce(taxi_setting_int('points_redeem'),5000),
    'per_trip', coalesce(taxi_setting_int('points_per_trip'),0),
    'history', coalesce((select json_agg(x order by x.at desc) from (
        select delta, reason, at, (select name from taxi_zones z join taxi_trips t on t.zone_id=z.id where t.id=p.trip_id) zone, note
        from taxi_points p where customer_id=p_c order by at desc limit 15) x),'[]'::json));
$$;

-- credit on done, refund on cancel
create or replace function public.taxi_trip_points_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare earn int := coalesce(taxi_setting_int('points_per_trip'),0); over int;
begin
  if new.customer_id is null then return new; end if;
  if new.status = 'done' and old.status is distinct from 'done' then
    if new.points_used > coalesce(new.fare,0) then   -- fare ended below what was reserved
      over := new.points_used - coalesce(new.fare,0);
      insert into taxi_points(customer_id,delta,reason,trip_id,note) values (new.customer_id, over, 'refund', new.id, 'الباقي من الكروة المجانية');
      update taxi_trips set points_used = coalesce(new.fare,0) where id = new.id;
    end if;
    if earn > 0 and new.points_used = 0 then
      insert into taxi_points(customer_id,delta,reason,trip_id) values (new.customer_id, earn, 'trip', new.id) on conflict do nothing;
    end if;
  elsif new.status = 'cancelled' and old.status is distinct from 'cancelled' and new.points_used > 0 then
    insert into taxi_points(customer_id,delta,reason,trip_id,note) values (new.customer_id, new.points_used, 'refund', new.id, 'رجعت النقاط لأن الطلب انلغى');
    update taxi_trips set points_used = 0 where id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists taxi_trip_points on public.taxi_trips;
create trigger taxi_trip_points after update of status on public.taxi_trips
  for each row execute function public.taxi_trip_points_trg();

create or replace function public.taxi_trip_json(t taxi_trips) returns json
language sql stable as $$
  select json_build_object('id',t.id,'status',t.status,'source',t.source,'pickup',t.pickup,'dropoff',t.dropoff,
    'customer_name',t.customer_name,'note',t.note,'fare',t.fare,'km',t.km,'created_at',t.created_at,
    'accepted_at',t.accepted_at,'started_at',t.started_at,'ended_at',t.ended_at,
    'zone_id',t.zone_id,'zone',(select name from taxi_zones z where z.id=t.zone_id),
    'pickup_lat',t.pickup_lat,'pickup_lng',t.pickup_lng,
    'points_used',t.points_used,'collect',greatest(coalesce(t.fare,0)-t.points_used,0));
$$;

-- signup: welcome points
create or replace function public.taxi_customer_signup(p jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare un text := taxi_norm_user(p->>'username'); nm text := left(trim(coalesce(p->>'name','')),60);
        pw text := coalesce(p->>'password',''); c taxi_customers; tok uuid;
        b text := left(trim(coalesce(p->>'building','')),40); f text := left(trim(coalesce(p->>'floor','')),10); a text := left(trim(coalesce(p->>'apartment','')),10);
        w int := coalesce(taxi_setting_int('points_welcome'),0);
begin
  if length(nm) < 2 then raise exception 'اكتب اسمك'; end if;
  if un is null then raise exception 'اسم المستخدم من 3 لحد 20 حرف إنگليزي أو رقم، بدون مسافات'; end if;
  if b = '' then raise exception 'اختار العمارة'; end if;
  if f = '' then raise exception 'اختار الطابق'; end if;
  if a = '' then raise exception 'اكتب رقم الشقة'; end if;
  if length(pw) < 6 then raise exception 'كلمة السر لازم 6 أحرف أو أكثر'; end if;
  if exists (select 1 from taxi_customers where lower(username) = un) then raise exception 'اسم المستخدم مأخوذ، اختار غيره'; end if;
  if (select count(*) from taxi_customers where created_at > now() - interval '10 minutes') >= 40 then
    raise exception 'حاول بعد شوية'; end if;
  insert into taxi_customers(name, username, phone, pass_hash, last_login, building, floor, apartment)
  values (nm, un, null, crypt(pw, gen_salt('bf')), now(), b, f, a) returning * into c;
  if w > 0 then insert into taxi_points(customer_id,delta,reason,note) values (c.id, w, 'welcome', 'هدية التسجيل'); end if;
  insert into taxi_customer_sessions(customer_id) values (c.id) returning token into tok;
  return json_build_object('token', tok, 'name', c.name, 'username', c.username, 'building', c.building, 'floor', c.floor, 'apartment', c.apartment, 'welcome', w);
end $$;

create or replace function public.taxi_customer_me(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_customers := taxi_session_customer(p_token);
begin
  return json_build_object('name', c.name, 'username', coalesce(c.username, c.phone), 'building', c.building, 'floor', c.floor, 'apartment', c.apartment,
    'points', taxi_points_json(c.id),
    'open', (select request_token from taxi_trips where customer_id=c.id and status in ('requested','assigned','accepted','started','rejected')
             order by id desc limit 1),
    'trips', coalesce((select json_agg(x order by x.created_at desc) from (
        select t.request_token as token, t.status, t.created_at, t.pickup, (select name from taxi_zones z where z.id=t.zone_id) as zone,
               t.points_used > 0 as free,
               (select delta from taxi_points p where p.trip_id=t.id and p.reason='trip') as earned
        from taxi_trips t where t.customer_id=c.id order by t.id desc limit 20) x), '[]'::json));
end $$;

-- order: optional use_points. Reserves min(threshold, fare) points; the customer never sees the fare.
create or replace function public.taxi_customer_order(p_token uuid, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_customers := taxi_session_customer(p_token); z taxi_zones; tr taxi_trips; lat double precision; lng double precision;
        th int := coalesce(taxi_setting_int('points_redeem'),5000); fare int; use int := 0;
begin
  if coalesce(trim(p->>'pickup'),'') = '' and p->>'lat' is null then raise exception 'اكتب وين إنت (العمارة أو البوابة)'; end if;
  select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
  if z.id is null then raise exception 'اختار المنطقة اللي رايح إلها'; end if;
  if exists (select 1 from taxi_trips where customer_id=c.id and status in ('requested','assigned','accepted','started')) then
    raise exception 'عندك طلب مفتوح، انتظر السائق أو ألغِه أولًا'; end if;
  if (select count(*) from taxi_trips where status='requested' and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'الطلبات كثيرة هسه، حاول بعد دقائق'; end if;
  lat := nullif(p->>'lat','')::double precision; lng := nullif(p->>'lng','')::double precision;
  if lat is not null and (lat not between -90 and 90 or lng not between -180 and 180) then lat := null; lng := null; end if;
  fare := taxi_zone_price(z);
  if coalesce((p->>'use_points')::boolean, false) then
    perform 1 from taxi_customers where id = c.id for update;   -- serialize redeems per customer
    if taxi_points_balance(c.id) < th then raise exception 'نقاطك ما وصلت % بعد', th; end if;
    use := least(th, coalesce(fare, th));
  end if;
  insert into taxi_trips(car_id,source,status,customer_id,customer_phone,customer_name,pickup,dropoff,note,zone_id,fare,request_token,pickup_lat,pickup_lng,points_used)
  values (null,'customer','requested',c.id,'',c.name,left(coalesce(trim(p->>'pickup'),''),120),z.name,
          left(coalesce(p->>'note',''),200),z.id,fare,gen_random_uuid(),lat,lng,use)
  returning * into tr;
  if use > 0 then
    insert into taxi_points(customer_id,delta,reason,trip_id,note) values (c.id, -use, 'redeem', tr.id, 'كروة مجانية');
  end if;
  insert into taxi_events(car_id,kind,info) values (null,'request', c.name || ': ' || coalesce(nullif(tr.pickup,''),'موقع على الخريطة') || ' ← ' || z.name
    || case when use > 0 then ' (كروة مجانية بالنقاط)' else '' end);
  return json_build_object('token', tr.request_token, 'points_used', use);
end $$;

create or replace function public.taxi_customer_status(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare tr taxi_trips; c taxi_cars;
begin
  select * into tr from taxi_trips where request_token = p_token;
  if tr.id is null then raise exception 'الطلب غير موجود'; end if;
  if tr.car_id is not null and tr.status in ('accepted','started','done') then select * into c from taxi_cars where id = tr.car_id; end if;
  return json_build_object('status', tr.status, 'zone', (select name from taxi_zones where id=tr.zone_id), 'pickup', tr.pickup,
    'created_at', tr.created_at, 'accepted_at', tr.accepted_at, 'started_at', tr.started_at, 'ended_at', tr.ended_at,
    'driver_name', c.driver_name, 'plate', c.plate, 'model', c.model, 'color', c.color,
    'car_lat', case when tr.status='accepted' then c.last_lat end, 'car_lng', case when tr.status='accepted' then c.last_lng end,
    'free', tr.points_used > 0,
    'earned', (select delta from taxi_points p where p.trip_id=tr.id and p.reason='trip'),
    'balance', case when tr.customer_id is not null then taxi_points_balance(tr.customer_id) end);
end $$;

-- admin: points settings, customers list with points, manual gift/deduct
create or replace function public.taxi_admin_points_settings(p_pin text, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare f text; v int;
begin
  perform taxi_chk(p_pin);
  foreach f in array array['points_per_trip','points_welcome','points_redeem'] loop
    if p ? f then
      v := coalesce(nullif(regexp_replace(coalesce(p->>f,''),'\D','','g'),'')::int, 0);
      if f = 'points_redeem' and v < 1000 then raise exception 'حد الكروة المجانية لازم 1000 نقطة أو أكثر'; end if;
      insert into taxi_settings as s(k,v) values (f, v::text) on conflict (k) do update set v = excluded.v;
    end if;
  end loop;
  return json_build_object('points_per_trip', taxi_setting_int('points_per_trip'), 'points_welcome', taxi_setting_int('points_welcome'),
    'points_redeem', taxi_setting_int('points_redeem'),
    'issued', (select coalesce(sum(delta),0) from taxi_points where delta > 0 and reason <> 'refund'),
    'redeemed', (select coalesce(sum(points_used),0) from taxi_trips where status='done'),
    'outstanding', (select coalesce(sum(delta),0) from taxi_points));
end $$;

create or replace function public.taxi_admin_points_adjust(p_pin text, p_id bigint, p_delta int, p_note text) returns int
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  if p_delta = 0 or abs(p_delta) > 100000 then raise exception 'اكتب عدد نقاط صحيح'; end if;
  if not exists (select 1 from taxi_customers where id = p_id) then raise exception 'الزبون غير موجود'; end if;
  if taxi_points_balance(p_id) + p_delta < 0 then raise exception 'رصيده ما يكفي'; end if;
  insert into taxi_points(customer_id,delta,reason,note) values (p_id, p_delta, 'gift', left(coalesce(p_note,''),100));
  return taxi_points_balance(p_id);
end $$;

create or replace function public.taxi_admin_customers(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select cu.id, cu.name, coalesce(cu.username, cu.phone) as username, cu.blocked, cu.created_at, cu.last_login, cu.building, cu.floor, cu.apartment,
      (select count(*) from taxi_trips t where t.customer_id=cu.id and t.status='done') as trips,
      (select count(*) from taxi_trips t where t.customer_id=cu.id and t.status='cancelled' and t.cancel_reason='ألغاه الزبون') as cancels,
      taxi_points_balance(cu.id) as points,
      (select count(*) from taxi_trips t where t.customer_id=cu.id and t.status='done' and t.points_used>0) as free_trips
    from taxi_customers cu) x), '[]'::json);
end $$;

-- money: the driver holds cash = fare - points_used; his share stays on the full fare.
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
      u.trips, u.fares, u.points, u.fares - u.points as cash, taxi_share(u.trips::int, u.fares::int) as share,
      s.trips as settled_trips, s.fares as settled_fares, s.share as settled_share, s.collected, s.paid_out, s.ids as settlement_ids,
      mv.unlogged, mv.unlogged_km
    from taxi_cars c
    cross join lateral (select count(*) trips, coalesce(sum(fare),0) fares, coalesce(sum(points_used),0) points from taxi_trips t
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

create or replace function public.taxi_settlement_trips(p_id bigint) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('ended_at',t.ended_at,'pickup',t.pickup,'dropoff',t.dropoff,'fare',t.fare,'points_used',t.points_used) order by t.ended_at), '[]'::json)
  from taxi_trips t where t.settlement_id = p_id;
$$;

create or replace function public.taxi_admin_settle(p_pin text, p_car uuid, p_week date, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare ws date := taxi_week_start(p_week);
        w0 timestamptz := ws::timestamp at time zone 'Asia/Baghdad';
        w1 timestamptz := (ws + 7)::timestamp at time zone 'Asia/Baghdad';
        n int; f int; pts int; sh int; col int; pay int; st taxi_settlements; c taxi_cars;
begin
  perform taxi_chk(p_pin);
  select * into c from taxi_cars where id=p_car;
  if c.id is null then raise exception 'السيارة غير موجودة'; end if;
  select count(*), coalesce(sum(fare),0), coalesce(sum(points_used),0) into n, f, pts from taxi_trips
    where car_id=p_car and status='done' and settlement_id is null and ended_at>=w0 and ended_at<w1;
  sh := taxi_share(n, f);
  col := coalesce(nullif(regexp_replace(coalesce(p->>'collected',''),'\D','','g'),'')::int, f - pts);
  pay := coalesce(nullif(regexp_replace(coalesce(p->>'paid_out',''),'\D','','g'),'')::int, sh);
  if n = 0 and col = 0 and pay = 0 then raise exception 'ماكو سفرات غير مسوّاة بهذا الأسبوع'; end if;
  insert into taxi_settlements(car_id,week_start,trips,fares,points,share,collected,paid_out,note)
  values (p_car, ws, n, f, pts, sh, col, pay, left(coalesce(p->>'note',''),200)) returning * into st;
  update taxi_trips set settlement_id=st.id
    where car_id=p_car and status='done' and settlement_id is null and ended_at>=w0 and ended_at<w1;
  if col > 0 then
    insert into taxi_cash(car_id,amount,note,at) values (p_car, col, 'تسوية أسبوع ' || to_char(ws,'YYYY/MM/DD'), now());
  end if;
  return json_build_object('id',st.id,'week_start',ws,'week_end',ws+6,'plate',c.plate,'driver_name',c.driver_name,
    'trips',n,'fares',f,'points',pts,'cash',f-pts,'share',sh,'collected',col,'paid_out',pay,'note',st.note,'created_at',st.created_at,
    'trip_list', taxi_settlement_trips(st.id));
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
    'trips',st.trips,'fares',st.fares,'points',st.points,'cash',st.fares-st.points,'share',st.share,'collected',st.collected,'paid_out',st.paid_out,
    'note',st.note,'created_at',st.created_at,'trip_list', taxi_settlement_trips(st.id));
end $$;

create or replace function public.taxi_balance_row(p_car uuid) returns json
language sql stable security definer set search_path = public as $$
  with f as (select count(*) n, coalesce(sum(fare),0) s, coalesce(sum(points_used),0) p from taxi_trips where car_id=p_car and status='done'),
       u as (select count(*) n, coalesce(sum(fare),0) s from taxi_trips where car_id=p_car and status='done' and settlement_id is null),
       k as (select coalesce(sum(amount),0) s, max(at) last_at from taxi_cash where car_id=p_car),
       st as (select coalesce(sum(share),0) sh, coalesce(sum(paid_out),0) po from taxi_settlements where car_id=p_car)
  select json_build_object(
    'trips', f.n, 'fares', f.s, 'points', f.p, 'cash', f.s - f.p, 'collected', k.s, 'last_collected_at', k.last_at,
    'in_hand', f.s - f.p - k.s,
    'share', st.sh + taxi_share(u.n::int, u.s::int), 'paid_out', st.po,
    'owed_to_him', st.sh + taxi_share(u.n::int, u.s::int) - st.po,
    'net', (f.s - f.p - k.s) - (st.sh + taxi_share(u.n::int, u.s::int) - st.po))
  from f, u, k, st;
$$;

revoke all on function public.taxi_points_balance(bigint), public.taxi_points_json(bigint), public.taxi_trip_points_trg(),
  public.taxi_settlement_trips(bigint), public.taxi_balance_row(uuid) from public, anon, authenticated;
grant execute on function public.taxi_admin_points_settings(text,jsonb), public.taxi_admin_points_adjust(text,bigint,int,text) to anon;

-- public: let the landing page show the points offer
create or replace function public.taxi_public_info() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'cars',    (select count(*) from taxi_cars where active),
    'online',  (select count(*) from taxi_cars where active and gps_state in ('ok','background') and last_seen > now() - interval '3 minutes'),
    'phone',   (select v from taxi_settings where k='contact_phone'),
    'whatsapp',(select v from taxi_settings where k='contact_whatsapp'),
    'hours',   (select v from taxi_settings where k='contact_hours'),
    'fare_base', taxi_setting_int('fare_base'),
    'fare_per_km', taxi_setting_int('fare_per_km'),
    'points_per_trip', taxi_setting_int('points_per_trip'),
    'points_welcome', taxi_setting_int('points_welcome'),
    'points_redeem', taxi_setting_int('points_redeem'));
$$;
