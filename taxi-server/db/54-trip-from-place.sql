-- 54: every trip shows "من ← إلى". Driver trips had an empty pickup: now the place the car was at
-- when the trip started is written as the pickup (the compound, or the nearest known zone).
-- Only the text is filled; pickup_lat/lng stay as they were (they mean "go fetch the customer here").

create or replace function public.taxi_place_name(p_lat double precision, p_lng double precision)
 returns text language plpgsql stable security definer set search_path to 'public' as $$
declare b json := taxi_base(); z taxi_zones; d double precision;
begin
  if p_lat is null or p_lng is null then return null; end if;
  if (b->>'lat') is not null and taxi_km((b->>'lat')::float8, (b->>'lng')::float8, p_lat, p_lng) <= 1.2 then
    return b->>'name'; end if;
  select * into z from taxi_zones where lat is not null and lng is not null and active
   order by power(lat-p_lat,2) + power((lng-p_lng)*cos(radians(p_lat)),2) limit 1;
  if z.id is null then return null; end if;
  d := taxi_km(z.lat, z.lng, p_lat, p_lng);
  return case when d <= 2.5 then z.name else 'قرب ' || z.name end;
end $$;

-- where the car was at a moment: the trail point nearest to it (±10 min), else its last fix if that moment is now
create or replace function public.taxi_car_place_at(p_car uuid, p_at timestamptz)
 returns text language plpgsql stable security definer set search_path to 'public' as $$
declare la double precision; lo double precision;
begin
  select lat, lng into la, lo from taxi_trail where car_id = p_car and at between p_at - interval '10 minutes' and p_at + interval '10 minutes'
   order by abs(extract(epoch from (at - p_at))) limit 1;
  if la is null and p_at > now() - interval '10 minutes' then
    select last_lat, last_lng into la, lo from taxi_cars where id = p_car; end if;
  return taxi_place_name(la, lo);
end $$;

create or replace function public.taxi_trip_from_trg()
 returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.car_id is not null and new.started_at is not null and coalesce(trim(new.pickup),'') = ''
     and (tg_op = 'INSERT' or old.started_at is null or coalesce(trim(old.pickup),'') = '') then
    new.pickup := coalesce(taxi_car_place_at(new.car_id, new.started_at), new.pickup);
  end if;
  return new;
exception when others then return new;
end $$;
drop trigger if exists taxi_trip_from on public.taxi_trips;
create trigger taxi_trip_from before insert or update of started_at, status on public.taxi_trips
  for each row execute function public.taxi_trip_from_trg();

-- backfill the last 30 days (other triggers off for this one update)
set local session_replication_role = replica;
update taxi_trips t set pickup = p.place
  from (select id, taxi_car_place_at(car_id, started_at) place from taxi_trips
         where coalesce(trim(pickup),'') = '' and started_at > now() - interval '30 days' and car_id is not null) p
 where t.id = p.id and p.place is not null;
set local session_replication_role = origin;

-- settlement / day view trips carry the "from" place too
do $$ declare d text; begin
  d := pg_get_functiondef('public.taxi_period_json(uuid,date,date)'::regprocedure);
  if position($a$'from', pickup, 'to', dropoff,$a$ in d) = 0 then
    d := replace(d, $a$'to', dropoff, 'fare',$a$, $a$'from', pickup, 'to', dropoff, 'fare',$a$);
    execute d;
  end if;
end $$;
