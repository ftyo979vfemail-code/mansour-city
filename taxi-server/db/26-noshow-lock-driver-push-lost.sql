-- 26: no-show locks the pickup clock; push notifications for drivers too; parked iPhones are not "lost".
--  * noshow request: the pickup clock stops (pickup_wait_sec frozen) so the office sees exactly how long he waited.
--    Refused -> the clock starts again. Approved -> the frozen time is kept on the cancelled trip.
--  * taxi_push_subs: customer_id OR car_id. taxi_driver_push(code, sub, on). taxi-push accepts car_id.
--    The driver is told: new trip from the office, no-show / special decisions, a booking released to him.
--  * taxi_mark_lost (iPhones pause GPS while the car stands still):
--      moving car (speed >= 1 m/s) or running trip  -> lost after 4 min of silence
--      parked car                                    -> state 'parked' (grey, no alarm) after 4 min,
--                                                       lost only after 45 min of silence
--    A ping brings either state back to ok; 'parked' -> ok is not logged as an event.

-- Applied as migration taxi_noshow_lock_driver_push_lost:
-- 26a: no-show locks the clock; refused -> clock runs again
do $$ declare d text; b0 text; begin
  d := pg_get_functiondef('public.taxi_driver_trip(text,text,jsonb)'::regprocedure); b0 := d;
  d := replace(d, $r$    update taxi_trips set noshow_status='pending', noshow_note=nt, noshow_at=now(), noshow_reason=null, noshow_by=null
      where id=tr.id returning * into tr;$r$,
  $r$    update taxi_trips set noshow_status='pending', noshow_note=nt, noshow_at=now(), noshow_reason=null, noshow_by=null,
      pickup_wait_sec = taxi_pickup_wait_total(tr), pickup_wait_started_at = null
      where id=tr.id returning * into tr;$r$);
  if d = b0 then raise exception 'noshow lock patch'; end if;
  -- a parked phone can start a trip
  d := replace(d, $r$if c.gps_state not in ('ok','background') then$r$, $r$if c.gps_state not in ('ok','background','parked') then$r$);
  if position($r$'background','parked'$r$ in d) = 0 then raise exception 'start parked patch'; end if;
  execute d;

  d := pg_get_functiondef('public.taxi_admin_noshow(text,bigint,boolean,text)'::regprocedure);
  d := replace(d, $r$update taxi_trips set noshow_status='rejected', noshow_by=who, noshow_reason=r where id = tr.id;$r$,
                  $r$update taxi_trips set noshow_status='rejected', noshow_by=who, noshow_reason=r, pickup_wait_started_at = now() where id = tr.id;$r$);
  if position('pickup_wait_started_at = now()' in d) = 0 then raise exception 'noshow reject patch'; end if;
  execute d;
end $$;

-- 26b: push to drivers too
alter table public.taxi_push_subs alter column customer_id drop not null,
  add column if not exists car_id uuid references public.taxi_cars(id) on delete cascade;
alter table public.taxi_push_subs drop constraint if exists taxi_push_subs_owner;
alter table public.taxi_push_subs add constraint taxi_push_subs_owner check ((customer_id is null) <> (car_id is null));

create or replace function public.taxi_driver_push(p_code text, p_sub jsonb, p_on boolean default true)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare c taxi_cars; ep text := p_sub->>'endpoint';
begin
  select * into c from taxi_cars where driver_code = trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  if ep is null or ep !~ '^https://' or length(ep) > 1000 then raise exception 'اشتراك غير صالح'; end if;
  if not p_on then delete from taxi_push_subs where endpoint = ep and car_id = c.id; return json_build_object('ok', true); end if;
  if coalesce(p_sub->'keys'->>'p256dh','') = '' or coalesce(p_sub->'keys'->>'auth','') = '' then raise exception 'اشتراك غير صالح'; end if;
  if (select count(*) from taxi_push_subs where car_id = c.id) >= 3 then
    delete from taxi_push_subs where id = (select id from taxi_push_subs where car_id = c.id order by created_at limit 1); end if;
  insert into taxi_push_subs(car_id, customer_id, endpoint, p256dh, auth) values (c.id, null, ep, p_sub->'keys'->>'p256dh', p_sub->'keys'->>'auth')
  on conflict (endpoint) do update set car_id = excluded.car_id, customer_id = null, p256dh = excluded.p256dh, auth = excluded.auth;
  return json_build_object('ok', true);
