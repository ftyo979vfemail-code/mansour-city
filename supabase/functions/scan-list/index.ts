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

const PRICE_PROMPT = `أمامك ملف أو صورة فيها قائمة مواد/منتجات مع أسعارها (قائمة أسعار، فاتورة، عرض سعر، جرد مخزن). قد تكون بالعربي أو الإنكليزي، مطبوعة أو بخط اليد، وقد تكون جدولاً أو أسطراً.
استخرج كل مادة كسطر مستقل. لا تخترع مواد. لا تُدخل أسطر المجموع أو الضريبة أو الخصم أو العناوين.
- name: اسم المادة كما مكتوب (مع المواصفة أو الحجم إن وجد).
- price: سعر القطعة الواحدة بالدينار العراقي كرقم فقط بدون فواصل. إذا المكتوب سعر إجمالي وكمية فاقسم الإجمالي على الكمية. إذا السعر بالآلاف (مثل 25 ألف) اكتبه 25000. إذا لا يوجد سعر ضع null.
- qty: الكمية كرقم إن وجدت وإلا null.
- unit: الوحدة إن ذُكرت (قطعة، كارتون، علبة، متر، كغم، طن، لتر، برميل، لفة، كيس، طقم) وإلا "".
- sku: رمز أو رقم المادة إن وجد وإلا "".
أجب بـ JSON فقط: {"items":[{"name":"","price":0,"qty":null,"unit":"","sku":""}],"supplier":"اسم المورد أو المحل إن ظهر","currency":"العملة المكتوبة إن وجدت"}`;

const VERIFY_PROMPT = (kind: string) => `أنت مدقق فواتير. أمامك صورة التقطها موظف مخزن بالكاميرا ويُفترض أنها ${kind || "فاتورة أو وصل"} (فاتورة شراء، وصل استلام، وصل صرف وقود، قائمة مواد بأسعار، أو أي مستند ورقي/مطبوع/مكتوب بخط اليد فيه بيانات معاملة).
افحص بدقة:
1) is_invoice: هل الصورة لمستند ورقي من هذا النوع؟ (false إذا كانت صورة شخص، مكان، شاشة فارغة، منتج، آلية، أو أي شيء ليس مستنداً)
2) complete: هل المستند ظاهر كاملاً داخل الصورة بحوافه الأربعة دون قص لأي جزء مهم (الرأس، الجدول، المجموع، التوقيع)؟ إذا كان مقصوصاً أو قريباً جداً فهو false.
3) readable: هل الكتابة واضحة ومقروءة (غير مهزوزة/مظلمة/بعيدة جداً)؟
ثم استخرج ما تستطيع قراءته.
أجب بـ JSON فقط:
{"is_invoice":true,"complete":true,"readable":true,"problem":"too_close|cropped|blurry|dark|too_far|not_document|none","doc_type":"نوع المستند","number":"رقم الفاتورة أو الوصل أو فارغ","date":"التاريخ المكتوب أو فارغ","supplier":"اسم المورد أو الجهة أو فارغ","total":رقم أو null,"items":[{"name":"","qty":null,"price":null}]}`;

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
    const { image, mime, dept, stock, mode } = await req.json();
    const isPdf = mime === "application/pdf";
    if (typeof image !== "string" || image.length < 200 || image.length > (isPdf ? 30_000_000 : 7_000_000)) return json({ code: "bad_image" }, 400);
    const media = ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime) ? mime : "image/jpeg";
    if (mode === "verify") {
      const rv = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 2000, messages: [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: media, data: image } }, { type: "text", text: VERIFY_PROMPT(String(dept || "")) }] }] }),
      });
      if (rv.status === 429) return json({ code: "rate_limited" }, 429);
      if (!rv.ok) return json({ code: "upstream", detail: (await rv.text()).slice(0, 300) }, 502);
      const o = await rv.json();
      const tx: string = (o.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
      const mm = tx.match(/\{[\s\S]*\}/);
      if (!mm) return json({ code: "bad_output" }, 502);
      const v = JSON.parse(mm[0]);
      const num = (x: unknown) => { if (x === null || x === undefined || x === "") return null; const n = Number(String(x).replace(/[^\d.\-]/g, "")); return isFinite(n) ? n : null; };
      return json({ is_invoice: !!v.is_invoice, complete: !!v.complete, readable: !!v.readable, problem: String(v.problem || ""), doc_type: String(v.doc_type || "").slice(0, 60),
        number: String(v.number || "").slice(0, 40), date: String(v.date || "").slice(0, 40), supplier: String(v.supplier || "").slice(0, 120), total: num(v.total),
        items: (Array.isArray(v.items) ? v.items : []).slice(0, 60).map((x: Record<string, unknown>) => ({ name: String(x.name || "").slice(0, 120), qty: num(x.qty), price: num(x.price) })).filter((x: { name: string }) => x.name) });
    }
    if (mode === "prices") {
      const block = isPdf ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: image } } : { type: "image", source: { type: "base64", media_type: media, data: image } };
      const rp = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 16000, messages: [{ role: "user", content: [block, { type: "text", text: PRICE_PROMPT }] }] }),
      });
      if (rp.status === 429) return json({ code: "rate_limited" }, 429);
      if (!rp.ok) return json({ code: "upstream", detail: (await rp.text()).slice(0, 300) }, 502);
      const o = await rp.json();
      const tx: string = (o.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
      const mm = tx.match(/\{[\s\S]*\}/);
      if (!mm) return json({ code: "bad_output" }, 502);
      const pj = JSON.parse(mm[0]);
      const num = (v: unknown) => { if (v === null || v === undefined || v === "") return null; const n = Number(String(v).replace(/[^\d.\-]/g, "")); return isFinite(n) ? n : null; };
      const items = (Array.isArray(pj.items) ? pj.items : []).slice(0, 2000).map((x: Record<string, unknown>) => ({
        name: String(x.name || "").trim().slice(0, 160), price: num(x.price), qty: num(x.qty), unit: String(x.unit || "").slice(0, 20), sku: String(x.sku || "").slice(0, 60),
      })).filter((x: { name: string }) => x.name);
      return json({ items, supplier: String(pj.supplier || "").slice(0, 120), currency: String(pj.currency || "") });
    }
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
