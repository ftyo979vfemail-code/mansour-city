-- 30: receipts (الاستلامات). Every amount the office received, with the exact trips it paid for.
-- Allocation is first-in-first-out on running totals per driver: trips (cash = fare - points) in the order they
-- ended, receipts in the order they were taken. A receipt pays for the trips whose running-total range overlaps
-- its own range (a trip can be paid partly by one receipt and finished by the next). Computed live, so manual
-- days, edited fares and deleted trips are always reflected. Every manager can see it.
create or replace function public.taxi_admin_receipts(p_pin text, p_car uuid default null, p_from date default null, p_to date default null)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare f timestamptz := coalesce(p_from, (now() at time zone 'Asia/Baghdad')::date - 13)::timestamp at time zone 'Asia/Baghdad';
        t timestamptz := (coalesce(p_to, (now() at time zone 'Asia/Baghdad')::date) + 1)::timestamp at time zone 'Asia/Baghdad';
begin
  perform taxi_chk(p_pin);
  return coalesce((
    with tr as (
      select x.*, sum(x.cash) over (partition by x.car_id order by x.ended_at, x.id) as e
      from (select id, car_id, ended_at, pickup, dropoff, fare, source, trip_kind,
                   greatest(coalesce(fare,0) - points_used, 0) as cash
            from taxi_trips where status = 'done' and greatest(coalesce(fare,0) - points_used, 0) > 0
              and (p_car is null or car_id = p_car)) x),
    kc as (
      select k.*, sum(k.amount) over (partition by k.car_id order by k.at, k.id) as e
      from taxi_cash k where (p_car is null or k.car_id = p_car)),
    owed as (
      select kc.id, (select coalesce(sum(cash),0) from tr where tr.car_id = kc.car_id and tr.ended_at <= kc.at) - kc.e as after
      from kc)
    select json_agg(json_build_object(
      'id', kc.id, 'car_id', kc.car_id, 'plate', c.plate, 'driver_name', c.driver_name, 'amount', kc.amount, 'at', kc.at,
      'note', kc.note, 'manual_day', kc.manual_day, 'owed_after', o.after,
      'trips', coalesce((select json_agg(json_build_object('id', tr.id, 'ended_at', tr.ended_at, 'pickup', tr.pickup, 'dropoff', tr.dropoff,
                   'fare', tr.fare, 'cash', tr.cash, 'manual', tr.source = 'manual', 'line', tr.trip_kind = 'line',
                   'covered', least(tr.e, kc.e) - greatest(tr.e - tr.cash, kc.e - kc.amount)) order by tr.ended_at, tr.id)
                 from tr where tr.car_id = kc.car_id and tr.e > kc.e - kc.amount and tr.e - tr.cash < kc.e), '[]'::json),
      'unallocated', greatest(kc.e - coalesce((select max(tr.e) from tr where tr.car_id = kc.car_id), 0), 0) - greatest(kc.e - kc.amount - coalesce((select max(tr.e) from tr where tr.car_id = kc.car_id), 0), 0)
    ) order by kc.at desc, kc.id desc)
    from kc join taxi_cars c on c.id = kc.car_id join owed o on o.id = kc.id
    where kc.at >= f and kc.at < t), '[]'::json);
end $$;
grant execute on function public.taxi_admin_receipts(text,uuid,date,date) to anon, authenticated;

-- update (migration taxi_cash_edit_owner): taxi_admin_cash_edit(pin, id, amount, note, delete) — the main manager fixes
-- or removes any received amount (any age); every change is kept in taxi_cash_audit.

-- update (migrations taxi_ledger_range, taxi_record_days): taxi_admin_ledger_range(pin, car, from, to) lists expenses and
-- advances for the receipts page; taxi_admin_record_days(pin, car) gives the days that have receipts / ledger / trips
-- so the date picker can mark them.
