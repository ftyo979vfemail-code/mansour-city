import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Background GPS for purchasing reps, drivers and operators via the free Traccar Client app
// (Android & iPhone). The app's "Device identifier" is the staff member's personal gps_token.
// Accepts Traccar Client v9+ JSON and the classic OsmAnd query/form protocol.
const ok = (b: unknown = "ok", status = 200) => new Response(typeof b === "string" ? b : JSON.stringify(b), { status });

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url);
    let id = url.searchParams.get("id") || url.searchParams.get("deviceid") || "";
    let lat = Number(url.searchParams.get("lat")), lon = Number(url.searchParams.get("lon") ?? url.searchParams.get("lng"));
    let acc = Number(url.searchParams.get("accuracy") || 0);
    if (req.method === "POST") {
      const ct = req.headers.get("content-type") || "";
      const raw = await req.text();
      if (ct.includes("json") || raw.trim().startsWith("{")) {
        try {
          const j = JSON.parse(raw);
          const loc = Array.isArray(j.location) ? j.location[0] : (j.location || j);
          const c = loc?.coords || {};
          id = String(j.device_id || j.deviceId || loc?.device_id || id || "");
          lat = Number(c.latitude ?? loc?.latitude ?? lat); lon = Number(c.longitude ?? loc?.longitude ?? lon);
          acc = Number(c.accuracy ?? loc?.accuracy ?? acc);
        } catch (_) { /* fall through */ }
      } else if (raw) {
        const f = new URLSearchParams(raw);
        id = f.get("id") || f.get("deviceid") || id;
        if (f.get("lat")) lat = Number(f.get("lat"));
        if (f.get("lon") || f.get("lng")) lon = Number(f.get("lon") || f.get("lng"));
        if (f.get("accuracy")) acc = Number(f.get("accuracy"));
      }
    }
    if (!id || !isFinite(lat) || !isFinite(lon)) return ok("bad request", 400);
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data, error } = await admin.rpc("gps_bg_ping", { p_token: id.trim(), p_lat: lat, p_lng: lon, p_acc: isFinite(acc) ? acc : 0 });
    if (error) return ok("error", 500);
    return data ? ok() : ok("unknown device", 404);
  } catch (_) {
    return ok("error", 500);
  }
});
