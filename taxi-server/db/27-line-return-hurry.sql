-- 27: "خط" trips, returning to the compound, "مستعجل؟" question, fare typo guard.
--  * base: settings base_name/base_lat/base_lng = مجمع المنصور (taken from where the cars park most).
--  * taxi_driver_trip 'line' {zone_id | dropoff}: the driver goes to deliver a line; trip_kind='line', from the compound,
--    round trip (مرجع) back to مجمع المنصور. Priced like any trip (zone price + المرجع, or the amount he types).
--  * After every finished trip the car is "returning" (taxi_cars.returning_since): its drive back is not flagged as
--    "بدون سفرة"; the office sees the estimated minutes to the compound. At the compound the driver presses
--    'ready' (جاهز للكراوي, must be within 1.5 km of the compound). Returning longer than 90 min -> event return_long.
--  * taxi_admin_hurry(pin, trip, eta_min): asks a waiting customer "مستعجل؟" (push + card);
--    taxi_customer_hurry(token, wait): wait -> stays; no -> request cancelled. Event hurry_answer for the office.
--  * Typed fare 1..100 means thousands (5 -> 5000); 101..499 is refused.

insert into public.taxi_settings(k,v) values ('base_name','مجمع المنصور'),('base_lat','33.3362'),('base_lng','44.3553') on conflict (k) do nothing;

alter table public.taxi_trips add column if not exists trip_kind text not null default 'normal' check (trip_kind in ('normal','line')),
  add column if not exists hurry_asked_at timestamptz, add column if not exists hurry_eta integer,
  add column if not exists hurry_answer text check (hurry_answer in ('wait','cancel')), add column if not exists hurry_answered_at timestamptz,
  add column if not exists hurry_by text;
alter table public.taxi_cars add column if not exists returning_since timestamptz, add column if not exists ready_at timestamptz;

create or replace function public.taxi_base() returns json language sql stable set search_path to 'public' as $$
  select json_build_object('name', coalesce((select v from taxi_settings where k='base_name'),'مجمع المنصور'),
    'lat', (select v::double precision from taxi_settings where k='base_lat'), 'lng', (select v::double precision from taxi_settings where k='base_lng'))
$$;

-- car state follows its trips: done -> returning; a new trip -> not returning
create or replace function public.taxi_car_return_trg() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.car_id is null then return new; end if;
  if new.status = 'done' and old.status is distinct from 'done' then
    update taxi_cars set returning_since = now(), ready_at = null where id = new.car_id
      and not exists(select 1 from taxi_trips o where o.car_id = new.car_id and o.id <> new.id and o.status in ('accepted','started'));
  elsif new.status in ('accepted','started') and old.status is distinct from new.status then
    update taxi_cars set returning_since = null, ready_at = null where id = new.car_id;
  end if;
  return new;
end $$;
drop trigger if exists taxi_car_return on public.taxi_trips;
create trigger taxi_car_return after update on public.taxi_trips for each row execute function public.taxi_car_return_trg();
create or replace function public.taxi_car_return_ins_trg() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.car_id is not null and new.status in ('accepted','started') then
    update taxi_cars set returning_since = null, ready_at = null where id = new.car_id; end if;
  return new;
end $$;
drop trigger if exists taxi_car_return_ins on public.taxi_trips;
create trigger taxi_car_return_ins after insert on public.taxi_trips for each row execute function public.taxi_car_return_ins_trg();

create or replace function public.taxi_admin_hurry(p_pin text, p_id bigint, p_eta integer default null)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare who text; tr taxi_trips;
begin
  perform taxi_chk(p_pin);
  who := coalesce(taxi_admin_who(p_pin)->>'name','المدير');
  update taxi_trips set hurry_asked_at = now(), hurry_eta = case when p_eta between 1 and 300 then p_eta end,
         hurry_answer = null, hurry_answered_at = null, hurry_by = who
   where id = p_id and customer_id is not null and status in ('requested','rejected','assigned')
  returning * into tr;
  if tr.id is null then raise exception 'الطلب انحسم أو مو من زبون'; end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.taxi_customer_hurry(p_token uuid, p_wait boolean)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare tr taxi_trips;
