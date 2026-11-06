import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Reads a vehicle number plate (Iraqi plates) from a photo taken at the gate.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

const PROMPT = `أمامك صورة سيارة أو لوحتها التقطها حارس بوابة في العراق. اقرأ لوحة التسجيل بدقة.
اللوحات العراقية فيها عادة رقم (أرقام عربية أو إنكليزية) واسم المحافظة أو حرف، وقد تكون لوحة قديمة أو حديثة أو مؤقتة أو حمل.
أجب بـ JSON فقط: {"plate":"الرقم مع المحافظة/الحرف كما هو مثل: بغداد 12345 أو 12345 أ بغداد","number":"الأرقام فقط","province":"المحافظة إن ظهرت","type":"نوع السيارة الظاهر (قلاب، تانكر، بيك أب، شاحنة، صالون، شفل...) أو فارغ","color":"لون السيارة أو فارغ","readable":true,"confidence":رقم من 0 إلى 1}
إذا اللوحة غير واضحة أو غير موجودة ضع readable=false واترك plate فارغ.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ code: "auth" }, 401);
    const { data: me } = await admin.from("staff").select("role,active").eq("id", user.id).maybeSingle();
    if (!me || !me.active || !["guard", "machines", "project", "owner"].includes(me.role)) return json({ code: "forbidden" }, 403);
    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return json({ code: "no_key" }, 400);
    const { image, mime } = await req.json();
    if (typeof image !== "string" || image.length < 200 || image.length > 7_000_000) return json({ code: "bad_image" }, 400);
    const media = ["image/jpeg", "image/png", "image/webp"].includes(mime) ? mime : "image/jpeg";
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 600, messages: [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: media, data: image } }, { type: "text", text: PROMPT }] }] }),
    });
    if (r.status === 429) return json({ code: "rate_limited" }, 429);
    if (!r.ok) return json({ code: "upstream", detail: (await r.text()).slice(0, 300) }, 502);
    const o = await r.json();
    const tx: string = (o.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
    const m = tx.match(/\{[\s\S]*\}/);
    if (!m) return json({ code: "bad_output" }, 502);
    const v = JSON.parse(m[0]);
    return json({ plate: String(v.plate || "").slice(0, 40), number: String(v.number || "").slice(0, 20), province: String(v.province || "").slice(0, 30), type: String(v.type || "").slice(0, 30), color: String(v.color || "").slice(0, 20), readable: !!v.readable, confidence: Number(v.confidence) || 0 });
  } catch (e) {
    return json({ code: "upstream", detail: String((e as Error).message || e) }, 500);
  }
});
