-- 60: any manager (حمزة، حسام) can mark a customer debt received from the debts list; who did it is kept.
create or replace function public.taxi_admin_debt_received(p_pin text, p_id bigint)
 returns json language plpgsql security definer set search_path to 'public' as $$
declare who text; n int;
begin
  perform taxi_chk(p_pin);
  who := coalesce(taxi_admin_who(p_pin)->>'name','المدير');
  update taxi_ledger set deducted_at = now(), deducted_by = who where id = p_id and kind = 'debt' and deducted_at is null;
  get diagnostics n = row_count;
  if n = 0 then raise exception 'الدين مستلم أو مو موجود'; end if;
  insert into taxi_events(car_id, kind, info) select car_id, 'debt_paid', 'انستلم دين ' || amount || ' · ' || coalesce(note,'') || ' · ' || who from taxi_ledger where id = p_id;
  return json_build_object('ok', true);
end $$;
grant execute on function public.taxi_admin_debt_received(text,bigint) to anon, authenticated;
