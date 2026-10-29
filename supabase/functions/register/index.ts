import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const DOMAIN = "staff.mansourcity.app";
const ROLES = ["machines","elec","mech","store","mstore","project","admin1","admin2","buyer","engineer","contractor","driver"];
const EXT = ["engineer","contractor"]; // remote supervisors of the attendance site
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const digits = (s: string) => s.replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660)).replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06F0)).replace(/\D/g, "");
const CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const body = await req.json();
    const name = String(body.full_name || "").trim().slice(0, 80);
    const phone = digits(String(body.phone || ""));
    const role = String(body.role || "");
    const password = String(body.password || "");
    const company = String(body.company || "").trim().replace(/\s+/g, " ").slice(0, 80);
    const specialty = String(body.specialty || "").trim().slice(0, 60);
    if (name.length < 3) return json({ error: "اكتب الاسم الكامل", code: "E_NAME" }, 400);
    if (phone.length < 10 || phone.length > 15) return json({ error: "رقم الهاتف غير صحيح", code: "E_PHONE" }, 400);
    if (!ROLES.includes(role)) return json({ error: "اختر دورك المهني", code: "E_TYPE" }, 400);
    if (role === "contractor" && company.length < 2) return json({ error: "اكتب اسم الشركة أو المقاول", code: "E_COMPANY" }, 400);
    if (password.length < 6) return json({ error: "كلمة السر 6 أحرف على الأقل", code: "E_PASS" }, 400);
    const { data: exists } = await admin.from("staff").select("id").or(`phone.eq.${phone},username.eq.${phone}`).maybeSingle();
    if (exists) return json({ error: "هذا الرقم مسجل مسبقاً. سجّل الدخول به أو راجع المدير", code: "E_EXISTS" }, 400);
    const { data: created, error } = await admin.auth.admin.createUser({ email: `${phone}@${DOMAIN}`, password, email_confirm: true, user_metadata: { full_name: name, phone } });
    if (error) return json({ error: error.message.includes("already") ? "هذا الرقم مسجل مسبقاً" : error.message, code: error.message.includes("already") ? "E_EXISTS" : undefined }, 400);
    const row: Record<string, unknown> = { id: created.user.id, username: phone, phone, full_name: name, role, active: false, status: "pending" };
    if (EXT.includes(role)) { row.company = company || null; row.specialty = specialty || null; if (role === "contractor") row.att_team = company; }
    const { error: e2 } = await admin.from("staff").insert(row);
    if (e2) { await admin.auth.admin.deleteUser(created.user.id); return json({ error: e2.message }, 400); }
    const a = new Uint32Array(8); crypto.getRandomValues(a);
    const code = Array.from(a, (n) => CODE_CHARS[n % CODE_CHARS.length]).join("");
    await admin.from("staff_codes").insert({ id: created.user.id, code });
    await admin.from("notifications").insert({ kind: "staff_pending", data: { name, role, phone, company: company || undefined, specialty: specialty || undefined, at: Date.now() } });
    return json({ ok: true });
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
