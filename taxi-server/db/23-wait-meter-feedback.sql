-- 23: waiting split in two, driver ratings, complaints, daily report.
--  * Pickup wait (driver reached the customer, trip 'accepted'): a clock only, no money.
--    Pressing انطلاق ('start') stops it and keeps the seconds for the record.
--  * Paid waiting meter (trip 'started', the customer says "انتظرني هنا"): charged by tiers
--    from setting wait_tiers "minute:amount,…" (default 10:250,15:1500,30:2500,60:5000).
--    The last tier is a full cycle: every full hour costs its amount, the remainder uses the
--    highest tier reached (under the first tier = 0).
--  * taxi_ratings: one 1–5 star rating per done trip, by its customer. ≤2 stars -> event low_rating.
--  * taxi_complaints: customer complaints (optionally about a trip); admin closes with a note.
--  * taxi_admin_daily(pin, day): the day's report.

alter table public.taxi_trips add column if not exists pickup_wait_started_at timestamptz,
  add column if not exists pickup_wait_sec integer not null default 0;

insert into public.taxi_settings(k,v) values ('wait_tiers','10:250,15:1500,30:2500,60:5000') on conflict (k) do nothing;

create or replace function public.taxi_wait_tiers() returns jsonb language sql stable set search_path to 'public' as $$
  select coalesce((
    select jsonb_agg(jsonb_build_object('m', m, 'f', f) order by m)
    from (select split_part(x,':',1)::int m, split_part(x,':',2)::int f
          from unnest(string_to_array(regexp_replace(coalesce((select v from taxi_settings where k='wait_tiers'),'10:250,15:1500,30:2500,60:5000'),'\s','','g'),',')) x
          where x ~ '^\d+:\d+$') q where m > 0), '[]'::jsonb)
$$;

create or replace function public.taxi_wait_fee(p_sec integer) returns integer language plpgsql stable set search_path to 'public' as $$
declare t jsonb := taxi_wait_tiers(); mins int := greatest(coalesce(p_sec,0),0) / 60; cyc int; cf int; r int; e jsonb; f int := 0;
begin
  if jsonb_array_length(t) = 0 then return 0; end if;
  cyc := (t->-1->>'m')::int; cf := (t->-1->>'f')::int;
  r := mins % cyc;
  for e in select * from jsonb_array_elements(t) loop
    if (e->>'m')::int <= r then f := (e->>'f')::int; end if;
  end loop;
  return (mins / cyc) * cf + f;
end $$;

create or replace function public.taxi_pickup_wait_total(t taxi_trips) returns integer language sql stable as $$
  select coalesce(t.pickup_wait_sec,0) + case when t.pickup_wait_started_at is null then 0 else extract(epoch from now() - t.pickup_wait_started_at)::int end
$$;

-- driver actions: wait_start / wait_end act on the pickup clock while 'accepted', on the paid meter while 'started'
create or replace function public.taxi_driver_trip(p_code text, p_action text, p jsonb default '{}'::jsonb)
 returns json language plpgsql security definer set search_path to 'public' as $function$
