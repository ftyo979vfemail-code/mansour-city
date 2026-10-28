-- =====================================================================
-- نظام حضور العمال وسجل الغيابات — Mansour City
-- Workers are NOT system users; a timekeeper (مراقب الدوام) records them.
-- Day boundaries are Baghdad local time (Asia/Baghdad).
-- =====================================================================

-- 1) new staff role: timekeeper
alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check check (role = any (array[
  'owner','machines','elec','mech','store','mstore','project','admin1','admin2','purchase','purchase2',
  'keeper','operator','mechanic','fueler','supply','receiver','elec_tech','mech_tech','buyer','clerk','timekeeper']));

-- 2) tables
create sequence if not exists public.worker_code_seq start 1001;

create table if not exists public.workers (
  id uuid primary key default gen_random_uuid(),
  code text not null unique default ('W' || nextval('public.worker_code_seq')::text),
  name text not null check (length(btrim(name)) >= 2),
  phone text,
  trade text,
  team text,
  site text,
  pay_type text not null default 'daily' check (pay_type in ('daily','monthly')),
  wage numeric(14,0) not null default 0 check (wage >= 0),
  photo text,
  notes text,
  active boolean not null default true,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.att_days (
  day date primary key,
  closed boolean not null default false,
  holiday boolean not null default false,
  holiday_note text,
  closed_at timestamptz,
  closed_by uuid,
  auto boolean not null default false
);

create table if not exists public.attendance (
  id bigserial primary key,
  worker_id uuid not null references public.workers(id) on delete restrict,
  day date not null,
  status text not null check (status in ('present','late','half','absent','leave')),
  in_at timestamptz,
  out_at timestamptz,
  in_lat double precision check (in_lat between -90 and 90),
  in_lng double precision check (in_lng between -180 and 180),
  in_acc real,
  out_lat double precision check (out_lat between -90 and 90),
  out_lng double precision check (out_lng between -180 and 180),
  method text not null default 'manual' check (method in ('manual','qr','auto')),
  reason text,
  excused boolean not null default false,
  attach text,
  edit_reason text,
  by_uid uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (worker_id, day),
  check (out_at is null or in_at is null or out_at >= in_at)
);
create index if not exists attendance_day_idx on public.attendance(day);

create table if not exists public.att_audit (
  id bigserial primary key,
  att_id bigint,
  worker_id uuid,
  day date,
  op text not null,
  old jsonb,
  new jsonb,
  reason text,
  by_uid uuid,
  at timestamptz not null default now()
);
create index if not exists att_audit_day_idx on public.att_audit(day);

-- 3) helpers
create schema if not exists private;
create or replace function private.bg_today() returns date language sql stable
as $$ select (now() at time zone 'Asia/Baghdad')::date $$;

-- 4) guards
create or replace function private.workers_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare rl text := public.my_role();
begin
  if rl is null or rl not in ('timekeeper','project','owner') then
    raise exception 'لا تملك صلاحية إدارة العمال';
  end if;
  new.name := btrim(new.name);
  new.updated_at := now();
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
    if rl = 'timekeeper' then new.wage := 0; new.pay_type := 'daily'; end if;
  else
    new.code := old.code; new.created_by := old.created_by; new.created_at := old.created_at;
    if rl = 'timekeeper' then new.wage := old.wage; new.pay_type := old.pay_type; end if;
  end if;
  return new;
end $$;
drop trigger if exists workers_guard on public.workers;
create trigger workers_guard before insert or update on public.workers
  for each row execute function private.workers_guard();

create or replace function private.att_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare
  rl text := public.my_role();
  sys boolean := coalesce(current_setting('att.sys', true), '') = '1';
  today date := private.bg_today();
  d date := case when tg_op = 'DELETE' then old.day else new.day end;
  is_closed boolean;
