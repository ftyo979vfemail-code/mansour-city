-- API grants for the trip functions (self-hosted: role web_anon).
grant execute on function
  public.taxi_ping(text,double precision,double precision,double precision,double precision,double precision,int),
  public.taxi_ping_v2(text,double precision,double precision,double precision,double precision,double precision,int),
  public.taxi_driver_state(text), public.taxi_driver_trip(text,text,jsonb),
  public.taxi_admin_trip_create(text,jsonb), public.taxi_admin_trip_action(text,bigint,text,uuid),
  public.taxi_admin_trips(text,date), public.taxi_admin_cash(text,text,jsonb),
  public.taxi_admin_statement(text,date), public.taxi_admin_driver_detail(text,uuid,date),
  public.taxi_admin_trail_range(text,uuid,timestamptz,timestamptz), public.taxi_admin_fares(text,jsonb),
  public.taxi_admin_list(text), public.taxi_public_info()
to web_anon;