declare c taxi_cars; tr taxi_trips; z taxi_zones; base int; ws int;
begin
  select * into c from taxi_cars where driver_code=trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  select * into tr from taxi_trips where car_id=c.id and status in ('assigned','accepted','started') order by id desc limit 1 for update;

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
      update taxi_trips set status='started', started_at=now(),
        pickup_wait_sec = taxi_pickup_wait_total(tr), pickup_wait_started_at = null
      where id=tr.id returning * into tr;
    else
      select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
      insert into taxi_trips(car_id,source,status,pickup,dropoff,zone_id,fare,accepted_at,started_at,round_trip)
      values (c.id,'driver','started',left(coalesce(p->>'pickup',''),120),
              coalesce(z.name, left(coalesce(p->>'dropoff',''),120)), z.id,
              case when z.id is null then null else taxi_zone_price(z) end, now(), now(),
              coalesce((p->>'round_trip')::boolean,false))
      returning * into tr;
    end if;
    update taxi_cars set moving_since=null, unlogged_flagged=false where id=c.id;
  elsif p_action = 'round' then
    if tr.status is distinct from 'started' then raise exception 'ماكو سفرة شغّالة'; end if;
    update taxi_trips set round_trip = coalesce((p->>'on')::boolean, not round_trip) where id=tr.id returning * into tr;
    insert into taxi_events(car_id,kind,info) values (c.id,'round', case when tr.round_trip then 'خلّاها مرجع (ذهاب ورجعة)' else 'شال المرجع' end);
  elsif p_action = 'wait_start' then
    if tr.status = 'accepted' then
      if tr.pickup_wait_started_at is not null then raise exception 'العدّاد شغّال'; end if;
      update taxi_trips set pickup_wait_started_at=now() where id=tr.id returning * into tr;
    elsif tr.status = 'started' then
      if tr.wait_started_at is not null then raise exception 'العدّاد شغّال'; end if;
      update taxi_trips set wait_started_at=now(), wait_count=wait_count+1 where id=tr.id returning * into tr;
    else raise exception 'ماكو سفرة شغّالة'; end if;
  elsif p_action = 'wait_end' then
    if tr.status = 'accepted' and tr.pickup_wait_started_at is not null then
      update taxi_trips set pickup_wait_sec = taxi_pickup_wait_total(tr), pickup_wait_started_at=null where id=tr.id returning * into tr;
    elsif tr.status = 'started' and tr.wait_started_at is not null then
      update taxi_trips set wait_sec = taxi_wait_total(tr), wait_started_at=null where id=tr.id returning * into tr;
    else raise exception 'ماكو انتظار شغّال'; end if;
  elsif p_action = 'end' then
    if tr.status is distinct from 'started' then raise exception 'ماكو سفرة شغّالة'; end if;
    if tr.zone_id is not null and tr.fare is not null then
      base := coalesce(tr.base_fare, tr.fare);
    else
      base := nullif(regexp_replace(coalesce(p->>'fare',''),'\D','','g'),'')::int;
      if base is null or base <= 0 then raise exception 'اكتب مبلغ الأجرة'; end if;
      if base > 1000000 then raise exception 'المبلغ كبير، تأكد منه'; end if;
    end if;
    ws := taxi_wait_total(tr);
    update taxi_trips set status='done', ended_at=now(),
      wait_sec = ws, wait_started_at = null, base_fare = base,
      round_fee = case when round_trip then taxi_round_fee(base) else 0 end,
      wait_fee = taxi_wait_fee(ws),
      fare = base + (case when round_trip then taxi_round_fee(base) else 0 end) + taxi_wait_fee(ws),
      dropoff = case when coalesce(p->>'dropoff','')<>'' and zone_id is null then left(p->>'dropoff',120) else dropoff end,
      km = (select round((coalesce(sum(m.km),0))::numeric,2) from taxi_moves(c.id, coalesce(tr.accepted_at,tr.started_at), now()+interval '1 second') m)
    where id=tr.id returning * into tr;
  else
    raise exception 'إجراء غير معروف';
  end if;
  return taxi_trip_json(tr);
end $function$;

create or replace function public.taxi_trip_json(t taxi_trips) returns json language sql stable as $function$
  select json_build_object('id',t.id,'status',t.status,'source',t.source,'pickup',t.pickup,'dropoff',t.dropoff,
    'customer_name',t.customer_name,'note',t.note,'fare',t.fare,'km',t.km,'created_at',t.created_at,
    'accepted_at',t.accepted_at,'started_at',t.started_at,'ended_at',t.ended_at,
    'zone_id',t.zone_id,'zone',z.name,'zone_lat',coalesce(t.dropoff_lat,z.lat),'zone_lng',coalesce(t.dropoff_lng,z.lng),
    'dropoff_lat',t.dropoff_lat,'dropoff_lng',t.dropoff_lng,'dropoff_note',t.dropoff_note,
    'pickup_lat',t.pickup_lat,'pickup_lng',t.pickup_lng,
    'points_used',t.points_used,'collect',greatest(coalesce(t.fare,0)-t.points_used,0),
    'round_trip',t.round_trip,'waiting',t.wait_started_at is not null,'wait_started_at',t.wait_started_at,
    'wait_sec',taxi_wait_total(t),'wait_count',t.wait_count,
    'pickup_waiting',t.pickup_wait_started_at is not null,'pickup_wait_sec',taxi_pickup_wait_total(t),
    'wait_tiers',taxi_wait_tiers(),'wait_free_min',0,'wait_per_min',0,
    'round_trip_pct',coalesce(taxi_setting_int('round_trip_pct'),100),
    'base_fare',coalesce(t.base_fare,t.fare),'round_fee',t.round_fee,'wait_fee',t.wait_fee,
    'dest_changes',t.dest_changes,
    'dest_change',(select taxi_route_change_json(rc) from taxi_route_changes rc
                   where rc.trip_id=t.id and (rc.status in ('pending','awaiting_customer') or rc.decided_at > now()-interval '3 minutes')
                   order by rc.id desc limit 1))
  from (select 1) one left join taxi_zones z on z.id = t.zone_id;
