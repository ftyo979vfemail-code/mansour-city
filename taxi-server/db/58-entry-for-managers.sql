-- 58: the daily entry book (📝 تسجيل يومي) is open to the managers (حمزة، حسام):
-- they can read it and fill an EMPTY box; changing or clearing a value already there stays with the owner.
do $do$
declare d text;
begin
  d := pg_get_functiondef('public.taxi_admin_manual_get(text,date,date)'::regprocedure);
  d := replace(d, 'perform taxi_chk_owner(p_pin);', 'perform taxi_chk(p_pin);');
  execute d;

  d := pg_get_functiondef('public.taxi_admin_manual_set(text,uuid,date,integer,boolean)'::regprocedure);
  if position('taxi_admin_who(p_pin)->>''id''' in d) = 0 then
    d := replace(d, $a$  perform taxi_chk_owner(p_pin);$a$, $a$  perform taxi_chk(p_pin);
  if coalesce((taxi_admin_who(p_pin)->>'id')::int, -1) <> 0 and (coalesce(p_amount,0) <= 0 or exists(
       select 1 from taxi_trips where source='manual' and car_id=p_car and (ended_at at time zone 'Asia/Baghdad')::date = p_day)) then
    raise exception 'الرقم مسجّل. التعديل بس للمدير الرئيسي'; end if;$a$);
    execute d;
  end if;

  d := pg_get_functiondef('public.taxi_admin_manual_cash_set(text,uuid,date,integer)'::regprocedure);
  if position('taxi_admin_who(p_pin)->>''id''' in d) = 0 then
    d := replace(d, $a$  perform taxi_chk_owner(p_pin);$a$, $a$  perform taxi_chk(p_pin);
  if coalesce((taxi_admin_who(p_pin)->>'id')::int, -1) <> 0 and (coalesce(p_amount,0) <= 0 or exists(
       select 1 from taxi_cash where car_id=p_car and manual_day = p_day)) then
    raise exception 'الرقم مسجّل. التعديل بس للمدير الرئيسي'; end if;$a$);
    execute d;
  end if;
end $do$;