end $$;
grant execute on function public.taxi_driver_push(text,jsonb,boolean) to anon, authenticated;

create or replace function public.taxi_customer_push(p_token uuid, p_sub jsonb, p_on boolean default true)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare cu taxi_customers := taxi_session_customer(p_token); ep text := p_sub->>'endpoint';
begin
  if ep is null or ep !~ '^https://' or length(ep) > 1000 then raise exception 'اشتراك غير صالح'; end if;
  if not p_on then delete from taxi_push_subs where endpoint = ep and customer_id = cu.id; return json_build_object('ok', true); end if;
  if coalesce(p_sub->'keys'->>'p256dh','') = '' or coalesce(p_sub->'keys'->>'auth','') = '' then raise exception 'اشتراك غير صالح'; end if;
  if (select count(*) from taxi_push_subs where customer_id = cu.id) >= 5 then
    delete from taxi_push_subs where id = (select id from taxi_push_subs where customer_id = cu.id order by created_at limit 1); end if;
  insert into taxi_push_subs(customer_id, car_id, endpoint, p256dh, auth) values (cu.id, null, ep, p_sub->'keys'->>'p256dh', p_sub->'keys'->>'auth')
  on conflict (endpoint) do update set customer_id = excluded.customer_id, car_id = null, p256dh = excluded.p256dh, auth = excluded.auth;
  return json_build_object('ok', true);
end $$;

create or replace function public.taxi_push_send(p_customer bigint, p_car uuid, p_title text, p_body text, p_tag text, p_url text)
 returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not exists(select 1 from taxi_push_subs where (p_customer is not null and customer_id = p_customer) or (p_car is not null and car_id = p_car)) then return; end if;
  perform net.http_post(
    url := 'https://xdyxcvyhoidojtfpoepk.supabase.co/functions/v1/taxi-push',
    body := jsonb_build_object('secret', (select v from taxi_settings where k='push_secret'), 'customer_id', p_customer, 'car_id', p_car,
                               'title', p_title, 'body', p_body, 'tag', p_tag, 'url', p_url),
    headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 15000);
exception when others then null;
end $$;
revoke execute on function public.taxi_push_send(bigint,uuid,text,text,text,text) from anon, authenticated, public;

create or replace function public.taxi_push_trg() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare t text; b text; drv text; dt text; db text;
begin
  -- customer
  if new.customer_id is not null then
    select driver_name into drv from taxi_cars where id = new.car_id;
    if new.status = 'accepted' and old.status is distinct from 'accepted' then
      t := '🚕 السائق جاي إلك'; b := coalesce(drv,'السائق') || ' قبل طلبك وهو بالطريق.';
    elsif new.status = 'accepted' and new.pickup_wait_started_at is not null and old.pickup_wait_started_at is null and old.noshow_status is distinct from 'pending' then
      t := '📍 السائق وصل وينتظرك'; b := 'انزل للسيارة.';
    elsif new.status = 'done' and old.status is distinct from 'done' then
      t := '✅ وصلت بالسلامة'; b := 'قيّم السائق من التطبيق.';
    elsif new.status = 'cancelled' and old.status is distinct from 'cancelled' and coalesce(new.cancel_reason,'') <> 'ألغاه الزبون' then
      t := '✖ انلغى طلبك'; b := case when new.noshow_status = 'approved' then 'السائق انتظرك وما نزلت.' when new.cancel_reason = 'انتهى وقت الحجز' then 'انتهى وقت الحجز.' else 'تواصل ويا الإدارة إذا تحتاج.' end;
    elsif new.status = 'scheduled' and new.sched_confirmed_at is not null and old.sched_confirmed_at is null then
      t := '🗓 انأكد حجزك'; b := 'حجزك ليوم ' || to_char(new.scheduled_at at time zone 'Asia/Baghdad','MM/DD الساعة HH24:MI') || ' انأكد.';
    end if;
    if t is not null then perform taxi_push_send(new.customer_id, null, t, b, 'trip-' || new.id, './#order'); end if;
  end if;
  -- driver
  if new.car_id is not null then
    if new.status = 'assigned' and (old.status is distinct from 'assigned' or old.car_id is distinct from new.car_id) then
      dt := case when old.status = 'scheduled' then '🗓 حجز مسبق إلك' else '📣 سفرة جديدة من المكتب' end;
      db := coalesce(nullif(new.pickup,''),'موقع على الخريطة') || ' ← ' || coalesce(new.dropoff,'') || '. افتح التطبيق واقبلها.';
    elsif new.noshow_status is distinct from old.noshow_status and new.noshow_status = 'approved' then
      dt := '✔ الإدارة سكّرت الطلب'; db := 'وافقت على التسكير (الزبون ما نزل).';
    elsif new.noshow_status is distinct from old.noshow_status and new.noshow_status = 'rejected' then
      dt := '✖ الإدارة رفضت التسكير'; db := coalesce(nullif(new.noshow_reason,''),'كمّل انتظار الزبون.');
    elsif new.special_status is distinct from old.special_status and new.special_status = 'approved' then
      dt := '⭐ وافقت الإدارة: زبون خاص'; db := 'السفرة بدون كروة. تكدر تنطلق.';
    elsif new.special_status is distinct from old.special_status and new.special_status = 'rejected' then
      dt := '✖ الإدارة رفضت الزبون الخاص'; db := 'السفرة بكروة عادية. ' || coalesce(new.special_reason,'');
    elsif new.status = 'cancelled' and old.status in ('assigned','accepted') and new.cancel_reason = 'ألغاه الزبون' then
      dt := '✖ الزبون ألغى الطلب'; db := 'ما عليك شي، انتظر طلب جديد.';
    end if;
    if dt is not null then perform taxi_push_send(null, new.car_id, dt, db, 'drv-' || new.id, './#driver'); end if;
  end if;
  return new;
