-- 57: "📕 الديون" — every customer debt (fare not collected), open first, with who recorded it and when it was received.
create or replace function public.taxi_admin_debts(p_pin text)
 returns json language plpgsql security definer set search_path to 'public' as $$
begin
  perform taxi_chk(p_pin);
  return coalesce((select json_agg(json_build_object('id',l.id,'car_id',l.car_id,'driver_name',c.driver_name,'amount',l.amount,'day',l.day,
      'note',l.note,'by',l.by,'at',l.at,'from_cash',l.from_cash,'done',l.deducted_at is not null,'done_at',l.deducted_at,'done_by',l.deducted_by)
      order by (l.deducted_at is not null), l.day desc, l.id desc)
    from taxi_ledger l left join taxi_cars c on c.id = l.car_id where l.kind = 'debt'), '[]'::json);
end $$;
grant execute on function public.taxi_admin_debts(text) to anon, authenticated;
