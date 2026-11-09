-- 33: "تفاصيل يوم السائق" for the owner and the managers:
-- every trip of the day with warnings, and every time the car left the compound with no trip open (from the GPS trail).

create or replace function public.taxi_km(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
 returns numeric language sql immutable as $$
  select round((6371*2*asin(sqrt(power(sin(radians(b_lat-a_lat)/2),2)+cos(radians(a_lat))*cos(radians(b_lat))*power(sin(radians(b_lng-a_lng)/2),2))))::numeric, 2)
$$;

create or replace function public.taxi_near_zone(p_lat double precision, p_lng double precision)
 returns text language sql stable security definer set search_path to 'public' as $$
  select z.name from taxi_zones z where z.lat is not null and z.lng is not null
  order by power(z.lat-p_lat,2) + power((z.lng-p_lng)*cos(radians(p_lat)),2) limit 1
$$;

create or replace function public.taxi_admin_driver_day(p_pin text, p_car uuid, p_day date default null)
 returns json language plpgsql security definer set search_path to 'public' as $function$
declare d date := coalesce(p_day, (now() at time zone 'Asia/Baghdad')::date);
        f timestamptz := d::timestamp at time zone 'Asia/Baghdad';
        t timestamptz := (d + 1)::timestamp at time zone 'Asia/Baghdad';
        blat double precision := 33.3362;
        blng double precision := 44.3553;
        c taxi_cars; trips json; outs json;
begin
  perform taxi_chk(p_pin);
  select * into c from taxi_cars where id = p_car;
  if c.id is null then raise exception 'السائق غير موجود'; end if;
  begin
    select coalesce(nullif(v,'')::double precision, blat) into blat from taxi_settings where k = 'base_lat';
    select coalesce(nullif(v,'')::double precision, blng) into blng from taxi_settings where k = 'base_lng';
  exception when others then null; end;
  blat := coalesce(blat, 33.3362); blng := coalesce(blng, 44.3553);

  -- trips with warnings
  select coalesce(json_agg(x order by x.started_at nulls last, x.id), '[]'::json) into trips from (
    select tr.id, tr.status, tr.trip_kind, tr.source, tr.pickup, tr.dropoff, tr.fare, tr.points_used, tr.km, tr.round_trip, tr.wait_fee,
           tr.special_status, tr.noshow_status, tr.started_at, tr.ended_at, tr.accepted_at,
           round(extract(epoch from (coalesce(tr.ended_at, now()) - coalesce(tr.started_at, tr.accepted_at)))/60) as minutes,
           array_remove(array[
             case when tr.status='done' and tr.trip_kind is distinct from 'line' and tr.source <> 'manual'
                   and tr.ended_at - tr.started_at < interval '2 minutes' then 'انفتحت وانسدّت بنفس الدقيقة' end,
             case when tr.status='done' and tr.trip_kind is distinct from 'line' and tr.source <> 'manual' and coalesce(tr.km,0) = 0 then 'المسافة 0 كم' end,
             case when tr.status='done' and tr.trip_kind = 'line' and not exists (
                     select 1 from taxi_trail p where p.car_id = c.id and p.at between tr.started_at and tr.started_at + interval '40 minutes'
                       and taxi_km(blat, blng, p.lat, p.lng) > 0.8) then 'سجّل خط بس السيارة ما طلعت من المجمع' end,
             case when exists (select 1 from taxi_trips o where o.car_id = c.id and o.id <> tr.id and o.status in ('done','started')
                     and o.started_at is not null and tr.started_at is not null
                     and abs(extract(epoch from (o.started_at - tr.started_at))) < 90) then 'بدت ويا سفرة ثانية بنفس الوقت' end
           ], null) as flags
    from taxi_trips tr
    where tr.car_id = c.id and tr.status in ('done','started','accepted') and tr.source <> 'manual'
      and coalesce(tr.started_at, tr.accepted_at, tr.created_at) >= f and coalesce(tr.started_at, tr.accepted_at, tr.created_at) < t) x;

  -- times away from the compound with no trip open
  with w as (
    select coalesce(accepted_at, started_at) a, coalesce(ended_at, now()) b, ended_at e, started_at s from taxi_trips
    where car_id = c.id and status in ('done','started','accepted') and source <> 'manual'
      and coalesce(ended_at, now()) >= f - interval '2 hours' and coalesce(accepted_at, started_at, created_at) < t),
  p as (
    select tr.at, tr.lat, tr.lng, taxi_km(blat, blng, tr.lat, tr.lng) km
    from taxi_trail tr where tr.car_id = c.id and tr.at >= f and tr.at < t
      and not exists (select 1 from w where tr.at between w.a and w.b)),
  aw as (select *, case when km > 0.6 then 1 else 0 end away, lag(at) over (order by at) prev_at,
                lag(case when km > 0.6 then 1 else 0 end) over (order by at) prev_away from p),
  g as (select *, sum(case when away = 1 and (prev_away is distinct from 1 or at - prev_at > interval '12 minutes') then 1 else 0 end) over (order by at) grp from aw),
  seg as (
    select grp, min(at) s, max(at) e, max(km) maxkm, count(*) n,
           (array_agg(lat order by km desc))[1] flat, (array_agg(lng order by km desc))[1] flng
    from g where away = 1 group by grp)
  select coalesce(json_agg(json_build_object(
      'from', s.s, 'to', s.e, 'minutes', round(extract(epoch from (s.e - s.s))/60), 'max_km', s.maxkm,
      'near', taxi_near_zone(s.flat, s.flng), 'lat', s.flat, 'lng', s.flng,
      'kind', case when exists (select 1 from w where w.e is not null and s.s between w.e and w.e + interval '6 minutes') then 'return'
                   when exists (select 1 from w where w.s is not null and w.s between s.e and s.e + interval '10 minutes') then 'before_trip'
                   else 'unlogged' end
    ) order by s.s), '[]'::json) into outs
  from seg s where s.maxkm >= 1 and s.e - s.s >= interval '4 minutes';

  return json_build_object('day', d, 'car_id', c.id, 'driver_name', c.driver_name, 'plate', c.plate,
    'base', json_build_object('lat', blat, 'lng', blng),
    'trips', trips, 'outings', outs,
    'totals', (select json_build_object(
        'done', count(*) filter (where status='done'),
        'paid', count(*) filter (where status='done' and coalesce(fare,0) > 0),
        'lines', count(*) filter (where status='done' and trip_kind='line'),
        'fares', coalesce(sum(fare) filter (where status='done'),0),
        'running', count(*) filter (where status in ('started','accepted')))
      from taxi_trips where car_id = c.id and source <> 'manual' and coalesce(started_at, accepted_at, created_at) >= f and coalesce(started_at, accepted_at, created_at) < t));
end $function$;

grant execute on function public.taxi_admin_driver_day(text, uuid, date) to anon, authenticated;
