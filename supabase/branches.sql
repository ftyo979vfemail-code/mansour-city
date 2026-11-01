-- =====================================================================
-- Multi-site (branches): المنصور ستي + مجمع الأميرات ستي في نفس النظام
-- Every data row belongs to a branch; each account sees only its current branch.
-- =====================================================================
create table if not exists public.branches (
  id text primary key, name text not null, sub text, sort int not null default 0
);
insert into public.branches(id,name,sub,sort) values
  ('mansour','المنصور ستي','نظام شركة المنصور',1),
  ('alamirat','مجمع الأميرات ستي','مجمع الفلوجة',2)
on conflict (id) do nothing;
alter table public.branches enable row level security;
drop policy if exists br_read on public.branches;
create policy br_read on public.branches for select to anon, authenticated using (true);
grant select on public.branches to anon, authenticated;

-- staff: home branch, allowed branches, currently selected branch
alter table public.staff add column if not exists branch text not null default 'mansour' references public.branches(id);
alter table public.staff add column if not exists branches text[] not null default array['mansour'];
alter table public.staff add column if not exists cur_branch text;
update public.staff set branches = array['mansour','alamirat'] where role = 'owner' or hidden;

create or replace function public.cur_branch() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select case when s.cur_branch is not null and s.cur_branch = any(s.branches) then s.cur_branch
                               when s.branch = any(s.branches) then s.branch else s.branches[1] end
                   from public.staff s where s.id = auth.uid()), 'mansour')
$$;
revoke all on function public.cur_branch() from public;
grant execute on function public.cur_branch() to anon, authenticated;

create or replace function public.set_branch(p_branch text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.staff where id = auth.uid() and p_branch = any(branches)) then
    raise exception 'ما عندك صلاحية على هذا الموقع';
  end if;
  update public.staff set cur_branch = p_branch where id = auth.uid();
  return p_branch;
end $$;
revoke all on function public.set_branch(text) from public;
grant execute on function public.set_branch(text) to authenticated;

-- branch column on every data table (existing rows -> mansour)
do $$ declare t text; begin
  foreach t in array array['requests','inventory','invlog','settings','deliveries','machines','invoices','audits','field_photos',
                           'receipt_codes','notifications','workers','att_days','attendance','att_audit','worker_requests'] loop
    execute format('alter table public.%I add column if not exists branch text not null default ''mansour'' references public.branches(id)', t);
    execute format('alter table public.%I alter column branch set default public.cur_branch()', t);
    execute format('create index if not exists %I on public.%I (branch)', t||'_branch_idx', t);
  end loop;
end $$;

-- keys that are fixed per site become per-branch
alter table public.settings drop constraint settings_pkey, add primary key (branch, id);
alter table public.att_days drop constraint att_days_pkey, add primary key (branch, day);
alter table public.inventory drop constraint inventory_pkey, add primary key (branch, id);

-- staff visibility: only people who belong to the current branch
alter policy staff_read on public.staff using ((id = (select auth.uid())) or (is_internal() and (not hidden) and ((select public.cur_branch()) = any(branches))));
alter policy lt_read on public.loc_trail using (((uid = auth.uid()) or (my_role() = any (array['project','owner','admin1','admin2']))
  or ((my_role() = 'machines') and exists (select 1 from public.staff s where s.id = loc_trail.uid and s.role = any (array['driver','operator']))))
  and exists (select 1 from public.staff s2 where s2.id = loc_trail.uid and (select public.cur_branch()) = any(s2.branches)));
alter policy sl_read on public.staff_locations using (((id = auth.uid()) or (my_role() = any (array['project','owner','admin1','admin2']))
  or ((my_role() = 'machines') and exists (select 1 from public.staff s where s.id = staff_locations.id and s.role = any (array['driver','operator']))))
  and exists (select 1 from public.staff s2 where s2.id = staff_locations.id and (select public.cur_branch()) = any(s2.branches)));
