-- 52: the driver asks to cancel an open trip (reason + note); the office approves or refuses it.
-- Approved -> the trip is cancelled with no fare. Refused -> the trip goes on and the driver sees why.

alter table public.taxi_trips add column if not exists cancel_req_status text;
alter table public.taxi_trips add column if not exists cancel_req_kind text;
alter table public.taxi_trips add column if not exists cancel_req_note text;
alter table public.taxi_trips add column if not exists cancel_req_at timestamptz;
alter table public.taxi_trips add column if not exists cancel_req_by text;
alter table public.taxi_trips add column if not exists cancel_req_answer text;
alter table public.taxi_trips drop constraint if exists taxi_trips_cancel_req_status_check;
alter table public.taxi_trips add constraint taxi_trips_cancel_req_status_check
  check (cancel_req_status = any (array['pending','approved','rejected']));

do $do$
declare d text;
begin
  -- driver: new action 'cancel_req'; ending the trip normally drops a pending request
  d := pg_get_functiondef('public.taxi_driver_trip(text,text,jsonb)'::regprocedure);
  if position('cancel_req' in d) = 0 then
    d := replace(d, $a$  elsif p_action = 'line' then$a$, $a$  elsif p_action = 'cancel_req' then
    nt := left(trim(coalesce(p->>'note','')), 200);
    if tr.id is null or tr.status not in ('accepted','started') then raise exception 'ماكو سفرة مفتوحة'; end if;
    if length(trim(coalesce(p->>'kind',''))) < 2 then raise exception 'اختار سبب الإلغاء'; end if;
    if length(nt) < 3 then raise exception 'اكتب ملاحظة: شنو صار؟'; end if;
    if tr.cancel_req_status = 'pending' then raise exception 'طلب الإلغاء بانتظار الإدارة'; end if;
    update taxi_trips set cancel_req_status='pending', cancel_req_kind=left(trim(p->>'kind'),60), cancel_req_note=nt,
      cancel_req_at=now(), cancel_req_by=null, cancel_req_answer=null
      where id=tr.id returning * into tr;
    insert into taxi_events(car_id,kind,info) values (c.id,'cancel_req', tr.cancel_req_kind || ' · ' || nt);
  elsif p_action = 'line' then$a$);
    d := replace(d, $a$update taxi_trips set status='done', ended_at=now(),$a$,
                    $a$update taxi_trips set status='done', ended_at=now(), cancel_req_status = nullif(cancel_req_status,'pending'),$a$);
    execute d;
  end if;

  d := pg_get_functiondef('public.taxi_trip_json(taxi_trips)'::regprocedure);
  if position('cancel_req' in d) = 0 then
    d := replace(d, $a$select json_build_object('id',t.id,$a$, $a$select (json_build_object('id',t.id,$a$);
    d := replace(d, $a$order by rc.id desc limit 1))
  from (select 1) one$a$, $a$order by rc.id desc limit 1))::jsonb
    || jsonb_build_object('cancel_req', case when t.cancel_req_status is null then null else jsonb_build_object('status',t.cancel_req_status,'kind',t.cancel_req_kind,'note',t.cancel_req_note,'answer',t.cancel_req_answer,'by',t.cancel_req_by) end))::json
  from (select 1) one$a$);
    if position('cancel_req' in d) = 0 then raise exception 'taxi_trip_json patch failed'; end if;
    execute d;
  end if;

  d := pg_get_functiondef('public.taxi_admin_trips(text,date)'::regprocedure);
  if position('cancel_req' in d) = 0 then
    d := replace(d, $a$t.trip_kind, t.hurry_asked_at,$a$,
      $a$t.trip_kind, t.cancel_req_status, t.cancel_req_kind, t.cancel_req_note, t.cancel_req_at, t.cancel_req_by, t.cancel_req_answer, t.hurry_asked_at,$a$);
    execute d;
  end if;

  -- driver gets a "the office cancelled it" card
  d := pg_get_functiondef('public.taxi_driver_cancelled(uuid)'::regprocedure);
  if position('cancel_req' in d) = 0 then
    d := replace(d, $a$case when t.noshow_status = 'approved' then 'noshow' else 'customer' end$a$,
      $a$case when t.noshow_status = 'approved' then 'noshow' when t.cancel_req_status = 'approved' then 'driver' else 'customer' end$a$);
    d := replace(d, $a$or t.noshow_status = 'approved')$a$, $a$or t.noshow_status = 'approved' or t.cancel_req_status = 'approved')$a$);
    execute d;
  end if;

  -- push to the driver on the answer
  d := pg_get_functiondef('public.taxi_push_trg()'::regprocedure);
  if position('cancel_req' in d) = 0 then
    d := replace(d, $a$    elsif new.special_status is distinct from old.special_status and new.special_status = 'approved' then$a$,
      $a$    elsif new.cancel_req_status is distinct from old.cancel_req_status and new.cancel_req_status = 'approved' then
      dt := '✔ الإدارة وافقت على الإلغاء'; db := 'انلغت السفرة. انتظر طلب جديد.';
    elsif new.cancel_req_status is distinct from old.cancel_req_status and new.cancel_req_status = 'rejected' then
      dt := '✖ الإدارة رفضت الإلغاء'; db := coalesce(nullif(new.cancel_req_answer,''),'كمّل السفرة.');
    elsif new.special_status is distinct from old.special_status and new.special_status = 'approved' then$a$);
    execute d;
  end if;
end $do$;

create or replace function public.taxi_admin_cancel_req(p_pin text, p_id bigint, p_ok boolean, p_reason text default '')
 returns json language plpgsql security definer set search_path to 'public' as $function$
declare who text; tr taxi_trips; r text := left(trim(coalesce(p_reason,'')),200);
begin
  perform taxi_chk(p_pin);
  who := coalesce(taxi_admin_who(p_pin)->>'name','المدير');
  select * into tr from taxi_trips where id = p_id for update;
  if tr.id is null or tr.cancel_req_status is distinct from 'pending' or tr.status not in ('accepted','started') then
    raise exception 'الطلب انحسم أو السفرة خلصت'; end if;
  if p_ok then
    update taxi_trips set cancel_req_status='approved', cancel_req_by=who, cancel_req_answer=r,
      status='cancelled', ended_at=now(), fare=0, base_fare=0, round_fee=0, wait_fee=0,
      wait_sec = taxi_wait_total(tr), wait_started_at=null,
      pickup_wait_sec = taxi_pickup_wait_total(tr), pickup_wait_started_at=null,
      cancel_reason = left('ألغاها السائق (' || coalesce(tr.cancel_req_kind,'') || '): ' || coalesce(tr.cancel_req_note,'') || ' · وافق ' || who, 300)
    where id = tr.id;
    insert into taxi_events(car_id,kind,info) values (tr.car_id,'cancel_ok', 'وافق ' || who || coalesce(' · ' || nullif(r,''),''));
  else
    if length(r) < 2 then raise exception 'اكتب سبب الرفض'; end if;
    update taxi_trips set cancel_req_status='rejected', cancel_req_by=who, cancel_req_answer=r where id = tr.id;
    insert into taxi_events(car_id,kind,info) values (tr.car_id,'cancel_no', 'رفض ' || who || ' · ' || r);
  end if;
  return json_build_object('ok', true);
end $function$;
grant execute on function public.taxi_admin_cancel_req(text,bigint,boolean,text) to anon, authenticated;
