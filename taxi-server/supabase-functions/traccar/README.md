Edge Function `traccar` (deployed on the `compound-taxi` Supabase project, verify_jwt = false).
Receives positions from the Traccar Client app (JSON from v9+, or OsmAnd query/form) and forwards
them to `taxi_ping_v2`. The app's "Device identifier" is the driver's 6-digit code.
URL: https://xdyxcvyhoidojtfpoepk.supabase.co/functions/v1/traccar
