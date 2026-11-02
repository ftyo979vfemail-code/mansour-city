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
    static final int AMBER = 0xFFF2A400, INK = 0xFF2A1D00, BG = 0xFFF3F2EE, FG = 0xFF1B1D22,
            MUTED = 0xFF6C6A63, OK = 0xFF16935A, BAD = 0xFFD6332B, CARD = 0xFFFFFFFF, LINE = 0xFFE0DDD4;
    static final int RQ_FINE = 1, RQ_BG = 2, RQ_NOTIF = 3;

    private final Handler h = new Handler(Looper.getMainLooper());
    private LinearLayout root;
    private TextView status, sub, sent, acc, spd, count;
    private LinearLayout setup;

    private final Runnable tick = new Runnable() {
        @Override public void run() { refresh(); h.postDelayed(this, 2000); }
    };

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
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
        root.addView(brand("صفحة السائق", "تكاسي المجمّع"));
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

        LinearLayout ring = new LinearLayout(this);
        ring.setOrientation(LinearLayout.VERTICAL);
        ring.setGravity(Gravity.CENTER);
        ring.setPadding(dp(16), dp(22), dp(16), dp(22));
        ring.setBackground(box(CARD, LINE, 18));
        status = text("…", 24, FG, true);
        status.setGravity(Gravity.CENTER);
        sub = text("", 14, MUTED, false);
        sub.setGravity(Gravity.CENTER);
        ring.addView(status);
        ring.addView(sub);
        root.addView(ring, full());
        root.addView(space(12));

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
        root.addView(note("التتبع يشتغل بالخلفية حتى لو قفلت الشاشة أو فتحت تطبيق ثاني، ويرجع يشتغل وحده بعد إعادة تشغيل التلفون. إطفاء الـ GPS يرن عليك ويوصل للإدارة فورًا."));
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

        if (fine && !TrackService.alive) TrackService.start(this);

        long at = Prefs.of(this).getLong("sentAt", 0);
        String err = Prefs.of(this).getString("err", "");
        if (!fine) { setStatus("التتبع متوقف", "اكمل الخطوات تحت", BAD); }
        else if (!gps) { setStatus("الـ GPS مطفأ", "الإدارة تم إبلاغها", BAD); }
        else if (!bg) { setStatus("يشتغل بس والتطبيق مفتوح", "اكمل الخطوة تحت حتى يشتغل بالخلفية", 0xFFD97706); }
        else if (at == 0) { setStatus("جارٍ تحديد الموقع…", err.isEmpty() ? "انتظر لحظة" : err, 0xFFD97706); }
        else if (!err.isEmpty() && System.currentTimeMillis() - at > 60000) { setStatus("الإرسال متأخر", err, 0xFFD97706); }
        else { setStatus("التتبع شغّال", "موقعك يوصل للإدارة", OK); }

        sent.setText(at == 0 ? "—" : ago(at));
        float a = Prefs.of(this).getFloat("acc", -1);
        acc.setText(a < 0 ? "—" : Math.round(a) + " م");
        spd.setText(Math.round(Prefs.of(this).getFloat("spd", 0) * 3.6f) + " كم/س");
        count.setText(String.valueOf(Prefs.of(this).getInt("count", 0)));
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
        if (rq == RQ_FINE && granted(Manifest.permission.ACCESS_FINE_LOCATION)) TrackService.start(this);
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
        TextView mark = text("🚕", 24, INK, false);
        mark.setGravity(Gravity.CENTER);
        mark.setBackground(box(AMBER, AMBER, 12));
        r.addView(mark, new LinearLayout.LayoutParams(dp(48), dp(48)));
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
}
