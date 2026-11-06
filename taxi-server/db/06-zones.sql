-- Fixed prices per destination area, and customer orders from the public page.
-- Customers only ever see area names; the price is attached to the trip automatically
-- and the driver cannot change it.

create table if not exists public.taxi_zones (
  id serial primary key,
  name text not null,
  price int not null check (price > 0),
  rush_price int check (rush_price > 0),
  rush_on boolean not null default false,
  sort int not null default 100,
  active boolean not null default true
);

alter table public.taxi_trips
  add column if not exists zone_id int references public.taxi_zones(id),
  add column if not exists customer_name text not null default '',
  add column if not exists request_token uuid,
  add column if not exists pickup_lat double precision,
  add column if not exists pickup_lng double precision;
create unique index if not exists taxi_trips_token on public.taxi_trips(request_token) where request_token is not null;
create index if not exists taxi_trips_requested on public.taxi_trips(created_at) where status = 'requested';

alter table public.taxi_events alter column car_id drop not null;
alter table public.taxi_events add column if not exists info text;

insert into public.taxi_zones(name, price, rush_price, sort)
select * from (values
  ('المنصور',5000,null::int,1),('الإسكان',5000,null,2),('علاوي',5000,null,3),('الزوراء',5000,null,4),
  ('الحارثية',6000,null,5),('العطيفية',6000,null,6),
  ('حي الجامعة',7000,null,7),('حي العدل',7000,null,8),
  ('حي الجهاد',8000,10000,9),('الأعظمية',8000,null,10),('الغزالية',8000,null,11),('الحرية',8000,null,12),
  ('حي الخضراء',8000,null,13),('العامرية',8000,null,14),('حي العامل',8000,null,15),
  ('الكرادة',10000,null,16),('الدورة',10000,null,17),('البياع',10000,null,18),('حي الإعلام',10000,null,19),
  ('البنوك',10000,null,20),('حي أور',10000,null,21),('مدينة الصدر',10000,null,22),('الشعلة',10000,null,23),
  ('باب الشرجي وما حولها',10000,null,24),('حي الشعب',10000,null,25),('البلديات',10000,null,26),
  ('الطالبية',10000,null,27),('جميلة',10000,null,28),
  ('أبو غريب (خارج المدينة)',10000,null,29),('أبو غريب (داخل المدينة)',15000,null,30),
  ('المحمودية',20000,null,31),('الحسينية',20000,null,32),
  ('مطار بغداد (ذهاب)',25000,null,33),('من مطار بغداد (رجوع)',35000,null,34)
) v(name,price,rush,sort)
where not exists (select 1 from public.taxi_zones);

create or replace function public.taxi_zone_price(z public.taxi_zones) returns int language sql stable as $$
  select case when z.rush_on and z.rush_price is not null then z.rush_price else z.price end;
$$;

-- the customer's phone stays with the office: drivers never get it (no side deals)
create or replace function public.taxi_trip_json(t taxi_trips) returns json language sql stable as $$
  select json_build_object('id',t.id,'status',t.status,'source',t.source,'pickup',t.pickup,'dropoff',t.dropoff,
    'customer_name',t.customer_name,'note',t.note,'fare',t.fare,'km',t.km,'created_at',t.created_at,
    'accepted_at',t.accepted_at,'started_at',t.started_at,'ended_at',t.ended_at,
    'zone_id',t.zone_id,'zone',(select name from taxi_zones z where z.id=t.zone_id),
    'pickup_lat',t.pickup_lat,'pickup_lng',t.pickup_lng);
$$;

-- ---------- Public (customer) ----------
create or replace function public.taxi_public_zones() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('id',id,'name',name) order by sort, name), '[]'::json) from taxi_zones where active;
$$;

