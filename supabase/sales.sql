-- مسؤول المبيعات: يسجّل ويشوف بس استلامات المبيعات (وارد · إيرادات مبيعات) بصندوق موقعه
alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check check (role = any (array[
  'owner','machines','elec','mech','store','mstore','project','admin1','admin2','purchase','purchase2','keeper','operator','mechanic','fueler',
  'supply','receiver','elec_tech','mech_tech','buyer','clerk','timekeeper','engineer','contractor','guard','driver','foreman','accountant','sales']));
create or replace function public.can_write() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role not in ('clerk','engineer','contractor','accountant','sales') from public.staff where id = auth.uid() and active), false) $$;
alter policy cash_read on public.cash using (branch = (select public.cur_branch()) and (public.sees_cash() or (public.my_role() = 'sales' and kind = 'in' and category = 'إيرادات مبيعات')));
alter policy cash_ins on public.cash with check (branch = (select public.cur_branch()) and by_uid = auth.uid() and (public.writes_cash() or (public.my_role() = 'sales' and kind = 'in' and category = 'إيرادات مبيعات')));
alter policy cash_upd on public.cash using (branch = (select public.cur_branch()) and (public.writes_cash() or (public.my_role() = 'sales' and by_uid = auth.uid())))
  with check (branch = (select public.cur_branch()) and (public.writes_cash() or (public.my_role() = 'sales' and kind = 'in' and category = 'إيرادات مبيعات')));
alter policy inv_i on public.invoices with check ((branch = (select public.cur_branch())) and (created_by = auth.uid()) and sees_wh(wh) and public.my_role() not in ('accountant','sales'));
