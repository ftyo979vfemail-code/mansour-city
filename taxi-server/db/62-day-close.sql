-- 62: "📥 الكاش المستلم" — the office closes the day by entering the cash it actually received.
-- Each close keeps the amount, who, when, and what the system showed for the stretch since the previous close
-- (fares, expenses, net). After a close every driver starts a new day: the close is a session boundary too
-- (taxi_session_boundary), so the driver's "today" and the new trips' day start fresh.
-- The 3-day net (📊 الصافي) shows the closes of the cycle beside the system's net.

insert into public.taxi_settings(k,v) values ('close_start','2026-11-18 00:00+03') on conflict (k) do nothing;  -- the first stretch starts today

create table if not exists public.taxi_day_closes (
  id bigserial primary key,
  at timestamptz not null default now(),
  from_at timestamptz,
  amount int not null check (amount >= 0),
  fares int not null default 0,
  expenses int not null default 0,
  net int not null default 0,
  note text,
  by text);
alter table public.taxi_day_closes enable row level security;

create or replace function public.taxi_close_since(p_at timestamptz default now())
 returns timestamptz language sql stable security definer set search_path to 'public' as $$
  select coalesce((select max(at) from taxi_day_closes where at <= p_at),
                  (select nullif(v,'')::timestamptz from taxi_settings where k = 'close_start'),
                  date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad')
$$;

-- what the system shows since a moment: fares of trips started since then, expenses entered since then
create or replace function public.taxi_open_stretch(p_from timestamptz, p_to timestamptz default now())
 returns json language sql stable security definer set search_path to 'public' as $$
  select json_build_object('from', p_from, 'to', p_to,
    'fares', (select coalesce(sum(greatest(coalesce(fare,0) - points_used,0)),0) from taxi_trips where status = 'done' and started_at >= p_from and started_at < p_to),
    'trips', (select count(*) from taxi_trips where status = 'done' and coalesce(fare,0) > 0 and started_at >= p_from and started_at < p_to),
    'expenses', (select coalesce(sum(amount),0) from taxi_ledger where kind = 'expense' and at >= p_from and at < p_to),
    'received', (select coalesce(sum(amount),0) from taxi_cash where manual_day is null and at >= p_from and at < p_to),
    'running', (select count(*) from taxi_trips where status in ('accepted','started')),
    'drivers', (select coalesce(json_agg(json_build_object('name', c.driver_name, 'fares', x.f, 'trips', x.n) order by x.f desc), '[]'::json)
                from (select car_id, sum(greatest(coalesce(fare,0) - points_used,0)) f, count(*) n from taxi_trips
                      where status = 'done' and started_at >= p_from and started_at < p_to group by car_id) x join taxi_cars c on c.id = x.car_id))
$$;

create or replace function public.taxi_admin_day_close(p_pin text, p_amount text, p_note text default '')
 returns json language plpgsql security definer set search_path to 'public' as $$
declare a int := nullif(regexp_replace(coalesce(p_amount,''),'\D','','g'),'')::int; f timestamptz := taxi_close_since(now()); s json; v_id bigint;
        who text := coalesce(taxi_admin_who(p_pin)->>'name','المدير');
begin
  perform taxi_chk(p_pin);
  if a is null then raise exception 'اكتب المبلغ'; end if;
  if a between 1 and 9999 then a := a * 1000; end if;
  if a > 100000000 then raise exception 'المبلغ كبير، تأكد منه'; end if;
  if exists(select 1 from taxi_day_closes where at > now() - interval '2 minutes') then raise exception 'انسجل تسكير قبل شوية'; end if;
  s := taxi_open_stretch(f, now());
  insert into taxi_day_closes(from_at, amount, fares, expenses, net, note, by)
  values (f, a, (s->>'fares')::int, (s->>'expenses')::int, (s->>'fares')::int - (s->>'expenses')::int,
          left(coalesce(p_note,''),300), who) returning id into v_id;
  insert into taxi_events(car_id, kind, info) values (null, 'day_close', 'الكاش المستلم ' || a || ' · ' || who);
  return json_build_object('ok', true, 'id', v_id, 'amount', a, 'net', (s->>'fares')::int - (s->>'expenses')::int);
end $$;

create or replace function public.taxi_admin_day_closes(p_pin text, p_from date default null, p_to date default null)
 returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk(p_pin);
  return json_build_object(
    'open', taxi_open_stretch(taxi_close_since(now()), now()),
    'closes', coalesce((select json_agg(json_build_object('id',id,'at',at,'from',from_at,'amount',amount,'fares',fares,'expenses',expenses,'net',net,'note',note,'by',by) order by at desc)
       from taxi_day_closes where (p_from is null or (at at time zone 'Asia/Baghdad')::date >= p_from) and (p_to is null or (at at time zone 'Asia/Baghdad')::date <= p_to)), '[]'::json));
end $$;

-- the owner can remove a close entered by mistake
create or replace function public.taxi_admin_day_close_delete(p_pin text, p_id bigint)
 returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk_owner(p_pin);
  delete from taxi_day_closes where id = p_id;
  return json_build_object('ok', true);
end $$;

grant execute on function public.taxi_admin_day_close(text,text,text), public.taxi_admin_day_closes(text,date,date), public.taxi_admin_day_close_delete(text,bigint) to anon, authenticated;

-- a close starts a new day for every driver
create or replace function public.taxi_session_boundary(p_car uuid, p_at timestamptz)
 returns timestamptz language sql stable security definer set search_path to 'public' as $$
  select max(x) from (
    select max(created_at) x from taxi_deposits where car_id = p_car and status <> 'rejected' and created_at <= p_at
    union all
    select max(at) from taxi_cash where car_id = p_car and manual_day is null and coalesce(note,'') not like 'إيداع من السائق%' and at <= p_at
    union all
    select max(at) from taxi_day_closes where at <= p_at
  ) b
$$;
