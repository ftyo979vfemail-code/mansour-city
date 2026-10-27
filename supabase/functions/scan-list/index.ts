import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Reads a photographed (handwritten or printed) materials list and returns structured items.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

const PROMPT = (dept: string, stock: string) => `أنت أمين مخزن خبير في معمل إسمنت بالعراق. أمامك صورة ورقة طلب مواد كتبها قسم ${dept || "غير محدد"} (قد تكون بخط اليد، بالعربي أو الإنكليزي أو مختلطة، وقد تحتوي أرقام قطع ومواصفات).
استخرج كل مادة مطلوبة كسطر مستقل. لا تخترع مواد غير موجودة في الورقة. إذا كانت الكمية غير مكتوبة ضع 1. إذا لم تستطع قراءة كلمة ضعها كما تراها وخفّض الثقة.
صنّف كل مادة في واحدة من الفئات: محامل، كهرباء، زيوت وشحوم، فلاتر، قطع غيار ميكانيكية، أحزمة وسيور، براغي وعدد، لحام وقطع، مواد بناء، سلامة، أخرى.
وحّد الوحدة إلى واحدة من: قطعة، متر، كغم، طن، لتر، برميل، لفة، علبة، طقم، كيس.
${stock ? `هذه أسماء مواد موجودة بالمخزن، إذا كانت المادة نفسها اكتب اسمها الموجود حرفياً في الحقل match:\n${stock}\n` : ""}
أجب بـ JSON فقط بهذا الشكل:
{"items":[{"name":"اسم المادة واضح ومختصر مع المواصفة","qty":رقم,"unit":"الوحدة","category":"الفئة","notes":"رقم القطعة أو الماكنة أو أي ملاحظة مكتوبة","match":"اسم المادة المطابقة بالمخزن أو نص فارغ","confidence":رقم من 0 إلى 1}],"header":{"date":"التاريخ إن وجد","signed_by":"الاسم أو التوقيع إن وجد","machine":"الماكنة أو المكان إن ذُكر"},"unreadable":"أي أجزاء لم تُقرأ، أو نص فارغ"}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ code: "auth" }, 401);
    const { data: me } = await admin.from("staff").select("role,active").eq("id", user.id).maybeSingle();
    if (!me || !me.active || ["clerk"].includes(me.role)) return json({ code: "forbidden" }, 403);

    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return json({ code: "no_key" }, 400);
    const { image, mime, dept, stock } = await req.json();
    if (typeof image !== "string" || image.length < 1000 || image.length > 7_000_000) return json({ code: "bad_image" }, 400);
    const media = ["image/jpeg", "image/png", "image/webp"].includes(mime) ? mime : "image/jpeg";
    const stockList = Array.isArray(stock) ? stock.slice(0, 300).map((s: unknown) => String(s).slice(0, 80)).join("، ") : "";

    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5",
        max_tokens: 3000,
        messages: [{ role: "user", content: [
          { type: "image", source: { type: "base64", media_type: media, data: image } },
          { type: "text", text: PROMPT(String(dept || ""), stockList) },
        ] }],
      }),
    });
    if (r.status === 429) return json({ code: "rate_limited" }, 429);
    if (!r.ok) return json({ code: "upstream", detail: (await r.text()).slice(0, 300) }, 502);
    const out = await r.json();
    const text: string = (out.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
    const m = text.match(/\{[\s\S]*\}/);
    if (!m) return json({ code: "bad_output" }, 502);
    const parsed = JSON.parse(m[0]);
    const items = (Array.isArray(parsed.items) ? parsed.items : []).slice(0, 80).map((x: Record<string, unknown>) => ({
      name: String(x.name || "").slice(0, 120), qty: Math.max(0, Number(x.qty) || 1), unit: String(x.unit || "قطعة").slice(0, 20),
      category: String(x.category || "أخرى").slice(0, 40), notes: String(x.notes || "").slice(0, 200), match: String(x.match || "").slice(0, 120),
      confidence: Math.max(0, Math.min(1, Number(x.confidence) || 0.5)),
    })).filter((x: { name: string }) => x.name);
    return json({ items, header: parsed.header || {}, unreadable: String(parsed.unreadable || "") });
  } catch (e) {
    return json({ code: "upstream", detail: String((e as Error).message || e) }, 500);
  }
});