$function$;

-- settings: wait_tiers replaces the per-minute fields
create or replace function public.taxi_admin_fares(p_pin text, p jsonb) returns void language plpgsql security definer set search_path to 'public' as $function$
declare f text; tiers text; prev int := 0; x text;
begin
  perform taxi_chk(p_pin);
  foreach f in array array['fare_base','fare_per_km','round_trip_pct'] loop
    if p ? f then
      if coalesce(regexp_replace(p->>f,'\D','','g'),'') = '' then delete from taxi_settings s where s.k = f;
      else
        if f = 'round_trip_pct' and regexp_replace(p->>f,'\D','','g')::int > 300 then raise exception 'نسبة المرجع كبيرة'; end if;
        insert into taxi_settings as s(k,v) values (f, regexp_replace(p->>f,'\D','','g')) on conflict (k) do update set v = excluded.v;
      end if;
    end if;
  end loop;
  if p ? 'wait_tiers' then
    tiers := regexp_replace(coalesce(p->>'wait_tiers',''),'\s','','g');
    if tiers = '' then raise exception 'حدّد أسعار عدّاد الانتظار'; end if;
    foreach x in array string_to_array(tiers, ',') loop
      if x !~ '^\d+:\d+$' then raise exception 'صيغة العدّاد غلط: %', x; end if;
      if split_part(x,':',1)::int <= prev then raise exception 'الدقائق لازم تكون بالترتيب وأكبر من صفر'; end if;
      if split_part(x,':',2)::int > 1000000 then raise exception 'المبلغ كبير'; end if;
      prev := split_part(x,':',1)::int;
    end loop;
    insert into taxi_settings as s(k,v) values ('wait_tiers', tiers) on conflict (k) do update set v = excluded.v;
  end if;
end $function$;

create or replace function public.taxi_admin_shares(p_pin text) returns json language plpgsql security definer set search_path to 'public' as $function$
begin
  perform taxi_chk(p_pin);
  return json_build_object('round_trip_pct', taxi_setting_int('round_trip_pct'), 'wait_tiers', taxi_wait_tiers());
end $function$;

create or replace function public.taxi_admin_trips(p_pin text, p_day date default null) returns json language plpgsql security definer set search_path to 'public' as $function$
declare d date := coalesce(p_day, (now() at time zone 'Asia/Baghdad')::date);
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select t.id, t.car_id, t.source, t.status, t.customer_phone, t.customer_name, t.pickup, t.dropoff, t.note, t.fare, t.km,
           t.created_at, t.accepted_at, t.started_at, t.ended_at, t.cancel_reason, t.zone_id, t.pickup_lat, t.pickup_lng, t.points_used,
           t.dispatched_by, t.round_trip, taxi_wait_total(t) as wait_sec, t.wait_started_at is not null as waiting, t.round_fee, t.wait_fee, t.base_fare,
           taxi_pickup_wait_total(t) as pickup_wait_sec, t.pickup_wait_started_at is not null as pickup_waiting,
           (select stars from taxi_ratings r where r.trip_id=t.id) as stars,
           t.dropoff_note, t.dropoff_lat, t.dropoff_lng, c.plate, c.driver_name
    from taxi_trips t left join taxi_cars c on c.id=t.car_id
    where (t.created_at at time zone 'Asia/Baghdad')::date = d
       or t.status in ('requested','assigned','accepted','started')
       or (t.status = 'rejected' and t.customer_id is not null and t.created_at > now() - interval '1 day')) x), '[]'::json);
end $function$;

