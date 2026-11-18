-- ترحيل: sales_reminders — سجل التذكيرات المشتركة لكل الموظفين (بدل localStorage)
create table if not exists public.sales_remind(id uuid primary key default gen_random_uuid(), branch text not null default public.cur_branch(),
  contract_id uuid not null references public.contracts(id) on delete cascade, at timestamptz not null default now(), by_uid uuid default auth.uid(),
  channel text default 'wa', amount numeric, note text);
-- RLS: قراءة sees_sales · إضافة writes_sales باسمك · حذف manages_sales أو صاحب التذكير