begin
  if sys then
    if tg_op <> 'DELETE' then new.updated_at := now(); end if;
    return coalesce(new, old);
  end if;
  if rl is null or rl not in ('timekeeper','project','owner') then
    raise exception 'لا تملك صلاحية تسجيل الحضور';
  end if;
  if tg_op = 'DELETE' and rl = 'timekeeper' then
    raise exception 'الحذف عن طريق مدير المشروع فقط';
  end if;
  if tg_op = 'UPDATE' and (new.day <> old.day or new.worker_id <> old.worker_id) then
    raise exception 'لا يمكن تغيير العامل أو اليوم';
  end if;
  if d > today then raise exception 'لا يمكن التسجيل ليوم قادم'; end if;
  select closed into is_closed from public.att_days where day = d;
  is_closed := coalesce(is_closed, false);

  if tg_op <> 'DELETE' and tg_op = 'UPDATE' and new.edit_reason is not distinct from old.edit_reason then
    new.edit_reason := null;  -- a reason belongs to one edit only
  end if;

  if rl = 'timekeeper' then
    if is_closed then raise exception 'هذا اليوم مغلق. التعديل عن طريق مدير المشروع فقط'; end if;
    if d < today - 1 then raise exception 'مراقب الدوام يسجّل لليوم الحالي أو الأمس فقط'; end if;
  elsif is_closed and tg_op <> 'DELETE' and coalesce(btrim(new.edit_reason), '') = '' then
    raise exception 'اليوم مغلق: اكتب سبب التعديل';
  end if;

  if tg_op = 'DELETE' then return old; end if;

  if tg_op = 'INSERT' and not exists (select 1 from public.workers where id = new.worker_id and active) then
    raise exception 'العامل موقوف أو غير موجود';
  end if;
  if new.status in ('absent','leave') then
    new.in_at := null; new.out_at := null; new.in_lat := null; new.in_lng := null; new.in_acc := null;
    new.out_lat := null; new.out_lng := null;
  else
    new.excused := false;
  end if;
  if new.in_at is not null and (new.in_at at time zone 'Asia/Baghdad')::date <> new.day then
    raise exception 'وقت الدخول لا يطابق اليوم';
  end if;
  if new.out_at is not null and (new.out_at at time zone 'Asia/Baghdad')::date not in (new.day, new.day + 1) then
    raise exception 'وقت الخروج لا يطابق اليوم';
  end if;
  if new.method = 'auto' and (tg_op = 'INSERT' or new.status <> old.status) then new.method := 'manual'; end if;
  new.by_uid := auth.uid();
  new.updated_at := now();
  if tg_op = 'INSERT' then new.created_at := now(); end if;
  return new;
end $$;
drop trigger if exists att_guard on public.attendance;
create trigger att_guard before insert or update or delete on public.attendance
  for each row execute function private.att_guard();

-- audit: every change, plus inserts made on an already-closed day
create or replace function private.att_audit_fn() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare closed_now boolean;
begin
  if tg_op = 'INSERT' then
    select closed into closed_now from public.att_days where day = new.day;
    if not coalesce(closed_now, false) then return null; end if;
    insert into public.att_audit(att_id, worker_id, day, op, new, reason, by_uid)
      values (new.id, new.worker_id, new.day, 'insert', to_jsonb(new), new.edit_reason, auth.uid());
  elsif tg_op = 'UPDATE' then
    if to_jsonb(new) - array['updated_at','by_uid','edit_reason'] = to_jsonb(old) - array['updated_at','by_uid','edit_reason'] then
      return null;
    end if;
    insert into public.att_audit(att_id, worker_id, day, op, old, new, reason, by_uid)
      values (new.id, new.worker_id, new.day, 'update', to_jsonb(old), to_jsonb(new), new.edit_reason, auth.uid());
  else
    insert into public.att_audit(att_id, worker_id, day, op, old, by_uid)
      values (old.id, old.worker_id, old.day, 'delete', to_jsonb(old), auth.uid());
  end if;
  return null;
end $$;
drop trigger if exists att_audit_trg on public.attendance;
create trigger att_audit_trg after insert or update or delete on public.attendance
  for each row execute function private.att_audit_fn();

-- 5) day operations
create or replace function public.att_close_day(p_day date) returns json
language plpgsql security definer set search_path = public, private as $$
declare
  rl text := public.my_role();
  is_cron boolean := coalesce(current_setting('att.cron', true), '') = '1';
  today date := private.bg_today();
  off jsonb; alert_n int; is_off boolean; hol boolean; n int := 0; alerts int := 0;
