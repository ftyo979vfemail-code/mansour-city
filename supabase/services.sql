-- الخدمات: صيانة، كهرباء، إنترنت، ماء… على كل ساكن (عقد بيع أو إيجار)
create table if not exists public.svc (
  id uuid primary key default gen_random_uuid(),
  branch text not null default public.cur_branch(),
  contract_id uuid not null references public.contracts(id) on delete cascade,
  name text not null check (length(btrim(name)) >= 2),
  kind text not null default 'monthly' check (kind in ('monthly','once')),
  amount numeric not null check (amount > 0),
  start_month date not null,
  end_month date,
  note text,
  by_uid uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index if not exists svc_contract on public.svc(contract_id);
create index if not exists svc_branch on public.svc(branch);
alter table public.svc enable row level security;
create policy svc_read on public.svc for select to authenticated using (branch = (select public.cur_branch()) and public.sees_sales());
create policy svc_ins on public.svc for insert to authenticated with check (branch = (select public.cur_branch()) and public.writes_sales());
create policy svc_upd on public.svc for update to authenticated using (branch = (select public.cur_branch()) and public.writes_sales()) with check (branch = (select public.cur_branch()) and public.writes_sales());
create policy svc_del on public.svc for delete to authenticated using (branch = (select public.cur_branch()) and public.writes_sales());
grant select, insert, update, delete on public.svc to authenticated;

-- كل وصل خدمة يعرف أي خدمة يسدد
alter table public.cash add column if not exists svc text;

-- مسؤول المبيعات يسجل ويشوف واردات «خدمات» أيضاً
alter policy cash_read on public.cash using (branch = (select public.cur_branch()) and (public.sees_cash() or (public.my_role() = 'sales' and kind = 'in' and category = any (array['إيرادات مبيعات','إيجارات','خدمات']))));
alter policy cash_ins on public.cash with check (branch = (select public.cur_branch()) and by_uid = auth.uid() and (public.writes_cash() or (public.my_role() = 'sales' and kind = 'in' and category = any (array['إيرادات مبيعات','إيجارات','خدمات']))));
alter policy cash_upd on public.cash using (branch = (select public.cur_branch()) and (public.writes_cash() or (public.my_role() = 'sales' and by_uid = auth.uid())))
  with check (branch = (select public.cur_branch()) and (public.writes_cash() or (public.my_role() = 'sales' and kind = 'in' and category = any (array['إيرادات مبيعات','إيجارات','خدمات']))));
