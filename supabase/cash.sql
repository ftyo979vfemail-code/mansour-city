-- =====================================================================
-- مسؤول الحسابات + الصندوق (الواردات والمصروفات) — per branch
-- =====================================================================
alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check check (role = any (array[
  'owner','machines','elec','mech','store','mstore','project','admin1','admin2','purchase','purchase2','keeper','operator','mechanic','fueler',
  'supply','receiver','elec_tech','mech_tech','buyer','clerk','timekeeper','engineer','contractor','guard','driver','foreman','accountant']));

-- the accountant reads the purchasing side but does not move requests/stock
create or replace function public.can_write() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role not in ('clerk','engineer','contractor','accountant') from public.staff where id = auth.uid() and active), false) $$;
create or replace function public.sees_wh(p_wh text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case
    when role in ('owner','project','admin1','admin2','accountant') then true
    when p_wh = 'main' then role in ('store','receiver')
    when p_wh = 'mach' then role in ('mstore','keeper','machines')
    else false end from public.staff where id = auth.uid() and active), false) $$;
alter policy inv_i on public.invoices with check ((branch = (select public.cur_branch())) and (created_by = auth.uid()) and sees_wh(wh) and public.my_role() <> 'accountant');

create table if not exists public.cash (
  id uuid primary key default gen_random_uuid(),
  branch text not null default public.cur_branch() references public.branches(id),
  day date not null default (now() at time zone 'Asia/Baghdad')::date,
  kind text not null check (kind in ('in','out')),
  amount numeric(16,0) not null check (amount > 0),
  category text not null default 'أخرى',
  party text, note text, ref text, attach text,
  usd numeric(14,2), rate numeric(10,2),
  by_uid uuid default auth.uid() references public.staff(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  voided boolean not null default false, void_reason text, voided_by uuid, voided_at timestamptz,
  log jsonb not null default '[]'::jsonb
);
create index if not exists cash_branch_day on public.cash (branch, day desc);
alter table public.cash enable row level security;

create or replace function public.sees_cash() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('accountant','owner','project','admin1','admin2') from public.staff where id = auth.uid() and active), false) $$;
create or replace function public.writes_cash() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('accountant','owner') from public.staff where id = auth.uid() and active), false) $$;
revoke all on function public.sees_cash() from public; grant execute on function public.sees_cash() to authenticated;
revoke all on function public.writes_cash() from public; grant execute on function public.writes_cash() to authenticated;

create policy cash_read on public.cash for select to authenticated using (branch = (select public.cur_branch()) and public.sees_cash());
create policy cash_ins on public.cash for insert to authenticated with check (branch = (select public.cur_branch()) and public.writes_cash() and by_uid = auth.uid());
create policy cash_upd on public.cash for update to authenticated using (branch = (select public.cur_branch()) and public.writes_cash()) with check (branch = (select public.cur_branch()) and public.writes_cash());
-- no delete: a wrong entry is voided with a reason, so the record stays

-- edits: the accountant can change own entries for 48 hours, then only voiding; the owner any time. every change is logged.
create or replace function private.cash_guard() returns trigger
language plpgsql security definer set search_path = public, private as $$
declare rl text := public.my_role(); ms bigint := (extract(epoch from clock_timestamp())*1000)::bigint; ch text[] := '{}';
begin
  if tg_op = 'INSERT' then
    new.created_at := now(); new.updated_at := now(); new.by_uid := auth.uid(); new.voided := false; new.void_reason := null; new.voided_by := null; new.voided_at := null;
    new.log := jsonb_build_array(jsonb_build_object('t', ms, 'uid', auth.uid(), 'a', 'سجّل الحركة'));
    return new;
  end if;
  if new.branch <> old.branch or new.by_uid is distinct from old.by_uid or new.created_at <> old.created_at then raise exception 'لا يمكن تغيير هذه البيانات'; end if;
  if old.voided and rl <> 'owner' then raise exception 'الحركة ملغاة ولا تتعدل'; end if;
  if new.voided and not old.voided then
    if coalesce(btrim(new.void_reason),'') = '' then raise exception 'اكتب سبب الإلغاء'; end if;
    new.voided_by := auth.uid(); new.voided_at := now();
    new.log := old.log || jsonb_build_array(jsonb_build_object('t', ms, 'uid', auth.uid(), 'a', 'ألغى الحركة', 'note', new.void_reason));
    new.kind := old.kind; new.amount := old.amount; new.day := old.day; new.category := old.category; new.party := old.party; new.note := old.note; new.ref := old.ref; new.usd := old.usd; new.rate := old.rate;
    new.updated_at := now(); return new;
  end if;
  if not new.voided and old.voided then
    if rl <> 'owner' then raise exception 'إرجاع الحركة من صلاحية المالك'; end if;
    new.void_reason := null; new.voided_by := null; new.voided_at := null;
    new.log := old.log || jsonb_build_array(jsonb_build_object('t', ms, 'uid', auth.uid(), 'a', 'أرجع الحركة الملغاة'));
    new.updated_at := now(); return new;
  end if;
  if rl <> 'owner' then
    if old.by_uid is distinct from auth.uid() then raise exception 'تكدر تعدّل بس الحركات اللي انت سجلتها'; end if;
    if old.created_at < now() - interval '48 hours' then raise exception 'فات وقت التعديل (48 ساعة). ألغِ الحركة وسجّلها من جديد'; end if;
  end if;
  if new.amount <> old.amount then ch := ch || ('المبلغ ' || old.amount || ' ← ' || new.amount); end if;
  if new.kind <> old.kind then ch := ch || 'النوع'::text; end if;
  if new.day <> old.day then ch := ch || ('التاريخ ' || old.day || ' ← ' || new.day); end if;
  if new.category <> old.category then ch := ch || ('الفئة ' || old.category || ' ← ' || new.category); end if;
  if new.note is distinct from old.note or new.party is distinct from old.party or new.ref is distinct from old.ref then ch := ch || 'البيان'::text; end if;
  new.log := old.log || jsonb_build_array(jsonb_build_object('t', ms, 'uid', auth.uid(), 'a', 'عدّل الحركة', 'note', array_to_string(ch, ' · ')));
  new.voided := old.voided; new.updated_at := now();
  return new;
end $$;
create trigger cash_guard before insert or update on public.cash for each row execute function private.cash_guard();
alter publication supabase_realtime add table public.cash;
