-- API grants for customer accounts (self-hosted: role web_anon). Ordering now needs an account.
revoke execute on function public.taxi_customer_request(jsonb) from web_anon;
grant execute on function
  public.taxi_customer_signup(jsonb), public.taxi_customer_login(jsonb), public.taxi_customer_logout(uuid),
  public.taxi_customer_me(uuid), public.taxi_customer_order(uuid,jsonb),
  public.taxi_admin_customers(text), public.taxi_admin_customer_block(text,bigint,boolean)
to web_anon;
