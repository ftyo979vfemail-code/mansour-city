package iq.mansour.taxi;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Manager's phone: checks for new driver events every 10 seconds and raises a loud
 * alarm notification the moment a driver turns off GPS, closes the app or stops sending.
 */
public class MonitorService extends Service {
    static final String CH_RUN = "monitor";
    static final String CH_ALARM = "driver_alarm_v1";
    static final String CH_INFO = "driver_info";
    static final int N_RUN = 10;
    static final long EVERY_MS = 10000;
    static volatile boolean alive = false;

    private final Handler h = new Handler(Looper.getMainLooper());
    private final ExecutorService net = Executors.newSingleThreadExecutor();
    private int nextId = 100;

    static void start(Context c) {
        Intent i = new Intent(c, MonitorService.class);
        if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
    }

    static String pin(Context c) { return Prefs.of(c).getString("admin_pin", null); }

    private final Runnable loop = new Runnable() {
        @Override public void run() {
            net.execute(MonitorService.this::check);
            h.postDelayed(this, EVERY_MS);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        alive = true;
        Api.init(this);
        channels(this);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notification n = running("مراقبة السواق شغّالة", "يرن عليك أول ما سائق يطفي الموقع أو ينقطع");
        if (Build.VERSION.SDK_INT >= 34) startForeground(N_RUN, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        else startForeground(N_RUN, n);
        if (pin(this) == null) { stopSelf(); return START_NOT_STICKY; }
        h.removeCallbacks(loop);
        h.post(loop);
        return START_STICKY;
    }

    private void check() {
        String pin = pin(this);
        if (pin == null) { h.post(this::stopSelf); return; }
        long after = Prefs.of(this).getLong("alert_last", 0);
        try {
            JSONObject r = new JSONObject(Api.call("taxi_admin_alerts",
                    new JSONObject().put("p_pin", pin).put("p_after", after)));
            JSONArray ev = r.optJSONArray("events");
            if (ev != null) for (int i = 0; i < ev.length(); i++) notifyEvent(ev.getJSONObject(i));
            Prefs.of(this).edit().putLong("alert_last", r.optLong("last", after))
                    .putLong("alert_ok_at", System.currentTimeMillis()).putString("alert_err", "").apply();
        } catch (Api.ApiError e) {
            Prefs.of(this).edit().putString("alert_err", e.getMessage()).apply();
            if (e.getMessage() != null && e.getMessage().contains("رمز المدير")) {
                Prefs.of(this).edit().remove("admin_pin").apply();
                h.post(this::stopSelf);
            }
        } catch (Exception e) {
            Prefs.of(this).edit().putString("alert_err", "ماكو إنترنت").apply();
        }
    }

    private void notifyEvent(JSONObject e) {
        String kind = e.optString("kind");
        String who = e.optString("driver_name") + " · " + e.optString("plate");
        String title; boolean alarm;
        switch (kind) {
            case "off":     title = "⚠ أطفأ الـ GPS"; alarm = true; break;
            case "denied":  title = "⚠ رفض إذن الموقع"; alarm = true; break;
            case "closed":  title = "⚠ أغلق التطبيق"; alarm = true; break;
            case "lost":    title = "⚠ انقطع الإرسال"; alarm = true; break;
            case "stopped": title = "أطفأ التتبع"; alarm = true; break;
            case "unlogged": title = "⚠ يتحرك بدون سفرة مسجّلة"; alarm = true; break;
            case "rejected": title = "⚠ رفض سفرة من المكتب"; alarm = true; break;
            case "started": title = "شغّل التتبع"; alarm = false; break;
            case "gps_on":  title = "رجع الإرسال"; alarm = false; break;
            default: return; // "background" is normal for the app
        }
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, AdminActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        Notification.Builder b = new Notification.Builder(this, alarm ? CH_ALARM : CH_INFO)
                .setSmallIcon(R.drawable.ic_car)
                .setContentTitle(title)
                .setContentText(who)
                .setStyle(new Notification.BigTextStyle().bigText(who
                        + (e.optString("driver_phone").isEmpty() ? "" : "\nهاتف: " + e.optString("driver_phone"))))
                .setAutoCancel(true)
                .setContentIntent(open);
        if (alarm) b.setCategory(Notification.CATEGORY_ALARM).setFullScreenIntent(open, true);
        getSystemService(NotificationManager.class).notify(nextId++, b.build());
    }

    static void channels(Context ctx) {
        NotificationManager nm = ctx.getSystemService(NotificationManager.class);
        NotificationChannel run = new NotificationChannel(CH_RUN, "المراقبة", NotificationManager.IMPORTANCE_LOW);
        run.setShowBadge(false);
        nm.createNotificationChannel(run);
        NotificationChannel alarm = new NotificationChannel(CH_ALARM, "إنذار إطفاء السائق", NotificationManager.IMPORTANCE_HIGH);
        alarm.enableVibration(true);
        alarm.setVibrationPattern(new long[]{0, 800, 300, 800, 300, 800});
        alarm.setBypassDnd(true);
        alarm.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build());
        nm.createNotificationChannel(alarm);
        nm.createNotificationChannel(new NotificationChannel(CH_INFO, "تشغيل السواق", NotificationManager.IMPORTANCE_DEFAULT));
    }

    private Notification running(String title, String text) {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, AdminActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CH_RUN)
                .setSmallIcon(R.drawable.ic_car).setContentTitle(title).setContentText(text)
                .setOngoing(true).setContentIntent(open).build();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        if (pin(this) != null) start(getApplicationContext());
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        alive = false;
        h.removeCallbacksAndMessages(null);
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent i) { return null; }
}
