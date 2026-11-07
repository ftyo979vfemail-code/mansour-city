-- Extra managers: each has his own name + PIN and full rights. Only the owner (main PIN) can add/remove them.
create table if not exists public.taxi_admins (
  id serial primary key,
  name text not null,
  pin_hash text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  last_seen timestamptz
);
alter table public.taxi_admins enable row level security;
revoke all on public.taxi_admins from anon, authenticated;
alter table public.taxi_trips add column if not exists dispatched_by text;

-- who owns this PIN: id 0 = the owner, otherwise taxi_admins.id
create or replace function public.taxi_admin_who(p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare h text; a taxi_admins;
begin
  select v into h from taxi_settings where k='admin_pin';
  if h is not null and crypt(coalesce(p_pin,''), h) = h then return json_build_object('id',0,'name','المدير'); end if;
  for a in select * from taxi_admins where active loop
    if crypt(coalesce(p_pin,''), a.pin_hash) = a.pin_hash then
      update taxi_admins set last_seen = now() where id = a.id and (last_seen is null or last_seen < now() - interval '1 minute');
      return json_build_object('id',a.id,'name',a.name);
    end if;
  end loop;
  raise exception 'رمز المدير غير صحيح';
end $$;

create or replace function public.taxi_chk(p_pin text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin perform taxi_admin_who(p_pin); end $$;

create or replace function public.taxi_pin_taken(p_new text, p_except int) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare h text; a taxi_admins;
begin
  if p_except <> 0 then
    select v into h from taxi_settings where k='admin_pin';
    if h is not null and crypt(p_new, h) = h then return true; end if;
  end if;
  for a in select * from taxi_admins where id <> p_except loop
    if crypt(p_new, a.pin_hash) = a.pin_hash then return true; end if;
  end loop;
  return false;
end $$;

create or replace function public.taxi_admin_me(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare w json := taxi_admin_who(p_pin);
begin
  return json_build_object('id', (w->>'id')::int, 'name', w->>'name', 'owner', (w->>'id')::int = 0);
end $$;

-- each manager changes his own PIN; the owner changes the main PIN
create or replace function public.taxi_admin_setpin(p_pin text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me int := (taxi_admin_who(p_pin)->>'id')::int;
begin
  if coalesce(p_new,'') !~ '^\d{4,12}$' then raise exception 'الرمز لازم 4 أرقام أو أكثر'; end if;
  if taxi_pin_taken(p_new, me) then raise exception 'هذا الرمز مستخدم، اختار غيره'; end if;
  if me = 0 then update taxi_settings set v=crypt(p_new, gen_salt('bf')) where k='admin_pin';
  else update taxi_admins set pin_hash=crypt(p_new, gen_salt('bf')) where id = me; end if;
end $$;

create or replace function public.taxi_admin_admins(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(json_build_object('id',id,'name',name,'active',active,'created_at',created_at,'last_seen',last_seen) order by id)
                   from taxi_admins), '[]'::json);
end $$;

-- owner only: add | toggle | delete | reset
create or replace function public.taxi_admin_admin_save(p_pin text, p_action text, p jsonb) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare me int := (taxi_admin_who(p_pin)->>'id')::int; nm text := left(trim(coalesce(p->>'name','')),40);
        pn text := coalesce(p->>'pin',''); aid int := nullif(p->>'id','')::int;
begin
  if me <> 0 then raise exception 'بس المدير الرئيسي يگدر يضيف أو يشيل مسؤولين'; end if;
  if p_action = 'add' then
    if length(nm) < 2 then raise exception 'اكتب اسم المسؤول'; end if;
    if pn !~ '^\d{4,12}$' then raise exception 'الرمز لازم 4 أرقام أو أكثر'; end if;
    if taxi_pin_taken(pn, -1) then raise exception 'هذا الرمز مستخدم، اختار غيره'; end if;
    if (select count(*) from taxi_admins) >= 20 then raise exception 'وصلت الحد'; end if;
    insert into taxi_admins(name, pin_hash) values (nm, crypt(pn, gen_salt('bf')));
  elsif p_action = 'toggle' then
    update taxi_admins set active = not active where id = aid;
  elsif p_action = 'delete' then
    delete from taxi_admins where id = aid;
  elsif p_action = 'reset' then
    if pn !~ '^\d{4,12}$' then raise exception 'الرمز لازم 4 أرقام أو أكثر'; end if;
    if taxi_pin_taken(pn, aid) then raise exception 'هذا الرمز مستخدم، اختار غيره'; end if;
    update taxi_admins set pin_hash = crypt(pn, gen_salt('bf')) where id = aid;
  else raise exception 'إجراء غير معروف'; end if;
end $$;

-- record which manager sent each trip
create or replace function public.taxi_admin_trip_action(p_pin text, p_id bigint, p_action text, p_car uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare tr taxi_trips; who text := taxi_admin_who(p_pin)->>'name';
begin
  select * into tr from taxi_trips where id=p_id;
  if tr.id is null then raise exception 'السفرة غير موجودة'; end if;
  if p_action = 'cancel' then
    if tr.status not in ('requested','assigned','accepted','started','rejected') then raise exception 'السفرة منتهية'; end if;
    update taxi_trips set status='cancelled', ended_at=now(), cancel_reason='ألغاها ' || who where id=p_id;
  elsif p_action = 'reassign' then
    if p_car is null then raise exception 'اختر السائق'; end if;
    if exists (select 1 from taxi_trips where car_id=p_car and status in ('assigned','accepted','started') and id<>p_id) then
      raise exception 'هذا السائق عنده سفرة مفتوحة'; end if;
    if tr.status in ('requested','assigned','rejected') then
      update taxi_trips set car_id=p_car, status='assigned', accepted_at=null, ended_at=null, cancel_reason=null, dispatched_by=who where id=p_id;
    else raise exception 'ما ينفع تحويل سفرة بدأت'; end if;
  else raise exception 'إجراء غير معروف'; end if;
end $$;

create or replace function public.taxi_admin_trips(p_pin text, p_day date default null) returns json
language plpgsql security definer set search_path = public as $$
declare d date := coalesce(p_day, (now() at time zone 'Asia/Baghdad')::date);
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select t.id, t.car_id, t.source, t.status, t.customer_phone, t.customer_name, t.pickup, t.dropoff, t.note, t.fare, t.km,
           t.created_at, t.accepted_at, t.started_at, t.ended_at, t.cancel_reason, t.zone_id, t.pickup_lat, t.pickup_lng, t.points_used,
           t.dispatched_by, c.plate, c.driver_name
    from taxi_trips t left join taxi_cars c on c.id=t.car_id
    where (t.created_at at time zone 'Asia/Baghdad')::date = d
       or t.status in ('requested','assigned','accepted','started')
       or (t.status = 'rejected' and t.customer_id is not null and t.created_at > now() - interval '1 day')) x), '[]'::json);
end $$;

revoke all on function public.taxi_admin_who(text), public.taxi_pin_taken(text,int) from public, anon, authenticated;
grant execute on function public.taxi_admin_me(text), public.taxi_admin_admins(text), public.taxi_admin_admin_save(text,text,jsonb) to anon;
