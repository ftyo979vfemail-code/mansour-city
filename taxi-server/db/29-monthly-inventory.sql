-- 29: monthly inventory (الجرد الشهري), main manager only.
-- Per driver for the chosen month: opening balance (what he owed when the month started), trips, fares,
-- points, free rides, cash he collected, what the office received, closing balance (what he still owes at the
-- end of the month / now), pending deposits. Plus totals and a day-by-day list.
create or replace function public.taxi_admin_inventory(p_pin text, p_month date default null)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare d0 date := date_trunc('month', coalesce(p_month, (now() at time zone 'Asia/Baghdad')::date))::date;
        m0 timestamptz := d0::timestamp at time zone 'Asia/Baghdad';
        m1 timestamptz := (d0 + interval '1 month')::timestamp at time zone 'Asia/Baghdad';
        rows json; days json;
begin
  perform taxi_chk_owner(p_pin);
  select coalesce(json_agg(r order by r.cash desc, r.driver_name), '[]'::json) into rows from (
    select c.id, c.plate, c.driver_name, c.active,
      coalesce(sum(greatest(coalesce(t.fare,0)-t.points_used,0)) filter (where t.ended_at < m0),0)
        - (select coalesce(sum(amount),0) from taxi_cash k where k.car_id=c.id and k.at < m0) as opening,
      count(t.*) filter (where t.ended_at >= m0 and t.ended_at < m1) as trips,
      coalesce(sum(t.fare) filter (where t.ended_at >= m0 and t.ended_at < m1),0) as fares,
      coalesce(sum(t.points_used) filter (where t.ended_at >= m0 and t.ended_at < m1),0) as points,
      count(t.*) filter (where t.ended_at >= m0 and t.ended_at < m1 and t.special_status = 'approved') as free_rides,
      count(t.*) filter (where t.ended_at >= m0 and t.ended_at < m1 and t.trip_kind = 'line') as lines,
      coalesce(sum(greatest(coalesce(t.fare,0)-t.points_used,0)) filter (where t.ended_at >= m0 and t.ended_at < m1),0) as cash,
      (select coalesce(sum(amount),0) from taxi_cash k where k.car_id=c.id and k.at >= m0 and k.at < m1) as received,
      coalesce(sum(greatest(coalesce(t.fare,0)-t.points_used,0)) filter (where t.ended_at < m1),0)
        - (select coalesce(sum(amount),0) from taxi_cash k where k.car_id=c.id and k.at < m1) as closing,
      (select coalesce(sum(amount),0) from taxi_deposits p where p.car_id=c.id and p.status='pending') as pending
    from taxi_cars c left join taxi_trips t on t.car_id = c.id and t.status = 'done'
    group by c.id) r
  where r.active or r.trips > 0 or r.opening <> 0 or r.received > 0;
  select coalesce(json_agg(x order by x.d), '[]'::json) into days from (
    select g::date d,
      (select count(*) from taxi_trips t where t.status='done' and t.ended_at >= g::timestamp at time zone 'Asia/Baghdad' and t.ended_at < (g + interval '1 day')::timestamp at time zone 'Asia/Baghdad') trips,
      (select coalesce(sum(greatest(coalesce(fare,0)-points_used,0)),0) from taxi_trips t where t.status='done' and t.ended_at >= g::timestamp at time zone 'Asia/Baghdad' and t.ended_at < (g + interval '1 day')::timestamp at time zone 'Asia/Baghdad') cash,
      (select coalesce(sum(amount),0) from taxi_cash k where k.at >= g::timestamp at time zone 'Asia/Baghdad' and k.at < (g + interval '1 day')::timestamp at time zone 'Asia/Baghdad') received
    from generate_series(d0, least((d0 + interval '1 month' - interval '1 day')::date, (now() at time zone 'Asia/Baghdad')::date), interval '1 day') g) x
  where x.trips > 0 or x.received > 0;
  return json_build_object('month', d0, 'rows', rows, 'days', days);
end $$;
grant execute on function public.taxi_admin_inventory(text,date) to anon, authenticated;

-- update (migration taxi_inventory_periods): taxi_admin_inventory(pin, p_day, p_period 'day'|'week'|'month')
-- returns {period, from, to, rows, days}; the week starts on Saturday (taxi_week_start).

-- update (migration taxi_manual_days): days before the system — taxi_admin_manual_set(pin, car, day, amount, received)
-- stores one 'manual' done trip per driver per day (replaced on re-entry; received -> a matching taxi_cash row),
-- taxi_admin_manual_get(pin, from, to) for the entry grid; the inventory counts them as manual_days, not trips.

-- update (migration taxi_manual_cash_days): taxi_cash.manual_day + taxi_admin_manual_cash_set(pin, car, day, amount):
-- what the office received from a driver on an old day (replaced on re-entry); manual_get also returns 'cash'.
