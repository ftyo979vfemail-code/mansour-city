-- 25: no-show close, manager permissions, scheduled bookings, quieter "lost" alarm.
--  * No-show: while waiting at pickup the driver presses تسكير and writes a note. The office sees the note
--    and the waiting time and approves (trip cancelled, reason "الزبون ما نزل") or refuses with a reason.
--    If the customer comes meanwhile, انطلاق clears the pending request.
--  * taxi_admins.perms: 'full' (everything) or 'drivers' (cars/drivers, map, trips, alerts — no money,
--    no prices, no settings, no deleting). taxi_chk_full(pin) guards every money/settings function.
--  * Scheduled booking: the customer picks a time 30 min – 7 days ahead -> status 'scheduled'.
--    The office confirms it and may reserve a driver; 20 min before the time it becomes a live request
--    (assigned to the reserved driver if he is free, otherwise 'requested').
--  * taxi_mark_lost: a parked car (speed < 1 m/s, no running trip) only counts as lost after 12 minutes of
--    silence (iPhones stop sending while the car stands still); a moving one after 3 minutes.

alter table public.taxi_trips
  add column if not exists noshow_status text check (noshow_status in ('pending','approved','rejected')),
  add column if not exists noshow_note text, add column if not exists noshow_at timestamptz,
  add column if not exists noshow_reason text, add column if not exists noshow_by text,
  add column if not exists scheduled_at timestamptz, add column if not exists sched_confirmed_at timestamptz,
  add column if not exists sched_confirmed_by text, add column if not exists sched_car uuid references public.taxi_cars(id) on delete set null;
create index if not exists taxi_trips_scheduled on public.taxi_trips(scheduled_at) where status = 'scheduled';

alter table public.taxi_admins add column if not exists perms text not null default 'full' check (perms in ('full','drivers'));

create or replace function public.taxi_admin_who(p_pin text) returns json language plpgsql security definer set search_path to 'public','extensions' as $function$
declare h text; a taxi_admins;
begin
  select v into h from taxi_settings where k='admin_pin';
  if h is not null and crypt(coalesce(p_pin,''), h) = h then return json_build_object('id',0,'name','المدير','perms','full'); end if;
  for a in select * from taxi_admins where active loop
    if crypt(coalesce(p_pin,''), a.pin_hash) = a.pin_hash then
      update taxi_admins set last_seen = now() where id = a.id and (last_seen is null or last_seen < now() - interval '1 minute');
      return json_build_object('id',a.id,'name',a.name,'perms',a.perms);
    end if;
  end loop;
  raise exception 'رمز المدير غير صحيح';
end $function$;

create or replace function public.taxi_chk_full(p_pin text) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(taxi_admin_who(p_pin)->>'perms','full') <> 'full' then
    raise exception 'ما عندك صلاحية على الحسابات والإعدادات، راجع المدير'; end if;
end $$;

create or replace function public.taxi_admin_me(p_pin text) returns json language plpgsql security definer set search_path to 'public' as $function$
declare w json := taxi_admin_who(p_pin);
begin
  return json_build_object('id', (w->>'id')::int, 'name', w->>'name', 'owner', (w->>'id')::int = 0, 'perms', coalesce(w->>'perms','full'));
end $function$;

-- (applied with a DO block) every money / settings function gets "perform taxi_chk_full(p_pin);" right after begin:
--   taxi_admin_balances, _cash, _daily, _deposit_decide, _deposit_settle, _deposits, _driver_detail, _driver_file, _fares,
--   _points_adjust, _points_settings, _route_decide, _route_review, _settle, _settlement, _shares, _special, _statement,
--   _unpaid, _week, _zone_save, _delete, _customers, _customer_block, _dispatchers, _routes_export, _setpin, _admins, taxi_export

-- managers list shows perms; the owner sets them with action 'perms' {id, perms}
-- (taxi_admin_admins / taxi_admin_admin_save patched in place)

-- no-show decision
create or replace function public.taxi_admin_noshow(p_pin text, p_id bigint, p_ok boolean, p_reason text default '')
 returns json language plpgsql security definer set search_path to 'public' as $$