create or replace function public.taxi_customer_request(p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p->>'phone',''),'\D','','g'); z taxi_zones; tr taxi_trips; lat double precision; lng double precision;
begin
  if length(ph) < 10 or length(ph) > 13 then raise exception 'اكتب رقم هاتف صحيح'; end if;
  if coalesce(trim(p->>'pickup'),'') = '' and p->>'lat' is null then raise exception 'اكتب وين إنت (العمارة أو البوابة)'; end if;
  select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
  if z.id is null then raise exception 'اختار المنطقة اللي رايح إلها'; end if;
  if (select count(*) from taxi_trips where customer_phone=ph and status in ('requested','assigned','accepted','started')) >= 2 then
    raise exception 'عندك طلب مفتوح، انتظر السائق أو ألغِه أولًا'; end if;
  if (select count(*) from taxi_trips where status='requested' and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'الطلبات كثيرة هسه، خابرنا على رقم الحجز'; end if;
  lat := nullif(p->>'lat','')::double precision; lng := nullif(p->>'lng','')::double precision;
  if lat is not null and (lat not between -90 and 90 or lng not between -180 and 180) then lat := null; lng := null; end if;
  insert into taxi_trips(car_id,source,status,customer_phone,customer_name,pickup,dropoff,note,zone_id,fare,request_token,pickup_lat,pickup_lng)
  values (null,'customer','requested',ph,left(coalesce(trim(p->>'name'),''),60),left(coalesce(trim(p->>'pickup'),''),120),z.name,
          left(coalesce(p->>'note',''),200),z.id,taxi_zone_price(z),gen_random_uuid(),lat,lng)
  returning * into tr;
  insert into taxi_events(car_id,kind,info) values (null,'request', coalesce(nullif(tr.pickup,''),'موقع على الخريطة') || ' ← ' || z.name);
  return json_build_object('token', tr.request_token);
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
    'car_lat', case when tr.status='accepted' then c.last_lat end, 'car_lng', case when tr.status='accepted' then c.last_lng end);
end $$;

create or replace function public.taxi_customer_cancel(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
declare tr taxi_trips;
begin
  select * into tr from taxi_trips where request_token = p_token;
  if tr.id is null then raise exception 'الطلب غير موجود'; end if;
  if tr.status not in ('requested','assigned','accepted') then raise exception 'ما ينفع تلغي هسه'; end if;
  update taxi_trips set status='cancelled', ended_at=now(), cancel_reason='ألغاه الزبون' where id=tr.id;
end $$;

-- ---------- Admin: zones ----------
create or replace function public.taxi_admin_zones(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(json_build_object('id',z.id,'name',z.name,'price',z.price,'rush_price',z.rush_price,'rush_on',z.rush_on,
            'current',taxi_zone_price(z),'sort',z.sort) order by z.sort, z.name) from taxi_zones z where z.active), '[]'::json);
end $$;

create or replace function public.taxi_admin_zone_save(p_pin text, p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare pr int := nullif(regexp_replace(coalesce(p->>'price',''),'\D','','g'),'')::int;
        rp int := nullif(regexp_replace(coalesce(p->>'rush_price',''),'\D','','g'),'')::int;
begin
  perform taxi_chk(p_pin);
  if p->>'action' = 'delete' then update taxi_zones set active=false where id=(p->>'id')::int; return; end if;
  if p->>'action' = 'rush' then update taxi_zones set rush_on=coalesce((p->>'on')::boolean,false) where id=(p->>'id')::int; return; end if;
  if coalesce(trim(p->>'name'),'') = '' then raise exception 'اكتب اسم المنطقة'; end if;
  if pr is null or pr <= 0 then raise exception 'اكتب السعر'; end if;
  if (p->>'id') is null then
    insert into taxi_zones(name,price,rush_price,sort) values (trim(p->>'name'),pr,rp,coalesce((select max(sort)+1 from taxi_zones),1));
  else
    update taxi_zones set name=trim(p->>'name'), price=pr, rush_price=rp, rush_on = rush_on and rp is not null where id=(p->>'id')::int;
  end if;
end $$;

-- office booking now takes a zone; the fixed price goes on the trip
create or replace function public.taxi_admin_trip_create(p_pin text, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare tr taxi_trips; car uuid; z taxi_zones;
begin
  perform taxi_chk(p_pin);
  car := nullif(p->>'car_id','')::uuid;
  if car is null then raise exception 'اختر السائق'; end if;
  if exists (select 1 from taxi_trips where car_id=car and status in ('assigned','accepted','started')) then
    raise exception 'هذا السائق عنده سفرة مفتوحة'; end if;
  select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
  insert into taxi_trips(car_id,source,status,customer_phone,customer_name,pickup,dropoff,note,zone_id,fare)
  values (car,'office','assigned',
          left(coalesce(p->>'customer_phone',''),30),left(coalesce(p->>'customer_name',''),60),left(coalesce(p->>'pickup',''),120),
          coalesce(z.name, left(coalesce(p->>'dropoff',''),120)),left(coalesce(p->>'note',''),200),z.id,
          case when z.id is null then null else taxi_zone_price(z) end)
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
    if tr.status not in ('requested','assigned','accepted','started') then raise exception 'السفرة منتهية'; end if;
    update taxi_trips set status='cancelled', ended_at=now(), cancel_reason='ألغاها المكتب' where id=p_id;
  elsif p_action = 'reassign' then
    if p_car is null then raise exception 'اختر السائق'; end if;
    if exists (select 1 from taxi_trips where car_id=p_car and status in ('assigned','accepted','started') and id<>p_id) then
      raise exception 'هذا السائق عنده سفرة مفتوحة'; end if;
    if tr.status in ('requested','assigned','rejected') then
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
    select t.id, t.car_id, t.source, t.status, t.customer_phone, t.customer_name, t.pickup, t.dropoff, t.note, t.fare, t.km,
           t.created_at, t.accepted_at, t.started_at, t.ended_at, t.cancel_reason, t.zone_id, t.pickup_lat, t.pickup_lng,
           c.plate, c.driver_name
    from taxi_trips t left join taxi_cars c on c.id=t.car_id
    where (t.created_at at time zone 'Asia/Baghdad')::date = d
       or (t.status in ('requested','assigned','accepted','started'))) x), '[]'::json);
