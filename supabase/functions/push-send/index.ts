import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const { data: cfg, error: ce } = await admin.rpc("push_config");
    if (ce || !cfg) return json({ error: "no config" }, 500);
    if (req.headers.get("x-push-secret") !== cfg.secret) return json({ error: "forbidden" }, 403);
    const b = await req.json();
    const uids = (b.uids || []).filter((x: string | null) => !!x);
    const { data: subs } = await admin.rpc("push_targets", { p_roles: b.roles || [], p_uids: uids, p_exclude: b.exclude || null });
    webpush.setVapidDetails("mailto:ftyo979vfemail@gmail.com", cfg.public_key, cfg.private_key);
    const payload = JSON.stringify({ title: b.title || "نظام شركة المنصور", body: b.body || "", tag: b.tag || "" });
    let sent = 0, dropped = 0;
    await Promise.all((subs || []).map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400, urgency: "high" });
        sent++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) { await admin.rpc("push_drop", { p_endpoint: s.endpoint }); dropped++; }
      }
    }));
    return json({ ok: true, targets: (subs || []).length, sent, dropped });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
