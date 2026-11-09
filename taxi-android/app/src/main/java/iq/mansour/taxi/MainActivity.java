package iq.mansour.taxi;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONObject;

/** Driver screen: sign in with the 6-digit code, grant permissions once, then tracking runs on its own. */
public class MainActivity extends Activity {
    static final int AMBER = 0xFFFEBD02, INK = 0xFF2A1D00, BG = 0xFFF3F2EE, FG = 0xFF1B1D22,
            MUTED = 0xFF6C6A63, OK = 0xFF16935A, BAD = 0xFFD6332B, CARD = 0xFFFFFFFF, LINE = 0xFFE0DDD4;
    static final int RQ_FINE = 1, RQ_BG = 2, RQ_NOTIF = 3;

    private final Handler h = new Handler(Looper.getMainLooper());
    private LinearLayout root;
    private TextView status, sub, sent, acc, spd, count;
    private LinearLayout setup;
    private LinearLayout ringView;
    private LinearLayout tripBox;
    private String tripKey = "";
    // "the customer changed his mind": 30 s for the office, else two fares
    private TextView chgLeft; private long chgUntil;
    private final Runnable chgTick = new Runnable() { @Override public void run() {
        if (chgLeft == null) return;
        long left = Math.max(0, (chgUntil - System.currentTimeMillis()) / 1000);
        chgLeft.setText(String.format(java.util.Locale.US, "0:%02d", left));
        if (left > 0) h.postDelayed(this, 1000); else h.postDelayed(() -> { tripKey = ""; loadTrip(); }, 1500);
    } };

    private void addDestChange(LinearLayout card, JSONObject t, JSONObject st, boolean waiting) {
        java.util.Locale L = java.util.Locale.US;
        JSONObject dc = t.optJSONObject("dest_change");
        String status = dc == null ? "" : dc.optString("status");
        if (status.equals("pending") || status.equals("awaiting_customer")) {
            LinearLayout b = new LinearLayout(this);
            b.setOrientation(LinearLayout.VERTICAL);
            b.setPadding(dp(12), dp(10), dp(12), dp(10));
            b.setBackground(box(0xFFFFF1DE, 0xFFD97706, 12));
            b.addView(text(dc.optString("title"), 16, FG, true));
            b.addView(text(dc.optString("msg"), 13, MUTED, false));
            chgLeft = text("", 22, FG, true);
            chgLeft.setTypeface(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.BOLD);
            b.addView(text(status.equals("awaiting_customer") ? "إذا ما ردّ الزبون خلال دقيقة يتغيّر وحده" : "جارٍ التغيير", 12, MUTED, false));
            b.addView(chgLeft);
            card.addView(space(8));
            card.addView(b, full());
            chgUntil = System.currentTimeMillis() + dc.optInt("seconds_left", 60) * 1000L;
            h.post(chgTick);
            return;
        }
        chgLeft = null;
        if (dc != null) {
            boolean bad = status.equals("customer_refused") || status.equals("reverted");
            String m = dc.optString("msg");
            TextView done = text(dc.optString("title") + (m.isEmpty() ? "" : "\n" + m), 14, bad ? 0xFFB42318 : OK, true);
            done.setBackground(box(bad ? 0xFFFDECEA : 0xFFE7F6EE, bad ? 0xFFB42318 : OK, 12));
            done.setPadding(dp(12), dp(10), dp(12), dp(10));
            card.addView(space(8));
            card.addView(done, full());
        }
        if (waiting) return;
        final org.json.JSONArray zones = st.optJSONArray("zones");
        if (zones == null) return;
        card.addView(space(8));
        Button chg = button("🔀 الزبون غيّر مساره", false);
        chg.setOnClickListener(v -> {
            final java.util.List<String> labels = new java.util.ArrayList<>();
            final java.util.List<Integer> ids = new java.util.ArrayList<>();
            for (int i = 0; i < zones.length(); i++) {
                JSONObject z = zones.optJSONObject(i);
                if (z.optInt("id") == t.optInt("zone_id", -1)) continue;
                labels.add(z.optString("name") + " — " + String.format(L, "%,d", z.optInt("price")));
                ids.add(z.optInt("id"));
            }
            new android.app.AlertDialog.Builder(this).setTitle("🔀 وين يريد يروح هسه؟")
                    .setItems(labels.toArray(new String[0]), (d, w) -> new android.app.AlertDialog.Builder(this)
                            .setTitle("تغيير الوجهة إلى " + labels.get(w).split(" — ")[0] + "؟")
                            .setMessage("الأجرة تنحسب حسب شكد مشيت من الطريق:\n• قبل الثلث: سعر المنطقة الجديدة بس\n• بالنص: نص الكروة القديمة + الجديدة\n• بعد الثلثين: كروتين\nإذا الزبون عنده حساب يأكّد من تلفونه.")
                            .setNegativeButton("رجوع", null)
                            .setPositiveButton("إرسال", (d2, w2) -> changeDest(ids.get(w))).show())
                    .setNegativeButton("رجوع", null).show();
        });
        card.addView(chg, full());
    }