declare who text; tr taxi_trips; r text := left(trim(coalesce(p_reason,'')),200);
begin
  perform taxi_chk(p_pin);
  who := coalesce(taxi_admin_who(p_pin)->>'name','المدير');
  select * into tr from taxi_trips where id = p_id for update;
  if tr.id is null or tr.noshow_status is distinct from 'pending' or tr.status <> 'accepted' then
    raise exception 'الطلب انحسم أو السفرة بدت'; end if;
  if p_ok then
    update taxi_trips set noshow_status='approved', noshow_by=who, noshow_reason=r, status='cancelled', ended_at=now(),
      pickup_wait_sec = taxi_pickup_wait_total(tr), pickup_wait_started_at = null,
      cancel_reason = 'الزبون ما نزل: ' || coalesce(tr.noshow_note,'')
    where id = tr.id;
  else
    if length(r) < 2 then raise exception 'اكتب سبب الرفض'; end if;
    update taxi_trips set noshow_status='rejected', noshow_by=who, noshow_reason=r where id = tr.id;
  end if;
  return json_build_object('ok', true);
end $$;

-- scheduled bookings: list, confirm (+ reserve a driver), release before time
create or replace function public.taxi_admin_scheduled(p_pin text) returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x order by x.scheduled_at) from (
    select t.id, t.scheduled_at, t.customer_name, t.pickup, t.pickup_lat, t.pickup_lng, t.dropoff, t.dropoff_note, t.note, t.created_at,
           t.sched_confirmed_at, t.sched_confirmed_by, t.sched_car, c.plate as sched_plate, c.driver_name as sched_driver,
           t.points_used > 0 as free
    from taxi_trips t left join taxi_cars c on c.id = t.sched_car
    where t.status = 'scheduled') x), '[]'::json);
end $$;

create or replace function public.taxi_admin_sched_confirm(p_pin text, p_id bigint, p_car uuid default null)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare who text;
begin
  perform taxi_chk(p_pin);
  who := coalesce(taxi_admin_who(p_pin)->>'name','المدير');
  if p_car is not null and not exists(select 1 from taxi_cars where id=p_car and active) then raise exception 'السائق غير موجود'; end if;
  update taxi_trips set sched_confirmed_at = coalesce(sched_confirmed_at, now()), sched_confirmed_by = who, sched_car = p_car
   where id = p_id and status = 'scheduled';
  if not found then raise exception 'الحجز مو موجود أو صار طلب'; end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.taxi_release_scheduled() returns void language plpgsql security definer set search_path to 'public' as $$
declare r taxi_trips; busy boolean;
begin
  for r in select * from taxi_trips where status = 'scheduled' and scheduled_at <= now() + interval '20 minutes' for update skip locked loop
    busy := r.sched_car is null or exists(select 1 from taxi_trips o where o.car_id = r.sched_car and o.status in ('assigned','accepted','started'))
            or not exists(select 1 from taxi_cars c where c.id = r.sched_car and c.active);
    if busy then
      update taxi_trips set status='requested', created_at = now() where id = r.id;
      insert into taxi_events(car_id,kind,info) values (null,'scheduled_due', coalesce(r.customer_name,'زبون') || ': حجز الساعة ' || to_char(r.scheduled_at at time zone 'Asia/Baghdad','HH24:MI') || ' ← ' || coalesce(r.dropoff,''));
    else
      update taxi_trips set status='assigned', car_id = r.sched_car, created_at = now(), dispatched_by = coalesce(r.sched_confirmed_by,'حجز مسبق') where id = r.id;
      insert into taxi_events(car_id,kind,info) values (r.sched_car,'scheduled_due', coalesce(r.customer_name,'زبون') || ': حجز الساعة ' || to_char(r.scheduled_at at time zone 'Asia/Baghdad','HH24:MI') || ' انرسل للسائق');
    end if;
  end loop;
  -- bookings nobody picked up within 2 hours of their time are dropped
  update taxi_trips set status='cancelled', ended_at=now(), cancel_reason='انتهى وقت الحجز'
   where status='scheduled' and scheduled_at < now() - interval '2 hours';
end $$;

