-- API grants for weekly settlement (self-hosted: role web_anon).
grant execute on function
  public.taxi_admin_week(text,date), public.taxi_admin_settle(text,uuid,date,jsonb),
  public.taxi_admin_settlement(text,bigint), public.taxi_admin_fares(text,jsonb),
  public.taxi_admin_shares(text), public.taxi_driver_state(text)
to web_anon;