begin
  select * into tr from taxi_trips where request_token = p_token for update;
  if tr.id is null then raise exception 'الطلب غير موجود'; end if;
  if tr.hurry_asked_at is null or tr.hurry_answer is not null then raise exception 'ماكو سؤال ينتظر جوابك'; end if;
  if p_wait then
    update taxi_trips set hurry_answer = 'wait', hurry_answered_at = now() where id = tr.id;
    insert into taxi_events(car_id,kind,info) values (null,'hurry_answer', coalesce(tr.customer_name,'زبون') || ': ينتظر ← ' || coalesce(tr.dropoff,''));
  else
    if tr.status not in ('requested','rejected','assigned') then raise exception 'السائق قبل طلبك، إذا تريد ألغِه من زر الإلغاء'; end if;
    update taxi_trips set hurry_answer = 'cancel', hurry_answered_at = now(), status = 'cancelled', ended_at = now(),
      cancel_reason = 'ألغاه الزبون' where id = tr.id;
    insert into taxi_events(car_id,kind,info) values (tr.car_id,'hurry_answer', coalesce(tr.customer_name,'زبون') || ': مستعجل، ألغى الطلب');
  end if;
  return json_build_object('ok', true);
end $$;

grant execute on function public.taxi_admin_hurry(text,bigint,integer), public.taxi_customer_hurry(uuid,boolean), public.taxi_base() to anon, authenticated;

create or replace function public.taxi_mark_returns() returns void language plpgsql security definer set search_path to 'public' as $$
declare r record;
begin
  for r in update taxi_cars set returning_since = null where returning_since < now() - interval '90 minutes' returning id loop
    insert into taxi_events(car_id,kind,info) values (r.id,'return_long','طوّل بالرجعة للمجمع أكثر من ساعة ونص');
  end loop;
end $$;
revoke execute on function public.taxi_mark_returns() from anon, authenticated, public;

