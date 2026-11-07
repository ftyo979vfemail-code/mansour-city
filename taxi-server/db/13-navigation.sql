-- Navigation: zone coordinates, saved routes, traffic learned from the fleet.
-- (Function bodies identical to the Supabase migrations "taxi_navigation" and "taxi_admin_zones_geo".)
alter table public.taxi_zones add column if not exists lat double precision, add column if not exists lng double precision;
alter table public.taxi_trips add column if not exists route jsonb, add column if not exists route_km numeric(8,2), add column if not exists route_min numeric(8,1);
create index if not exists taxi_trail_at on public.taxi_trail(at);