end $$;

-- ---------- Driver: fixed price follows the zone ----------
create or replace function public.taxi_driver_trip(p_code text, p_action text, p jsonb default '{}'::jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_cars; tr taxi_trips; f int; z taxi_zones;
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
      select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
      insert into taxi_trips(car_id,source,status,pickup,dropoff,zone_id,fare,accepted_at,started_at)
      values (c.id,'driver','started',left(coalesce(p->>'pickup',''),120),
              coalesce(z.name, left(coalesce(p->>'dropoff',''),120)), z.id,
              case when z.id is null then null else taxi_zone_price(z) end, now(), now())
      returning * into tr;
    end if;
    update taxi_cars set moving_since=null, unlogged_flagged=false where id=c.id;
  elsif p_action = 'end' then
    if tr.status is distinct from 'started' then raise exception 'ماكو سفرة شغّالة'; end if;
    if tr.zone_id is not null and tr.fare is not null then
      f := tr.fare;                                  -- fixed area price: the driver cannot change it
    else
      f := nullif(regexp_replace(coalesce(p->>'fare',''),'\D','','g'),'')::int;
      if f is null or f <= 0 then raise exception 'اكتب مبلغ الأجرة'; end if;
      if f > 1000000 then raise exception 'المبلغ كبير، تأكد منه'; end if;
    end if;
    update taxi_trips set status='done', ended_at=now(), fare=f,
      dropoff = case when coalesce(p->>'dropoff','')<>'' and zone_id is null then left(p->>'dropoff',120) else dropoff end,
      km = (select round((coalesce(sum(m.km),0))::numeric,2) from taxi_moves(c.id, coalesce(tr.accepted_at,tr.started_at), now()+interval '1 second') m)
    where id=tr.id returning * into tr;
  else
    raise exception 'إجراء غير معروف';
  end if;
  return taxi_trip_json(tr);
end $$;

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
    'gps_state', c.gps_state, 'last_seen', c.last_seen,
    'zones', (select coalesce(json_agg(json_build_object('id',z.id,'name',z.name,'price',taxi_zone_price(z)) order by z.sort, z.name),'[]'::json) from taxi_zones z where z.active));
end $$;

-- ---------- Alerts/log: customer requests have no car ----------
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
       select e.id, e.kind, e.at, coalesce(c.plate, e.info, '') as plate, coalesce(c.driver_name, 'طلب زبون') as driver_name,
              coalesce(c.driver_phone, '') as driver_phone
       from taxi_events e left join taxi_cars c on c.id=e.car_id
       where e.id > p_after order by e.id limit 50) x), '[]'::json));
end $$;

create or replace function public.taxi_admin_events(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x) from (
    select e.kind, e.at, coalesce(c.plate, '') as plate, coalesce(c.driver_name, 'طلب زبون: ' || coalesce(e.info,'')) as driver_name
    from taxi_events e left join taxi_cars c on c.id=e.car_id
    order by e.at desc limit 60) x), '[]'::json);
end $$;