create or replace function private._fnpatch(p_sig text, p_old text, p_new text) returns void
language plpgsql as $f$
declare d text; n int;
begin
  d := coalesce(current_setting('fnp.b'||md5(p_sig), true), '');
  if d = '' then d := pg_get_functiondef(p_sig::regprocedure); end if;
  n := (length(d) - length(replace(d, p_old, ''))) / greatest(length(p_old),1);
  if n <> 1 then raise exception 'fnpatch % : expected 1 match, got % for: %', p_sig, n, left(p_old,80); end if;
  perform set_config('fnp.b'||md5(p_sig), replace(d, p_old, p_new), true);
end $f$;
create or replace function private._fnflush(p_sig text) returns void language plpgsql as $f$
begin execute current_setting('fnp.b'||md5(p_sig)); perform set_config('fnp.b'||md5(p_sig), '', true); end $f$;
select private._fnpatch('public.issue_receipt_code(text)', $x$from public.requests where id = p_req;$x$, $x$from public.requests where id = p_req and branch = public.cur_branch();$x$);
select private._fnpatch('public.confirm_receipt(text,text)', $x$from public.requests where id = p_req for update;$x$, $x$from public.requests where id = p_req and branch = public.cur_branch() for update;$x$);
select private._fnpatch('public.approve_staff(text)', $x$if s.status <> 'pending' then$x$, $x$if not (public.cur_branch() = any(s.branches)) then return jsonb_build_object('ok', false, 'reason', 'other_branch'); end if;
  if s.status <> 'pending' then$x$);
