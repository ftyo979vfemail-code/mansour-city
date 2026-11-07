-- A money file per driver, all-time:
--   fares       = fares of his completed trips
--   collected   = everything he handed over (manual handovers + weekly settlements)
--   in_hand     = fares - collected            (company money still with him)
--   share       = his share (settled weeks as recorded + not-yet-settled trips at today's rule)
--   paid_out    = what the company paid him in settlements
--   owed_to_him = share - paid_out
--   net         = in_hand - owed_to_him        (positive: he owes the company; negative: the company owes him)

create or replace function public.taxi_balance_row(p_car uuid) returns json
language sql stable security definer set search_path = public as $$
  with f as (select count(*) n, coalesce(sum(fare),0) s from taxi_trips where car_id=p_car and status='done'),
       u as (select count(*) n, coalesce(sum(fare),0) s from taxi_trips where car_id=p_car and status='done' and settlement_id is null),
       k as (select coalesce(sum(amount),0) s, max(at) last_at from taxi_cash where car_id=p_car),
       st as (select coalesce(sum(share),0) sh, coalesce(sum(paid_out),0) po from taxi_settlements where car_id=p_car)
  select json_build_object(
    'trips', f.n, 'fares', f.s, 'collected', k.s, 'last_collected_at', k.last_at,
    'in_hand', f.s - k.s,
    'share', st.sh + taxi_share(u.n::int, u.s::int), 'paid_out', st.po,
    'owed_to_him', st.sh + taxi_share(u.n::int, u.s::int) - st.po,
    'net', (f.s - k.s) - (st.sh + taxi_share(u.n::int, u.s::int) - st.po))
  from f, u, k, st;
$$;

create or replace function public.taxi_admin_balances(p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare rows json;
begin
  perform taxi_chk(p_pin);
  select json_agg(r order by (r.bal->>'net')::numeric desc) into rows from (
    select c.id, c.plate, c.driver_name, c.driver_phone, c.model, c.active, c.gps_state, c.last_seen, taxi_balance_row(c.id)::jsonb as bal
    from taxi_cars c) r;
  return json_build_object('rows', coalesce(rows,'[]'::json),
    'totals', (select json_build_object(
       'fares', coalesce(sum((b->>'fares')::numeric),0), 'collected', coalesce(sum((b->>'collected')::numeric),0),
       'in_hand', coalesce(sum((b->>'in_hand')::numeric),0), 'share', coalesce(sum((b->>'share')::numeric),0),
       'paid_out', coalesce(sum((b->>'paid_out')::numeric),0), 'owed', coalesce(sum((b->>'owed_to_him')::numeric),0),
       'net', coalesce(sum((b->>'net')::numeric),0))
       from (select taxi_balance_row(id)::jsonb b from taxi_cars) x));
end $$;

create or replace function public.taxi_admin_driver_file(p_pin text, p_car uuid) returns json
language plpgsql security definer set search_path = public as $$
declare c taxi_cars; ws date := taxi_week_start((now() at time zone 'Asia/Baghdad')::date);
        m0 timestamptz := date_trunc('month', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad';
begin
  perform taxi_chk(p_pin);
  select * into c from taxi_cars where id = p_car;
  if c.id is null then raise exception 'السيارة غير موجودة'; end if;
  return json_build_object(
    'car', json_build_object('id',c.id,'plate',c.plate,'model',c.model,'year',c.year,'color',c.color,'driver_name',c.driver_name,
                             'driver_phone',c.driver_phone,'driver_code',c.driver_code,'active',c.active,'gps_state',c.gps_state,
                             'last_seen',c.last_seen,'battery',c.battery,'created_at',c.created_at),
    'balance', taxi_balance_row(c.id),
    'week', (select json_build_object('trips',count(*),'fares',coalesce(sum(fare),0)) from taxi_trips
             where car_id=c.id and status='done' and ended_at >= ws::timestamp at time zone 'Asia/Baghdad'),
    'month', (select json_build_object('trips',count(*),'fares',coalesce(sum(fare),0)) from taxi_trips
             where car_id=c.id and status='done' and ended_at >= m0),
    'month_unlogged', (select json_build_object('n',count(*),'km',round(coalesce(sum(km),0),1)) from taxi_moves(c.id, m0, now()) where not matched),
    'month_cutoffs', (select count(*) from taxi_events where car_id=c.id and kind in ('off','denied','closed','lost') and at >= m0),
    'month_rejected', (select count(*) from taxi_trips where car_id=c.id and status='rejected' and created_at >= m0),
    'ledger', coalesce((select json_agg(x order by x.at desc) from (
        select 'trip' as type, t.ended_at as at, t.fare as amount, coalesce(t.pickup,'') || ' ← ' || coalesce(t.dropoff,'') as note
          from taxi_trips t where t.car_id=c.id and t.status='done'
        union all
        select 'cash', k.at, k.amount, k.note from taxi_cash k where k.car_id=c.id
        union all
        select 'payout', s.created_at, s.paid_out, 'تسوية أسبوع ' || to_char(s.week_start,'YYYY/MM/DD') from taxi_settlements s where s.car_id=c.id and s.paid_out > 0
        order by 2 desc limit 60) x), '[]'::json));
end $$;