begin
  if not is_cron and (rl is null or rl not in ('timekeeper','project','owner')) then
    raise exception 'لا تملك صلاحية إغلاق اليوم';
  end if;
  if p_day is null or p_day > today then raise exception 'لا يمكن إغلاق يوم قادم'; end if;
  if rl = 'timekeeper' and p_day < today - 1 then raise exception 'مراقب الدوام يغلق اليوم الحالي أو الأمس فقط'; end if;
  if exists (select 1 from public.att_days where day = p_day and closed) then raise exception 'هذا اليوم مغلق مسبقاً'; end if;

  select data->'att'->'off', (data->'att'->>'alertDays')::int into off, alert_n from public.settings where id = 'main';
  off := coalesce(off, '[5]'::jsonb);
  alert_n := greatest(coalesce(alert_n, 3), 2);
  is_off := off @> to_jsonb(extract(dow from p_day)::int);
  select holiday into hol from public.att_days where day = p_day;
  hol := coalesce(hol, false);

  perform set_config('att.sys', '1', true);
  if not is_off and not hol then
    insert into public.attendance(worker_id, day, status, method, by_uid)
      select w.id, p_day, 'absent', 'auto', auth.uid() from public.workers w
      where w.active and (w.created_at at time zone 'Asia/Baghdad')::date <= p_day
        and not exists (select 1 from public.attendance a where a.worker_id = w.id and a.day = p_day);
    get diagnostics n = row_count;

    with recent as (
      select a.worker_id, (a.status = 'absent' and not a.excused) as ab,
             row_number() over (partition by a.worker_id order by a.day desc) rn
      from public.attendance a
      where a.day <= p_day and a.day > p_day - 60
        and a.worker_id in (select worker_id from public.attendance where day = p_day and status = 'absent' and not excused)
    ), streaks as (
      select worker_id, coalesce(min(rn) filter (where not ab) - 1, count(*)) as streak from recent group by worker_id
    ), ins as (
      insert into public.notifications(kind, data)
      select 'att_absent', jsonb_build_object('wid', w.id, 'name', w.name, 'code', w.code, 'site', w.site,
                                              'trade', w.trade, 'days', s.streak, 'day', p_day)
      from streaks s join public.workers w on w.id = s.worker_id
      where s.streak = alert_n
      returning 1
    ) select count(*) into alerts from ins;
  end if;

  insert into public.att_days(day, closed, closed_at, closed_by, auto)
    values (p_day, true, now(), auth.uid(), is_cron)
    on conflict (day) do update set closed = true, closed_at = now(), closed_by = excluded.closed_by, auto = excluded.auto;
  insert into public.att_audit(day, op, new, by_uid)
    values (p_day, 'close', jsonb_build_object('absent', n, 'off', is_off, 'holiday', hol, 'alerts', alerts, 'auto', is_cron), auth.uid());
  perform set_config('att.sys', '', true);
  return json_build_object('absent', n, 'off', is_off, 'holiday', hol, 'alerts', alerts);
end $$;

create or replace function public.att_reopen_day(p_day date, p_reason text) returns void
language plpgsql security definer set search_path = public, private as $$
declare rl text := public.my_role();
begin
  if rl is null or rl not in ('project','owner') then raise exception 'إعادة فتح اليوم من صلاحية مدير المشروع'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'اكتب سبب إعادة الفتح'; end if;
  if not exists (select 1 from public.att_days where day = p_day and closed) then raise exception 'هذا اليوم غير مغلق'; end if;
  update public.att_days set closed = false, closed_at = null, closed_by = null, auto = false where day = p_day;
  insert into public.att_audit(day, op, reason, by_uid) values (p_day, 'reopen', btrim(p_reason), auth.uid());
end $$;

create or replace function public.att_set_holiday(p_day date, p_on boolean, p_note text default null) returns json
language plpgsql security definer set search_path = public, private as $$
declare rl text := public.my_role(); n int := 0;
begin
  if rl is null or rl not in ('project','owner') then raise exception 'تحديد العطل من صلاحية مدير المشروع'; end if;
  if p_day is null then raise exception 'اختر اليوم'; end if;
  insert into public.att_days(day, holiday, holiday_note) values (p_day, p_on, nullif(btrim(coalesce(p_note,'')), ''))
    on conflict (day) do update set holiday = excluded.holiday, holiday_note = excluded.holiday_note;
  if p_on then
    perform set_config('att.sys', '1', true);
    delete from public.attendance where day = p_day and method = 'auto' and status = 'absent';
    get diagnostics n = row_count;
    perform set_config('att.sys', '', true);
  end if;
  insert into public.att_audit(day, op, reason, new, by_uid)
    values (p_day, case when p_on then 'holiday' else 'unholiday' end, p_note, jsonb_build_object('removed_absent', n), auth.uid());
  return json_build_object('removed', n);
end $$;

-- nightly auto-close (23:00 Baghdad): closes yesterday and today if still open
create or replace function private.att_cron() returns void
language plpgsql security definer set search_path = public, private as $$
declare d date;
begin
  perform set_config('att.cron', '1', true);
  foreach d in array array[private.bg_today() - 1, private.bg_today()] loop
    if not exists (select 1 from public.att_days where day = d and closed) then
      begin perform public.att_close_day(d); exception when others then raise warning 'att_cron %: %', d, sqlerrm; end;
    end if;
  end loop;
  perform set_config('att.cron', '', true);
end $$;

revoke all on function public.att_close_day(date) from public, anon;
revoke all on function public.att_reopen_day(date, text) from public, anon;
revoke all on function public.att_set_holiday(date, boolean, text) from public, anon;
grant execute on function public.att_close_day(date) to authenticated;
grant execute on function public.att_reopen_day(date, text) to authenticated;
grant execute on function public.att_set_holiday(date, boolean, text) to authenticated;
revoke all on function private.att_cron() from public, anon, authenticated;

