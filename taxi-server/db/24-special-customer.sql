-- 24: "زبون خاص" (special customer): a ride the company gives for free.
-- The driver presses زبون خاص and writes who exactly it is. The trip waits for the office:
--   special_status 'pending'  -> the driver can't start or end it yet
--   'approved'                -> the trip runs normally and ends with fare 0 (no waiting/round fees, no points earned)
--   'rejected'                -> a normal paid trip
-- A special trip made from the empty card is created as 'accepted' (the customer is at the car).

alter table public.taxi_trips add column if not exists special_status text check (special_status in ('pending','approved','rejected')),
  add column if not exists special_note text, add column if not exists special_by text,
  add column if not exists special_at timestamptz, add column if not exists special_reason text;

create or replace function public.taxi_driver_trip(p_code text, p_action text, p jsonb default '{}'::jsonb)
 returns json language plpgsql security definer set search_path to 'public' as $function$
declare c taxi_cars; tr taxi_trips; z taxi_zones; base int; ws int; nt text; free boolean;
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
  elsif p_action = 'special' then
    nt := left(trim(coalesce(p->>'note','')), 200);
    if length(nt) < 3 then raise exception 'اكتب منو الزبون بالضبط'; end if;
    if tr.status = 'assigned' then raise exception 'اقبل سفرة المكتب أولًا'; end if;
    if tr.special_status in ('pending','approved') then raise exception 'السفرة مسجّلة زبون خاص'; end if;
    if tr.id is null then
      select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
      insert into taxi_trips(car_id,source,status,pickup,dropoff,zone_id,fare,accepted_at,special_status,special_note,special_at)
      values (c.id,'driver','accepted',left(coalesce(p->>'pickup',''),120),
              coalesce(z.name, left(coalesce(p->>'dropoff',''),120)), z.id,
              case when z.id is null then null else taxi_zone_price(z) end, now(), 'pending', nt, now())
      returning * into tr;
    else
      update taxi_trips set special_status='pending', special_note=nt, special_at=now(), special_by=null, special_reason=null
      where id=tr.id returning * into tr;
    end if;
    insert into taxi_events(car_id,kind,info) values (c.id,'special', nt);
  elsif p_action = 'start' then
    if c.gps_state not in ('ok','background') then raise exception 'شغّل التتبع أولًا'; end if;
    if tr.status = 'started' then raise exception 'عندك سفرة شغّالة'; end if;
    if tr.status = 'assigned' then raise exception 'اقبل سفرة المكتب أولًا'; end if;
    if tr.special_status = 'pending' then raise exception 'انتظر موافقة الإدارة على الزبون الخاص'; end if;
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
    if tr.special_status = 'pending' then raise exception 'انتظر موافقة الإدارة على الزبون الخاص'; end if;
    free := tr.special_status = 'approved';
    if free then base := 0;
    elsif tr.zone_id is not null and tr.fare is not null then
      base := coalesce(tr.base_fare, tr.fare);
    else
      base := nullif(regexp_replace(coalesce(p->>'fare',''),'\D','','g'),'')::int;
      if base is null or base <= 0 then raise exception 'اكتب مبلغ الأجرة'; end if;
      if base > 1000000 then raise exception 'المبلغ كبير، تأكد منه'; end if;
    end if;
    ws := taxi_wait_total(tr);
    update taxi_trips set status='done', ended_at=now(),
      wait_sec = ws, wait_started_at = null, base_fare = base,
      round_fee = case when round_trip and not free then taxi_round_fee(base) else 0 end,
      wait_fee = case when free then 0 else taxi_wait_fee(ws) end,
      fare = case when free then 0 else base + (case when round_trip then taxi_round_fee(base) else 0 end) + taxi_wait_fee(ws) end,
      dropoff = case when coalesce(p->>'dropoff','')<>'' and zone_id is null then left(p->>'dropoff',120) else dropoff end,
      km = (select round((coalesce(sum(m.km),0))::numeric,2) from taxi_moves(c.id, coalesce(tr.accepted_at,tr.started_at), now()+interval '1 second') m)
    where id=tr.id returning * into tr;
  else
    raise exception 'إجراء غير معروف';
  end if;
  return taxi_trip_json(tr);
end $function$;

-- the office approves or refuses a special customer
create or replace function public.taxi_admin_special(p_pin text, p_id bigint, p_ok boolean, p_reason text default '')
 returns json language plpgsql security definer set search_path to 'public' as $$
declare who text; tr taxi_trips;
begin
  perform taxi_chk(p_pin);
  who := coalesce((taxi_admin_who(p_pin))->>'name','المدير');
  update taxi_trips set special_status = case when p_ok then 'approved' else 'rejected' end, special_by = who,
         special_reason = left(trim(coalesce(p_reason,'')),200)
   where id = p_id and special_status = 'pending' and status in ('accepted','started')
  returning * into tr;
  if tr.id is null then raise exception 'الطلب انحسم أو السفرة خلصت'; end if;
  return json_build_object('ok', true, 'status', tr.special_status);
end $$;

-- free (approved special) rides earn no points; points used on them come back via the existing refund rule
create or replace function public.taxi_trip_points_trg() returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare earn int := coalesce(taxi_setting_int('points_per_trip'),0); over int;
begin
  if new.customer_id is null then return new; end if;
  if new.status = 'done' and old.status is distinct from 'done' then
    if new.points_used > coalesce(new.fare,0) then
      over := new.points_used - coalesce(new.fare,0);
      insert into taxi_points(customer_id,delta,reason,trip_id,note) values (new.customer_id, over, 'refund', new.id, 'الباقي من الكروة المجانية');
      update taxi_trips set points_used = coalesce(new.fare,0) where id = new.id;
    end if;
    if earn > 0 and new.points_used = 0 and new.special_status is distinct from 'approved' then
      insert into taxi_points(customer_id,delta,reason,trip_id) values (new.customer_id, earn, 'trip', new.id) on conflict do nothing;
    end if;
  elsif new.status = 'cancelled' and old.status is distinct from 'cancelled' and new.points_used > 0 then
    insert into taxi_points(customer_id,delta,reason,trip_id,note) values (new.customer_id, new.points_used, 'refund', new.id, 'رجعت النقاط لأن الطلب انلغى');
    update taxi_trips set points_used = 0 where id = new.id;
  end if;
  return new;
end $function$;

grant execute on function public.taxi_admin_special(text,bigint,boolean,text) to anon, authenticated;

-- Also applied (migration taxi_special_customer): taxi_trip_json, taxi_admin_trips and taxi_admin_daily were patched in place
-- to return special_status / special_note / special_by / special_reason (and 'special' = free rides done in the daily totals).
