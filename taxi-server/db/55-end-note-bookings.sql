-- 55: (1) the driver can add a note when he ends a trip (optional).
--     (2) a booking confirmed by the office for a named driver pushes him "عندك حجز: من ← إلى · الوقت",
--         and his upcoming confirmed bookings show on his screen (driver state 'bookings').

alter table public.taxi_trips add column if not exists end_note text;

do $do$
declare d text;
begin
  -- end / special_end keep the driver's note
  d := pg_get_functiondef('public.taxi_driver_trip(text,text,jsonb)'::regprocedure);
  if position('end_note' in d) = 0 then
    d := replace(d, $a$update taxi_trips set status='done', ended_at=now(), cancel_req_status = nullif(cancel_req_status,'pending'),$a$,
                    $a$update taxi_trips set status='done', ended_at=now(), cancel_req_status = nullif(cancel_req_status,'pending'),
      end_note = nullif(left(trim(coalesce(p->>'end_note','')),200),''),$a$);
    d := replace(d, $a$update taxi_trips set status='done', started_at=coalesce(started_at, now()), ended_at=now(),$a$,
                    $a$update taxi_trips set status='done', started_at=coalesce(started_at, now()), ended_at=now(),
      end_note = nullif(left(trim(coalesce(p->>'end_note','')),200),''),$a$);
    if (length(d) - length(replace(d, 'end_note =', ''))) / length('end_note =') <> 2 then raise exception 'driver_trip patch failed'; end if;
    execute d;
  end if;

  -- admin trips list
  d := pg_get_functiondef('public.taxi_admin_trips(text,date)'::regprocedure);
  if position('end_note' in d) = 0 then
    d := replace(d, $a$t.trip_kind, t.cancel_req_status,$a$, $a$t.trip_kind, t.end_note, t.cancel_req_status,$a$);
    if position('end_note' in d) = 0 then raise exception 'admin_trips patch failed'; end if;
    execute d;
  end if;

  -- settlement / book trips
  d := pg_get_functiondef('public.taxi_period_json(uuid,date,date)'::regprocedure);
  if position('end_note' in d) = 0 then
    d := replace(d, $a$'from', pickup, 'to', dropoff,$a$, $a$'from', pickup, 'to', dropoff, 'end_note', end_note,$a$);
    if position('end_note' in d) = 0 then raise exception 'period_json patch failed'; end if;
    execute d;
  end if;

  -- driver-day details
  d := pg_get_functiondef('public.taxi_admin_driver_day(text,uuid,date)'::regprocedure);
  if position('end_note' in d) = 0 then
    d := replace(d, $a$tr.special_status, tr.noshow_status,$a$, $a$tr.special_status, tr.noshow_status, tr.end_note,$a$);
    execute d;
  end if;

  -- the driver's upcoming confirmed bookings
  d := pg_get_functiondef('public.taxi_driver_state(text)'::regprocedure);
  if position('bookings' in d) = 0 then
    d := replace(d, $a$'returning_since', c.returning_since,$a$,
      $a$'bookings', (select coalesce(json_agg(json_build_object('id',b.id,'at',b.scheduled_at,'pickup',b.pickup,'dropoff',b.dropoff,'customer',b.customer_name,'note',b.note) order by b.scheduled_at),'[]'::json)
                    from taxi_trips b where b.sched_car = c.id and b.status = 'scheduled' and b.sched_confirmed_at is not null),
    'returning_since', c.returning_since,$a$);
    if position('bookings' in d) = 0 then raise exception 'driver_state patch failed'; end if;
    execute d;
  end if;

  -- push the named driver when the office confirms a booking for him (or moves it to him)
  d := pg_get_functiondef('public.taxi_push_trg()'::regprocedure);
  if position('عندك حجز' in d) = 0 then
    d := replace(d, $a$  return new;
exception when others then return new;$a$, $a$  if new.status = 'scheduled' and new.sched_car is not null and new.sched_confirmed_at is not null
     and (old.sched_confirmed_at is null or old.sched_car is distinct from new.sched_car) then
    perform taxi_push_send(null, new.sched_car, '🗓 عندك حجز توصيل',
      'من ' || coalesce(nullif(new.pickup,''),'موقع الزبون') || ' ← ' || coalesce(nullif(new.dropoff,''),'—')
      || ' · ' || to_char(new.scheduled_at at time zone 'Asia/Baghdad','MM/DD الساعة HH24:MI')
      || coalesce(' · ' || nullif(new.customer_name,''), ''),
      'book-' || new.id, './#driver');
    insert into taxi_events(car_id,kind,info) values (new.sched_car, 'booking',
      'حجز ' || to_char(new.scheduled_at at time zone 'Asia/Baghdad','MM/DD HH24:MI') || ': ' || coalesce(nullif(new.pickup,''),'—') || ' ← ' || coalesce(new.dropoff,''));
  end if;
  return new;
exception when others then return new;$a$);
    if position('عندك حجز' in d) = 0 then raise exception 'push patch failed'; end if;
    execute d;
  end if;
end $do$;