exception when others then return new;  -- a push problem never blocks the trip
end $$;
drop trigger if exists taxi_push on public.taxi_trips;
create trigger taxi_push after update on public.taxi_trips for each row execute function public.taxi_push_trg();

-- a brand-new trip created straight as 'assigned' (office booking) also notifies the driver
create or replace function public.taxi_push_ins_trg() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.status = 'assigned' and new.car_id is not null then
    perform taxi_push_send(null, new.car_id, '📣 سفرة جديدة من المكتب',
      coalesce(nullif(new.pickup,''),'موقع على الخريطة') || ' ← ' || coalesce(new.dropoff,'') || '. افتح التطبيق واقبلها.', 'drv-' || new.id, './#driver');
  end if;
  return new;
exception when others then return new;
end $$;
drop trigger if exists taxi_push_ins on public.taxi_trips;
create trigger taxi_push_ins after insert on public.taxi_trips for each row execute function public.taxi_push_ins_trg();

-- 26c: parked iPhones
create or replace function public.taxi_mark_lost() returns void language plpgsql security definer set search_path to 'public' as $function$
declare r record;
begin
  -- parked (slow, no running trip) and quiet for 4 min -> 'parked', no alarm
  update taxi_cars c set gps_state = 'parked'
   where active and gps_state in ('ok','background') and last_seen < now() - interval '4 minutes'
     and coalesce(last_speed,0) < 1
     and not exists(select 1 from taxi_trips t where t.car_id = c.id and t.status = 'started');
  -- moving / on a trip and quiet for 4 min, or parked and quiet for 45 min -> lost (alarm)
  for r in update taxi_cars c set gps_state = 'lost'
           where active and ((gps_state in ('ok','background') and last_seen < now() - interval '4 minutes')
                          or (gps_state = 'parked' and last_seen < now() - interval '45 minutes'))
           returning id loop
    insert into taxi_events(car_id,kind) values (r.id,'lost');
  end loop;
end $function$;

do $$ declare f text; d text; begin
  d := pg_get_functiondef('public.taxi_ping_v2(text,double precision,double precision,double precision,double precision,double precision,integer)'::regprocedure);
  d := replace(d, $r$elsif c.gps_state <> 'ok' then insert$r$, $r$elsif c.gps_state not in ('ok','parked') then insert$r$);
  if position($r$not in ('ok','parked')$r$ in d) = 0 then raise exception 'ping patch'; end if;
  execute d;
  foreach f in array array['taxi_public_info','taxi_admin_balances','taxi_disp_state','taxi_driver_state','taxi_admin_driver_file'] loop
    for d in select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=f loop
      if position($r$('ok','background')$r$ in d) > 0 then
        d := replace(d, $r$('ok','background')$r$, $r$('ok','background','parked')$r$); execute d;
      end if;
    end loop;
  end loop;
end $$;