-- ---------- ratings & complaints ----------
create table if not exists public.taxi_ratings (
  trip_id bigint primary key references public.taxi_trips(id) on delete cascade,
  customer_id bigint not null references public.taxi_customers(id) on delete cascade,
  car_id uuid references public.taxi_cars(id) on delete set null,
  stars smallint not null check (stars between 1 and 5),
  comment text not null default '',
  created_at timestamptz not null default now());
create index if not exists taxi_ratings_car on public.taxi_ratings(car_id, created_at desc);

create table if not exists public.taxi_complaints (
  id bigserial primary key,
  customer_id bigint not null references public.taxi_customers(id) on delete cascade,
  trip_id bigint references public.taxi_trips(id) on delete set null,
  car_id uuid references public.taxi_cars(id) on delete set null,
  body text not null,
  status text not null default 'open' check (status in ('open','closed')),
  admin_note text not null default '',
  closed_by text, created_at timestamptz not null default now(), closed_at timestamptz);
create index if not exists taxi_complaints_open on public.taxi_complaints(status, created_at desc);
alter table public.taxi_ratings enable row level security;
alter table public.taxi_complaints enable row level security;
revoke all on public.taxi_ratings, public.taxi_complaints from anon, authenticated;

create or replace function public.taxi_customer_rate(p_token uuid, p_trip bigint, p_stars integer, p_comment text default '')
 returns json language plpgsql security definer set search_path to 'public' as $$
declare cu taxi_customers := taxi_session_customer(p_token); tr taxi_trips;
begin
  select * into tr from taxi_trips where id = p_trip and customer_id = cu.id;
  if tr.id is null then raise exception 'السفرة غير موجودة'; end if;
  if tr.status <> 'done' then raise exception 'تكدر تقيّم بعد ما توصل'; end if;
  if tr.ended_at < now() - interval '7 days' then raise exception 'انتهى وقت التقييم لهاي السفرة'; end if;
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'اختار من 1 إلى 5 نجوم'; end if;
  insert into taxi_ratings(trip_id, customer_id, car_id, stars, comment)
  values (tr.id, cu.id, tr.car_id, p_stars, left(trim(coalesce(p_comment,'')), 300))
  on conflict (trip_id) do update set stars = excluded.stars, comment = excluded.comment, created_at = now();
  if p_stars <= 2 then
    insert into taxi_events(car_id, kind, info) values (tr.car_id, 'low_rating', p_stars || ' نجمة' || case when trim(coalesce(p_comment,''))<>'' then ': ' || left(trim(p_comment),80) else '' end);
  end if;
  return json_build_object('ok', true, 'stars', p_stars);
end $$;

create or replace function public.taxi_customer_complain(p_token uuid, p_trip bigint, p_body text)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare cu taxi_customers := taxi_session_customer(p_token); tr taxi_trips; cid bigint;
begin
  if length(trim(coalesce(p_body,''))) < 5 then raise exception 'اكتب الشكوى بالتفصيل'; end if;
  if (select count(*) from taxi_complaints where customer_id = cu.id and created_at > now() - interval '1 day') >= 5 then
    raise exception 'وصلتنا شكاويك، الإدارة راح تتابعها'; end if;
  if p_trip is not null then
    select * into tr from taxi_trips where id = p_trip and customer_id = cu.id;
    if tr.id is null then raise exception 'السفرة غير موجودة'; end if;
  end if;
  insert into taxi_complaints(customer_id, trip_id, car_id, body) values (cu.id, tr.id, tr.car_id, left(trim(p_body), 1000)) returning id into cid;
  insert into taxi_events(car_id, kind, info) values (tr.car_id, 'complaint', left(trim(p_body), 80));
  return json_build_object('ok', true, 'id', cid);
end $$;

