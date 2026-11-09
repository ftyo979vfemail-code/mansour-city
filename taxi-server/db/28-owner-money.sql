-- 28: money is changed by the owner only; every manager can look at the accounts.
--  * taxi_chk_owner(pin): only the main manager (id 0).
--  * read-only money views open to every manager: balances, daily, deposits (list), driver_detail, driver_file,
--    settlement, statement, unpaid, week, shares, customers.
--  * money changes need the owner: cash, deposit_decide, deposit_settle, fares, points_adjust, settle.
--  * taxi_admin_trip_edit / taxi_admin_trip_delete (owner): change a trip's fare or delete a trip.
--    Every change is kept in taxi_trip_audit (old row as JSON, who, when, note).

create table if not exists public.taxi_trip_audit (
  id bigserial primary key, trip_id bigint not null, action text not null check (action in ('edit','delete')),
  old jsonb not null, new_fare integer, note text not null default '', by text not null, at timestamptz not null default now());
alter table public.taxi_trip_audit enable row level security;
revoke all on public.taxi_trip_audit from anon, authenticated;

create or replace function public.taxi_chk_owner(p_pin text) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce((taxi_admin_who(p_pin)->>'id')::int, -1) <> 0 then
    raise exception 'بس المدير الرئيسي يگدر يغيّر بالحسابات. إنت تگدر تشوف بس'; end if;
end $$;

create or replace function public.taxi_admin_trip_edit(p_pin text, p_id bigint, p_fare integer, p_note text default '')
 returns json language plpgsql security definer set search_path to 'public' as $$
declare tr taxi_trips; fees int; f int := p_fare;
begin
  perform taxi_chk_owner(p_pin);
  select * into tr from taxi_trips where id = p_id for update;
  if tr.id is null then raise exception 'السفرة غير موجودة'; end if;
  if tr.status <> 'done' then raise exception 'تعديل الكروة بس للسفرات اللي خلصت'; end if;
  if f is null or f < 0 or f > 1000000 then raise exception 'المبلغ غلط'; end if;
  if f between 1 and 100 then f := f * 1000; end if;
  insert into taxi_trip_audit(trip_id, action, old, new_fare, note, by) values (tr.id, 'edit', to_jsonb(tr), f, left(coalesce(p_note,''),200), 'المدير');
  fees := coalesce(tr.round_fee,0) + coalesce(tr.wait_fee,0);
  update taxi_trips set fare = f,
    base_fare = case when f >= fees then f - fees else f end,
    round_fee = case when f >= fees then round_fee else 0 end,
    wait_fee = case when f >= fees then wait_fee else 0 end,
    points_used = least(points_used, f)
  where id = tr.id;
  insert into taxi_events(car_id,kind,info) values (tr.car_id,'trip_edit', 'كروة سفرة ' || coalesce(tr.dropoff,'') || ': ' || coalesce(tr.fare,0) || ' ← ' || f);
  return json_build_object('ok', true, 'fare', f);
end $$;

create or replace function public.taxi_admin_trip_delete(p_pin text, p_id bigint, p_note text default '')
 returns json language plpgsql security definer set search_path to 'public' as $$
declare tr taxi_trips;
begin
  perform taxi_chk_owner(p_pin);
  select * into tr from taxi_trips where id = p_id for update;
  if tr.id is null then raise exception 'السفرة غير موجودة'; end if;
  if tr.status in ('assigned','accepted','started') then raise exception 'السفرة شغّالة، ألغِها أولًا'; end if;
  insert into taxi_trip_audit(trip_id, action, old, note, by) values (tr.id, 'delete', to_jsonb(tr), left(coalesce(p_note,''),200), 'المدير');
  -- points: earned ones go, used ones come back to the customer
  delete from taxi_points where trip_id = tr.id and reason = 'trip';
  if tr.customer_id is not null and tr.points_used > 0 and tr.status = 'done' then
    insert into taxi_points(customer_id,delta,reason,trip_id,note) values (tr.customer_id, tr.points_used, 'refund', null, 'رجعت النقاط لأن السفرة انحذفت');
  end if;
  update taxi_points set trip_id = null where trip_id = tr.id;
  delete from taxi_trips where id = tr.id;
  insert into taxi_events(car_id,kind,info) values (tr.car_id,'trip_delete', 'حذف سفرة ' || coalesce(tr.dropoff,'') || ' بكروة ' || coalesce(tr.fare,0));
  return json_build_object('ok', true);
end $$;

create or replace function public.taxi_admin_trip_audit(p_pin text) returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(json_build_object('id',a.id,'trip_id',a.trip_id,'action',a.action,'old_fare',(a.old->>'fare')::int,'new_fare',a.new_fare,
     'dropoff',a.old->>'dropoff','driver',c.driver_name,'note',a.note,'at',a.at) order by a.at desc)
     from (select * from taxi_trip_audit order by at desc limit 100) a left join taxi_cars c on c.id = (a.old->>'car_id')::uuid), '[]'::json);
end $$;

grant execute on function public.taxi_chk_owner(text), public.taxi_admin_trip_edit(text,bigint,integer,text), public.taxi_admin_trip_delete(text,bigint,text),
  public.taxi_admin_trip_audit(text) to anon, authenticated;

do $$
declare f text; d text; o oid;
  ro text[] := array['taxi_admin_balances','taxi_admin_daily','taxi_admin_deposits','taxi_admin_driver_detail','taxi_admin_driver_file',
                     'taxi_admin_settlement','taxi_admin_statement','taxi_admin_unpaid','taxi_admin_week','taxi_admin_shares','taxi_admin_customers'];
  wr text[] := array['taxi_admin_cash','taxi_admin_deposit_decide','taxi_admin_deposit_settle','taxi_admin_fares','taxi_admin_points_adjust','taxi_admin_settle'];
begin
  foreach f in array ro loop
    for o in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=f loop
      d := pg_get_functiondef(o);
      if position('perform taxi_chk_full(p_pin);' in d) = 0 then raise exception 'no chk_full in %', f; end if;
      d := replace(d, 'perform taxi_chk_full(p_pin);', 'perform taxi_chk(p_pin);'); execute d;
    end loop;
  end loop;
  foreach f in array wr loop
    for o in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=f loop
      d := pg_get_functiondef(o);
      if position('perform taxi_chk_full(p_pin);' in d) = 0 then raise exception 'no chk_full in %', f; end if;
      d := replace(d, 'perform taxi_chk_full(p_pin);', 'perform taxi_chk_owner(p_pin);'); execute d;
    end loop;
  end loop;
end $$;
