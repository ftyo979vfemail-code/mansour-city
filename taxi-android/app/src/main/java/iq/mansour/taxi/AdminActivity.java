package iq.mansour.taxi;

import android.Manifest;
import android.app.Activity;
import android.app.NotificationManager;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
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

import org.json.JSONArray;
import org.json.JSONObject;

/** Manager mode: sign in with the admin PIN; the phone then rings whenever a driver switches off. */
public class AdminActivity extends Activity {
    static final int AMBER = 0xFFF2A400, INK = 0xFF2A1D00, BG = 0xFFF3F2EE, FG = 0xFF1B1D22,
            MUTED = 0xFF6C6A63, OK = 0xFF16935A, BAD = 0xFFD6332B, WARN = 0xFFD97706, IDLE = 0xFF8A8A8A,
            CARD = 0xFFFFFFFF, LINE = 0xFFE0DDD4;

    private final Handler h = new Handler(Looper.getMainLooper());
    private LinearLayout root, list, setup;
    private TextView health;

    private final Runnable tick = new Runnable() {
        @Override public void run() { loadCars(); h.postDelayed(this, 10000); }
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
        root.setPadding(dp(20), dp(28), dp(20), dp(20));
        sv.addView(root);
        setContentView(sv);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (MonitorService.pin(this) == null) showLogin(null); else showMain();
    }

    @Override
    protected void onPause() {
        super.onPause();
        h.removeCallbacks(tick);
    }

    private void showLogin(String error) {
        h.removeCallbacks(tick);
        root.removeAllViews();
        root.addView(title("دخول المدير", "تنبيهات التكاسي على تلفونك"));
        root.addView(space(24));
        root.addView(text("رمز المدير", 14, MUTED, true));
        final EditText in = new EditText(this);
        in.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        in.setTextSize(28);
        in.setGravity(Gravity.CENTER);
        in.setBackground(box(CARD, LINE, 12));
        in.setPadding(dp(12), dp(12), dp(12), dp(12));
        root.addView(in, full());
        final TextView err = text(error == null ? "" : error, 15, BAD, false);
        root.addView(err);
        root.addView(space(8));
        Button go = button("دخول وتشغيل التنبيهات", true);
        go.setOnClickListener(v -> {
            final String pin = in.getText().toString().trim();
            if (pin.length() < 4) { err.setText("اكتب الرمز كامل"); return; }
            go.setEnabled(false);
            err.setText("جارٍ التحقق…");
            new Thread(() -> {
                try {
                    JSONObject r = new JSONObject(Api.call("taxi_admin_alerts",
                            new JSONObject().put("p_pin", pin).put("p_after", 0)));
                    Prefs.of(this).edit().putString("admin_pin", pin).putLong("alert_last", r.optLong("last", 0)).apply();
                    h.post(() -> { askPermissions(); MonitorService.start(this); showMain(); });
                } catch (Api.ApiError e) {
                    h.post(() -> { err.setText(e.getMessage()); go.setEnabled(true); });
                } catch (Exception e) {
                    h.post(() -> { err.setText("ماكو إنترنت، حاول مرة ثانية"); go.setEnabled(true); });
                }
            }).start();
        });
        root.addView(go, full());
        root.addView(space(12));
        Button back = button("رجوع لصفحة السائق", false);
        back.setOnClickListener(v -> { startActivity(new Intent(this, MainActivity.class).putExtra("driver", true)); finish(); });
        root.addView(back, full());
    }

    private void showMain() {
        root.removeAllViews();
        root.addView(title("مراقبة السواق", "يرن عليك أول ما سائق يطفي التتبع أو الموقع"));
        root.addView(space(12));
        health = text("", 14, MUTED, false);
        health.setBackground(box(CARD, LINE, 12));
        health.setPadding(dp(14), dp(12), dp(14), dp(12));
        root.addView(health, full());
        root.addView(space(8));
        setup = new LinearLayout(this);
        setup.setOrientation(LinearLayout.VERTICAL);
        root.addView(setup, full());
        root.addView(space(8));
        list = new LinearLayout(this);
        list.setOrientation(LinearLayout.VERTICAL);
        root.addView(list, full());
        root.addView(space(16));
        Button test = button("جرّب صوت الإنذار", false);
        test.setOnClickListener(v -> testAlarm());
        root.addView(test, full());
        root.addView(space(8));
        Button out = button("خروج المدير", false);
        out.setOnClickListener(v -> {
            Prefs.of(this).edit().remove("admin_pin").apply();
            stopService(new Intent(this, MonitorService.class));
            showLogin(null);
        });
        root.addView(out, full());
        if (!MonitorService.alive) MonitorService.start(this);
        refreshSetup();
        loadCars();
        h.removeCallbacks(tick);
        h.postDelayed(tick, 10000);
    }

