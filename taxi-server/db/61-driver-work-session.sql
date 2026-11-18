-- 61: a driver's "day" is his work session, not the calendar day.
-- The session starts with his first trip after his last deposit (or receipt), and the next deposit ends it.
-- Every trip of the session counts on the day the session STARTED, even after midnight (evening shift that
-- settles at 2 AM, morning shift that deposits at noon and goes on…). A session never runs longer than 20 h.
-- Only trips from now on (setting wday_since); older trips keep their calendar day, so closed accounts don't move.
-- Manual entries keep the day they were entered for.

alter table public.taxi_trips add column if not exists wday date;
insert into public.taxi_settings(k, v) values ('wday_since', now()::text) on conflict (k) do nothing;

-- the moment his current session began (his last deposit / receipt), or null
create or replace function public.taxi_session_boundary(p_car uuid, p_at timestamptz)
 returns timestamptz language sql stable security definer set search_path to 'public' as $$
  select max(x) from (
    select max(created_at) x from taxi_deposits where car_id = p_car and status <> 'rejected' and created_at <= p_at
    union all
    select max(at) from taxi_cash where car_id = p_car and manual_day is null and coalesce(note,'') not like 'إيداع من السائق%' and at <= p_at
  ) b
$$;

create or replace function public.taxi_trip_wday_trg()
 returns trigger language plpgsql security definer set search_path to 'public' as $$
declare since timestamptz; b timestamptz; d date;
begin
  if new.started_at is null or new.car_id is null then return new; end if;
  if tg_op = 'UPDATE' and new.wday is not null and old.started_at is not distinct from new.started_at then return new; end if;
  if new.source = 'manual' then new.wday := taxi_work_day(new.started_at); return new; end if;
  select nullif(v,'')::timestamptz into since from taxi_settings where k = 'wday_since';
  if since is null or new.started_at < since then new.wday := null; return new; end if;
  b := greatest(coalesce(taxi_session_boundary(new.car_id, new.started_at), since), since, new.started_at - interval '20 hours');
  select t.wday into d from taxi_trips t
   where t.car_id = new.car_id and t.id is distinct from new.id and t.source <> 'manual' and t.wday is not null
     and t.started_at >= b and t.started_at < new.started_at
   order by t.started_at limit 1;
  new.wday := coalesce(d, taxi_work_day(new.started_at));
  return new;
exception when others then return new;
end $$;
drop trigger if exists taxi_trip_wday on public.taxi_trips;
create trigger taxi_trip_wday before insert or update of started_at on public.taxi_trips
  for each row execute function public.taxi_trip_wday_trg();

-- every report counts a trip on its session day (falls back to the calendar day for older trips)
do $do$
declare f text; d text;
begin
  foreach f in array array['public.taxi_admin_month_book(text,date)','public.taxi_admin_month_days(text,date)','public.taxi_period_flags(uuid,date,date)','public.taxi_period_json(uuid,date,date)','public.taxi_admin_record_days(text,uuid)'] loop
    d := pg_get_functiondef(f::regprocedure);
    if position('coalesce(wday,' in d) = 0 then
      d := replace(d, 'taxi_work_day(coalesce(started_at, ended_at))', 'coalesce(wday, taxi_work_day(coalesce(started_at, ended_at)))');
      d := replace(d, 'taxi_work_day(coalesce(started_at,ended_at))', 'coalesce(wday, taxi_work_day(coalesce(started_at,ended_at)))');
      execute d;
    end if;
  end loop;

  -- the driver's "today" = his current session (since his last deposit, at most 20 h back)
  d := pg_get_functiondef('public.taxi_driver_state(text)'::regprocedure);
  if position('taxi_session_boundary' in d) = 0 then
    d := replace(d, $a$taxi_work_day(coalesce(started_at, ended_at)) = taxi_work_day(now())$a$,
      $a$started_at >= greatest(coalesce(taxi_session_boundary(c.id, now()), now() - interval '20 hours'), now() - interval '20 hours')$a$);
    if position('taxi_session_boundary' in d) = 0 then raise exception 'driver_state patch failed'; end if;
    execute d;
  end if;
end $do$;