create or replace function public.taxi_admin_feedback(p_pin text) returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk(p_pin);
  return json_build_object(
    'drivers', coalesce((select json_agg(x order by x.avg nulls last) from (
        select c.id as car_id, c.plate, c.driver_name, round(avg(r.stars)::numeric, 1) as avg, count(r.*) as count,
               count(*) filter (where r.stars <= 2) as low,
               (select count(*) from taxi_complaints k where k.car_id = c.id) as complaints,
               (select count(*) from taxi_complaints k where k.car_id = c.id and k.status='open') as open_complaints
        from taxi_cars c left join taxi_ratings r on r.car_id = c.id
        where c.active group by c.id) x), '[]'::json),
    'ratings', coalesce((select json_agg(x order by x.created_at desc) from (
        select r.trip_id, r.stars, r.comment, r.created_at, c.plate, c.driver_name, cu.name as customer_name,
               (select name from taxi_zones z where z.id = t.zone_id) as zone
        from taxi_ratings r join taxi_trips t on t.id = r.trip_id left join taxi_cars c on c.id = r.car_id
        join taxi_customers cu on cu.id = r.customer_id
        order by r.created_at desc limit 60) x), '[]'::json),
    'complaints', coalesce((select json_agg(x order by x.status desc, x.created_at desc) from (
        select k.id, k.body, k.status, k.admin_note, k.closed_by, k.created_at, k.closed_at, k.trip_id,
               c.plate, c.driver_name, cu.name as customer_name, coalesce(cu.username, cu.phone) as customer_user,
               (select name from taxi_zones z where z.id = t.zone_id) as zone, t.created_at as trip_at
        from taxi_complaints k join taxi_customers cu on cu.id = k.customer_id
        left join taxi_cars c on c.id = k.car_id left join taxi_trips t on t.id = k.trip_id
        where k.status = 'open' or k.created_at > now() - interval '60 days'
        order by k.created_at desc limit 100) x), '[]'::json));
end $$;

create or replace function public.taxi_admin_complaint_close(p_pin text, p_id bigint, p_note text default '')
 returns json language plpgsql security definer set search_path to 'public' as $$
declare who text;
begin
  perform taxi_chk(p_pin);
  select coalesce((taxi_admin_who(p_pin))->>'name','المدير') into who;
  update taxi_complaints set status='closed', admin_note=left(trim(coalesce(p_note,'')),300), closed_by=who, closed_at=now()
   where id = p_id and status = 'open';
  if not found then raise exception 'الشكوى مسكّرة أو مو موجودة'; end if;
  return json_build_object('ok', true);
end $$;

-- customer order status: pickup clock, trip id and rating state (still no prices)
create or replace function public.taxi_customer_status(p_token uuid) returns json language plpgsql security definer set search_path to 'public' as $function$
declare tr taxi_trips; c taxi_cars;
begin
  perform taxi_resolve_route_changes();
  select * into tr from taxi_trips where request_token = p_token;
  if tr.id is null then raise exception 'الطلب غير موجود'; end if;
  if tr.car_id is not null and tr.status in ('accepted','started','done') then select * into c from taxi_cars where id = tr.car_id; end if;
  return json_build_object('trip_id', tr.id, 'status', tr.status, 'zone', (select name from taxi_zones where id=tr.zone_id), 'pickup', tr.pickup,
    'created_at', tr.created_at, 'accepted_at', tr.accepted_at, 'started_at', tr.started_at, 'ended_at', tr.ended_at,
    'driver_name', c.driver_name, 'plate', c.plate, 'model', c.model, 'color', c.color,
    'car_lat', case when tr.status='accepted' then c.last_lat end, 'car_lng', case when tr.status='accepted' then c.last_lng end,
    'free', tr.points_used > 0,
    'earned', (select delta from taxi_points p where p.trip_id=tr.id and p.reason='trip'),
    'balance', case when tr.customer_id is not null then taxi_points_balance(tr.customer_id) end,
    'round_trip', tr.round_trip, 'waiting', tr.wait_started_at is not null, 'wait_sec', taxi_wait_total(tr),
    'pickup_waiting', tr.pickup_wait_started_at is not null, 'pickup_wait_sec', taxi_pickup_wait_total(tr),
    'wait_free_min', 0,
    'stars', (select stars from taxi_ratings r where r.trip_id = tr.id),
    'complained', exists(select 1 from taxi_complaints k where k.trip_id = tr.id),
    'dest_change', (select json_build_object('id',rc.id,'status',rc.status,'to',rc.to_name,'from',rc.from_name,
                      'seconds_left',greatest(0,60-extract(epoch from now()-rc.created_at)::int))
                    from taxi_route_changes rc where rc.trip_id = tr.id and (rc.status = 'awaiting_customer' or rc.decided_at > now() - interval '3 minutes')
                    order by rc.id desc limit 1));
end $function$;

