-- Customers register their home address in the compound (building, floor, apartment).
alter table public.taxi_customers
  add column if not exists building text not null default '',
  add column if not exists floor text not null default '',
  add column if not exists apartment text not null default '';
-- (function bodies identical to the Supabase migration "taxi_customer_address")