    private void refreshSetup() {
        setup.removeAllViews();
        boolean notif = Build.VERSION.SDK_INT < 33 || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        boolean battery = pm.isIgnoringBatteryOptimizations(getPackageName());
        boolean fullScreen = Build.VERSION.SDK_INT < 34 || getSystemService(NotificationManager.class).canUseFullScreenIntent();
        if (!notif) step("اسمح بالإشعارات حتى يوصلك الإنذار", "السماح", v -> askPermissions());
        if (!battery) step("خلي التطبيق «بدون قيود» على البطارية", "فتح الإعداد", v -> {
            try { startActivity(new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:" + getPackageName()))); }
            catch (Exception e) { startActivity(new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + getPackageName()))); }
        });
        if (!fullScreen) step("اسمح بإنذار ملء الشاشة", "فتح الإعداد", v -> {
            try { startActivity(new Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:" + getPackageName()))); }
            catch (Exception ignored) {}
        });
    }

    private void askPermissions() {
        if (Build.VERSION.SDK_INT >= 33) requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 5);
    }

    @Override
    public void onRequestPermissionsResult(int rq, String[] p, int[] r) {
        super.onRequestPermissionsResult(rq, p, r);
        if (setup != null) refreshSetup();
    }

    private void loadCars() {
        final String pin = MonitorService.pin(this);
        if (pin == null) { showLogin(null); return; }
        new Thread(() -> {
            try {
                final JSONArray cars = new JSONArray(Api.call("taxi_admin_list", new JSONObject().put("p_pin", pin)));
                h.post(() -> renderCars(cars));
            } catch (Exception e) {
                h.post(() -> { if (health != null) health.setText("تعذّر التحديث: " + e.getMessage()); });
            }
        }).start();
        long ok = Prefs.of(this).getLong("alert_ok_at", 0);
        if (health != null) {
            boolean fresh = System.currentTimeMillis() - ok < 60000;
            health.setText(fresh ? "✔ التنبيهات شغّالة، آخر فحص " + ago(ok)
                    : "⚠ التنبيهات ما فحصت من فترة. تأكد من الإنترنت وإن البطارية «بدون قيود».");
            health.setTextColor(fresh ? OK : WARN);
        }
        if (setup != null) refreshSetup();
    }

    private void renderCars(JSONArray cars) {
        if (list == null) return;
        list.removeAllViews();
        if (cars.length() == 0) { list.addView(text("ماكو سيارات بعد. أضفها من لوحة الإدارة.", 15, MUTED, false)); return; }
        for (int i = 0; i < cars.length(); i++) {
            JSONObject c = cars.optJSONObject(i);
            String[] st = status(c);
            int color = st[0].equals("ok") ? OK : st[0].equals("bad") ? BAD : st[0].equals("warn") ? WARN : IDLE;
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(dp(14), dp(12), dp(14), dp(12));
            row.setBackground(box(CARD, LINE, 12));
            LinearLayout col = new LinearLayout(this);
            col.setOrientation(LinearLayout.VERTICAL);
            col.addView(text(c.optString("driver_name"), 16, FG, true));
            col.addView(text(c.optString("plate") + " · " + c.optString("model"), 13, MUTED, false));
            row.addView(col, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            TextView pill = text(st[1], 13, Color.WHITE, true);
            pill.setBackground(box(color, color, 20));
            pill.setPadding(dp(12), dp(5), dp(12), dp(5));
            row.addView(pill);
            LinearLayout.LayoutParams lp = full();
            lp.bottomMargin = dp(8);
            list.addView(row, lp);
        }
    }

    private static String[] status(JSONObject c) {
        String g = c.optString("gps_state");
        if (!c.optBoolean("active", true)) return new String[]{"idle", "موقوفة"};
        switch (g) {
            case "never": return new String[]{"idle", "لم يبدأ"};
            case "stopped": return new String[]{"bad", "التتبع مطفأ"};
            case "off": return new String[]{"bad", "GPS مطفأ"};
            case "denied": return new String[]{"bad", "رفض الموقع"};
            case "closed": return new String[]{"bad", "أغلق التطبيق"};
            case "lost": return new String[]{"bad", "انقطع الإرسال"};
            case "background": return new String[]{"ok", "متصل"};
            default: return new String[]{"ok", "متصل"};
        }
    }

    private void testAlarm() {
        MonitorService.channels(this);
        android.app.Notification n = new android.app.Notification.Builder(this, MonitorService.CH_ALARM)
                .setSmallIcon(R.drawable.ic_car).setContentTitle("⚠ تجربة الإنذار")
                .setContentText("هكذا يرن عليك إذا سائق طفّى").setAutoCancel(true).build();
        getSystemService(NotificationManager.class).notify(99, n);
    }

    private void step(String what, String action, View.OnClickListener l) {
        LinearLayout r = new LinearLayout(this);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setPadding(dp(14), dp(10), dp(14), dp(10));
        r.setBackground(box(0xFFFFF4DC, AMBER, 12));
        TextView t = text(what, 15, FG, false);
        r.addView(t, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Button b = button(action, true);
        b.setOnClickListener(l);
        r.addView(b);
        LinearLayout.LayoutParams lp = full();
        lp.bottomMargin = dp(8);
        setup.addView(r, lp);
    }

    private View title(String t, String s) {
        LinearLayout c = new LinearLayout(this);
        c.setOrientation(LinearLayout.VERTICAL);
        c.addView(text(t, 24, FG, true));
        c.addView(text(s, 14, MUTED, false));
        return c;
    }

    private TextView text(String s, int sp, int color, boolean bold) {
        TextView t = new TextView(this);
        t.setText(s); t.setTextSize(sp); t.setTextColor(color);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        return t;
    }

    private Button button(String s, boolean primary) {
        Button b = new Button(this);
        b.setText(s); b.setAllCaps(false); b.setTextSize(15); b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setTextColor(primary ? INK : FG);
        b.setBackground(box(primary ? AMBER : CARD, primary ? AMBER : LINE, 10));
        b.setPadding(dp(16), dp(10), dp(16), dp(10));
        return b;
    }

    private GradientDrawable box(int fill, int stroke, int radius) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(fill); g.setStroke(dp(1), stroke); g.setCornerRadius(dp(radius));
        return g;
    }

    private View space(int d) { View v = new View(this); v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(d))); return v; }
    private LinearLayout.LayoutParams full() { return new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT); }
    private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }

    private static String ago(long at) {
        long s = Math.max(0, (System.currentTimeMillis() - at) / 1000);
        return s < 60 ? "قبل " + s + " ث" : "قبل " + (s / 60) + " د";
    }
}
