-- موظف مبيعات (sales_staff): كادر مسؤول المبيعات — يشوف الشقق والحجوزات والدفعات، يسجل حجز/إيجار/دفعة،
-- وما يكدر يعدّل أو يلغي عقد، ولا يغيّر بيانات/أسعار الوحدات، ولا يعدّل أو يحذف خدمة.
alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check check (role = any (array['owner','machines','elec','mech','store','mstore','project','admin1','admin2','purchase','purchase2','keeper','operator','mechanic','fueler','supply','receiver','elec_tech','mech_tech','buyer','clerk','timekeeper','engineer','contractor','guard','driver','foreman','accountant','sales','sales_staff']));

create or replace function public.can_write() returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select role not in ('clerk','engineer','contractor','accountant','sales','sales_staff') from public.staff where id = auth.uid() and active), false) $$;
create or replace function public.sees_sales() returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select role in ('sales','sales_staff','owner','project','accountant','admin1','admin2') from public.staff where id = auth.uid() and active), false) $$;
create or replace function public.writes_sales() returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select role in ('sales','sales_staff','owner') from public.staff where id = auth.uid() and active), false) $$;
create or replace function public.manages_sales() returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce((select role in ('sales','owner') from public.staff where id = auth.uid() and active), false) $$;
grant execute on function public.manages_sales() to authenticated;

-- الوحدات: الإضافة للمسؤول؛ الموظف يغيّر الحالة بس (عند الحجز/التأجير)
alter policy u_ins on public.units with check (branch = (select public.cur_branch()) and public.manages_sales());
create or replace function private.units_staff_guard() returns trigger language plpgsql security definer set search_path to 'public','private' as $$
begin
  if public.my_role() = 'sales_staff' and (new.code,new.kind,new.building,new.floor,new.apt,new.area,new.price_m,new.share,new.notes,new.branch)
     is distinct from (old.code,old.kind,old.building,old.floor,old.apt,old.area,old.price_m,old.share,old.notes,old.branch) then
    raise exception 'تعديل بيانات الوحدة من صلاحية مسؤول المبيعات';
  end if;
  return new;
end $$;
drop trigger if exists units_staff_guard on public.units;
create trigger units_staff_guard before update on public.units for each row execute function private.units_staff_guard();

-- العقود: الموظف يسجل جديد بس؛ التعديل والإلغاء للمسؤول
alter policy k_upd on public.contracts using (branch = (select public.cur_branch()) and public.manages_sales()) with check (branch = (select public.cur_branch()) and public.manages_sales());
-- الخدمات: الموظف يضيف؛ التعديل والحذف للمسؤول
alter policy svc_upd on public.svc using (branch = (select public.cur_branch()) and public.manages_sales()) with check (branch = (select public.cur_branch()) and public.manages_sales());
alter policy svc_del on public.svc using (branch = (select public.cur_branch()) and public.manages_sales());

-- الصندوق: نفس صلاحيات مسؤول المبيعات بالواردات (مبيعات/إيجارات/خدمات)
alter policy cash_read on public.cash using (branch = (select public.cur_branch()) and (public.sees_cash() or (public.my_role() in ('sales','sales_staff') and kind = 'in' and category = any (array['إيرادات مبيعات','إيجارات','خدمات']))));
alter policy cash_ins on public.cash with check (branch = (select public.cur_branch()) and by_uid = auth.uid() and (public.writes_cash() or (public.my_role() in ('sales','sales_staff') and kind = 'in' and category = any (array['إيرادات مبيعات','إيجارات','خدمات']))));
alter policy cash_upd on public.cash using (branch = (select public.cur_branch()) and (public.writes_cash() or (public.my_role() in ('sales','sales_staff') and by_uid = auth.uid())))
  with check (branch = (select public.cur_branch()) and (public.writes_cash() or (public.my_role() in ('sales','sales_staff') and kind = 'in' and category = any (array['إيرادات مبيعات','إيجارات','خدمات']))));
alter policy inv_i on public.invoices with check ((branch = (select public.cur_branch())) and (created_by = auth.uid()) and public.sees_wh(wh) and public.my_role() not in ('accountant','sales','sales_staff'));
