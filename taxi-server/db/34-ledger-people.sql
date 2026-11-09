-- 34: people who aren't drivers (staff like حمزة) can have expenses and advances too.
-- They appear only in the expenses/advances area (not on the map, trips, inventory or driver lists).

create table if not exists public.taxi_ledger_people (
  id serial primary key,
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now());
alter table public.taxi_ledger_people enable row level security;
insert into public.taxi_ledger_people(name) values ('حمزة') on conflict (name) do nothing;

alter table public.taxi_ledger alter column car_id drop not null;
alter table public.taxi_ledger add column if not exists person_id int references public.taxi_ledger_people(id);
alter table public.taxi_ledger drop constraint if exists taxi_ledger_who_chk;
alter table public.taxi_ledger add constraint taxi_ledger_who_chk check ((car_id is null) <> (person_id is null));

create or replace function public.taxi_admin_ledger_people(p_pin text)
 returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(json_build_object('id', id, 'name', name,
      'advances_total', (select coalesce(sum(amount),0) from taxi_ledger l where l.person_id = p.id and l.kind='advance'),
      'expenses_total', (select coalesce(sum(amount),0) from taxi_ledger l where l.person_id = p.id and l.kind='expense')) order by id)
    from taxi_ledger_people p where active), '[]'::json);
end $$;

create or replace function public.taxi_admin_ledger_save(p_pin text, p jsonb)
 returns json language plpgsql security definer set search_path to 'public' as $function$
declare a int := nullif(regexp_replace(coalesce(p->>'amount',''),'\D','','g'),'')::int; d date := coalesce(nullif(p->>'day','')::date, (now() at time zone 'Asia/Baghdad')::date);
        k text := p->>'kind'; lid bigint := nullif(p->>'id','')::bigint; r taxi_ledger;
        car uuid := nullif(p->>'car_id','')::uuid; per int := nullif(p->>'person_id','')::int; fc boolean := coalesce((p->>'from_cash')::boolean, true);
begin
  perform taxi_chk(p_pin);
  if lid is not null then perform taxi_chk_owner(p_pin); end if;
  if k not in ('expense','advance') then raise exception 'نوع غلط'; end if;
  if a is null or a <= 0 then raise exception 'اكتب المبلغ'; end if;
  if a <= 100 then a := a * 1000; end if;
  if a > 10000000 then raise exception 'المبلغ كبير'; end if;
  if d > (now() at time zone 'Asia/Baghdad')::date then raise exception 'التاريخ بالمستقبل'; end if;
  if per is not null then car := null; fc := false; end if;   -- staff: always paid by the office
  if (car is null) = (per is null) then raise exception 'اختار الشخص'; end if;
  if lid is null then
    insert into taxi_ledger(car_id, person_id, kind, amount, day, note, from_cash, by)
    values (car, per, k, a, d, left(coalesce(p->>'note',''),200), fc, coalesce((taxi_admin_who(p_pin))->>'name','المدير')) returning * into r;
  else
    update taxi_ledger set kind = k, amount = a, day = d, note = left(coalesce(p->>'note',''),200),
           from_cash = case when person_id is not null then false else fc end
     where id = lid returning * into r;
    if r.id is null then raise exception 'السجل غير موجود'; end if;
  end if;
  if r.car_id is not null then
    insert into taxi_events(car_id,kind,info) values (r.car_id, 'ledger', case when k='expense' then 'مصروف ' else 'سلفة ' end || a || coalesce(' · ' || nullif(r.note,''),''));
  end if;
  return json_build_object('ok', true, 'id', r.id, 'amount', a);
end $function$;

-- one person's list (staff)
create or replace function public.taxi_admin_ledger_person_list(p_pin text, p_person int)
 returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk(p_pin);
  return json_build_object(
    'items', coalesce((select json_agg(json_build_object('id',id,'kind',kind,'amount',amount,'day',day,'note',note,'from_cash',from_cash,'at',at,'by',by) order by day desc, id desc)
       from taxi_ledger where person_id = p_person), '[]'::json),
    'advances_total', (select coalesce(sum(amount),0) from taxi_ledger where person_id = p_person and kind = 'advance'),
    'expenses_total', (select coalesce(sum(amount),0) from taxi_ledger where person_id = p_person and kind = 'expense'));
end $$;

create or replace function public.taxi_admin_ledger_range(p_pin text, p_car uuid default null, p_from date default null, p_to date default null)
 returns json language plpgsql security definer set search_path to 'public' as $function$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(json_build_object('id',l.id,'car_id',l.car_id,'person_id',l.person_id,
      'driver_name',coalesce(c.driver_name, pp.name),'plate',c.plate,'staff',l.person_id is not null,'kind',l.kind,'amount',l.amount,
      'day',l.day,'note',l.note,'from_cash',l.from_cash,'at',l.at,'by',l.by) order by l.day desc, l.id desc)
    from taxi_ledger l left join taxi_cars c on c.id = l.car_id left join taxi_ledger_people pp on pp.id = l.person_id
    where (p_car is null or l.car_id = p_car)
      and l.day >= coalesce(p_from, (now() at time zone 'Asia/Baghdad')::date - 13)
      and l.day <= coalesce(p_to, (now() at time zone 'Asia/Baghdad')::date)), '[]'::json);
end $function$;

grant execute on function public.taxi_admin_ledger_people(text), public.taxi_admin_ledger_person_list(text,int) to anon, authenticated;
