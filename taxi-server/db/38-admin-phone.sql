-- 38: taxi_admins.phone (shown in the managers list). Added manager "حسام صالح" (perms 'drivers', like حمزة) on 2026-11-09.
alter table public.taxi_admins add column if not exists phone text not null default '';
-- taxi_admin_admins now also returns phone (and no longer calls taxi_chk twice).
