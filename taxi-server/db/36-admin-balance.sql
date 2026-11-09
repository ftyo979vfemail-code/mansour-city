-- 36: taxi_admin_balance(pin, car): the driver's all-time balance (taxi_balance_row) + pending deposits + received today,
-- shown in the "✅ تم الاستلام" box of the accounts tab.
-- Data fix 2026-11-09: the old entries of 1/11 (4 manual trips + 4 receipts) were moved to 31/10 at the owner's request.
create or replace function public.taxi_admin_balance(p_pin text, p_car uuid)
 returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk(p_pin);
  return (taxi_balance_row(p_car)::jsonb || jsonb_build_object(
    'pending', (select coalesce(sum(amount),0) from taxi_deposits where car_id = p_car and status = 'pending'),
    'today_received', (select coalesce(sum(amount),0) from taxi_cash where car_id = p_car and manual_day is null and (at at time zone 'Asia/Baghdad')::date = (now() at time zone 'Asia/Baghdad')::date)))::json;
end $$;
grant execute on function public.taxi_admin_balance(text, uuid) to anon, authenticated;