-- in-place patches (see the migration taxi_line_return_hurry)
do $$ declare d text; b0 text; begin
  -- driver: 'line' and 'ready' actions, fare typo guard
  d := pg_get_functiondef('public.taxi_driver_trip(text,text,jsonb)'::regprocedure); b0 := d;
  d := replace(d, $r$  elsif p_action = 'start' then$r$, $r$  elsif p_action = 'line' then
    if c.gps_state not in ('ok','background','parked') then raise exception 'شغّل التتبع أولًا'; end if;
    if tr.id is not null then raise exception 'عندك سفرة مفتوحة، خلّصها أولًا'; end if;
    select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
    if z.id is null and length(trim(coalesce(p->>'dropoff',''))) < 2 then raise exception 'اكتب اسم المنطقة اللي رايح إلها'; end if;
    insert into taxi_trips(car_id,source,status,pickup,dropoff,zone_id,fare,accepted_at,started_at,round_trip,trip_kind,note)
    values (c.id,'driver','started',taxi_base()->>'name',
            coalesce(z.name, left(trim(p->>'dropoff'),120)), z.id,
            case when z.id is null then null else taxi_zone_price(z) end, now(), now(), true, 'line',
            'خط: رايح ' || coalesce(z.name, left(trim(p->>'dropoff'),120)) || ' والمرجع ' || (taxi_base()->>'name'))
    returning * into tr;
    update taxi_cars set moving_since=null, unlogged_flagged=false where id=c.id;
    insert into taxi_events(car_id,kind,info) values (c.id,'line', tr.dropoff);
  elsif p_action = 'ready' then
    if tr.id is not null then raise exception 'عندك سفرة مفتوحة'; end if;
    if c.last_lat is not null and (taxi_base()->>'lat') is not null
       and taxi_dist(c.last_lat, c.last_lng, (taxi_base()->>'lat')::float8, (taxi_base()->>'lng')::float8) > 1500 then
      raise exception 'إنت بعيد عن %، دوس الزر من توصل', taxi_base()->>'name'; end if;
    update taxi_cars set returning_since = null, ready_at = now(), moving_since = null, unlogged_flagged = false where id = c.id;
    insert into taxi_events(car_id,kind) values (c.id,'ready');
    return json_build_object('ready', true);
  elsif p_action = 'start' then$r$);
  d := replace(d, $r$      if base is null or base <= 0 then raise exception 'اكتب مبلغ الأجرة'; end if;$r$,
                  $r$      if base is null or base <= 0 then raise exception 'اكتب مبلغ الأجرة'; end if;
      if base <= 100 then base := base * 1000;  -- "5" means 5000
      elsif base < 500 then raise exception 'المبلغ قليل، اكتبه كامل (مثلًا 5000)'; end if;$r$);
  if position($r$p_action = 'line'$r$ in d) = 0 or position('base * 1000' in d) = 0 then raise exception 'driver_trip patch'; end if;
  execute d;

  -- ping: the drive back to the compound is not "بدون سفرة"
  d := pg_get_functiondef('public.taxi_ping_v2(text,double precision,double precision,double precision,double precision,double precision,integer)'::regprocedure);
  d := replace(d, $r$legit := open_trip.id is not null and open_trip.status in ('accepted','started');$r$,
                  $r$legit := (open_trip.id is not null and open_trip.status in ('accepted','started'))
           or (c.returning_since is not null and c.returning_since > now() - interval '90 minutes');$r$);
  if position('returning_since' in d) = 0 then raise exception 'ping patch'; end if;
  execute d;

  -- trip json / admin trips / customer status / driver state / admin me
  d := pg_get_functiondef('public.taxi_trip_json(taxi_trips)'::regprocedure);
  d := replace(d, '''special_status'',t.special_status,', '''special_status'',t.special_status,''trip_kind'',t.trip_kind,');
  if position('trip_kind' in d) = 0 then raise exception 'trip_json patch'; end if; execute d;

  d := pg_get_functiondef('public.taxi_admin_trips(text,date)'::regprocedure);
  d := replace(d, 't.sched_car, c.plate', 't.sched_car, t.trip_kind, t.hurry_asked_at, t.hurry_eta, t.hurry_answer, t.hurry_answered_at, c.plate');
  if position('hurry_answer' in d) = 0 then raise exception 'admin_trips patch'; end if; execute d;

  d := pg_get_functiondef('public.taxi_customer_status(uuid)'::regprocedure);
  d := replace(d, $r$'stars', (select$r$, $r$'hurry', tr.hurry_asked_at is not null and tr.hurry_answer is null and tr.status in ('requested','rejected','assigned'),
    'hurry_eta', tr.hurry_eta, 'hurry_answer', tr.hurry_answer,
    'stars', (select$r$);
  if position('hurry_eta' in d) = 0 then raise exception 'customer_status patch'; end if; execute d;

  d := pg_get_functiondef('public.taxi_driver_state(text)'::regprocedure);
  d := replace(d, $r$'money', taxi_driver_money(c.id),$r$, $r$'returning_since', c.returning_since, 'ready_at', c.ready_at, 'base', taxi_base(),
    'last_lat', c.last_lat, 'last_lng', c.last_lng,
    'money', taxi_driver_money(c.id),$r$);
  if position('returning_since' in d) = 0 then raise exception 'driver_state patch'; end if; execute d;

  d := pg_get_functiondef('public.taxi_admin_me(text)'::regprocedure);
  d := replace(d, $r$'perms', coalesce(w->>'perms','full'));$r$, $r$'perms', coalesce(w->>'perms','full'), 'base', taxi_base());$r$);
  if position('taxi_base' in d) = 0 then raise exception 'admin_me patch'; end if; execute d;

  -- push: ask the customer
  d := pg_get_functiondef('public.taxi_push_trg()'::regprocedure);
  d := replace(d, $r$    elsif new.status = 'done' and old.status is distinct from 'done' then
      t := '✅ وصلت بالسلامة';$r$, $r$    elsif new.hurry_asked_at is not null and new.hurry_asked_at is distinct from old.hurry_asked_at then
      t := '⏳ إنت مستعجل؟'; b := 'السيارات كلها طالعة' || coalesce('، أقرب سيارة بعد ~' || new.hurry_eta || ' دقيقة', '') || '. افتح التطبيق وكلّنا تنتظر لو تلغي.';
    elsif new.status = 'done' and old.status is distinct from 'done' then
      t := '✅ وصلت بالسلامة';$r$);
  if position('hurry_asked_at' in d) = 0 then raise exception 'push patch'; end if; execute d;
end $$;

-- the minute job also expires long returns
create or replace function public.taxi_mark_lost() returns void language plpgsql security definer set search_path to 'public' as $function$
declare r record;
begin
  update taxi_cars c set gps_state = 'parked'
   where active and gps_state in ('ok','background') and last_seen < now() - interval '4 minutes'
     and coalesce(last_speed,0) < 1
     and not exists(select 1 from taxi_trips t where t.car_id = c.id and t.status = 'started');
  for r in update taxi_cars c set gps_state = 'lost'
           where active and ((gps_state in ('ok','background') and last_seen < now() - interval '4 minutes')
                          or (gps_state = 'parked' and last_seen < now() - interval '45 minutes'))
           returning id loop
    insert into taxi_events(car_id,kind) values (r.id,'lost');
  end loop;
  perform taxi_mark_returns();
end $function$;
