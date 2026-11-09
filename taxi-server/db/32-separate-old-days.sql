-- 32: keep the old (manually entered) days apart from the live accounts.
-- Before: entering an old day's receipt auto-confirmed the driver's pending deposits of TODAY
-- (taxi_cash_settles_deposits) and could mark today's trips paid (FIFO without a date limit).

-- an old-day receipt never touches today's deposits
create or replace function public.taxi_cash_settles_deposits()
 returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare d taxi_deposits; left_amt int := new.amount;
begin
  if new.amount <= 0 or new.manual_day is not null or coalesce(new.note,'') like 'إيداع من السائق%' or coalesce(new.note,'') like 'استلام قديم%' then return new; end if;
  for d in select * from taxi_deposits where car_id = new.car_id and status = 'pending' order by created_at loop
    exit when d.amount > left_amt;
    update taxi_deposits set status = 'confirmed', decided_at = now(), received = d.amount, decided_by = 'سجّلها المدير يدويًا' where id = d.id;
    left_amt := left_amt - d.amount;
  end loop;
  return new;
end $function$;

-- an old-day receipt only pays trips of that day or before it
create or replace function public.taxi_admin_manual_cash_set(p_pin text, p_car uuid, p_day date, p_amount integer)
 returns json language plpgsql security definer set search_path to 'public' as $function$
declare at timestamptz := (p_day::timestamp + interval '18 hours') at time zone 'Asia/Baghdad'; a int := coalesce(p_amount,0);
        t record; left_amt int; ref text := 'استلام قديم · ' || to_char(p_day,'MM-DD');
begin
  perform taxi_chk_owner(p_pin);
  if p_day > (now() at time zone 'Asia/Baghdad')::date then raise exception 'ما تگدر تدخل يوم بالمستقبل'; end if;
  if a < 0 or a > 10000000 then raise exception 'المبلغ غلط'; end if;
  if a between 1 and 100 then a := a * 1000; end if;
  delete from taxi_cash where car_id = p_car and manual_day = p_day;
  update taxi_trips set paid_at = null, paid_ref = null where car_id = p_car and paid_ref = ref;
  if a > 0 then
    insert into taxi_cash(car_id, amount, note, at, manual_day) values (p_car, a, ref, at, p_day);
    left_amt := a;
    for t in select id, fare - points_used as cash from taxi_trips
             where car_id = p_car and status = 'done' and paid_at is null and settlement_id is null and coalesce(fare,0) - points_used > 0
               and (ended_at at time zone 'Asia/Baghdad')::date <= p_day
             order by ended_at loop
      exit when t.cash > left_amt;
      update taxi_trips set paid_at = at, paid_ref = ref where id = t.id;
      left_amt := left_amt - t.cash;
    end loop;
  end if;
  return json_build_object('ok', true, 'amount', a);
end $function$;

-- data fix (applied once, 2026-11-09):
--  * Haidar's deposits #6 (10,000) and #7 (8,000) of 9/11 got auto-confirmed by the 1/11 old-day entry -> undone
--    (his 28,000 deposit #8 covered the same trips).
--  * the 28,000 received by mistake was already deleted; his four 9/11 trips stayed marked paid -> unmarked.
