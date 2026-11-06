-- Customer accounts: sign up with name + phone + password, log in, order, see own orders.
-- Ordering now needs an account, so every order is tied to a known customer.

create table if not exists public.taxi_customers (
  id bigserial primary key,
  name text not null,
  phone text not null unique,
  pass_hash text not null,
  failed int not null default 0,
  locked_until timestamptz,
  blocked boolean not null default false,
  created_at timestamptz not null default now(),
  last_login timestamptz
);

create table if not exists public.taxi_customer_sessions (
  token uuid primary key default gen_random_uuid(),
  customer_id bigint not null references public.taxi_customers(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_used timestamptz not null default now()
);
create index if not exists taxi_customer_sessions_c on public.taxi_customer_sessions(customer_id);

alter table public.taxi_trips add column if not exists customer_id bigint references public.taxi_customers(id) on delete set null;

-- Iraqi mobile numbers: 07XXXXXXXXX (also accepts +964 / 964 / 7XXXXXXXXX)
create or replace function public.taxi_norm_phone(p text) returns text language sql immutable as $$
  select case
    when d ~ '^9647\d{9}$' then '0' || substr(d,4)
    when d ~ '^07\d{9}$' then d
    when d ~ '^7\d{9}$' then '0' || d
    else null end
  from (select regexp_replace(coalesce(p,''),'\D','','g') as d) x;
$$;

create or replace function public.taxi_session_customer(p_token uuid) returns public.taxi_customers
language plpgsql security definer set search_path = public as $$
declare c taxi_customers;
begin
  select cu.* into c from taxi_customer_sessions s join taxi_customers cu on cu.id = s.customer_id
   where s.token = p_token and s.last_used > now() - interval '180 days';
  if c.id is null then raise exception 'سجّل دخولك من جديد'; end if;
  if c.blocked then raise exception 'حسابك موقوف، راجع الإدارة'; end if;
  update taxi_customer_sessions set last_used = now() where token = p_token;
  return c;
end $$;

create or replace function public.taxi_customer_signup(p jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare ph text := taxi_norm_phone(p->>'phone'); nm text := left(trim(coalesce(p->>'name','')),60);
        pw text := coalesce(p->>'password',''); c taxi_customers; tok uuid;
begin
  if length(nm) < 2 then raise exception 'اكتب اسمك'; end if;
  if ph is null then raise exception 'اكتب رقم موبايل عراقي صحيح، مثل 07801234567'; end if;
  if length(pw) < 6 then raise exception 'كلمة السر لازم 6 أحرف أو أكثر'; end if;
  if exists (select 1 from taxi_customers where phone = ph) then raise exception 'هذا الرقم عنده حساب، سجّل دخول'; end if;
  if (select count(*) from taxi_customers where created_at > now() - interval '10 minutes') >= 40 then
    raise exception 'حاول بعد شوية'; end if;
  insert into taxi_customers(name, phone, pass_hash, last_login) values (nm, ph, crypt(pw, gen_salt('bf')), now()) returning * into c;
  insert into taxi_customer_sessions(customer_id) values (c.id) returning token into tok;
  return json_build_object('token', tok, 'name', c.name, 'phone', c.phone);
end $$;

create or replace function public.taxi_customer_login(p jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare ph text := taxi_norm_phone(p->>'phone'); c taxi_customers; tok uuid;
begin
  select * into c from taxi_customers where phone = ph;
  if c.id is null then raise exception 'الرقم أو كلمة السر غلط'; end if;
  if c.blocked then raise exception 'حسابك موقوف، راجع الإدارة'; end if;
  if c.locked_until is not null and c.locked_until > now() then raise exception 'محاولات كثيرة، حاول بعد ربع ساعة'; end if;
  if crypt(coalesce(p->>'password',''), c.pass_hash) <> c.pass_hash then
    update taxi_customers set failed = case when failed + 1 >= 5 then 0 else failed + 1 end,
      locked_until = case when failed + 1 >= 5 then now() + interval '15 minutes' else locked_until end
      where id = c.id;
    -- returned, not raised: raising would roll back the failed-attempt counter
    return json_build_object('error', 'الرقم أو كلمة السر غلط');
  end if;
  update taxi_customers set failed = 0, locked_until = null, last_login = now() where id = c.id;
  delete from taxi_customer_sessions where customer_id = c.id and last_used < now() - interval '180 days';
  insert into taxi_customer_sessions(customer_id) values (c.id) returning token into tok;
  return json_build_object('token', tok, 'name', c.name, 'phone', c.phone);
end $$;

create or replace function public.taxi_customer_logout(p_token uuid) returns void
language sql security definer set search_path = public as $$
  delete from taxi_customer_sessions where token = p_token;
$$;

-- profile + own orders (no prices shown to customers)
create or replace function public.taxi_customer_me(p_token uuid) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_customers := taxi_session_customer(p_token);
begin
  return json_build_object('name', c.name, 'phone', c.phone,
    'open', (select request_token from taxi_trips where customer_id=c.id and status in ('requested','assigned','accepted','started','rejected')
             order by id desc limit 1),
    'trips', coalesce((select json_agg(x order by x.created_at desc) from (
        select t.request_token as token, t.status, t.created_at, t.pickup, (select name from taxi_zones z where z.id=t.zone_id) as zone
        from taxi_trips t where t.customer_id=c.id order by t.id desc limit 20) x), '[]'::json));
end $$;

create or replace function public.taxi_customer_order(p_token uuid, p jsonb) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_customers := taxi_session_customer(p_token); z taxi_zones; tr taxi_trips; lat double precision; lng double precision;
begin
  if coalesce(trim(p->>'pickup'),'') = '' and p->>'lat' is null then raise exception 'اكتب وين إنت (العمارة أو البوابة)'; end if;
  select * into z from taxi_zones where id = nullif(p->>'zone_id','')::int and active;
  if z.id is null then raise exception 'اختار المنطقة اللي رايح إلها'; end if;
  if exists (select 1 from taxi_trips where customer_id=c.id and status in ('requested','assigned','accepted','started')) then
    raise exception 'عندك طلب مفتوح، انتظر السائق أو ألغِه أولًا'; end if;
  if (select count(*) from taxi_trips where status='requested' and created_at > now() - interval '10 minutes') >= 30 then
    raise exception 'الطلبات كثيرة هسه، حاول بعد دقائق'; end if;
  lat := nullif(p->>'lat','')::double precision; lng := nullif(p->>'lng','')::double precision;
  if lat is not null and (lat not between -90 and 90 or lng not between -180 and 180) then lat := null; lng := null; end if;
  insert into taxi_trips(car_id,source,status,customer_id,customer_phone,customer_name,pickup,dropoff,note,zone_id,fare,request_token,pickup_lat,pickup_lng)
  values (null,'customer','requested',c.id,c.phone,c.name,left(coalesce(trim(p->>'pickup'),''),120),z.name,
          left(coalesce(p->>'note',''),200),z.id,taxi_zone_price(z),gen_random_uuid(),lat,lng)
  returning * into tr;
  insert into taxi_events(car_id,kind,info) values (null,'request', c.name || ': ' || coalesce(nullif(tr.pickup,''),'موقع على الخريطة') || ' ← ' || z.name);
  return json_build_object('token', tr.request_token);
end $$;

-- admin: list customers, block/unblock
create or replace function public.taxi_admin_customers(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select cu.id, cu.name, cu.phone, cu.blocked, cu.created_at, cu.last_login,
      (select count(*) from taxi_trips t where t.customer_id=cu.id and t.status='done') as trips,
      (select count(*) from taxi_trips t where t.customer_id=cu.id and t.status='cancelled' and t.cancel_reason='ألغاه الزبون') as cancels
    from taxi_customers cu) x), '[]'::json);
end $$;

create or replace function public.taxi_admin_customer_block(p_pin text, p_id bigint, p_block boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  update taxi_customers set blocked = p_block where id = p_id;
  if p_block then delete from taxi_customer_sessions where customer_id = p_id; end if;
end $$;
