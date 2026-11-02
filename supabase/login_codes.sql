-- 8-digit login code shown under the login barcode (one use, 1 hour)
create table if not exists private.login_codes (
  code text primary key, token text not null, staff_id uuid not null references public.staff(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '1 hour', used_at timestamptz, created_at timestamptz not null default now());
create table if not exists private.login_fails (at timestamptz not null default now());
create or replace function public.login_code_put(p_code text, p_token text, p_staff uuid) returns boolean
language plpgsql security definer set search_path = public, private as $$
begin
  delete from private.login_codes where expires_at < now() - interval '1 day' or (staff_id = p_staff and used_at is null);
  insert into private.login_codes(code, token, staff_id) values (p_code, p_token, p_staff);
  return true;
exception when unique_violation then return false;
end $$;
revoke all on function public.login_code_put(text,text,uuid) from public, anon, authenticated;
grant execute on function public.login_code_put(text,text,uuid) to service_role;
create or replace function public.login_code_exchange(p_code text) returns text
language plpgsql security definer set search_path = public, private as $$
declare c text := private.norm_digits(p_code); r private.login_codes;
begin
  if (select count(*) from private.login_fails where at > now() - interval '10 minutes') >= 30 then raise exception 'E_BUSY'; end if;
  select * into r from private.login_codes where code = c for update;
  if r.code is null or r.used_at is not null or r.expires_at < now() then
    insert into private.login_fails default values;
    delete from private.login_fails where at < now() - interval '1 hour';
    perform pg_sleep(0.5);
    return null;
  end if;
  update private.login_codes set used_at = now() where code = c;
  return r.token;
end $$;
revoke all on function public.login_code_exchange(text) from public;
grant execute on function public.login_code_exchange(text) to anon, authenticated;