-- quieter lost alarm for parked phones
create or replace function public.taxi_mark_lost() returns void language plpgsql security definer set search_path to 'public' as $function$
declare r record;
begin
  for r in update taxi_cars c set gps_state='lost'
           where active and gps_state in ('ok','background')
             and last_seen < now() - case when coalesce(last_speed,0) < 1
                                           and not exists(select 1 from taxi_trips t where t.car_id=c.id and t.status='started')
                                          then interval '12 minutes' else interval '3 minutes' end
           returning id loop
    insert into taxi_events(car_id,kind) values (r.id,'lost');
  end loop;
end $function$;

-- customer order: optional scheduled_at (30 min – 7 days ahead, max 3 upcoming)
create or replace function public.taxi_customer_order(p_token uuid, p jsonb) returns json language plpgsql security definer set search_path to 'public' as $function$
declare c taxi_customers := taxi_session_customer(p_token); z taxi_zones; tr taxi_trips; lat double precision; lng double precision;
        dlat double precision; dlng double precision; sat timestamptz;
        th int := coalesce(taxi_setting_int('points_redeem'),5000); fare int; use int := 0;
begin
  if coalesce(trim(p->>'pickup'),'') = '' and p->>'lat' is null then raise exception 'اكتب وين إنت (العمارة أو البوابة)'; end if;
  select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
  if z.id is null then raise exception 'اختار المنطقة اللي رايح إلها'; end if;
  sat := nullif(p->>'scheduled_at','')::timestamptz;
  if sat is not null then
    if sat < now() + interval '25 minutes' then raise exception 'الحجز المسبق لازم بعد نص ساعة على الأقل، وإذا تريد هسه اطلب عادي'; end if;
    if sat > now() + interval '7 days' then raise exception 'تكدر تحجز لحد 7 أيام قدّام'; end if;
    if (select count(*) from taxi_trips where customer_id=c.id and status='scheduled') >= 3 then raise exception 'عندك 3 حجوزات، ألغِ وحدة أولًا'; end if;
  elsif exists (select 1 from taxi_trips where customer_id=c.id and status in ('requested','assigned','accepted','started')) then
    raise exception 'عندك طلب مفتوح، انتظر السائق أو ألغِه أولًا'; end if;
  if (select count(*) from taxi_trips where status in ('requested','scheduled') and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'الطلبات كثيرة هسه، حاول بعد دقائق'; end if;
  lat := nullif(p->>'lat','')::double precision; lng := nullif(p->>'lng','')::double precision;
  if lat is not null and (lat not between -90 and 90 or lng not between -180 and 180) then lat := null; lng := null; end if;
  dlat := nullif(p->>'dest_lat','')::double precision; dlng := nullif(p->>'dest_lng','')::double precision;
  if dlat is not null and (dlat not between 32.5 and 34.2 or dlng not between 43.5 and 45.2) then dlat := null; dlng := null; end if;
  fare := taxi_zone_price(z);
  if coalesce((p->>'use_points')::boolean, false) then
    perform 1 from taxi_customers where id = c.id for update;
    if taxi_points_balance(c.id) < th then raise exception 'نقاطك ما وصلت % بعد', th; end if;
    use := least(th, coalesce(fare, th));
  end if;
  insert into taxi_trips(car_id,source,status,customer_id,customer_phone,customer_name,pickup,dropoff,note,zone_id,fare,request_token,pickup_lat,pickup_lng,points_used,dropoff_lat,dropoff_lng,dropoff_note,scheduled_at)
  values (null,'customer',case when sat is null then 'requested' else 'scheduled' end,c.id,'',c.name,left(coalesce(trim(p->>'pickup'),''),120),z.name,
          left(coalesce(p->>'note',''),200),z.id,fare,gen_random_uuid(),lat,lng,use,dlat,dlng,nullif(left(trim(coalesce(p->>'dest_note','')),100),''),sat)
  returning * into tr;
  if use > 0 then
    insert into taxi_points(customer_id,delta,reason,trip_id,note) values (c.id, -use, 'redeem', tr.id, 'كروة مجانية');
  end if;
  insert into taxi_events(car_id,kind,info) values (null, case when sat is null then 'request' else 'scheduled' end,
    c.name || ': ' || case when sat is null then '' else 'حجز ' || to_char(sat at time zone 'Asia/Baghdad','YYYY-MM-DD HH24:MI') || ' · ' end
    || coalesce(nullif(tr.pickup,''),'موقع على الخريطة') || ' ← ' || z.name
    || coalesce(' (' || tr.dropoff_note || ')','') || case when use > 0 then ' (كروة مجانية بالنقاط)' else '' end);
  return json_build_object('token', tr.request_token, 'points_used', use, 'scheduled', sat is not null);
end $function$;

grant execute on function public.taxi_admin_noshow(text,bigint,boolean,text), public.taxi_admin_scheduled(text),
  public.taxi_admin_sched_confirm(text,bigint,uuid), public.taxi_chk_full(text) to anon, authenticated;
revoke execute on function public.taxi_release_scheduled() from anon, authenticated, public;

-- in-place patches
do $$
declare f text; d text; fns text[] := array['taxi_admin_balances','taxi_admin_cash','taxi_admin_daily','taxi_admin_deposit_decide','taxi_admin_deposit_settle',
  'taxi_admin_deposits','taxi_admin_driver_detail','taxi_admin_driver_file','taxi_admin_fares','taxi_admin_points_adjust','taxi_admin_points_settings',
  'taxi_admin_route_decide','taxi_admin_route_review','taxi_admin_settle','taxi_admin_settlement','taxi_admin_shares','taxi_admin_special',
  'taxi_admin_statement','taxi_admin_unpaid','taxi_admin_week','taxi_admin_zone_save','taxi_admin_delete','taxi_admin_customers',
  'taxi_admin_customer_block','taxi_admin_dispatchers','taxi_admin_routes_export','taxi_admin_setpin','taxi_admin_admins','taxi_export'];
  o oid;
begin
  foreach f in array fns loop
    for o in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=f loop
      d := pg_get_functiondef(o);
      if position('taxi_chk_full' in d) > 0 then continue; end if;
      if d !~ E'\nbegin\\s' then raise exception 'no begin in %', f; end if;
      d := regexp_replace(d, E'\nbegin(\\s)', E'\nbegin\\1  perform taxi_chk_full(p_pin);\\1');
      execute d;
    end loop;
  end loop;

  -- managers: perms in the list, and an owner-only 'perms' action
  d := pg_get_functiondef('public.taxi_admin_admins(text)'::regprocedure);
  d := replace(d, '''last_seen'',last_seen)', '''last_seen'',last_seen,''perms'',perms)'); execute d;
  d := pg_get_functiondef('public.taxi_admin_admin_save(text,text,jsonb)'::regprocedure);
  d := replace(d, $r$  elsif p_action = 'delete' then$r$, $r$  elsif p_action = 'perms' then
    if coalesce(p->>'perms','') not in ('full','drivers') then raise exception 'صلاحية غير معروفة'; end if;
    update taxi_admins set perms = p->>'perms' where id = aid;
  elsif p_action = 'delete' then$r$);
  d := replace(d, $r$insert into taxi_admins(name, pin_hash) values (nm, crypt(pn, gen_salt('bf')));$r$,
                  $r$insert into taxi_admins(name, pin_hash, perms) values (nm, crypt(pn, gen_salt('bf')), case when p->>'perms' = 'drivers' then 'drivers' else 'full' end);$r$);
  if position('''perms''' in d) = 0 then raise exception 'admin_save patch'; end if; execute d;

  -- driver: no-show request, and انطلاق clears a pending one
  d := pg_get_functiondef('public.taxi_driver_trip(text,text,jsonb)'::regprocedure);
  d := replace(d, $r$  elsif p_action = 'start' then$r$, $r$  elsif p_action = 'noshow' then
    nt := left(trim(coalesce(p->>'note','')), 200);
    if tr.status is distinct from 'accepted' then raise exception 'التسكير بس وإنت تنتظر الزبون'; end if;
    if length(nt) < 3 then raise exception 'اكتب ملاحظة: شنو صار؟'; end if;
    if tr.noshow_status = 'pending' then raise exception 'طلب التسكير بانتظار الإدارة'; end if;
    update taxi_trips set noshow_status='pending', noshow_note=nt, noshow_at=now(), noshow_reason=null, noshow_by=null
      where id=tr.id returning * into tr;
    insert into taxi_events(car_id,kind,info) values (c.id,'noshow', nt || ' · انتظر ' || (taxi_pickup_wait_total(tr)/60) || ' د');
  elsif p_action = 'start' then$r$);
  d := replace(d, $r$      update taxi_trips set status='started', started_at=now(),
        pickup_wait_sec$r$, $r$      update taxi_trips set status='started', started_at=now(), noshow_status = nullif(noshow_status,'pending'),
        pickup_wait_sec$r$);
  if position('noshow_status = nullif' in d) = 0 or position($r$p_action = 'noshow'$r$ in d) = 0 then raise exception 'driver_trip patch'; end if;
  execute d;

  -- trip json: no-show + schedule fields
  d := pg_get_functiondef('public.taxi_trip_json(taxi_trips)'::regprocedure);
  d := replace(d, '''special_status'',t.special_status,', '''special_status'',t.special_status,''noshow_status'',t.noshow_status,''noshow_note'',t.noshow_note,''noshow_reason'',t.noshow_reason,''noshow_by'',t.noshow_by,''scheduled_at'',t.scheduled_at,');
  if position('noshow_status' in d) = 0 then raise exception 'trip_json patch'; end if; execute d;

  -- admin trips: fields + scheduled always listed
  d := pg_get_functiondef('public.taxi_admin_trips(text,date)'::regprocedure);
  d := replace(d, 't.special_at, c.plate', 't.special_at, t.noshow_status, t.noshow_note, t.noshow_at, t.noshow_reason, t.noshow_by, t.scheduled_at, t.sched_confirmed_at, t.sched_confirmed_by, t.sched_car, c.plate');
  d := replace(d, $r$or t.status in ('requested','assigned','accepted','started')$r$, $r$or t.status in ('requested','assigned','accepted','started','scheduled')$r$);
  if position('noshow_note' in d) = 0 or position($r$'started','scheduled'$r$ in d) = 0 then raise exception 'admin_trips patch'; end if; execute d;

  -- customer status / me
  d := pg_get_functiondef('public.taxi_customer_status(uuid)'::regprocedure);
  d := replace(d, $r$'stars', (select$r$, $r$'scheduled_at', tr.scheduled_at, 'sched_confirmed', tr.sched_confirmed_at is not null,
    'noshow', tr.noshow_status = 'approved', 'cancel_reason', case when tr.noshow_status = 'approved' then 'السائق انتظرك وما نزلت' when tr.cancel_reason = 'انتهى وقت الحجز' then tr.cancel_reason end,
    'stars', (select$r$);
  if position('sched_confirmed' in d) = 0 then raise exception 'customer_status patch'; end if; execute d;
  d := pg_get_functiondef('public.taxi_customer_me(uuid)'::regprocedure);
  d := replace(d, $r$'trips', coalesce($r$, $r$'scheduled', coalesce((select json_agg(json_build_object('token', t.request_token, 'at', t.scheduled_at, 'zone', t.dropoff,
                    'confirmed', t.sched_confirmed_at is not null) order by t.scheduled_at) from taxi_trips t where t.customer_id=c.id and t.status='scheduled'), '[]'::json),
    'trips', coalesce($r$);
  if position($r$'scheduled', coalesce$r$ in d) = 0 then raise exception 'customer_me patch'; end if; execute d;

  -- customer may cancel a booking
  d := pg_get_functiondef('public.taxi_customer_cancel(uuid)'::regprocedure);
  d := replace(d, $r$('requested','assigned','accepted','rejected')$r$, $r$('requested','assigned','accepted','rejected','scheduled')$r$);
  if position($r$'rejected','scheduled'$r$ in d) = 0 then raise exception 'customer_cancel patch'; end if; execute d;

  -- driver sees "office closed it: customer didn't come"
  d := pg_get_functiondef('public.taxi_driver_cancelled(uuid)'::regprocedure);
  d := replace(d, $r$t.cancel_reason = 'ألغاه الزبون'$r$, $r$(t.cancel_reason = 'ألغاه الزبون' or t.noshow_status = 'approved')$r$);
  d := replace(d, $r$'at', t.ended_at)$r$, $r$'at', t.ended_at, 'kind', case when t.noshow_status = 'approved' then 'noshow' else 'customer' end)$r$);
  if position('noshow' in d) = 0 then raise exception 'driver_cancelled patch'; end if; execute d;
end $$;

select cron.schedule('taxi-release-scheduled', '* * * * *', 'select public.taxi_release_scheduled()');
