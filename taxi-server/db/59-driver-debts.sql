-- 59: the driver records a customer debt himself (fare not paid): amount + a note with the details
-- (customer name, building/flat, when he'll pay…). It goes to the debts list for the office, is taken off
-- what the driver holds (from_cash), and stays open until the owner marks it received.
-- The driver also sees his open debts on his screen (driver state 'debts').

alter table public.taxi_ledger add column if not exists trip_id bigint;

create or replace function public.taxi_driver_debt_add(p_code text, p_amount text, p_note text, p_trip bigint default null)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare c taxi_cars; a int := nullif(regexp_replace(coalesce(p_amount,''),'\D','','g'),'')::int; n text := left(trim(coalesce(p_note,'')),200); v_id bigint;
begin
  select * into c from taxi_cars where driver_code = trim(p_code) and active;
  if c.id is null then raise exception 'رمز غير صالح'; end if;
  if a is null or a <= 0 then raise exception 'اكتب المبلغ'; end if;
  if a <= 100 then a := a * 1000; end if;
  if a < 500 then raise exception 'المبلغ قليل، اكتبه كامل (مثال 5000)'; end if;
  if a > 200000 then raise exception 'المبلغ كبير، تأكد منه'; end if;
  if length(n) < 3 then raise exception 'اكتب معلومات الزبون: الاسم والعمارة'; end if;
  if p_trip is not null and not exists(select 1 from taxi_trips where id = p_trip and car_id = c.id) then p_trip := null; end if;
  if p_trip is not null and exists(select 1 from taxi_ledger where trip_id = p_trip and kind = 'debt') then raise exception 'الدين مسجّل على هاي السفرة'; end if;
  insert into taxi_ledger(car_id, kind, amount, day, note, from_cash, by, trip_id)
  values (c.id, 'debt', a, (now() at time zone 'Asia/Baghdad')::date, n, true, 'السائق ' || c.driver_name, p_trip) returning taxi_ledger.id into v_id;
  insert into taxi_events(car_id, kind, info) values (c.id, 'debt', 'دين على زبون ' || a || ' · ' || n);
  return json_build_object('ok', true, 'id', v_id, 'amount', a);
end $$;
grant execute on function public.taxi_driver_debt_add(text,text,text,bigint) to anon, authenticated;

do $do$
declare d text;
begin
  d := pg_get_functiondef('public.taxi_driver_state(text)'::regprocedure);
  if position('''debts'', (select' in d) = 0 then   -- (the closing json already has a 'debts' key)
    d := replace(d, $a$'bookings', ($a$, $a$'debts', (select coalesce(json_agg(json_build_object('id',l.id,'amount',l.amount,'day',l.day,'note',l.note,'by',l.by) order by l.day desc, l.id desc),'[]'::json)
                 from taxi_ledger l where l.car_id = c.id and l.kind = 'debt' and l.deducted_at is null),
    'bookings', ($a$);
    if position('''debts'', (select' in d) = 0 then raise exception 'driver_state patch failed'; end if;
    execute d;
  end if;
end $do$;