    private void changeDest(int zone) {
        final String code = Prefs.code(this);
        if (code == null) return;
        new Thread(() -> {
            try {
                Api.call("taxi_driver_change_dest", new JSONObject().put("p_code", code).put("p_zone", zone));
                h.post(() -> { android.widget.Toast.makeText(this, "انسجل التغيير", android.widget.Toast.LENGTH_SHORT).show(); tripKey = ""; loadTrip(); });
            } catch (Exception e) {
                h.post(() -> android.widget.Toast.makeText(this, e instanceof Api.ApiError ? e.getMessage() : "ماكو إنترنت", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }
    // live waiting timer / fare on the running trip card
    private int waitBase; private long waitFrom; private boolean waitRunning; private JSONObject waitTrip;
    private EditText waitFare; private TextView waitClock, waitNote, waitTotal;
    private final Runnable waitTick = new Runnable() { @Override public void run() { updateWait(); if (waitRunning) h.postDelayed(this, 1000); } };
    // free clock while the driver waits for the customer at pickup (no money)
    private int pwBase; private long pwFrom; private TextView pwClock;
    private final Runnable pwTick = new Runnable() { @Override public void run() {
        if (pwClock == null) return;
        pwClock.setText(clock(pwBase + (int) ((System.currentTimeMillis() - pwFrom) / 1000)));
        h.postDelayed(this, 1000); } };

    // paid waiting meter ("انتظرني هنا"): tiers [{m,f}], the last tier is the cycle (e.g. 60 min = 5000)
    static int[][] tiers(JSONObject t) {
        org.json.JSONArray a = t == null ? null : t.optJSONArray("wait_tiers");
        if (a == null || a.length() == 0) return new int[][]{{10, 250}, {15, 1500}, {30, 2500}, {60, 5000}};
        int[][] r = new int[a.length()][2];
        for (int i = 0; i < a.length(); i++) { JSONObject o = a.optJSONObject(i); r[i][0] = o.optInt("m"); r[i][1] = o.optInt("f"); }
        return r;
    }
    static int waitFee(int sec, int[][] T) {
        int cyc = T[T.length - 1][0], mins = Math.max(0, sec) / 60, r = mins % cyc, f = 0;
        for (int[] x : T) if (x[0] <= r) f = x[1];
        return (mins / cyc) * T[T.length - 1][1] + f;
    }

    static String clock(int s) {
        if (s < 0) s = 0;
        int hh = s / 3600, m = s % 3600 / 60, x = s % 60;
        return hh > 0 ? String.format(java.util.Locale.US, "%d:%02d:%02d", hh, m, x) : String.format(java.util.Locale.US, "%d:%02d", m, x);
    }

    private void updateWait() {
        JSONObject t = waitTrip;
        if (t == null || waitTotal == null) return;
        int ws = waitBase + (waitRunning ? (int) ((System.currentTimeMillis() - waitFrom) / 1000) : 0);
        if ("approved".equals(t.optString("special_status"))) {
            waitTotal.setText("⭐ زبون خاص: لا تستلم شي");
            if (waitClock != null) waitClock.setText(clock(ws));
            if (waitNote != null) waitNote.setText("زبون خاص، العدّاد ما ينحسب");
            return;
        }
        int base;
        if (waitFare == null) base = t.optInt("base_fare", t.optInt("fare"));
        else { try { base = Integer.parseInt(waitFare.getText().toString().replaceAll("\\D", "")); } catch (Exception e) { base = 0; } }
        int rf = t.optBoolean("round_trip") ? Math.round(base * t.optInt("round_trip_pct", 100) / 100f) : 0;
        int[][] T = tiers(t);
        int wf = waitFee(ws, T);
        int tot = base + rf + wf, pts = t.optInt("points_used", 0), coll = Math.max(0, tot - pts);
        java.util.Locale L = java.util.Locale.US;
        StringBuilder b = new StringBuilder();
        if (rf > 0 || wf > 0 || pts > 0) {
            b.append("الأجرة ").append(String.format(L, "%,d", base));
            if (rf > 0) b.append(" + مرجع ").append(String.format(L, "%,d", rf));
            if (wf > 0) b.append(" + عدّاد الانتظار ").append(String.format(L, "%,d", wf));
            if (pts > 0) b.append(" − نقاط ").append(String.format(L, "%,d", Math.min(pts, tot)));
            b.append("\n");
        }
        b.append(coll == 0 && pts > 0 ? "الكروة مجانية بالنقاط، لا تستلم شي" : "استلم من الزبون: " + String.format(L, "%,d", coll) + " د.ع");
        waitTotal.setText(b.toString());
        if (waitClock != null) waitClock.setText(clock(ws));
        if (waitNote != null) {
            int cyc = T[T.length - 1][0], mins = ws / 60, base0 = mins - mins % cyc, r = mins % cyc;
            String nx = "";
            for (int[] x : T) if (x[0] > r) { int at = (base0 + x[0]) * 60; nx = " · بعد " + clock(at - ws) + " يصير " + String.format(L, "%,d", waitFee(at, T)); break; }
            waitNote.setText("هسه " + String.format(L, "%,d", wf) + " د.ع" + nx);
        }
    }
    private int tickN = 0;
    private int selZone = -1;  // the zone the driver tapped on the empty card (-1 none, 0 other)

    private final Runnable tick = new Runnable() {
        @Override public void run() { refresh(); h.postDelayed(this, 2000); }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        Api.init(this);
        getWindow().setStatusBarColor(BG);
        getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR);
        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(BG);
        root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setLayoutDirection(View.LAYOUT_DIRECTION_RTL);
        int p = dp(20);
        root.setPadding(p, dp(28), p, p);
        sv.addView(root);
        setContentView(sv);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (MonitorService.pin(this) != null && Prefs.code(this) == null && !getIntent().getBooleanExtra("driver", false)) {
            startActivity(new Intent(this, AdminActivity.class));
            finish();
            return;
        }
        if (Prefs.code(this) == null) showLogin(null); else showMain();
    }

    @Override
    protected void onPause() {
        super.onPause();
        h.removeCallbacks(tick);
    }

    /* ---------- Login ---------- */
    private void showLogin(String error) {
        h.removeCallbacks(tick);
        root.removeAllViews();
        root.addView(brand("صفحة السائق", "المنصور تاكسي"));
        root.addView(space(24));
        root.addView(label("رمز السائق (6 أرقام من الإدارة)"));
        final EditText in = new EditText(this);
        in.setInputType(InputType.TYPE_CLASS_NUMBER);
        in.setTextSize(30);
        in.setGravity(Gravity.CENTER);
        in.setLetterSpacing(0.3f);
        in.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        in.setBackground(box(CARD, LINE, 12));
        in.setPadding(dp(12), dp(12), dp(12), dp(12));
        root.addView(in, full());
        final TextView err = text(error == null ? "" : error, 15, BAD, false);
        root.addView(err);
        root.addView(space(8));
        final Button go = button("دخول وتشغيل التتبع", true);
        go.setOnClickListener(v -> {
            final String code = in.getText().toString().trim();
            if (code.length() < 4) { err.setText("اكتب الرمز كامل"); return; }
            go.setEnabled(false);
            err.setText("جارٍ التحقق…");
            new Thread(() -> {
                try {
                    JSONObject car = Api.login(code);
                    Prefs.of(this).edit().putString("code", code).putString("car", car.toString())
                            .putInt("count", 0).putLong("sentAt", 0).apply();
                    h.post(this::showMain);
                } catch (Api.ApiError e) {
                    h.post(() -> { err.setText(e.getMessage()); go.setEnabled(true); });
                } catch (Exception e) {
                    h.post(() -> { err.setText("ماكو إنترنت، تأكد من الاتصال وحاول مرة ثانية"); go.setEnabled(true); });
                }
            }).start();
        });
        root.addView(go, full());
        root.addView(space(16));
        root.addView(note("بعد الدخول راح يطلب منك التطبيق أذونات. وافق على كلها حتى يشتغل التتبع بالخلفية والشاشة مقفولة."));
        root.addView(space(24));
        Button admin = button("دخول المدير (تنبيهات إطفاء السواق)", false);
        admin.setOnClickListener(v -> { startActivity(new Intent(this, AdminActivity.class)); finish(); });
        root.addView(admin, full());
    }

    /* ---------- Main ---------- */
    private void showMain() {
        root.removeAllViews();
        JSONObject car;
        try { car = new JSONObject(Prefs.of(this).getString("car", "{}")); } catch (Exception e) { car = new JSONObject(); }
        String meta = join(car.optString("model"), car.optString("year"), car.optString("color"));
        root.addView(brand(car.optString("driver_name", "السائق"), meta));
        root.addView(space(16));
        root.addView(plate(car.optString("plate", "—")));
        root.addView(space(18));

        // The big round button: tap to start the shift (tracking on), tap again to end it.
        LinearLayout ring = new LinearLayout(this);
        ringView = ring;
        ring.setOrientation(LinearLayout.VERTICAL);
        ring.setGravity(Gravity.CENTER);
        ring.setPadding(dp(18), dp(18), dp(18), dp(18));
        ring.setClickable(true);
        ring.setFocusable(true);
        status = text("…", 22, FG, true);
        status.setGravity(Gravity.CENTER);
        sub = text("", 14, MUTED, false);
        sub.setGravity(Gravity.CENTER);
        ring.addView(status);
        ring.addView(sub);
        ring.setOnClickListener(v -> toggle());
        ring.setOnTouchListener((v, e) -> {
            if (e.getAction() == android.view.MotionEvent.ACTION_DOWN) v.animate().scaleX(.95f).scaleY(.95f).setDuration(80).start();
            else if (e.getAction() == android.view.MotionEvent.ACTION_UP || e.getAction() == android.view.MotionEvent.ACTION_CANCEL)
                v.animate().scaleX(1f).scaleY(1f).setDuration(80).start();
            return false;
        });
        LinearLayout ringWrap = new LinearLayout(this);
        ringWrap.setGravity(Gravity.CENTER);
        ringWrap.addView(ring, new LinearLayout.LayoutParams(dp(230), dp(230)));
        root.addView(ringWrap, full());
        root.addView(space(16));
        tripBox = new LinearLayout(this);
        tripBox.setOrientation(LinearLayout.VERTICAL);
        root.addView(tripBox, full());
        tripKey = "";

        LinearLayout r1 = row(), r2 = row();
        sent = stat(r1, "آخر إرسال");
        acc = stat(r1, "دقة الموقع");
        spd = stat(r2, "السرعة");
        count = stat(r2, "عدد الإرسالات");
        root.addView(r1, full());
        root.addView(space(8));
        root.addView(r2, full());
        root.addView(space(16));

        setup = new LinearLayout(this);
        setup.setOrientation(LinearLayout.VERTICAL);
        root.addView(setup, full());
        root.addView(space(12));
        root.addView(note("الزر الأحمر يشغّل التتبع، ولما يشتغل يصير أخضر، واضغطه مرة ثانية حتى تطفيه. أثناء الدوام التتبع يشتغل بالخلفية حتى لو قفلت الشاشة أو فتحت تطبيق ثاني، وإطفاء الـ GPS يرن عليك ويوصل للإدارة فورًا."));
        refresh();
        h.removeCallbacks(tick);
        h.postDelayed(tick, 2000);
    }

    private void refresh() {
        if (Prefs.code(this) == null) { showLogin("الرمز تغيّر أو السيارة موقوفة. اطلب رمز جديد من الإدارة."); return; }
        if (status == null) return;
        boolean fine = granted(Manifest.permission.ACCESS_FINE_LOCATION);
        boolean bg = Build.VERSION.SDK_INT < 29 || granted(Manifest.permission.ACCESS_BACKGROUND_LOCATION);
        boolean notif = Build.VERSION.SDK_INT < 33 || granted(Manifest.permission.POST_NOTIFICATIONS);
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        boolean battery = pm.isIgnoringBatteryOptimizations(getPackageName());
        LocationManager lm = (LocationManager) getSystemService(LOCATION_SERVICE);
        boolean gps = lm.isProviderEnabled(LocationManager.GPS_PROVIDER);

        setup.removeAllViews();
        if (!fine) step("١", "اسمح للتطبيق بالموقع", "السماح", v -> requestPermissions(
                new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION}, RQ_FINE));
        else if (!bg) step("٢", "اختر «السماح طوال الوقت» حتى يشتغل والشاشة مقفولة", "فتح الإعداد", v -> {
            if (Build.VERSION.SDK_INT >= 30) openAppSettings();
            else requestPermissions(new String[]{Manifest.permission.ACCESS_BACKGROUND_LOCATION}, RQ_BG);
        });
        if (!notif) step("٣", "اسمح بالإشعارات حتى يوصلك تنبيه الـ GPS", "السماح",
                v -> requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, RQ_NOTIF));
        if (!battery) step("٤", "خلي التطبيق «بدون قيود» على البطارية حتى النظام ما يوقفه", "فتح الإعداد", v -> {
            try {
                startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName())));
            } catch (Exception e) { openAppSettings(); }
        });
        if (!gps) step("!", "الـ GPS مطفأ. شغّله حالًا", "تشغيل", v -> startActivity(new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)));

        boolean on = Prefs.of(this).getBoolean("on", false);
        if (on && fine && !TrackService.alive) TrackService.start(this);

        long at = Prefs.of(this).getLong("sentAt", 0);
        String err = Prefs.of(this).getString("err", "");
        // Red button = tracking off (tap to turn on). Green button = tracking on (tap to turn off).
        if (!on) setButton(false, fine ? "التتبع مطفأ" : "اكمل الخطوات تحت أولًا");
        else if (!fine) setButton(true, "اسمح بالموقع من الخطوات تحت");
        else if (!gps) setButton(true, "⚠ الـ GPS مطفأ، شغّله");
        else if (!bg) setButton(true, "يشتغل بس والتطبيق مفتوح");
        else if (at == 0) setButton(true, err.isEmpty() ? "جارٍ تحديد الموقع…" : err);
        else if (!err.isEmpty() && System.currentTimeMillis() - at > 60000) setButton(true, "الإرسال متأخر");
        else setButton(true, "التتبع شغّال");

        sent.setText(at == 0 ? "—" : ago(at));
        float a = Prefs.of(this).getFloat("acc", -1);
        acc.setText(a < 0 ? "—" : Math.round(a) + " م");
        spd.setText(Math.round(Prefs.of(this).getFloat("spd", 0) * 3.6f) + " كم/س");
        count.setText(String.valueOf(Prefs.of(this).getInt("count", 0)));

        if (!on) { if (tripBox != null && tripBox.getChildCount() > 0) { tripBox.removeAllViews(); tripKey = ""; } }
        else if (tickN++ % 2 == 0) loadTrip();
    }

    /* ---------- Trips ---------- */
    private void loadTrip() {
        final String code = Prefs.code(this);
        if (code == null) return;
        new Thread(() -> {
            try { final JSONObject st = Api.driverState(code); h.post(() -> renderTrip(st)); }
            catch (Exception ignored) {}
        }).start();
    }

    private void renderTrip(JSONObject st) {
        if (tripBox == null || !Prefs.of(this).getBoolean("on", false)) return;
        JSONObject t = st.optJSONObject("trip");
        JSONObject cxk = st.optJSONObject("cancelled");
        String key = (t == null ? "none:" + st.optString("returning_since") + st.optString("ready_at") + ":" + st.optInt("today_trips") + ":" + (cxk == null ? 0 : cxk.optLong("id")) : t.optLong("id") + ":" + t.optString("status") + ":" + t.optBoolean("waiting") + ":" + t.optBoolean("pickup_waiting") + ":" + t.optString("special_status") + ":" + t.optString("noshow_status") + ":" + t.optBoolean("round_trip") + ":" + t.optInt("fare") + ":" + t.optInt("zone_id") + ":" + (t.optJSONObject("dest_change") == null ? "" : t.optJSONObject("dest_change").optLong("id") + t.optJSONObject("dest_change").optString("status"))) + ":" + st.optLong("week_share") + ":" + moneyKey(st.optJSONObject("money"));
        if (key.equals(tripKey)) return;
        tripKey = key;
        h.removeCallbacks(waitTick);
        h.removeCallbacks(pwTick); pwClock = null;
        h.removeCallbacks(chgTick);
        tripBox.removeAllViews();
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(dp(16), dp(14), dp(16), dp(14));
        String status = t == null ? "" : t.optString("status");
        card.setBackground(box(status.equals("assigned") ? 0xFFFFF4DC : CARD,
                status.equals("assigned") ? AMBER : status.equals("started") ? OK : LINE, 16));
        if (t == null) {
            JSONObject cx = st.optJSONObject("cancelled");
            if (cx != null) {
                TextView cv = text(("noshow".equals(cx.optString("kind")) ? "✔ الإدارة سكّرت الطلب (الزبون ما نزل)" : "✖ الزبون ألغى طلبه") + (cx.optString("dropoff").isEmpty() ? "" : " لـ " + cx.optString("dropoff")), 16, 0xFFB42318, true);
                cv.setBackground(box(0xFFFDECEA, 0xFFB42318, 12));
                cv.setPadding(dp(12), dp(10), dp(12), dp(10));
                card.addView(cv, full());
                card.addView(space(8));
            }
            if (!st.optString("returning_since").isEmpty() && !st.isNull("returning_since")) {
                JSONObject b = st.optJSONObject("base");
                String bn = b == null ? "المجمع" : b.optString("name", "المجمع");
                String eta = "";
                if (b != null && !st.isNull("last_lat")) {
                    double km = km(st.optDouble("last_lat"), st.optDouble("last_lng"), b.optDouble("lat"), b.optDouble("lng"));
                    eta = "توصل بعد ~" + Math.max(1, Math.round(km * 1.35 / 25 * 60)) + " دقيقة (" + String.format(java.util.Locale.US, "%.1f", km) + " كم). ";
                }
                TextView rt = text("🔙 راجع لـ" + bn + "\n" + eta + "الطريق للمجمع ما ينحسب «بدون سفرة».", 15, OK, true);
                rt.setBackground(box(0xFFE7F6EE, OK, 12));
                rt.setPadding(dp(12), dp(10), dp(12), dp(10));
                card.addView(rt, full());
                card.addView(space(6));
                Button rd = button("✅ وصلت المجمع، جاهز للكراوي", true);
                rd.setOnClickListener(v -> tripAction("ready", null));
                card.addView(rd, full());
                card.addView(space(12));
            } else if (!st.isNull("ready_at") && !st.optString("ready_at").isEmpty()) {
                card.addView(text("✅ إنت جاهز بالمجمع من " + hm(st.optString("ready_at")), 14, OK, true));
                card.addView(space(8));
            }
            card.addView(text("ماكو سفرة", 19, FG, true));
            card.addView(text("إذا ركب زبون، سجّل السفرة قبل لا تتحرك. الحركة بدون سفرة تنسجل وتوصل للإدارة.", 14, MUTED, false));
            card.addView(space(8));
            final org.json.JSONArray zones = st.optJSONArray("zones");
            final java.util.List<String> labels = new java.util.ArrayList<>();
            final java.util.List<Integer> ids = new java.util.ArrayList<>();
            if (zones != null) for (int i = 0; i < zones.length(); i++) {
                JSONObject z = zones.optJSONObject(i);
                labels.add(z.optString("name") + " — " + String.format(java.util.Locale.US, "%,d", z.optInt("price")));
                ids.add(z.optInt("id"));
            }
            labels.add("منطقة أخرى");
            ids.add(0);
            card.addView(text("إلى وين؟ اضغط على المنطقة", 13, MUTED, true));
            // zones as big buttons, two per row: one tap picks it
            // zones as big buttons, two per row (plain rows of weighted buttons: renders the same on every phone)
            final java.util.List<Button> zbtns = new java.util.ArrayList<>();
            final EditText to = input("اسم المكان", InputType.TYPE_CLASS_TEXT);
            to.setVisibility(selZone == 0 ? View.VISIBLE : View.GONE);
            final Button go = button("بدء سفرة", true);
            final Runnable paint = () -> {
                for (int i = 0; i < zbtns.size(); i++) {
                    boolean on = ids.get(i) == selZone;
                    zbtns.get(i).setBackground(box(on ? 0xFFFFF4DC : CARD, on ? AMBER : LINE, 12));
                }
                int k = ids.indexOf(selZone);
                if (selZone > 0 && k < 0) selZone = -1;
                go.setText(selZone < 0 ? "اختار المنطقة وابدأ السفرة" : selZone == 0 ? "🚕 بدء سفرة" : "🚕 بدء سفرة لـ " + labels.get(k).replaceAll(" — [0-9,]+$", ""));
                go.setEnabled(selZone >= 0);
                go.setAlpha(selZone >= 0 ? 1f : 0.5f);
                to.setVisibility(selZone == 0 ? View.VISIBLE : View.GONE);
            };
            LinearLayout zrow = null;
            for (int i = 0; i < labels.size(); i++) {
                final int zid = ids.get(i);
                if (i % 2 == 0) {
                    zrow = new LinearLayout(this);
                    zrow.setOrientation(LinearLayout.HORIZONTAL);
                    card.addView(zrow, full());
                }
                Button zb = button(zid == 0 ? "✏️ منطقة أخرى" : labels.get(i).replace(" — ", "\n"), false);
                zb.setTextSize(15);
                zb.setMinHeight(dp(58));
                zb.setOnClickListener(v -> { selZone = zid; paint.run(); if (zid == 0) to.requestFocus(); });
                LinearLayout.LayoutParams zl = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
                zl.setMargins(dp(3), dp(3), dp(3), dp(3));
                zrow.addView(zb, zl);
                zbtns.add(zb);
            }
            if (labels.size() % 2 == 1 && zrow != null) zrow.addView(new View(this), new LinearLayout.LayoutParams(0, 1, 1));
            card.addView(to, full());
            card.addView(space(8));
            paint.run();
            go.setOnClickListener(v -> {
                if (selZone < 0) return;
                JSONObject p = obj("dropoff", selZone == 0 ? to.getText().toString() : "");
                if (selZone == 0 && to.getText().toString().trim().length() < 2) { android.widget.Toast.makeText(this, "اكتب اسم المكان", android.widget.Toast.LENGTH_LONG).show(); return; }
                try { if (selZone > 0) p.put("zone_id", selZone); } catch (Exception ignored) {}
                selZone = -1;
                tripAction("start", p);
            });
            card.addView(go, full());
            card.addView(space(8));
            Button spb = button("⭐ زبون خاص (بدون كروة)", false);
            spb.setOnClickListener(v -> specialDialog(Math.max(0, selZone)));
            card.addView(spb, full());
            card.addView(space(8));
            Button lnb = button("🛣 رايح أوصل خط", false);
            lnb.setOnClickListener(v -> lineDialog(labels, ids, st.optJSONObject("base")));
            card.addView(lnb, full());
        } else {
            String where = "من: " + or(t.optString("pickup")) + "\nإلى: " + or(t.optString("dropoff"))
                    + (t.optString("customer_name").isEmpty() ? "" : "\nالزبون: " + t.optString("customer_name"))
                    + (t.optInt("zone_id", 0) > 0 && t.optInt("fare", 0) > 0 ? "\nالأجرة: " + String.format(java.util.Locale.US, "%,d", t.optInt("fare")) + " د.ع (ثابتة)" : "")
                    + (t.optInt("points_used", 0) > 0 ? "\n⭐ الزبون دافع " + String.format(java.util.Locale.US, "%,d", t.optInt("points_used")) + " بالنقاط" : "")
                    + (t.optString("note").isEmpty() ? "" : "\nملاحظة: " + t.optString("note"));
            if (status.equals("assigned")) {
                card.addView(text("📣 سفرة جديدة من المكتب", 19, FG, true));
                card.addView(text(where, 15, FG, false));
                card.addView(space(10));
                LinearLayout r = row();
                Button acc = button("قبول", true);
                acc.setOnClickListener(v -> tripAction("accept", null));
                Button rej = button("رفض", false);
                rej.setOnClickListener(v -> {
                    final EditText why = input("السبب", InputType.TYPE_CLASS_TEXT);
                    new android.app.AlertDialog.Builder(this).setTitle("رفض السفرة؟")
                            .setMessage("الرفض ينسجل عليك ويوصل للإدارة.").setView(why)
                            .setNegativeButton("رجوع", null)
                            .setPositiveButton("رفض", (d, w) -> tripAction("reject", obj("reason", why.getText().toString()))).show();
                });
                r.addView(acc, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 2));
                LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
                lp.setMarginStart(dp(8));
                r.addView(rej, lp);
                card.addView(r, full());
            } else if (status.equals("accepted")) {
                final boolean pw = t.optBoolean("pickup_waiting");
                final String ns = t.optString("noshow_status");
                final boolean nsPending = ns.equals("pending");
                card.addView(text(pw || nsPending ? "وصلت للزبون" : "رايح للزبون", 19, FG, true));
                card.addView(text(where, 15, FG, false));
                card.addView(space(10));
                final boolean spPending = addSpecial(card, t);
                pwBase = t.optInt("pickup_wait_sec", 0);
                pwFrom = System.currentTimeMillis();
                if (nsPending) {
                    // the clock is locked while the office decides on the close request
                    TextView lk = text("🔒 العدّاد انقفل: " + clock(pwBase) + "\n⏳ طلب التسكير عند الإدارة\n" + t.optString("noshow_note")
                            + "\nإذا نزل الزبون دوس «انطلاق» عادي.", 15, 0xFF8A5A00, true);
                    lk.setBackground(box(0xFFFFF4DC, AMBER, 12));
                    lk.setPadding(dp(12), dp(10), dp(12), dp(10));
                    card.addView(lk, full());
                } else if (pw) {
                    LinearLayout wb = new LinearLayout(this);
                    wb.setOrientation(LinearLayout.VERTICAL);
                    wb.setGravity(Gravity.CENTER);
                    wb.setPadding(dp(12), dp(12), dp(12), dp(12));
                    wb.setBackground(box(0xFFFFF4DC, AMBER, 14));
                    wb.addView(text("🕓 تنتظر الزبون ينزل", 14, MUTED, true));
                    pwClock = text(clock(pwBase), 40, FG, true);
                    pwClock.setGravity(Gravity.CENTER);
                    pwClock.setTypeface(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.BOLD);
                    wb.addView(pwClock);
                    TextView nt = text("هذا الوقت ما ينحسب بفلوس", 13, MUTED, false);
                    nt.setGravity(Gravity.CENTER);
                    wb.addView(nt);
                    card.addView(wb, full());
                    h.postDelayed(pwTick, 1000);
                    if (ns.equals("rejected")) {
                        TextView rj = text("✖ الإدارة رفضت التسكير: كمّل انتظار" + (t.optString("noshow_reason").isEmpty() ? "" : "\n" + t.optString("noshow_reason")), 14, 0xFFB42318, true);
                        rj.setBackground(box(0xFFFDECEA, 0xFFB42318, 12));
                        rj.setPadding(dp(12), dp(10), dp(12), dp(10));
                        card.addView(space(8));
                        card.addView(rj, full());
                    }
                    card.addView(space(8));
                    Button close = button("✖ تسكير (الزبون ما نزل)", false);
                    close.setOnClickListener(v -> noshowDialog(t));
                    card.addView(close, full());
                } else {
                    Button arr = button("📍 وصلت، دا أنتظر الزبون", false);
                    arr.setOnClickListener(v -> tripAction("wait_start", null));
                    card.addView(arr, full());
                    if (pwBase > 0) card.addView(text("انتظرت: " + clock(pwBase), 13, MUTED, false));
                }
                card.addView(space(8));
                Button go = button("🚕 انطلاق (ركب الزبون)", true);
                go.setOnClickListener(v -> tripAction("start", null));
                if (spPending) { go.setEnabled(false); go.setAlpha(0.45f); }
                card.addView(go, full());
            } else {
                final boolean round = t.optBoolean("round_trip");
                final boolean waiting = t.optBoolean("waiting");
                card.addView(text("line".equals(t.optString("trip_kind"))
                        ? "🛣 خط: رايح " + t.optString("dropoff") + "\n↩ المرجع " + or(t.optString("pickup"))
                        : "بسفرة من " + hm(t.optString("started_at")) + (round ? "  ↩ مرجع" : ""), 19, OK, true));
                card.addView(text(where, 15, FG, false));
                card.addView(space(10));
                final boolean spPending = waiting ? "pending".equals(t.optString("special_status")) : addSpecial(card, t);
                final boolean spFree = "approved".equals(t.optString("special_status"));
                final boolean fixed = spFree || t.optInt("zone_id", 0) > 0 && t.optInt("fare", 0) > 0;
                final EditText fare = input("الأجرة المستلمة (دينار)", InputType.TYPE_CLASS_NUMBER);
                // waiting timer + round trip
                waitBase = t.optInt("wait_sec", 0);
                waitFrom = System.currentTimeMillis();
                waitRunning = waiting;
                waitTrip = t;
                waitFare = fixed ? null : fare;
                if (waiting) {
                    LinearLayout wb = new LinearLayout(this);
                    wb.setOrientation(LinearLayout.VERTICAL);
                    wb.setGravity(Gravity.CENTER);
                    wb.setPadding(dp(12), dp(12), dp(12), dp(12));
                    wb.setBackground(box(0xFFFFF4DC, AMBER, 14));
                    wb.addView(text("⏱ عدّاد الانتظار شغّال", 14, MUTED, true));
                    waitClock = text(clock(waitBase), 40, FG, true);
                    waitClock.setGravity(Gravity.CENTER);
                    waitClock.setTypeface(android.graphics.Typeface.MONOSPACE, android.graphics.Typeface.BOLD);
                    wb.addView(waitClock);
                    waitNote = text("", 13, MUTED, false);
                    waitNote.setGravity(Gravity.CENTER);
                    wb.addView(waitNote);
                    Button cont = button("▶ رجع الزبون، طفّي العدّاد", true);
                    cont.setOnClickListener(v -> tripAction("wait_end", null));
                    wb.addView(cont, full());
                    card.addView(wb, full());
                } else {
                    waitClock = null; waitNote = null;
                    LinearLayout r2 = row();
                    Button wbtn = button("⏱ انتظرني هنا (العدّاد)", false);
                    wbtn.setOnClickListener(v -> tripAction("wait_start", null));
                    Button rbtn = button(round ? "↩ مرجع ✓" : "↩ خلّيها مرجع", false);
                    if (round) rbtn.setBackground(box(0xFFFFF4DC, AMBER, 14));
                    rbtn.setOnClickListener(v -> new android.app.AlertDialog.Builder(this)
                            .setTitle(round ? "تشيل المرجع؟" : "تخلّي السفرة مرجع؟")
                            .setMessage(round ? "ترجع السفرة ذهاب بس." : "ذهاب ورجعة، وينضاف سعر الرجعة على الأجرة.")
                            .setNegativeButton("رجوع", null)
                            .setPositiveButton(round ? "شيل المرجع" : "نعم، مرجع", (d, w) -> tripAction("round", obj("on", round ? "false" : "true"))).show());
                    r2.addView(wbtn, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 3));
                    LinearLayout.LayoutParams rl = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 2);
                    rl.setMarginStart(dp(8));
                    r2.addView(rbtn, rl);
                    card.addView(r2, full());
                    card.addView(text(waitBase > 0 ? "العدّاد لحد هسه: " + clock(waitBase) + " = " + String.format(java.util.Locale.US, "%,d", waitFee(waitBase, tiers(t))) + " د.ع"
                            : "العدّاد بس إذا الزبون وصل وكال «انتظرني هنا».", 13, MUTED, false));
                }
                addDestChange(card, t, st, waiting);
                card.addView(space(8));
                if (fixed) {
                    waitTotal = text("", 20, FG, true);
                    waitTotal.setGravity(Gravity.CENTER);
                    waitTotal.setBackground(box(0xFFFFF4DC, AMBER, 12));
                    waitTotal.setPadding(dp(12), dp(12), dp(12), dp(12));
                    card.addView(waitTotal, full());
                } else {
                    int base = st.optInt("fare_base", 0);
                    if (base > 0) fare.setText(String.valueOf(base));
                    fare.setTextSize(22);
                    fare.setGravity(Gravity.CENTER);
                    card.addView(text("الأجرة (دينار)", 13, MUTED, true));
                    card.addView(fare, full());
                    waitTotal = text("", 16, FG, true);
                    waitTotal.setGravity(Gravity.CENTER);
                    card.addView(waitTotal, full());
                    fare.addTextChangedListener(new android.text.TextWatcher() {
                        public void beforeTextChanged(CharSequence a, int b, int c, int d) {}
                        public void onTextChanged(CharSequence a, int b, int c, int d) {}
                        public void afterTextChanged(android.text.Editable e) { updateWait(); }
                    });
                }
                updateWait();
                if (waiting) h.postDelayed(waitTick, 1000);
                card.addView(space(8));
                Button end = button("إنهاء السفرة", true);
                end.setEnabled(!waiting && !spPending);
                if (waiting || spPending) end.setAlpha(0.45f);
                end.setOnClickListener(v -> tripAction("end", obj("fare", fare.getText().toString())));
                card.addView(end, full());
            }
        }
        if (t != null && (status.equals("accepted") || status.equals("started"))) {
            final String waze = wazeUrl(t, status);
            if (waze != null) {
                card.addView(space(8));
                Button wz = button(status.equals("accepted") ? "🚗 ويز: روح للزبون"
                        : "🚗 ويز: روح لـ " + or(t.optString("zone", t.optString("dropoff"))), true);
                wz.setBackground(box(0xFF33CCFF, 0xFF33CCFF, 14));
                wz.setTextColor(0xFF06283D);
                wz.setOnClickListener(v -> openWaze(waze));
                card.addView(wz, full());
            }
            card.addView(space(8));
            Button nav = button("🧭 الطريق على الخريطة", false);
            nav.setOnClickListener(v -> {
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(
                            "https://ftyo979vfemail-code.github.io/mansour-city/taxi/?c=" + Prefs.code(this) + "#nav")));
                } catch (Exception ignored) {}
            });
            card.addView(nav, full());
        }
        tripBox.addView(card, full());
        TextView sum = text("سفرات اليوم: " + st.optInt("today_trips") + " · " + String.format(java.util.Locale.US, "%,d", st.optLong("today_fares")) + " د.ع", 14, MUTED, true);
        sum.setPadding(dp(4), dp(8), dp(4), dp(2));
        tripBox.addView(sum);
        JSONObject rt = st.optJSONObject("rating");
        TextView wk = text("هذا الأسبوع: " + st.optInt("week_trips") + " سفرة" + (rt != null && rt.optInt("count") > 0 ? " · تقييمك ⭐ " + rt.optString("avg") + " (" + rt.optInt("count") + ")" : ""), 15, FG, true);
        wk.setPadding(dp(4), dp(2), dp(4), dp(4));
        tripBox.addView(wk);
        addMoney(st.optJSONObject("money"));
    }

    private static String moneyKey(JSONObject m) {
        if (m == null) return "";
        JSONObject last = m.optJSONArray("deposits") != null && m.optJSONArray("deposits").length() > 0 ? m.optJSONArray("deposits").optJSONObject(0) : null;
        return m.optInt("in_hand") + "/" + m.optInt("pending") + "/" + (last == null ? "" : last.optLong("id") + last.optString("status"));
    }

    /** What the driver holds for the company, and the "إيداع" button (counts once the office confirms). */
    private void addMoney(JSONObject m) {
        if (m == null) return;
        java.util.Locale L = java.util.Locale.US;
        final int inHand = m.optInt("in_hand"), pending = m.optInt("pending");
        final int free = Math.max(0, inHand - pending);
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(16), dp(14), dp(16), dp(14));
        c.setBackground(box(0xFFFFF8E1, AMBER, 16));
        c.addView(text("💵 المبلغ اللي بيدك للشركة", 14, MUTED, true));
        c.addView(text(String.format(L, "%,d", inHand) + " د.ع", 26, FG, true));
        if (pending > 0) c.addView(text("منها " + String.format(L, "%,d", pending) + " بانتظار تأكيد الإدارة", 13, MUTED, false));
        org.json.JSONArray ds = m.optJSONArray("deposits");
        JSONObject last = ds != null && ds.length() > 0 ? ds.optJSONObject(0) : null;
        if (last != null) {
            String st = last.optString("status");
            String line = st.equals("pending") ? "⏳ إيداع " + String.format(L, "%,d", last.optInt("amount")) + " بانتظار تأكيد الإدارة"
                    : st.equals("confirmed") ? "✔ الإدارة استلمت " + String.format(L, "%,d", last.isNull("received") ? last.optInt("amount") : last.optInt("received"))
                    : "✖ انرفض إيداع " + String.format(L, "%,d", last.optInt("amount")) + (last.optString("reason").isEmpty() || last.isNull("reason") ? "" : ": " + last.optString("reason"));
            c.addView(text(line, 13, st.equals("rejected") ? 0xFFB42318 : FG, true));
        }
        c.addView(space(8));
        if (free <= 0) {
            TextView ok = text("✔ ما عليك شي للشركة هسه" + (pending > 0 ? "، والإيداع بانتظار التأكيد" : ""), 15, OK, true);
            ok.setGravity(Gravity.CENTER);
            ok.setBackground(box(0xFFE7F6EE, OK, 12));
            ok.setPadding(dp(10), dp(10), dp(10), dp(10));
            c.addView(ok, full());
            JSONObject lc = m.optJSONObject("last_collected");
            if (lc != null && pending == 0) c.addView(text("آخر استلام سجّلته الإدارة: " + String.format(L, "%,d", lc.optInt("amount")) + " د.ع", 12, MUTED, false));
            LinearLayout.LayoutParams lp0 = full();
            lp0.topMargin = dp(10);
            tripBox.addView(c, lp0);
            return;
        }
        Button dep = button("إيداع: سلّمت المبلغ للإدارة", true);
        dep.setOnClickListener(v -> {
            final EditText amt = input("المبلغ (دينار)", InputType.TYPE_CLASS_NUMBER);
            amt.setText(String.valueOf(free));
            amt.setTextSize(22);
            amt.setGravity(Gravity.CENTER);
            final EditText note = input("ملاحظة (اختياري)", InputType.TYPE_CLASS_TEXT);
            LinearLayout f = new LinearLayout(this);
            f.setOrientation(LinearLayout.VERTICAL);
            f.setPadding(dp(20), dp(8), dp(20), 0);
            f.addView(amt, full());
            f.addView(note, full());
            new android.app.AlertDialog.Builder(this).setTitle("💵 إيداع للإدارة")
                    .setMessage("اكتب المبلغ اللي سلّمته. ينحسب بعد ما الإدارة تأكد إنها استلمته.")
                    .setView(f)
                    .setNegativeButton("رجوع", null)
                    .setPositiveButton("إرسال", (d, w) -> sendDeposit(amt.getText().toString(), note.getText().toString())).show();
        });
        c.addView(dep, full());
        LinearLayout.LayoutParams lp = full();
        lp.topMargin = dp(10);
        tripBox.addView(c, lp);
    }

    private void sendDeposit(String amount, String note) {
        final String code = Prefs.code(this);
        int a;
        try { a = Integer.parseInt(amount.replaceAll("\\D", "")); } catch (Exception e) { a = 0; }
        if (code == null || a <= 0) { android.widget.Toast.makeText(this, "اكتب المبلغ", android.widget.Toast.LENGTH_SHORT).show(); return; }
        final int amt = a;
        new Thread(() -> {
            try {
                Api.call("taxi_driver_deposit", new JSONObject().put("p_code", code).put("p_amount", amt).put("p_note", note));
                h.post(() -> {
                    android.widget.Toast.makeText(this, "انرسل الإيداع، بانتظار تأكيد الإدارة", android.widget.Toast.LENGTH_LONG).show();
                    tripKey = ""; loadTrip();
                });
            } catch (Exception e) {
                h.post(() -> android.widget.Toast.makeText(this, e instanceof Api.ApiError ? e.getMessage() : "ماكو إنترنت", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private void tripAction(String action, JSONObject p) {
        final String code = Prefs.code(this);
        if (code == null) return;
        new Thread(() -> {
            try {
                Api.driverTrip(code, action, p);
                h.post(() -> {
                    android.widget.Toast.makeText(this, action.equals("end") ? "انسجلت السفرة" : action.equals("reject") ? "انرفضت" : "تم", android.widget.Toast.LENGTH_SHORT).show();
                    tripKey = ""; loadTrip();
                });
            } catch (Exception e) {
                h.post(() -> android.widget.Toast.makeText(this, e instanceof Api.ApiError ? e.getMessage() : "ماكو إنترنت", android.widget.Toast.LENGTH_LONG).show());
            }
        }).start();
    }

    private EditText input(String hint, int type) {
        EditText e = new EditText(this);
        e.setHint(hint);
        e.setInputType(type);
        e.setBackground(box(CARD, LINE, 10));
        e.setPadding(dp(12), dp(10), dp(12), dp(10));
        return e;
    }

    // "زبون خاص": free ride; the office approves what the driver wrote. Returns true while it waits for the office.
    private boolean addSpecial(LinearLayout card, JSONObject t) {
        String st = t.optString("special_status");
        java.util.Locale L = java.util.Locale.US;
        if (st.equals("pending") || st.equals("approved") || st.equals("rejected")) {
            int fg = st.equals("approved") ? OK : st.equals("rejected") ? 0xFFB42318 : 0xFF8A5A00;
            String title = st.equals("pending") ? "⏳ زبون خاص: بانتظار موافقة الإدارة" : st.equals("approved") ? "⭐ زبون خاص: بدون كروة" : "✖ الإدارة رفضت الزبون الخاص: السفرة بكروة عادية";
            String sub = st.equals("rejected") ? t.optString("special_reason") : t.optString("special_note") + (st.equals("approved") && !t.optString("special_by").isEmpty() ? " · وافق " + t.optString("special_by") : "");
            if (st.equals("pending")) sub += "\nما تكدر تبدي أو تنهي السفرة لحد ما ترد الإدارة.";
            TextView v = text(title + (sub.trim().isEmpty() ? "" : "\n" + sub.trim()), 14, fg, true);
            v.setBackground(box(st.equals("approved") ? 0xFFE7F6EE : st.equals("rejected") ? 0xFFFDECEA : 0xFFFFF4DC, fg, 12));
            v.setPadding(dp(12), dp(10), dp(12), dp(10));
            card.addView(v, full());
            card.addView(space(8));
        }
        if (!st.equals("pending") && !st.equals("approved")) {
            Button b = button("⭐ زبون خاص (بدون كروة)", false);
            b.setOnClickListener(x -> specialDialog(0));
            card.addView(b, full());
            card.addView(space(8));
        }
        return st.equals("pending");
    }

    static double km(double a1, double o1, double a2, double o2) {
        double r = Math.PI / 180, dl = (a2 - a1) * r, dg = (o2 - o1) * r;
        double h = Math.sin(dl / 2) * Math.sin(dl / 2) + Math.cos(a1 * r) * Math.cos(a2 * r) * Math.sin(dg / 2) * Math.sin(dg / 2);
        return 2 * 6371 * Math.asin(Math.sqrt(h));
    }

    // "خط": going to deliver a line; the return is always the compound
    private void lineDialog(java.util.List<String> labels, java.util.List<Integer> ids, JSONObject base) {
        String bn = base == null ? "المجمع" : base.optString("name", "المجمع");
        LinearLayout v = new LinearLayout(this);
        v.setOrientation(LinearLayout.VERTICAL);
        v.setPadding(dp(16), dp(8), dp(16), 0);
        final android.widget.Spinner sp = new android.widget.Spinner(this);
        final java.util.List<String> l2 = new java.util.ArrayList<>();
        for (String s : labels) l2.add(s.replaceAll(" — [0-9,]+$", ""));
        sp.setAdapter(new android.widget.ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, l2));
        v.addView(text("المنطقة:", 13, MUTED, true));
        v.addView(sp, full());
        final EditText other = input("اسم المنطقة (إذا مو بالقائمة)", InputType.TYPE_CLASS_TEXT);
        v.addView(other, full());
        new android.app.AlertDialog.Builder(this).setTitle("🛣 رايح أوصل خط")
                .setMessage("اختار أو اكتب المنطقة. المرجع ثابت: " + bn + ".")
                .setView(v)
                .setNegativeButton("رجوع", null)
                .setPositiveButton("انطلق", (d, w) -> {
                    int zid = ids.get(Math.max(0, sp.getSelectedItemPosition()));
                    String typed = other.getText().toString().trim();
                    JSONObject p = obj("dropoff", typed);
                    try { if (zid > 0 && typed.isEmpty()) p.put("zone_id", zid); } catch (Exception ignored) {}
                    if (zid == 0 && typed.length() < 2) { android.widget.Toast.makeText(this, "اكتب اسم المنطقة", android.widget.Toast.LENGTH_LONG).show(); return; }
                    tripAction("line", p);
                }).show();
    }

    private void noshowDialog(JSONObject t) {
        int mins = (t.optInt("pickup_wait_sec", 0) + (int) ((System.currentTimeMillis() - pwFrom) / 1000)) / 60;
        final EditText note = input("مثال: وصلت للعمارة وانتظرت وما نزل أحد", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        new android.app.AlertDialog.Builder(this).setTitle("✖ تسكير الطلب")
                .setMessage("انتظرت الزبون " + mins + " دقيقة. العدّاد ينقفل، والطلب يروح للإدارة توافق على التسكير أو ترفضه. اكتب شنو صار:")
                .setView(note)
                .setNegativeButton("رجوع", null)
                .setPositiveButton("إرسال للإدارة", (d, w) -> {
                    String n = note.getText().toString().trim();
                    if (n.length() < 3) { android.widget.Toast.makeText(this, "اكتب ملاحظة: شنو صار؟", android.widget.Toast.LENGTH_LONG).show(); return; }
                    tripAction("noshow", obj("note", n));
                }).show();
    }

    private void specialDialog(int zoneId) {
        final EditText who = input("منو الزبون بالضبط؟ مثال: أبو علي، مدير المجمّع", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        new android.app.AlertDialog.Builder(this).setTitle("⭐ زبون خاص")
                .setMessage("سفرة بدون كروة. اكتب منو الزبون بالضبط، والطلب يروح للإدارة توافق عليه، وبعدها تكمّل السفرة.")
                .setView(who)
                .setNegativeButton("رجوع", null)
                .setPositiveButton("إرسال للإدارة", (d, w) -> {
                    String n = who.getText().toString().trim();
                    if (n.length() < 3) { android.widget.Toast.makeText(this, "اكتب منو الزبون بالضبط", android.widget.Toast.LENGTH_LONG).show(); return; }
                    JSONObject p = obj("note", n);
                    try { if (zoneId > 0) p.put("zone_id", zoneId); } catch (Exception ignored) {}
                    tripAction("special", p);
                }).show();
    }

    private static JSONObject obj(String k, String v) {
        try { return new JSONObject().put(k, v); } catch (Exception e) { return new JSONObject(); }
    }

    private static String or(String s) { return s == null || s.isEmpty() ? "—" : s; }

    private static String hm(String iso) {
        try {
            java.time.OffsetDateTime t = java.time.OffsetDateTime.parse(iso);
            return t.atZoneSameInstant(java.time.ZoneId.systemDefault()).toLocalTime().withNano(0).withSecond(0).toString();
        } catch (Exception e) { return ""; }
    }

    private void toggle() {
        boolean on = Prefs.of(this).getBoolean("on", false);
        if (!on) {
            if (!granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
                requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION}, RQ_FINE);
                return;
            }
            Prefs.of(this).edit().putBoolean("on", true).putLong("sentAt", 0).putString("err", "").apply();
            TrackService.start(this);
            refresh();
            return;
        }
        new android.app.AlertDialog.Builder(this)
                .setTitle("إطفاء التتبع؟")
                .setMessage("راح يتوقف إرسال موقعك للإدارة.")
                .setNegativeButton("لا، استمر", null)
                .setPositiveButton("إنهاء الدوام", (d, w) -> {
                    Prefs.of(this).edit().putBoolean("on", false).apply();
                    stopService(new Intent(this, TrackService.class));
                    refresh();
                })
                .show();
    }

    private void setButton(boolean on, String state) {
        int fill = on ? OK : BAD;
        GradientDrawable g = new GradientDrawable();
        g.setShape(GradientDrawable.OVAL);
        g.setColor(fill);
        g.setStroke(dp(8), on ? 0xFF0F6E43 : 0xFFA3241E);
        ringView.setBackground(g);
        ringView.setElevation(dp(6));
        status.setText(on ? "إطفاء التتبع" : "تشغيل التتبع");
        status.setTextColor(Color.WHITE);
        status.setTextSize(26);
        sub.setText(state);
        sub.setTextColor(0xE6FFFFFF);
    }

    private void setStatus(String t, String s, int color) {
        status.setText(t);
        status.setTextColor(color);
        sub.setText(s);
    }

    private void step(String n, String what, String action, View.OnClickListener l) {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setPadding(dp(14), dp(12), dp(14), dp(12));
        r.setBackground(box(0xFFFFF4DC, AMBER, 12));
        TextView num = text(n, 16, INK, true);
        num.setGravity(Gravity.CENTER);
        num.setBackground(box(AMBER, AMBER, 20));
        r.addView(num, new LinearLayout.LayoutParams(dp(30), dp(30)));
        TextView t = text(what, 15, FG, false);
        t.setPadding(dp(10), 0, dp(10), 0);
        r.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Button b = button(action, true);
        b.setOnClickListener(l);
        r.addView(b);
        LinearLayout.LayoutParams lp = full();
        lp.bottomMargin = dp(8);
        setup.addView(r, lp);
    }

    @Override
    public void onRequestPermissionsResult(int rq, String[] perms, int[] res) {
        super.onRequestPermissionsResult(rq, perms, res);
        if (rq == RQ_FINE && granted(Manifest.permission.ACCESS_FINE_LOCATION)) {
            Prefs.of(this).edit().putBoolean("on", true).apply();
            TrackService.start(this);
        }
        refresh();
    }

    private void openAppSettings() {
        startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName())));
    }

    private boolean granted(String p) { return checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED; }

    /* ---------- Small UI helpers ---------- */
    private View brand(String title, String subtitle) {
        LinearLayout r = row();
        r.setGravity(Gravity.CENTER_VERTICAL);
        android.widget.ImageView mark = new android.widget.ImageView(this);
        mark.setImageResource(R.drawable.logo_mark);
        mark.setScaleType(android.widget.ImageView.ScaleType.FIT_CENTER);
        r.addView(mark, new LinearLayout.LayoutParams(dp(48), dp(56)));
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setPadding(dp(12), 0, dp(12), 0);
        col.addView(text(title, 22, FG, true));
        if (subtitle != null && !subtitle.isEmpty()) col.addView(text(subtitle, 14, MUTED, false));
        r.addView(col);
        return r;
    }

    private View plate(String number) {
        LinearLayout wrap = new LinearLayout(this);
        wrap.setGravity(Gravity.CENTER);
        LinearLayout p = new LinearLayout(this);
        p.setLayoutDirection(View.LAYOUT_DIRECTION_LTR);
        p.setBackground(box(Color.WHITE, FG, 6));
        p.setPadding(dp(2), dp(2), dp(2), dp(2));
        TextView band = text("IRQ", 12, Color.WHITE, true);
        band.setBackgroundColor(0xFF1F4FA3);
        band.setGravity(Gravity.CENTER);
        band.setPadding(dp(8), dp(4), dp(8), dp(4));
        p.addView(band, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT));
        TextView num = text(number, 26, 0xFF111111, true);
        num.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        num.setPadding(dp(16), dp(8), dp(16), dp(8));
        p.addView(num);
        wrap.addView(p);
        return wrap;
    }

    private TextView stat(LinearLayout row, String label) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.setPadding(dp(14), dp(10), dp(14), dp(10));
        c.setBackground(box(CARD, LINE, 12));
        c.addView(text(label, 13, MUTED, false));
        TextView v = text("—", 18, FG, true);
        v.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        c.addView(v);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1);
        lp.setMarginStart(row.getChildCount() == 0 ? 0 : dp(8));
        row.addView(c, lp);
        return v;
    }

    private TextView note(String s) {
        TextView t = text(s, 14, MUTED, false);
        t.setBackground(box(CARD, LINE, 12));
        t.setPadding(dp(14), dp(12), dp(14), dp(12));
        t.setLineSpacing(0, 1.25f);
        return t;
    }

    private TextView label(String s) { TextView t = text(s, 14, MUTED, true); t.setPadding(0, 0, 0, dp(6)); return t; }

    private TextView text(String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }

    private Button button(String s, boolean primary) {
        Button b = new Button(this);
        b.setText(s);
        b.setAllCaps(false);
        b.setTextSize(15);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setTextColor(primary ? INK : FG);
        b.setBackground(box(primary ? AMBER : CARD, primary ? AMBER : LINE, 10));
        b.setPadding(dp(16), dp(10), dp(16), dp(10));
        return b;
    }

    private LinearLayout row() {
        LinearLayout r = new LinearLayout(this);
        r.setOrientation(LinearLayout.HORIZONTAL);
        return r;
    }

    private View space(int d) {
        View v = new View(this);
        v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(d)));
        return v;
    }

    private GradientDrawable box(int fill, int stroke, int radius) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(fill);
        g.setStroke(dp(1), stroke);
        g.setCornerRadius(dp(radius));
        return g;
    }

    private LinearLayout.LayoutParams full() {
        return new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    private static String join(String... parts) {
        StringBuilder sb = new StringBuilder();
        for (String p : parts) if (p != null && !p.isEmpty()) { if (sb.length() > 0) sb.append(" · "); sb.append(p); }
        return sb.toString();
    }

    private static String ago(long at) {
        long s = Math.max(0, (System.currentTimeMillis() - at) / 1000);
        if (s < 60) return "قبل " + s + " ث";
        if (s < 3600) return "قبل " + (s / 60) + " د";
        return "قبل " + (s / 3600) + " س";
    }
    /** Waze deep link: to the customer before pickup, to the destination zone after the trip starts. */
    static String wazeUrl(JSONObject t, String status) {
        if (status.equals("accepted")) {
            if (t.isNull("pickup_lat") || !t.has("pickup_lat")) return null;
            return "https://waze.com/ul?ll=" + t.optDouble("pickup_lat") + "," + t.optDouble("pickup_lng") + "&navigate=yes";
        }
        if (t.has("zone_lat") && !t.isNull("zone_lat"))
            return "https://waze.com/ul?ll=" + t.optDouble("zone_lat") + "," + t.optDouble("zone_lng") + "&navigate=yes";
        String q = t.optString("zone", "");
        if (q.isEmpty() || q.equals("null")) q = t.optString("dropoff", "");
        if (q.isEmpty()) return null;
        return "https://waze.com/ul?q=" + Uri.encode(q + " بغداد") + "&navigate=yes";
    }

    private void openWaze(String url) {
        Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
        i.setPackage("com.waze");
        try { startActivity(i); return; } catch (Exception ignored) {}
        try {   // Waze not installed: offer it from the Play Store, else open the web link
            startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.waze")));
        } catch (Exception e) {
            try { startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(url))); } catch (Exception ignored) {}
        }
    }
}