create or replace function public.taxi_customer_me(p_token uuid) returns json language plpgsql security definer set search_path to 'public' as $function$
declare c taxi_customers := taxi_session_customer(p_token);
begin
  return json_build_object('name', c.name, 'username', coalesce(c.username, c.phone), 'building', c.building, 'floor', c.floor, 'apartment', c.apartment,
    'points', taxi_points_json(c.id),
    'open', (select request_token from taxi_trips where customer_id=c.id and status in ('requested','assigned','accepted','started','rejected')
             order by id desc limit 1),
    'unrated', (select json_build_object('id', t.id, 'zone', (select name from taxi_zones z where z.id=t.zone_id), 'driver_name', cr.driver_name, 'ended_at', t.ended_at)
                from taxi_trips t left join taxi_cars cr on cr.id = t.car_id
                where t.customer_id=c.id and t.status='done' and t.ended_at > now() - interval '2 days'
                  and not exists(select 1 from taxi_ratings r where r.trip_id=t.id)
                order by t.id desc limit 1),
    'trips', coalesce((select json_agg(x order by x.created_at desc) from (
        select t.id, t.request_token as token, t.status, t.created_at, t.ended_at, t.pickup, (select name from taxi_zones z where z.id=t.zone_id) as zone,
               t.points_used > 0 as free,
               (select delta from taxi_points p where p.trip_id=t.id and p.reason='trip') as earned,
               (select stars from taxi_ratings r where r.trip_id=t.id) as stars
        from taxi_trips t where t.customer_id=c.id order by t.id desc limit 20) x), '[]'::json));
end $function$;

-- driver sees his own average stars (not the comments, not who rated)
create or replace function public.taxi_driver_state(p_code text) returns json language plpgsql security definer set search_path to 'public' as $function$
declare c taxi_cars; open_trip taxi_trips; ws date := taxi_week_start((now() at time zone 'Asia/Baghdad')::date);
        wn int; wf int;
