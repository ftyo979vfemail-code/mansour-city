-- Mansour City stores & purchasing — schema
create table if not exists public.staff (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  full_name text,
  role text not null check (role in ('owner','machines','elec','mech','store','project','admin1','admin2','purchase','purchase2')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.requests (id text primary key, data jsonb not null, updated_at timestamptz not null default now());
create table if not exists public.inventory (id text primary key, data jsonb not null, updated_at timestamptz not null default now());
create table if not exists public.invlog (id bigserial primary key, data jsonb not null, created_at timestamptz not null default now());
create table if not exists public.settings (id text primary key, data jsonb not null);

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.staff where id = auth.uid() and active
$$;
revoke all on function public.my_role() from public;
grant execute on function public.my_role() to authenticated;

-- writers: every active staff member except the two monitoring admins
create or replace function public.can_write() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role not in ('admin1','admin2') from public.staff where id = auth.uid() and active), false)
$$;
revoke all on function public.can_write() from public;
grant execute on function public.can_write() to authenticated;

alter table public.staff enable row level security;
alter table public.requests enable row level security;
alter table public.inventory enable row level security;
alter table public.invlog enable row level security;
alter table public.settings enable row level security;

create policy staff_read on public.staff for select to authenticated using (public.my_role() is not null or id = auth.uid());

create policy req_read on public.requests for select to authenticated using (public.my_role() is not null);
create policy req_ins on public.requests for insert to authenticated with check (public.can_write());
create policy req_upd on public.requests for update to authenticated using (public.can_write()) with check (public.can_write());
create policy req_del on public.requests for delete to authenticated using (public.my_role() = 'owner');

create policy inv_read on public.inventory for select to authenticated using (public.my_role() is not null);
create policy inv_ins on public.inventory for insert to authenticated with check (public.can_write());
create policy inv_upd on public.inventory for update to authenticated using (public.can_write()) with check (public.can_write());
create policy inv_del on public.inventory for delete to authenticated using (public.my_role() in ('owner','store'));

create policy log_read on public.invlog for select to authenticated using (public.my_role() is not null);
create policy log_ins on public.invlog for insert to authenticated with check (public.can_write());

create policy set_read on public.settings for select to authenticated using (public.my_role() is not null);
create policy set_ins on public.settings for insert to authenticated with check (public.can_write());
create policy set_upd on public.settings for update to authenticated using (public.can_write()) with check (public.can_write());

-- the request log can only grow: no client may delete or rewrite earlier history entries
create or replace function public.keep_history() returns trigger
language plpgsql set search_path = public as $$
declare old_n int; new_n int;
begin
  old_n := coalesce(jsonb_array_length(old.data->'log'),0);
  new_n := coalesce(jsonb_array_length(new.data->'log'),0);
  if new_n < old_n or (old_n > 0 and (new.data->'log') -> 0 is distinct from (old.data->'log') -> 0)
     or (old_n > 0 and (new.data->'log') -> (old_n-1) is distinct from (old.data->'log') -> (old_n-1)) then
    raise exception 'history is append-only';
  end if;
  return new;
end $$;
create trigger requests_keep_history before update on public.requests for each row execute function public.keep_history();

-- storage for photos and invoices (private)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('files','files', false, 10485760, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy files_read on storage.objects for select to authenticated using (bucket_id = 'files' and public.my_role() is not null);
create policy files_ins on storage.objects for insert to authenticated with check (bucket_id = 'files' and public.can_write());

-- realtime
alter publication supabase_realtime add table public.requests, public.inventory, public.invlog, public.settings, public.staff;