select private._fnpatch('public.decide_pending(uuid,boolean)', $x$if s.id is null or s.status <> 'pending' then$x$, $x$if s.id is null or s.status <> 'pending' or not (public.cur_branch() = any(s.branches)) then$x$);
select private._fnpatch('public.staff_contacts()', $x$where s.id = auth.uid()
       or (not s.hidden and$x$, $x$where s.id = auth.uid()
       or (not s.hidden and public.cur_branch() = any(s.branches) and$x$);
select private._fnpatch('public.issue_stock(text,numeric)', $x$from public.inventory where id = p_item for update;$x$, $x$from public.inventory where id = p_item and branch = public.cur_branch() for update;$x$);
select private._fnpatch('public.issue_stock(text,numeric)', $x$where id = p_item;
  return$x$, $x$where id = p_item and branch = public.cur_branch();
  return$x$);
select private._fnpatch('public.att_reopen_day(date,text)', $x$declare rl text := public.my_role();$x$, $x$declare rl text := public.my_role(); b text := public.cur_branch();$x$);
select private._fnpatch('public.att_reopen_day(date,text)', $x$where day = p_day and closed) then$x$, $x$where branch = b and day = p_day and closed) then$x$);
select private._fnpatch('public.att_reopen_day(date,text)', $x$auto = false where day = p_day;$x$, $x$auto = false where branch = b and day = p_day;$x$);
select private._fnpatch('public.att_reopen_day(date,text)', $x$insert into public.att_audit(day, op, reason, by_uid) values (p_day,$x$, $x$insert into public.att_audit(branch, day, op, reason, by_uid) values (b, p_day,$x$);
select private._fnpatch('public.att_set_holiday(date,boolean,text)', $x$declare rl text := public.my_role(); n int := 0;$x$, $x$declare rl text := public.my_role(); n int := 0; b text := public.cur_branch();$x$);
select private._fnpatch('public.att_set_holiday(date,boolean,text)', $x$insert into public.att_days(day, holiday, holiday_note) values (p_day,$x$, $x$insert into public.att_days(branch, day, holiday, holiday_note) values (b, p_day,$x$);
select private._fnpatch('public.att_set_holiday(date,boolean,text)', $x$on conflict (day) do update$x$, $x$on conflict (branch, day) do update$x$);
select private._fnpatch('public.att_set_holiday(date,boolean,text)', $x$where day = p_day and method = 'auto' and status = 'absent';$x$, $x$where branch = b and day = p_day and method = 'auto' and status = 'absent';$x$);
select private._fnpatch('public.att_set_holiday(date,boolean,text)', $x$insert into public.att_audit(day, op, reason, new, by_uid)
    values (p_day,$x$, $x$insert into public.att_audit(branch, day, op, reason, new, by_uid)
    values (b, p_day,$x$);
select private._fnpatch('public.att_close_day(date)', $x$  off jsonb;$x$, $x$  b text := coalesce(nullif(current_setting('att.branch', true), ''), public.cur_branch());
  off jsonb;$x$);
select private._fnpatch('public.att_close_day(date)', $x$if exists (select 1 from public.att_days where day = p_day and closed)$x$, $x$if exists (select 1 from public.att_days where branch = b and day = p_day and closed)$x$);
select private._fnpatch('public.att_close_day(date)', $x$from public.settings where id = 'main';$x$, $x$from public.settings where branch = b and id = 'main';$x$);
select private._fnpatch('public.att_close_day(date)', $x$select holiday into hol from public.att_days where day = p_day;$x$, $x$select holiday into hol from public.att_days where branch = b and day = p_day;$x$);
select private._fnpatch('public.att_close_day(date)', $x$insert into public.attendance(worker_id, day, status, method, by_uid)
      select w.id, p_day, 'absent', 'auto', auth.uid() from public.workers w
      where w.active and$x$, $x$insert into public.attendance(branch, worker_id, day, status, method, by_uid)
      select b, w.id, p_day, 'absent', 'auto', auth.uid() from public.workers w
      where w.branch = b and w.active and$x$);
select private._fnpatch('public.att_close_day(date)', $x$where a.day <= p_day and a.day > p_day - 60$x$, $x$where a.branch = b and a.day <= p_day and a.day > p_day - 60$x$);
select private._fnpatch('public.att_close_day(date)', $x$insert into public.notifications(kind, data)
      select 'att_absent',$x$, $x$insert into public.notifications(branch, kind, data)
      select b, 'att_absent',$x$);
select private._fnpatch('public.att_close_day(date)', $x$insert into public.att_days(day, closed, closed_at, closed_by, auto)
    values (p_day,$x$, $x$insert into public.att_days(branch, day, closed, closed_at, closed_by, auto)
    values (b, p_day,$x$);
select private._fnpatch('public.att_close_day(date)', $x$on conflict (day) do update$x$, $x$on conflict (branch, day) do update$x$);
select private._fnpatch('public.att_close_day(date)', $x$insert into public.att_audit(day, op, new, by_uid)
    values (p_day,$x$, $x$insert into public.att_audit(branch, day, op, new, by_uid)
    values (b, p_day,$x$);
select private._fnpatch('public.att_requests_list()', $x$from public.worker_requests q where q.status$x$, $x$from public.worker_requests q where q.branch = public.cur_branch() and (q.status$x$);
select private._fnpatch('public.att_requests_list()', $x$interval '30 days' order by$x$, $x$interval '30 days') order by$x$);
select private._fnpatch('public.att_request_decide(bigint,boolean,text,uuid)', $x$from public.worker_requests where id = p_id for update;$x$, $x$from public.worker_requests where id = p_id and branch = public.cur_branch() for update;$x$);
select private._fnpatch('public.att_request_decide(bigint,boolean,text,uuid)', $x$active = true where id = p_worker returning$x$, $x$active = true where id = p_worker and branch = r.branch returning$x$);
select private._fnpatch('public.att_request_decide(bigint,boolean,text,uuid)', $x$insert into public.workers(name, phone, origin, trade, site) values (r.name,$x$, $x$insert into public.workers(branch, name, phone, origin, trade, site) values (r.branch, r.name,$x$);
select private._fnpatch('public.att_worker_register(text,text,text,text,text,text)', $x$rid bigint;
begin$x$, $x$rid bigint;
  b text := coalesce((select id from public.branches where id = p_branch), 'mansour');
begin$x$);
select private._fnpatch('public.att_worker_register(text,text,text,text,text,text)', $x$insert into public.worker_requests(name, phone, origin, trade, lang, pin_hash)
    values (nm,$x$, $x$insert into public.worker_requests(branch, name, phone, origin, trade, lang, pin_hash)
    values (b, nm,$x$);
select private._fnpatch('public.att_worker_register(text,text,text,text,text,text)', $x$insert into public.notifications(kind, data) values ('att_join',$x$, $x$insert into public.notifications(branch, kind, data) values (b, 'att_join',$x$);
select private._fnpatch('public.att_worker_register(text,text,text,text,text,text)', $x$p_pin text, p_lang text DEFAULT 'ar'::text)$x$, $x$p_pin text, p_lang text DEFAULT 'ar'::text, p_branch text DEFAULT NULL::text)$x$);
select private._fnpatch('public.trip_scan(text,text,text,text)', $x$where id = p_mid or data->>'plate' = p_mid for update;$x$, $x$where branch = public.cur_branch() and (id = p_mid or data->>'plate' = p_mid) for update;$x$);
select private._fnpatch('public.trip_scan(text,text,text,text)', $x$where id = m.id;$x$, $x$where id = m.id and branch = m.branch;$x$);
select private._fnpatch('public.machine_scan(text,text,jsonb)', $x$where id = p_mid or (p_mid <> '' and data->>'plate' = p_mid) for update;$x$, $x$where branch = public.cur_branch() and (id = p_mid or (p_mid <> '' and data->>'plate' = p_mid)) for update;$x$);
select private._fnpatch('public.machine_scan(text,text,jsonb)', $x$where id = m.id;$x$, $x$where id = m.id and branch = m.branch;$x$);
select private._fnpatch('public.machine_undo(text)', $x$where id = p_mid or (p_mid <> '' and data->>'plate' = p_mid) for update;$x$, $x$where branch = public.cur_branch() and (id = p_mid or (p_mid <> '' and data->>'plate' = p_mid)) for update;$x$);
select private._fnpatch('public.machine_undo(text)', $x$where id = m.id;$x$, $x$where id = m.id and branch = m.branch;$x$);
select private._fnpatch('public.audit_sign(text)', $x$from public.audits where id = p_id for update;$x$, $x$from public.audits where id = p_id and branch = public.cur_branch() for update;$x$);
select private._fnpatch('public.audit_sign(text)', $x$where id = p_id;$x$, $x$where id = p_id and branch = a.branch;$x$);
select private._fnpatch('public.push_targets(text[],uuid[],uuid)', $x$where t.active and (t.role = any(p_roles) or t.id = any(p_uids))$x$, $x$where t.active and ((t.role = any(p_roles) and (p_branch is null or p_branch = any(t.branches))) or t.id = any(p_uids))$x$);
select private._fnpatch('public.push_targets(text[],uuid[],uuid)', $x$push_targets(p_roles text[], p_uids uuid[], p_exclude uuid)$x$, $x$push_targets(p_roles text[], p_uids uuid[], p_exclude uuid, p_branch text)$x$);
select private._fnflush('public.issue_receipt_code(text)');
select private._fnflush('public.confirm_receipt(text,text)');
select private._fnflush('public.approve_staff(text)');
select private._fnflush('public.decide_pending(uuid,boolean)');
select private._fnflush('public.staff_contacts()');
select private._fnflush('public.issue_stock(text,numeric)');
select private._fnflush('public.att_reopen_day(date,text)');
select private._fnflush('public.att_set_holiday(date,boolean,text)');
select private._fnflush('public.att_close_day(date)');
select private._fnflush('public.att_requests_list()');
select private._fnflush('public.att_request_decide(bigint,boolean,text,uuid)');
select private._fnflush('public.att_worker_register(text,text,text,text,text,text)');
select private._fnflush('public.trip_scan(text,text,text,text)');
select private._fnflush('public.machine_scan(text,text,jsonb)');
select private._fnflush('public.machine_undo(text)');
select private._fnflush('public.audit_sign(text)');
select private._fnflush('public.push_targets(text[],uuid[],uuid)');
drop function public.att_worker_register(text,text,text,text,text,text);
revoke all on function public.att_worker_register(text,text,text,text,text,text,text) from public; grant execute on function public.att_worker_register(text,text,text,text,text,text,text) to anon, authenticated;
revoke all on function public.push_targets(text[],uuid[],uuid,text) from public, anon, authenticated;
drop function private._fnpatch(text,text,text); drop function private._fnflush(text);
do $p$ declare r record; u text; c text; b text := '(branch = (select public.cur_branch()))';
begin
  for r in select * from pg_policies where schemaname='public' and tablename = any(array['requests','inventory','invlog','settings','deliveries','machines','invoices','audits','field_photos','receipt_codes','notifications','workers','att_days','attendance','att_audit','worker_requests']) loop
    u := case when r.qual is not null then format(' using (%s and (%s))', b, r.qual) else '' end;
    c := case when r.with_check is not null then format(' with check (%s and (%s))', b, r.with_check) else '' end;
    execute format('alter policy %I on public.%I%s%s', r.policyname, r.tablename, u, c);
  end loop;
end $p$;
-- push: every notification carries the branch it belongs to
CREATE OR REPLACE FUNCTION private.push_enqueue(p_roles text[], p_uids uuid[], p_title text, p_body text, p_tag text)
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'private', 'extensions'
AS $function$
declare c private.push_config; b text := coalesce(nullif(current_setting('app.push_branch', true), ''), public.cur_branch());
  bn text := (select name from public.branches where id = b);
begin
  select * into c from private.push_config where id = 1;
  if c.id is null then return; end if;
  perform net.http_post(
    url := c.fn_url,
    body := jsonb_build_object('roles', to_jsonb(coalesce(p_roles, '{}'::text[])), 'uids', to_jsonb(coalesce(p_uids, '{}'::uuid[])), 'exclude', auth.uid(),
      'title', case when b = 'mansour' then p_title else coalesce(bn || ' · ', '') || p_title end, 'body', p_body, 'tag', p_tag, 'branch', b),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', c.secret)
  );
exception when others then null;
end $function$;

CREATE OR REPLACE FUNCTION private.on_notification()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'private'
AS $function$
declare d jsonb := new.data;
begin
  perform set_config('app.push_branch', new.branch, true);
  if new.kind = 'receipt' then
    perform private.push_enqueue(array['admin1','admin2','clerk','project','owner'], null, 'استلام مكتمل: ' || coalesce(d->>'item',''),
      'السعر ' || coalesce(d->>'total','—') || ' د.ع · المشتري ' || coalesce(d->>'buyer','') || ' · المخزن ' || coalesce(d->>'store',''), 'n'||new.id);
  elsif new.kind = 'staff_pending' then
    perform private.push_enqueue(array['admin1','admin2','project','owner'], null, 'طلب انضمام جديد', coalesce(d->>'name','') || ' يطلب الدخول', 'n'||new.id);
  elsif new.kind = 'att_absent' then
    perform private.push_enqueue(array['project','owner','admin1','admin2'], null, 'غياب متكرر: ' || coalesce(d->>'name',''),
      coalesce(d->>'name','') || ' غائب ' || coalesce(d->>'days','') || ' أيام متتالية بدون إذن' || coalesce(' · ' || nullif(d->>'site',''), ''), 'n'||new.id);
  elsif new.kind = 'att_join' then
    perform private.push_enqueue(array['timekeeper','project','owner'], null, 'عامل جديد يطلب التسجيل',
      coalesce(d->>'name','') || ' · ' || coalesce(d->>'origin','') || ' · ' || coalesce(d->>'trade',''), 'n'||new.id);
  end if;
  perform set_config('app.push_branch', '', true);
  return new;
end $function$;

-- attendance guard / audit: day status is per branch
CREATE OR REPLACE FUNCTION private.att_guard()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'private'
AS $function$
declare
  rl text := public.my_role();
  sys boolean := coalesce(current_setting('att.sys', true), '') = '1';
  today date := private.bg_today();
  d date := case when tg_op = 'DELETE' then old.day else new.day end;
  br text := case when tg_op = 'DELETE' then old.branch else new.branch end;
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
  if tg_op = 'UPDATE' and (new.day <> old.day or new.worker_id <> old.worker_id or new.branch <> old.branch) then
    raise exception 'لا يمكن تغيير العامل أو اليوم';
  end if;
  if d > today then raise exception 'لا يمكن التسجيل ليوم قادم'; end if;
  select closed into is_closed from public.att_days where branch = br and day = d;
  is_closed := coalesce(is_closed, false);

  if tg_op = 'UPDATE' and new.edit_reason is not distinct from old.edit_reason then
    new.edit_reason := null;
  end if;

  if rl = 'timekeeper' then
    if is_closed then raise exception 'هذا اليوم مغلق. التعديل عن طريق مدير المشروع فقط'; end if;
    if d < today - 1 then raise exception 'مراقب الدوام يسجّل لليوم الحالي أو الأمس فقط'; end if;
  elsif is_closed and tg_op <> 'DELETE' and coalesce(btrim(new.edit_reason), '') = '' then
    raise exception 'اليوم مغلق: اكتب سبب التعديل';
  end if;

  if tg_op = 'DELETE' then return old; end if;

  if tg_op = 'INSERT' and not exists (select 1 from public.workers where id = new.worker_id and active and branch = new.branch) then
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
end $function$;

CREATE OR REPLACE FUNCTION private.att_audit_fn()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'private'
AS $function$
declare closed_now boolean;
begin
  if tg_op = 'INSERT' then
    select closed into closed_now from public.att_days where branch = new.branch and day = new.day;
    if not coalesce(closed_now, false) then return null; end if;
    insert into public.att_audit(branch, att_id, worker_id, day, op, new, reason, by_uid)
      values (new.branch, new.id, new.worker_id, new.day, 'insert', to_jsonb(new), new.edit_reason, auth.uid());
  elsif tg_op = 'UPDATE' then
    if to_jsonb(new) - array['updated_at','by_uid','edit_reason'] = to_jsonb(old) - array['updated_at','by_uid','edit_reason'] then
      return null;
    end if;
    insert into public.att_audit(branch, att_id, worker_id, day, op, old, new, reason, by_uid)
      values (new.branch, new.id, new.worker_id, new.day, 'update', to_jsonb(old), to_jsonb(new), new.edit_reason, auth.uid());
  else
    insert into public.att_audit(branch, att_id, worker_id, day, op, old, by_uid)
      values (old.branch, old.id, old.worker_id, old.day, 'delete', to_jsonb(old), auth.uid());
  end if;
  return null;
end $function$;

-- nightly auto-close runs for every branch
CREATE OR REPLACE FUNCTION private.att_cron()
 RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'private'
AS $function$
declare d date; b text;
begin
  perform set_config('att.cron', '1', true);
  for b in select id from public.branches order by sort loop
    perform set_config('att.branch', b, true);
    perform set_config('app.push_branch', b, true);
    foreach d in array array[private.bg_today() - 1, private.bg_today()] loop
      if not exists (select 1 from public.att_days where branch = b and day = d and closed) then
        begin perform public.att_close_day(d); exception when others then raise warning 'att_cron % %: %', b, d, sqlerrm; end;
      end if;
    end loop;
  end loop;
  perform set_config('att.branch', '', true);
  perform set_config('app.push_branch', '', true);
  perform set_config('att.cron', '', true);
end $function$;