begin
  perform taxi_resolve_route_changes();
  select * into c from taxi_cars where driver_code=trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  select * into open_trip from taxi_trips where car_id=c.id and status in ('assigned','accepted','started') order by id desc limit 1;
  select count(*), coalesce(sum(fare),0) into wn, wf from taxi_trips
    where car_id=c.id and status='done' and ended_at >= ws::timestamp at time zone 'Asia/Baghdad';
  return json_build_object(
    'trip', case when open_trip.id is null then null else taxi_trip_json(open_trip) end,
    'cancelled', case when open_trip.id is null then taxi_driver_cancelled(c.id) end,
    'today_trips', (select count(*) from taxi_trips where car_id=c.id and status='done' and ended_at >= date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad'),
    'today_fares', (select coalesce(sum(fare),0) from taxi_trips where car_id=c.id and status='done' and ended_at >= date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad'),
    'week_trips', wn, 'week_fares', wf, 'week_share', 0,
    'rating', (select json_build_object('avg', round(avg(stars)::numeric,1), 'count', count(*)) from taxi_ratings where car_id = c.id),
    'money', taxi_driver_money(c.id),
    'fare_base', taxi_setting_int('fare_base'),
    'gps_state', c.gps_state, 'last_seen', c.last_seen,
    'zones', (select coalesce(json_agg(json_build_object('id',z.id,'name',z.name,'price',taxi_zone_price(z)) order by z.sort, z.name),'[]'::json) from taxi_zones z where z.active));
end $function$;

-- ---------- daily report ----------
create or replace function public.taxi_admin_daily(p_pin text, p_day date default null) returns json language plpgsql security definer set search_path to 'public' as $function$
declare d date := coalesce(p_day, (now() at time zone 'Asia/Baghdad')::date);
        t0 timestamptz := d::timestamp at time zone 'Asia/Baghdad'; t1 timestamptz := (d + 1)::timestamp at time zone 'Asia/Baghdad';
begin
  perform taxi_chk(p_pin);
  return json_build_object('day', d,
    'totals', (select json_build_object(
        'requests', count(*) filter (where t.source='customer'),
        'done', count(*) filter (where t.status='done'),
        'cancelled', count(*) filter (where t.status='cancelled'),
        'rejected', count(*) filter (where t.status='rejected'),
        'fares', coalesce(sum(t.fare) filter (where t.status='done'),0),
        'cash', coalesce(sum(greatest(t.fare - t.points_used,0)) filter (where t.status='done'),0),
        'points', coalesce(sum(t.points_used) filter (where t.status='done'),0),
        'wait_fees', coalesce(sum(t.wait_fee) filter (where t.status='done'),0),
        'round_fees', coalesce(sum(t.round_fee) filter (where t.status='done'),0),
        'round_trips', count(*) filter (where t.status='done' and t.round_trip),
        'km', round(coalesce(sum(t.km) filter (where t.status='done'),0)::numeric,1),
        'avg_pickup_min', round((avg(extract(epoch from t.started_at - t.accepted_at)/60) filter (where t.source='customer' and t.started_at is not null and t.accepted_at is not null))::numeric,1),
        'pickup_wait_min', round(coalesce(sum(t.pickup_wait_sec),0)/60.0),
        'dest_changes', coalesce(sum(t.dest_changes) filter (where t.status='done'),0))
      from taxi_trips t where coalesce(t.ended_at, t.created_at) >= t0 and coalesce(t.ended_at, t.created_at) < t1),
    'received', (select coalesce(sum(amount),0) from taxi_cash where at >= t0 and at < t1),
    'new_customers', (select count(*) from taxi_customers where created_at >= t0 and created_at < t1),
    'ratings', (select json_build_object('avg', round(avg(stars)::numeric,1), 'count', count(*), 'low', count(*) filter (where stars<=2)) from taxi_ratings where created_at >= t0 and created_at < t1),
    'complaints', (select json_build_object('new', count(*) filter (where created_at >= t0 and created_at < t1), 'open', count(*) filter (where status='open')) from taxi_complaints),
    'alerts', (select json_build_object('lost', count(*) filter (where kind='lost'), 'off', count(*) filter (where kind in ('off','denied','closed')),
                 'unlogged', count(*) filter (where kind='unlogged'), 'rejected', count(*) filter (where kind='rejected'))
               from taxi_events where at >= t0 and at < t1),
    'hours', coalesce((select json_agg(json_build_object('h', h, 'n', n) order by h) from (
        select extract(hour from t.created_at at time zone 'Asia/Baghdad')::int h, count(*) n
        from taxi_trips t where t.created_at >= t0 and t.created_at < t1 and t.status <> 'rejected' group by 1) x), '[]'::json),
    'zones', coalesce((select json_agg(x order by x.n desc) from (
        select z.name, count(*) n from taxi_trips t join taxi_zones z on z.id = t.zone_id
        where t.status='done' and t.ended_at >= t0 and t.ended_at < t1 group by z.name order by 2 desc limit 8) x), '[]'::json),
    'drivers', coalesce((select json_agg(x order by x.done desc, x.driver_name) from (
        select c.id, c.plate, c.driver_name,
          count(t.*) filter (where t.status='done') as done,
          coalesce(sum(t.fare) filter (where t.status='done'),0) as fares,
          coalesce(sum(greatest(t.fare - t.points_used,0)) filter (where t.status='done'),0) as cash,
          round(coalesce(sum(t.km) filter (where t.status='done'),0)::numeric,1) as km,
          (select count(*) from taxi_events e where e.car_id=c.id and e.kind='rejected' and e.at >= t0 and e.at < t1) as rejected,
          (select count(*) from taxi_events e where e.car_id=c.id and e.kind='lost' and e.at >= t0 and e.at < t1) as lost,
          (select round(avg(stars)::numeric,1) from taxi_ratings r where r.car_id=c.id and r.created_at >= t0 and r.created_at < t1) as stars,
          (select coalesce(sum(amount),0) from taxi_cash k where k.car_id=c.id and k.at >= t0 and k.at < t1) as received,
          (select json_build_object('first', min(e.at), 'last', max(e.at)) from taxi_events e where e.car_id=c.id and e.at >= t0 and e.at < t1) as span
        from taxi_cars c left join taxi_trips t on t.car_id=c.id and t.ended_at >= t0 and t.ended_at < t1
        where c.active group by c.id) x), '[]'::json));
end $function$;

grant execute on function public.taxi_customer_rate(uuid,bigint,integer,text), public.taxi_customer_complain(uuid,bigint,text),
  public.taxi_admin_feedback(text), public.taxi_admin_complaint_close(text,bigint,text), public.taxi_admin_daily(text,date) to anon, authenticated;
