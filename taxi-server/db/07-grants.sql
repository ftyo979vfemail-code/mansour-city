-- API grants for zones and customer orders (self-hosted: role web_anon).
grant execute on function
  public.taxi_public_zones(), public.taxi_customer_request(jsonb), public.taxi_customer_status(uuid), public.taxi_customer_cancel(uuid),
  public.taxi_admin_zones(text), public.taxi_admin_zone_save(text,jsonb), public.taxi_admin_trip_create(text,jsonb),
  public.taxi_admin_trip_action(text,bigint,text,uuid), public.taxi_admin_trips(text,date),
  public.taxi_driver_trip(text,text,jsonb), public.taxi_driver_state(text), public.taxi_admin_alerts(text,bigint), public.taxi_admin_events(text)
to web_anon;
