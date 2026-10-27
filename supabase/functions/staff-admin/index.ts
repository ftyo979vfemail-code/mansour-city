import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const DOMAIN = "staff.mansourcity.app";
const ROLES = ["owner","machines","elec","mech","store","mstore","project","admin1","admin2","purchase","purchase2","keeper","operator","mechanic","fueler"];
// which crew roles each manager may add / manage
const CREW: Record<string, string[]> = {
  machines: ["operator", "mechanic", "fueler"],
  mstore: ["keeper"],
  project: ["keeper", "operator", "mechanic", "fueler"],
};
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const digits = (s: string) => s.replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660)).replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06F0)).replace(/\D/g, "");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ error: "يجب تسجيل الدخول" }, 401);
    const { data: me } = await admin.from("staff").select("role,active,hidden").eq("id", user.id).maybeSingle();
    if (!me || !me.active) return json({ error: "غير مسموح" }, 403);
    const isOwner = me.role === "owner";
    const allowed = isOwner ? ROLES : (CREW[me.role] || []);
    if (!allowed.length) return json({ error: "هذا الإجراء غير متاح لصفتك" }, 403);

    const body = await req.json();
    const { action } = body;
    if (body.id) {
      const { data: tgt } = await admin.from("staff").select("hidden,role").eq("id", body.id).maybeSingle();
      if (!tgt) return json({ error: "الحساب غير موجود" }, 404);
      if (tgt.hidden && !me.hidden) return json({ error: "غير مسموح" }, 403);
      if (!isOwner && !allowed.includes(tgt.role)) return json({ error: "هذا الحساب ليس من كادرك" }, 403);
    }
    if (body.role && !allowed.includes(body.role)) return json({ error: "لا يمكنك تعيين هذه الصفة" }, 403);

    if (action === "create") {
      let username = String(body.username || "").trim().toLowerCase();
      const phone = body.phone ? digits(String(body.phone)) : "";
      if (!username && phone) username = phone;
      if (phone && (phone.length < 10 || phone.length > 15)) return json({ error: "رقم الهاتف غير صحيح" }, 400);
      if (!/^[a-z0-9._-]{3,30}$/.test(username)) return json({ error: "اسم المستخدم يجب أن يكون 3 أحرف إنكليزية أو أرقام على الأقل بدون مسافات" }, 400);
      if (!body.role) return json({ error: "اختر الصفة" }, 400);
      if (String(body.password || "").length < 6) return json({ error: "الرمز السري 6 أحرف على الأقل" }, 400);
      const { data: exists } = await admin.from("staff").select("id").or(`username.eq.${username}${phone ? `,phone.eq.${phone}` : ""}`).maybeSingle();
      if (exists) return json({ error: "اسم المستخدم أو الرقم مسجل مسبقاً" }, 400);
      const { data: created, error } = await admin.auth.admin.createUser({
        email: `${username}@${DOMAIN}`, password: body.password, email_confirm: true,
        user_metadata: { username, full_name: body.full_name || "" },
      });
      if (error) return json({ error: error.message }, 400);
      const row: Record<string, unknown> = { id: created.user.id, username, full_name: body.full_name || username, role: body.role, active: true, status: "active", manager_id: user.id };
      if (phone) row.phone = phone;
      if (body.machine_id) row.machine_id = String(body.machine_id);
      const { error: e2 } = await admin.from("staff").insert(row);
      if (e2) { await admin.auth.admin.deleteUser(created.user.id); return json({ error: e2.message }, 400); }
      return json({ ok: true, id: created.user.id, username });
    }

    if (action === "update") {
      if (!body.id) return json({ error: "id مطلوب" }, 400);
      if (body.id === user.id && ((body.role && body.role !== me.role) || body.active === false)) return json({ error: "لا يمكنك إزالة صلاحيتك أنت" }, 400);
      const { data: cur } = await admin.from("staff").select("status").eq("id", body.id).maybeSingle();
      if (cur?.status === "pending" && body.active === false) delete body.active;
      const patch: Record<string, unknown> = {};
      if (body.role) patch.role = body.role;
      if (typeof body.full_name === "string" && body.full_name.trim()) patch.full_name = body.full_name.trim();
      if (typeof body.active === "boolean") { patch.active = body.active; if (body.active) patch.status = "active"; }
      if ("machine_id" in body) patch.machine_id = body.machine_id || null;
      if (Object.keys(patch).length) {
        const { error } = await admin.from("staff").update(patch).eq("id", body.id);
        if (error) return json({ error: error.message }, 400);
      }
      if (body.active === true) await admin.from("staff_codes").delete().eq("id", body.id);
      const authPatch: Record<string, unknown> = {};
      if (body.password) { if (String(body.password).length < 6) return json({ error: "الرمز السري 6 أحرف على الأقل" }, 400); authPatch.password = body.password; }
      if (body.active === false) authPatch.ban_duration = "876000h";
      if (body.active === true) authPatch.ban_duration = "none";
      if (Object.keys(authPatch).length) {
        const { error: e3 } = await admin.auth.admin.updateUserById(body.id, authPatch);
        if (e3) return json({ error: e3.message }, 400);
      }
      return json({ ok: true });
    }

    if (action === "delete") {
      if (!body.id || body.id === user.id) return json({ error: "لا يمكن حذف هذا الحساب" }, 400);
      const { error } = await admin.auth.admin.deleteUser(body.id);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: "إجراء غير معروف" }, 400);
  } catch (e) {
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
