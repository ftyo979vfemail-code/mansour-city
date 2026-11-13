-- 53: the driver's "سفرات اليوم" counts a trip on the day it STARTED (same rule as the accounts, doc 42/46).
-- Before: it counted by ended_at, so a night trip started yesterday and ended after midnight showed in today's total
-- (Wisam 13/11 saw 96,000 / 12 trips while the accounts had 86,000 / 11).
do $$ declare d text; o text := $a$status='done' and ended_at >= date_trunc('day', now() at time zone 'Asia/Baghdad') at time zone 'Asia/Baghdad')$a$; begin
  d := pg_get_functiondef('public.taxi_driver_state(text)'::regprocedure);
  if position(o in d) > 0 then
    d := replace(d, o, $a$status='done' and taxi_work_day(coalesce(started_at, ended_at)) = taxi_work_day(now()))$a$);
    execute d;
  end if;
end $$;

-- data (2026-11-13): Wisam's 25,000 advance of 13/11 (ledger #21, all from cash) left him at -17,000.
-- The owner asked to zero it: #21 became 8,000 from cash + a new 17,000 advance not from cash (total still 25,000).
-- Backup: taxi_backup.wisam_zero_20261113.
