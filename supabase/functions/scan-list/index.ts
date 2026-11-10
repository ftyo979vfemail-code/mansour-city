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
{"is_invoice":true,"complete":true,"readable":true,"problem":"too_close|cropped|blurry|dark|too_far|not_document|none","doc_type":"نوع المستند","number":"رقم الفاتورة أو الوصل أو فارغ","date":"التاريخ بصيغة YYYY-MM-DD إن أمكن وإلا كما مكتوب","supplier":"اسم المورد أو الشركة أو المحل (البائع وليس الزبون) أو فارغ","customer":"اسم الزبون المكتوب أو فارغ","payment":"credit|cash|","delivery":رقم أو null,"prev_balance":رقم أو null,"total":رقم أو null,"items":[{"name":"","qty":null,"unit":"","price":null}]}
ملاحظات الاستخراج:
- payment: credit إذا مكتوب ذمم أو آجل أو دين أو On credit أو بالحساب؛ cash إذا مكتوب نقداً أو واصل أو مدفوع أو Cash؛ وإلا فارغ.
- delivery: أجور النقل أو التوصيل أو التحميل إن وجدت (ليست مادة).
- prev_balance: الرصيد السابق إن كان مكتوباً.
- items: كل مادة سطر. price سعر الوحدة بالدينار كرقم كامل (إذا مكتوب 13 أو 190 بمعنى الآلاف حسب المجموع اكتبه 13000 أو 190000). qty الكمية المحاسب عليها (مثلاً الأمتار إذا السعر بالمتر). unit: قطعة، متر، م²، كيس، علبة، كارتون، لتر، كغم، طن.
- تأكد أن qty × price يساوي مبلغ السطر، وأن مجموع الأسطر + delivery = total.`;

const CT_PROMPT = (hint: string) => `أمامك سجل مقاولين من نظام قديم لشركة مقاولات بناء (Excel أو PDF أو صورة، عربي أو إنكليزي، مطبوع أو بخط اليد). ${hint}
الملف ممكن يكون أي شكل: كل ورقة/صفحة لمقاول واسمه بالعنوان أو اسم الورقة، أو جدول واحد لكل المقاولين، أو كشف حساب (مدين/دائن/رصيد)، أو مستخلصات وذرعات.
استخرج كل حركة مالية بالملف بدون استثناء، سطراً سطراً:
- name: اسم المقاول (إذا مكتوب بالعنوان أو اسم الورقة طبّقه على كل أسطرها).
- kind: "pay" إذا مبلغ مدفوع/مصروف/سلفة/دفعة/صرف للمقاول، "bill" إذا قيمة عمل منجز/مستخلص/ذرعة/استحقاق للمقاول. بكشف الحساب: المدفوع للمقاول = pay، المستحق له = bill.
- amount: المبلغ رقم فقط بدون فواصل. cur: "IQD" أو "USD" ($ أو دولار).
- day: التاريخ YYYY-MM-DD إذا موجود.
- building, work (وصف الشغل، الطوابق، الكمية، سعر الوحدة)، engineer، trade (اختصاص المقاول)، note.
لا تحسب أسطر المجموع أو الرصيد أو المدور كحركات. إذا الكمية × سعر الوحدة بدون مبلغ، احسب المبلغ. اختصر: لا تكتب أي حقل فارغ، واكتب JSON مضغوط بدون مسافات.
أجب بـ JSON فقط: {"entries":[{"name":"","kind":"pay","amount":0,"cur":"IQD","day":"","building":"","work":"","engineer":"","trade":"","note":""}],"notes":[]}`;

const PB_PROMPT = (hint: string) => `أمامك سجل صندوق صرف (عهدة) لمسؤولة صرف بشركة مقاولات بناء من نظام قديم (Excel أو PDF أو صورة، عربي أو إنكليزي، مطبوع أو بخط اليد). ${hint}
الملف ممكن يكون أي شكل: دفتر يومية، كشف وارد/صادر، مدين/دائن/رصيد، قوائم مصاريف، أوراق لكل شهر.
استخرج كل حركة مالية بالملف بدون استثناء، سطراً سطراً:
- kind: "fund" إذا مبلغ استلمته (وارد، مقبوض، عهدة، تمويل، استلام من الحسابات أو المدير). "exp" إذا مبلغ صرفته (صادر، مصروف، مدفوع، شراء، أجور، سلفة لأحد).
- amount: المبلغ رقم فقط بدون فواصل. cur: "IQD" أو "USD" ($ أو دولار).
- day: التاريخ YYYY-MM-DD إذا موجود.
- party: الجهة أو الشخص المستلم أو المسلّم. category: نوع المصروف باختصار (مواد، أجور، نقل، وقود، طعام، صيانة، نثرية...). ref: رقم الوصل. note: البيان/التفاصيل.
لا تحسب أسطر المجموع أو الرصيد أو المدور كحركات. اختصر: لا تكتب أي حقل فارغ، واكتب JSON مضغوط بدون مسافات.
أجب بـ JSON فقط: {"entries":[{"kind":"exp","amount":0,"cur":"IQD","day":"","party":"","category":"","ref":"","note":""}],"notes":[]}`;

const BK_PROMPT = (hint: string) => `أمامك ملف حجز شقة/وحدة سكنية من نظام قديم لمجمع سكني (عقد حجز، استمارة، كشف حساب مشتري، وصولات قبض، جدول أقساط — Excel أو PDF أو صورة، عربي أو إنكليزي، مطبوع أو بخط اليد). ${hint}
استخرج بيانات الحجز وكل الدفعات المدفوعة فعلاً بدون استثناء:
- buyer: name (اسم المشتري الكامل), phone, id_no (رقم الهوية/البطاقة), address.
- plan: total (السعر الكلي بعد الخصم), down (المقدمة), handover (دفعة الاستلام), monthly (القسط الشهري), months (عدد الأقساط), start_month (أول قسط YYYY-MM-DD), signed_on (تاريخ الحجز/العقد YYYY-MM-DD), area (المساحة م2), price_m (سعر المتر), unit (رقم الشقة/الوحدة كما مكتوب).
- payments: كل مبلغ مستلم من المشتري: day (YYYY-MM-DD), amount (رقم بالدينار بدون فواصل), cur ("IQD" أو "USD"), ref (رقم الوصل), note (عن شنو: مقدمة، قسط 3، دفعة استلام...).
لا تحسب الأقساط المستقبلية غير المدفوعة كدفعات. لا تكرر نفس الوصل. أسطر المجموع والرصيد ليست دفعات. إذا الحقل مو موجود اتركه فارغ.
أجب بـ JSON فقط ومضغوط: {"buyer":{"name":"","phone":"","id_no":"","address":""},"plan":{"total":0,"down":0,"handover":0,"monthly":0,"months":0,"start_month":"","signed_on":"","area":0,"price_m":0,"unit":""},"payments":[{"day":"","amount":0,"cur":"IQD","ref":"","note":""}],"notes":[]}`;

const TABLE_PROMPT = `أمامك ملف أو صورة فيها جدول بيانات (قوائم مشترين أو مستأجرين أو حجوزات أو عقود أو وحدات سكنية) من نظام قديم. قد يكون بالعربي أو الإنكليزي، مطبوع أو بخط اليد.
انقل الجدول كما هو حرفياً: سطر العناوين ثم كل سطر بيانات. لا تترجم ولا تغيّر الأسماء أو الأرقام، ولا تحذف أي سطر بيانات، ولا تضف أسطر المجاميع.
إذا الجدول ممتد على عدة صفحات اجمعها كلها بنفس الأعمدة. إذا خلية فارغة اكتب "".
أجب بـ JSON فقط: {"header":["العنوان1","العنوان2"],"rows":[["قيمة","قيمة"]]}`;

const FUEL_PROMPT = `أمامك كشف حساب من محطة وقود (كاز/ديزل/بنزين) مرسل لشركة. قد يكون صورة أو PDF أو جدول منسوخ من Excel، بالعربي أو الإنكليزي، مطبوع أو بخط اليد.
استخرج كل عملية تجهيز/تعبئة كسطر مستقل بالترتيب. لا تخترع أسطر. لا تُدخل أسطر المجموع أو الرصيد المدور أو الدفعات (الدفعات ضعها في payments).
- date: تاريخ العملية بصيغة YYYY-MM-DD (السنة إذا ناقصة خمّنها من سياق الكشف).
- liters: الكمية باللتر كرقم (إذا مكتوبة بالمتر المكعب حوّلها ×1000، وإذا بالبرميل اتركها واكتب الوحدة في note).
- price: سعر اللتر بالدينار كرقم أو null.
- amount: مبلغ السطر بالدينار كرقم أو null.
- ref: رقم الوصل أو القسيمة إن وجد.
- vehicle: رقم السيارة أو التانكر أو اسم السائق أو المستلم إن وجد.
- fuel: نوع الوقود (كاز، بنزين، ...) إن ذُكر.
- note: أي ملاحظة على السطر.
تأكد أن liters × price = amount عندما تكون كلها موجودة.
أجب بـ JSON فقط: {"station":"اسم المحطة","from":"YYYY-MM-DD","to":"YYYY-MM-DD","lines":[{"date":"","liters":0,"price":null,"amount":null,"ref":"","vehicle":"","fuel":"","note":""}],"payments":[{"date":"","amount":0,"note":""}],"total_liters":null,"total_amount":null,"balance":null}`;

const FUEL_AUDIT = (ex: string) => `أنت مدقق حسابات. أمامك نفس كشف محطة الوقود، وهذا ما استُخرج منه آلياً (JSON، الأسطر مرقمة من 0):
${ex}
قارن الاستخراج بالكشف سطراً سطراً بدقة 100%:
- أي سطر موجود بالكشف وغير موجود بالاستخراج ضعه في missing بنفس شكل الأسطر.
- أي سطر بالاستخراج غير موجود بالكشف (مكرر أو مخترع أو سطر مجموع/رصيد) ضع رقمه في extra.
- أي رقم أو تاريخ مقروء خطأ (لترات، سعر، مبلغ، تاريخ، رقم وصل) ضعه في fix: {"i":رقم السطر,"field":"liters|price|amount|date|ref|vehicle","value":القيمة الصحيحة كما بالكشف}.
- صحح from/to/total_liters/total_amount/balance إذا خطأ في header.
- اكتب في notes أي ملاحظة مهمة للمحاسب (أسطر غير واضحة، شطب، تعديل باليد، اختلاف المجموع المكتوب عن مجموع الأسطر).
لا تغيّر شيئاً صحيحاً. أجب بـ JSON فقط: {"fix":[],"missing":[],"extra":[],"header":{},"notes":[],"confidence":رقم من 0 إلى 1}`;

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
    const { image, mime, dept, stock, mode, text: srcText } = await req.json();
    if (mode === "fuel") {
      const isPdfF = mime === "application/pdf";
      let block: Record<string, unknown>;
      if (typeof srcText === "string" && srcText.trim().length > 10) block = { type: "text", text: "الكشف (منسوخ من Excel/CSV):\n" + srcText.slice(0, 200_000) };
      else if (typeof image === "string" && image.length >= 200 && image.length <= (isPdfF ? 30_000_000 : 7_000_000)) block = isPdfF ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: image } } : { type: "image", source: { type: "base64", media_type: ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime) ? mime : "image/jpeg", data: image } };
      else return json({ code: "bad_image" }, 400);
      const rf = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 16000, messages: [{ role: "user", content: [block, { type: "text", text: FUEL_PROMPT }] }] }),
      });
      if (rf.status === 429) return json({ code: "rate_limited" }, 429);
      if (!rf.ok) return json({ code: "upstream", detail: (await rf.text()).slice(0, 300) }, 502);
      const o = await rf.json();
      const tx: string = (o.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
      const mm = tx.match(/\{[\s\S]*\}/);
      if (!mm) return json({ code: "bad_output" }, 502);
      const fj = JSON.parse(mm[0]);
      const num = (v: unknown) => { if (v === null || v === undefined || v === "") return null; const n = Number(String(v).replace(/[^\d.\-]/g, "")); return isFinite(n) ? n : null; };
      const str = (v: unknown, n: number) => String(v ?? "").slice(0, n);
      // second pass: independent audit against the document
      const audit = { fixed: 0, added: 0, removed: 0, notes: [] as string[], confidence: null as number | null, ok: false };
      try {
        const lines0 = Array.isArray(fj.lines) ? fj.lines : [];
        const ex = JSON.stringify({ from: fj.from, to: fj.to, total_liters: fj.total_liters, total_amount: fj.total_amount, balance: fj.balance, lines: lines0.map((x: Record<string, unknown>, i: number) => ({ i, ...x })) });
        const ra = await fetch("https://api.anthropic.com/v1/messages", {
          method: "POST",
          headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
          body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 16000, messages: [{ role: "user", content: [block, { type: "text", text: FUEL_AUDIT(ex.slice(0, 150_000)) }] }] }),
        });
        if (ra.ok) {
          const ao = await ra.json();
          const at: string = (ao.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
          const am = at.match(/\{[\s\S]*\}/);
          if (am) {
            const A = JSON.parse(am[0]);
            for (const f of (Array.isArray(A.fix) ? A.fix : [])) {
              const i = Number(f.i), k = String(f.field || "");
              if (lines0[i] && ["liters", "price", "amount", "date", "ref", "vehicle"].includes(k)) { lines0[i][k] = f.value; lines0[i]._fixed = (lines0[i]._fixed || []).concat(k); audit.fixed++; }
            }
            const ext = new Set((Array.isArray(A.extra) ? A.extra : []).map((x: unknown) => Number(x)));
            audit.removed = ext.size;
            const kept = lines0.filter((_: unknown, i: number) => !ext.has(i));
            const miss = (Array.isArray(A.missing) ? A.missing : []).map((x: Record<string, unknown>) => ({ ...x, _added: true }));
            audit.added = miss.length;
            fj.lines = kept.concat(miss);
            const H = A.header || {};
            for (const k of ["from", "to", "total_liters", "total_amount", "balance"]) if (H[k] !== undefined && H[k] !== null && H[k] !== "") fj[k] = H[k];
            audit.notes = (Array.isArray(A.notes) ? A.notes : []).slice(0, 20).map((x: unknown) => String(x).slice(0, 300));
            audit.confidence = num(A.confidence);
            audit.ok = true;
          }
        }
      } catch (_) { /* keep first pass */ }
      return json({ audit, station: str(fj.station, 120), from: str(fj.from, 20), to: str(fj.to, 20),
        lines: (Array.isArray(fj.lines) ? fj.lines : []).slice(0, 3000).map((x: Record<string, unknown>) => ({ date: str(x.date, 20), liters: num(x.liters), price: num(x.price), amount: num(x.amount), ref: str(x.ref, 40), vehicle: str(x.vehicle, 80), fuel: str(x.fuel, 20), note: str(x.note, 160), fixed: Array.isArray(x._fixed) ? x._fixed : undefined, added: x._added ? true : undefined })).filter((x: { liters: number | null; amount: number | null }) => x.liters || x.amount),
        payments: (Array.isArray(fj.payments) ? fj.payments : []).slice(0, 200).map((x: Record<string, unknown>) => ({ date: str(x.date, 20), amount: num(x.amount), note: str(x.note, 120) })),
        total_liters: num(fj.total_liters), total_amount: num(fj.total_amount), balance: num(fj.balance) });
    }
    if (mode === "booking") {
      const isPdfB = mime === "application/pdf";
      let block: Record<string, unknown>;
      if (typeof srcText === "string" && srcText.trim().length > 5) block = { type: "text", text: "محتوى الملف (منسوخ من Excel):\n" + srcText.slice(0, 150_000) };
      else if (typeof image === "string" && image.length >= 200 && image.length <= (isPdfB ? 30_000_000 : 7_000_000)) block = isPdfB ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: image } } : { type: "image", source: { type: "base64", media_type: ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime) ? mime : "image/jpeg", data: image } };
      else return json({ code: "bad_image" }, 400);
      const rb = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 16000, messages: [{ role: "user", content: [block, { type: "text", text: BK_PROMPT(String(dept || "")) }] }] }),
      });
      if (rb.status === 429) return json({ code: "rate_limited" }, 429);
      if (!rb.ok) return json({ code: "upstream", detail: (await rb.text()).slice(0, 300) }, 502);
      const o = await rb.json();
      const tx: string = (o.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
      let bj: Record<string, any> = {};
      const mm = tx.match(/\{[\s\S]*\}/);
      try { bj = JSON.parse(mm ? mm[0] : "{}"); } catch { bj = {}; }
      const num = (x: unknown) => { const n = Number(String(x ?? "").replace(/[^\d.]/g, "")); return isFinite(n) && n > 0 ? n : 0; };
      const st = (x: unknown, n: number) => String(x ?? "").replace(/\s+/g, " ").trim().slice(0, n);
      const dy = (x: unknown) => /^\d{4}-\d{2}-\d{2}$/.test(String(x || "")) ? String(x) : "";
      const b = bj.buyer || {}, pl = bj.plan || {};
      return json({
        buyer: { name: st(b.name, 120), phone: st(b.phone, 30), id_no: st(b.id_no, 40), address: st(b.address, 200) },
        plan: { total: num(pl.total), down: num(pl.down), handover: num(pl.handover), monthly: num(pl.monthly), months: Math.round(num(pl.months)), start_month: dy(pl.start_month), signed_on: dy(pl.signed_on), area: num(pl.area), price_m: num(pl.price_m), unit: st(pl.unit, 40) },
        payments: (Array.isArray(bj.payments) ? bj.payments : []).slice(0, 1000).map((p: Record<string, unknown>) => ({ day: dy(p.day), amount: num(p.amount), cur: /usd|\$|دولار/i.test(String(p.cur || "")) ? "USD" : "IQD", ref: st(p.ref, 40), note: st(p.note, 200) })).filter((p: { amount: number }) => p.amount > 0),
        notes: (Array.isArray(bj.notes) ? bj.notes : []).slice(0, 10).map((x: unknown) => st(x, 300)), truncated: o.stop_reason === "max_tokens" });
    }
    if (mode === "contractors" || mode === "pbox") {
      const isPdfC = mime === "application/pdf";
      let block: Record<string, unknown>;
      if (typeof srcText === "string" && srcText.trim().length > 5) block = { type: "text", text: "محتوى الملف (منسوخ من Excel، كل ورقة باسمها):\n" + srcText.slice(0, 120_000) };
      else if (typeof image === "string" && image.length >= 200 && image.length <= (isPdfC ? 30_000_000 : 7_000_000)) block = isPdfC ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: image } } : { type: "image", source: { type: "base64", media_type: ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime) ? mime : "image/jpeg", data: image } };
      else return json({ code: "bad_image" }, 400);
      const rc = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 16000, messages: [{ role: "user", content: [block, { type: "text", text: (mode === "pbox" ? PB_PROMPT : CT_PROMPT)(String(dept || "")) }] }] }),
      });
      if (rc.status === 429) return json({ code: "rate_limited" }, 429);
      if (!rc.ok) return json({ code: "upstream", detail: (await rc.text()).slice(0, 300) }, 502);
      const o = await rc.json();
      let tx: string = (o.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
      let cj: Record<string, unknown> = {};
      const mm = tx.match(/\{[\s\S]*\}/);
      try { cj = JSON.parse(mm ? mm[0] : "{}"); } catch {
        const cut = tx.lastIndexOf("},"); if (cut > 0) { try { cj = JSON.parse(tx.slice(tx.indexOf("{"), cut + 1) + "]}"); } catch { cj = {}; } }
      }
      const num = (x: unknown) => { const n = Number(String(x ?? "").replace(/[^\d.]/g, "")); return isFinite(n) && n > 0 ? n : 0; };
      const st = (x: unknown, n: number) => String(x ?? "").replace(/\s+/g, " ").trim().slice(0, n);
      const cur = (e: Record<string, unknown>) => /usd|\$|دولار/i.test(String(e.cur || "")) ? "USD" : "IQD";
      const dy = (e: Record<string, unknown>) => /^\d{4}-\d{2}-\d{2}$/.test(String(e.day || "")) ? String(e.day) : "";
      if (mode === "pbox") {
        const pe = (Array.isArray(cj.entries) ? cj.entries : []).slice(0, 4000).map((e: Record<string, unknown>) => ({ kind: e.kind === "fund" ? "fund" : "exp", amount: num(e.amount), cur: cur(e), day: dy(e), party: st(e.party, 120), category: st(e.category, 60), ref: st(e.ref, 40), note: st(e.note, 300) })).filter((e: { amount: number }) => e.amount > 0);
        return json({ entries: pe, notes: (Array.isArray(cj.notes) ? cj.notes : []).slice(0, 20).map((x: unknown) => st(x, 300)), truncated: o.stop_reason === "max_tokens" });
      }
      const entries = (Array.isArray(cj.entries) ? cj.entries : []).slice(0, 4000).map((e: Record<string, unknown>) => ({ name: st(e.name, 120), kind: e.kind === "bill" ? "bill" : "pay", amount: num(e.amount), cur: cur(e), day: dy(e), building: st(e.building, 60), work: st(e.work, 400), engineer: st(e.engineer, 80), trade: st(e.trade, 60), note: st(e.note, 300) })).filter((e: { name: string; amount: number }) => e.name && e.amount > 0);
      return json({ entries, notes: (Array.isArray(cj.notes) ? cj.notes : []).slice(0, 20).map((x: unknown) => st(x, 300)), truncated: o.stop_reason === "max_tokens" });
    }
    const isPdf = mime === "application/pdf";
    if (typeof image !== "string" || image.length < 200 || image.length > (isPdf ? 30_000_000 : 7_000_000)) return json({ code: "bad_image" }, 400);
    const media = ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mime) ? mime : "image/jpeg";
    if (mode === "verify") {
      const rv = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 4000, messages: [{ role: "user", content: [isPdf ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: image } } : { type: "image", source: { type: "base64", media_type: media, data: image } }, { type: "text", text: VERIFY_PROMPT(String(dept || "")) }] }] }),
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
        number: String(v.number || "").slice(0, 40), date: String(v.date || "").slice(0, 40), supplier: String(v.supplier || "").slice(0, 120), customer: String(v.customer || "").slice(0, 120),
        payment: ["credit", "cash"].includes(String(v.payment)) ? String(v.payment) : "", delivery: num(v.delivery), prev_balance: num(v.prev_balance), total: num(v.total),
        items: (Array.isArray(v.items) ? v.items : []).slice(0, 60).map((x: Record<string, unknown>) => ({ name: String(x.name || "").slice(0, 120), qty: num(x.qty), unit: String(x.unit || "").slice(0, 20), price: num(x.price) })).filter((x: { name: string }) => x.name) });
    }
    if (mode === "table") {
      const block = isPdf ? { type: "document", source: { type: "base64", media_type: "application/pdf", data: image } } : { type: "image", source: { type: "base64", media_type: media, data: image } };
      const rt = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 16000, messages: [{ role: "user", content: [block, { type: "text", text: TABLE_PROMPT }] }] }),
      });
      if (rt.status === 429) return json({ code: "rate_limited" }, 429);
      if (!rt.ok) return json({ code: "upstream", detail: (await rt.text()).slice(0, 300) }, 502);
      const o = await rt.json();
      const tx: string = (o.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
      const mm = tx.match(/\{[\s\S]*\}/);
      if (!mm) return json({ code: "bad_output" }, 502);
      const tj = JSON.parse(mm[0]);
      const header = (Array.isArray(tj.header) ? tj.header : []).slice(0, 40).map((x: unknown) => String(x ?? "").slice(0, 80));
      const rows = (Array.isArray(tj.rows) ? tj.rows : []).slice(0, 5000).map((r: unknown[]) => (Array.isArray(r) ? r : []).slice(0, 40).map((x) => String(x ?? "").slice(0, 300)));
      return json({ header, rows });
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