-- 6) row level security
alter table public.workers enable row level security;
alter table public.attendance enable row level security;
alter table public.att_days enable row level security;
alter table public.att_audit enable row level security;

drop policy if exists w_read on public.workers;
drop policy if exists w_ins on public.workers;
drop policy if exists w_upd on public.workers;
drop policy if exists w_del on public.workers;
create policy w_read on public.workers for select to authenticated
  using (public.my_role() = any (array['timekeeper','project','owner','admin1','admin2','clerk']));
create policy w_ins on public.workers for insert to authenticated
  with check (public.my_role() = any (array['timekeeper','project','owner']));
create policy w_upd on public.workers for update to authenticated
  using (public.my_role() = any (array['timekeeper','project','owner']))
  with check (public.my_role() = any (array['timekeeper','project','owner']));
create policy w_del on public.workers for delete to authenticated
  using (public.my_role() = any (array['project','owner']));

drop policy if exists a_read on public.attendance;
drop policy if exists a_ins on public.attendance;
drop policy if exists a_upd on public.attendance;
drop policy if exists a_del on public.attendance;
create policy a_read on public.attendance for select to authenticated
  using (public.my_role() = any (array['timekeeper','project','owner','admin1','admin2','clerk']));
create policy a_ins on public.attendance for insert to authenticated
  with check (public.my_role() = any (array['timekeeper','project','owner']));
create policy a_upd on public.attendance for update to authenticated
  using (public.my_role() = any (array['timekeeper','project','owner']))
  with check (public.my_role() = any (array['timekeeper','project','owner']));
create policy a_del on public.attendance for delete to authenticated
  using (public.my_role() = any (array['project','owner']));

drop policy if exists ad_read on public.att_days;
create policy ad_read on public.att_days for select to authenticated
  using (public.my_role() = any (array['timekeeper','project','owner','admin1','admin2','clerk']));

drop policy if exists au_read on public.att_audit;
create policy au_read on public.att_audit for select to authenticated
  using (public.my_role() = any (array['project','owner','admin1','admin2']));

-- 7) push for repeated-absence alerts (keeps the existing kinds unchanged)
create or replace function private.on_notification() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare d jsonb := new.data;
begin
  if new.kind = 'receipt' then
    perform private.push_enqueue(array['admin1','admin2','clerk','project','owner'], null, 'استلام مكتمل: ' || coalesce(d->>'item',''),
      'السعر ' || coalesce(d->>'total','—') || ' د.ع · المشتري ' || coalesce(d->>'buyer','') || ' · المخزن ' || coalesce(d->>'store',''), 'n'||new.id);
  elsif new.kind = 'staff_pending' then
    perform private.push_enqueue(array['admin1','admin2','project','owner'], null, 'طلب انضمام جديد', coalesce(d->>'name','') || ' يطلب الدخول', 'n'||new.id);
  elsif new.kind = 'att_absent' then
    perform private.push_enqueue(array['project','owner','admin1','admin2'], null, 'غياب متكرر: ' || coalesce(d->>'name',''),
      coalesce(d->>'name','') || ' غائب ' || coalesce(d->>'days','') || ' أيام متتالية بدون إذن' || coalesce(' · ' || nullif(d->>'site',''), ''), 'n'||new.id);
  end if;
  return new;
end $$;

-- 8) live updates
do $$ begin
  begin alter publication supabase_realtime add table public.workers; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.attendance; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.att_days; exception when duplicate_object then null; end;
end $$;

-- 9) nightly auto-close at 23:00 Baghdad (20:00 UTC)
create extension if not exists pg_cron;
select cron.schedule('att-auto-close', '0 20 * * *', 'select private.att_cron()');
alter function private.bg_today() set search_path = pg_catalog;

-- 10) nationality on workers
alter table public.workers add column if not exists origin text check (origin is null or length(btrim(origin)) between 2 and 40);

-- 11) worker self sign-up (public site), approval by timekeeper/project, worker "my account" by phone + PIN
--     tables/functions: worker_requests, att_worker_register, att_worker_me (5 wrong PINs => 15 min lock),
--     att_requests_list, att_request_decide, notification kind 'att_join'
--     (applied as migrations: worker_self_signup, worker_me_lockout_fix)

-- 12) remote supervisors (engineer / contractor), applied as migration remote_engineers_contractors:
--     roles engineer, contractor; staff.company, staff.specialty, staff.att_team (contractor crew = workers.team)
--     is_internal(): outsiders can't read requests, inventory, invlog, machines, deliveries, staff, files
--     can_write() excludes outsiders; attendance/workers readable by engineer (all) and contractor (own crew only)
--     att_set_scope(p_id, p_team) for project/owner; worker self sign-up functions revoked

-- 13) staff has column-level SELECT grants: every new column must be granted explicitly
grant select (company, specialty, att_team) on public.staff to authenticated;
