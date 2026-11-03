import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// ورقة الحضور: الفورمن يصوّر الورقة → الذكاء الاصطناعي يقرا الأسماء (حتى بخط اليد) ويطابقها ويا قائمة العمال
// → العمال المطابقين بثقة عالية ينسجلون حاضرين تلقائياً، والباقي ينتظر مسؤول الإدارة.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });
const ROLES = ["foreman", "timekeeper", "project", "hr", "owner"];
const AUTO = 0.8;

const PROMPT = (list: string, typed: string, nimg: number) => `${nimg ? `أمامك ${nimg > 1 ? nimg + " صور" : "صورة"} رفعها الفورمن من سجلات العمل اليومية (ورقة حضور، جدول عمل، دفتر، أو صور شغل). إذا صورة ما بيها أسماء عمال (مثلاً صورة موقع أو شغل) تجاهلها.` : "ما أكو صور، بس أسماء كتبها الفورمن."}
${typed ? `وهذه أسماء الكادر اللي كتبها الفورمن بيده إنهم اشتغلوا اليوم (كلهم حاضرين):\n${typed}\n` : ""}
الأوراق تكون عادة لعمال موقع بناء بالعراق (ورقة حضور عمال مكتوبة بخط اليد أو مطبوعة، بالعربي غالباً، وأحياناً أسماء أجنبية مكتوبة بالعربي أو الإنكليزي، وقد يكون جنب الاسم ✓ أو × أو كلمة حاضر/غائب أو توقيع).
هذه قائمة العمال المسجلين بالنظام (الرقم|الاسم|الرمز|المهنة|الموقع):
${list}

المطلوب:
1) اقرأ كل اسم عامل مكتوب بالصور، وكل اسم كتبه الفورمن، كسطر مستقل كما هو مكتوب بالضبط (written). نفس الشخص إذا تكرر بأكثر من مكان اكتبه مرة وحدة.
2) طابقه ويا عامل واحد من القائمة (n = رقمه بالقائمة) حسب شكل الاسم والخط: انتبه للأخطاء الإملائية، اختصار الاسم الثلاثي، الألقاب، الهمزات والتاء المربوطة، وتشابه الحروف بخط اليد (مثل ح/ج/خ، س/ش، ر/ز، ف/ق، ة/ه، ي/ى). إذا الرمز مكتوب استخدمه. إذا ما تكدر تحدد عامل واحد بثقة ضع n = 0.
3) conf: ثقتك بالمطابقة من 0 إلى 1 (1 = متأكد تماماً). لا ترفع الثقة إذا أكثر من عامل يشبه الاسم.
4) mark: present إذا الاسم مأشر حاضر أو مكتوب بقائمة الحاضرين أو ما عليه إشارة غياب؛ absent إذا مأشر غائب أو مشطوب؛ leave إذا مكتوب إجازة.
5) date: التاريخ المكتوب على الورقة إن وجد بصيغة YYYY-MM-DD وإلا "".
لا تخترع أسماء غير موجودة بالورقة، ولا تطابق نفس العامل مرتين.
أجب بـ JSON فقط: {"date":"","rows":[{"written":"","n":0,"conf":0,"mark":"present"}],"unreadable":""}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
    const token = (req.headers.get("Authorization") || "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    if (!user) return json({ code: "auth" }, 401);
    const { data: me } = await admin.from("staff").select("role,active,branch,branches,cur_branch").eq("id", user.id).maybeSingle();
    if (!me || !me.active || !ROLES.includes(me.role)) return json({ code: "forbidden" }, 403);
    const brs: string[] = me.branches || ["mansour"];
    const branch: string = me.cur_branch && brs.includes(me.cur_branch) ? me.cur_branch : (brs.includes(me.branch) ? me.branch : brs[0]);

    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return json({ code: "no_key" }, 400);
    const body = await req.json();
    const { mime, day, img, src } = body;
    const images: string[] = (Array.isArray(body.images) ? body.images : body.image ? [body.image] : []).filter((x: unknown) => typeof x === "string" && (x as string).length > 200).slice(0, 4);
    if (images.some((x) => x.length > 7_000_000)) return json({ code: "bad_image" }, 400);
    const typedNames: string[] = (Array.isArray(body.names) ? body.names : []).map((x: unknown) => String(x || "").trim().slice(0, 80)).filter(Boolean).slice(0, 200);
    if (!images.length && !typedNames.length) return json({ id: null, applied: 0, pending: 0, total: 0, result: { rows: [] } });
    const imgs: string[] = (Array.isArray(body.imgs) ? body.imgs : img ? [img] : []).filter((x: unknown) => typeof x === "string").map((x: string) => x.slice(0, 300)).slice(0, 10);
    const today = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Baghdad" }).format(new Date());
    const d = /^\d{4}-\d{2}-\d{2}$/.test(String(day || "")) ? String(day) : today;
    if (d > today) return json({ code: "bad_day" }, 400);
    const media = ["image/jpeg", "image/png", "image/webp"].includes(mime) ? mime : "image/jpeg";

    const { data: ws } = await admin.from("workers").select("id,name,code,trade,site").eq("branch", branch).eq("active", true).order("name").limit(3000);
    const W = ws || [];
    if (!W.length) return json({ code: "no_workers" }, 400);
    const list = W.map((w, i) => `${i + 1}|${w.name}|${w.code || ""}|${w.trade || ""}|${w.site || ""}`).join("\n");

    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") || "claude-sonnet-5-5", max_tokens: 8000,
        messages: [{ role: "user", content: [...images.map((data) => ({ type: "image", source: { type: "base64", media_type: media, data } })), { type: "text", text: PROMPT(list, typedNames.join("\n"), images.length) }] }] }),
    });
    if (r.status === 429) return json({ code: "rate_limited" }, 429);
    if (!r.ok) return json({ code: "upstream", detail: (await r.text()).slice(0, 300) }, 502);
    const o = await r.json();
    const tx: string = (o.content || []).filter((c: { type: string }) => c.type === "text").map((c: { text: string }) => c.text).join("");
    const mm = tx.match(/\{[\s\S]*\}/);
    if (!mm) return json({ code: "bad_output" }, 502);
    const v = JSON.parse(mm[0]);

    const seen = new Set<string>();
    const rows = (Array.isArray(v.rows) ? v.rows : []).slice(0, 600).map((x: Record<string, unknown>) => {
      const n = Math.round(Number(x.n) || 0), w = n >= 1 && n <= W.length ? W[n - 1] : null;
      let conf = Math.max(0, Math.min(1, Number(x.conf) || 0));
      const mark = ["present", "absent", "leave"].includes(String(x.mark)) ? String(x.mark) : "present";
      const dup = !!(w && seen.has(w.id)); if (w && !dup) seen.add(w.id); if (dup) conf = Math.min(conf, 0.5);
      const auto = !!w && !dup && conf >= AUTO && mark === "present";
      return { written: String(x.written || "").slice(0, 120), wid: w?.id || null, name: w?.name || null, code: w?.code || null, conf: Math.round(conf * 100) / 100, mark, auto, state: auto ? "applied" : (mark === "present" ? "pending" : "info") };
    }).filter((x: { written: string }) => x.written);

    const { data: st } = await admin.from("settings").select("data").eq("branch", branch).eq("id", "main").maybeSingle();
    const start = String(st?.data?.att?.start || "07:00");
    const ids = rows.filter((x: { auto: boolean }) => x.auto).map((x: { wid: string }) => x.wid);
    let applied = 0;
    if (ids.length) {
      const { data: n, error } = await admin.rpc("att_sheet_apply", { p_branch: branch, p_day: d, p_wids: ids, p_by: user.id, p_start: start });
      if (error) return json({ code: "apply", detail: error.message }, 400);
      applied = Number(n) || 0;
    }
    const pending = rows.filter((x: { state: string }) => x.state === "pending").length;
    if (!rows.length) return json({ id: null, applied: 0, pending: 0, total: 0, result: { rows: [] } });
    const result = { date_on_sheet: String(v.date || ""), unreadable: String(v.unreadable || "").slice(0, 300), rows, imgs, src: ["work", "table", "sheet"].includes(src) ? src : "sheet", typed: typedNames.length, fph: typeof body.fph === "string" ? body.fph.slice(0, 60) : null };
    const { data: sh, error: e2 } = await admin.from("att_sheets").insert({ branch, day: d, uid: user.id, img: imgs[0] || null, result, applied, pending }).select("id").single();
    if (e2) return json({ code: "save", detail: e2.message }, 400);
    if (pending) await admin.from("notifications").insert({ branch, kind: "att_sheet", data: { id: sh.id, day: d, pending, applied, at: Date.now() } }).then(() => {}, () => {});
    return json({ id: sh.id, day: d, applied, pending, total: rows.length, result });
  } catch (e) {
    return json({ code: "error", detail: String((e as Error).message || e) }, 500);
  }
});
