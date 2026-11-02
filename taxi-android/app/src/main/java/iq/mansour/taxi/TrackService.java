package iq.mansour.taxi;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.media.AudioAttributes;
import android.media.RingtoneManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;
import android.provider.Settings;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Foreground service that keeps sending the driver's location while the phone is
 * locked or another app is open, and raises a loud alert whenever GPS is turned off.
 */
public class TrackService extends Service implements LocationListener {
    static final String CH_RUN = "tracking";
    static final String CH_ALERT = "gps_alert";
    static final int N_RUN = 1, N_ALERT = 2;
    static final long SEND_EVERY_MS = 5000;
    static final long HEARTBEAT_MS = 30000;

    private LocationManager lm;
    private final Handler h = new Handler(Looper.getMainLooper());
    private final ExecutorService net = Executors.newSingleThreadExecutor();
    private Location last;
    private long lastSentAt = 0;
    private boolean gpsOffReported = false;
    private PowerManager.WakeLock wake;
    private boolean registered = false;
    static volatile boolean alive = false;

    static void start(Context c) {
        Intent i = new Intent(c, TrackService.class);
        if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
    }

    static boolean hasLocation(Context c) {
        return c.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED;
    }

    private final BroadcastReceiver providers = new BroadcastReceiver() {
        @Override public void onReceive(Context c, Intent i) { checkGps(); }
    };

    private final Runnable heartbeat = new Runnable() {
        @Override public void run() {
            checkGps();
            if (gpsEnabled()) {
                Location l = last;
                if (l == null || System.currentTimeMillis() - lastSentAt > HEARTBEAT_MS) {
                    Location k = bestKnown();
                    if (k != null) send(k, true);
                }
            }
            h.postDelayed(this, HEARTBEAT_MS);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        alive = true;
        lm = (LocationManager) getSystemService(LOCATION_SERVICE);
        channels();
        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "taxi:track");
        wake.setReferenceCounted(false);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notification n = runningNotification("التتبع شغّال", "موقعك يوصل للإدارة");
        if (Build.VERSION.SDK_INT >= 29) startForeground(N_RUN, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
        else startForeground(N_RUN, n);

        if (Prefs.code(this) == null || !hasLocation(this) || !Prefs.of(this).getBoolean("on", false)) { stopSelf(); return START_NOT_STICKY; }
        if (!wake.isHeld()) wake.acquire();
        Prefs.of(this).edit().putBoolean("running", true).apply();
        requestUpdates();
        if (!registered) try {
            registered = true;
            IntentFilter f = new IntentFilter(LocationManager.PROVIDERS_CHANGED_ACTION);
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(providers, f, Context.RECEIVER_EXPORTED);
            else registerReceiver(providers, f);
        } catch (Exception ignored) {}
        h.removeCallbacks(heartbeat);
        h.post(heartbeat);
        return START_STICKY;
    }

    @SuppressWarnings("MissingPermission")
    private void requestUpdates() {
        try {
            lm.removeUpdates(this);
            if (lm.isProviderEnabled(LocationManager.GPS_PROVIDER))
                lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, SEND_EVERY_MS, 0f, this, Looper.getMainLooper());
            if (lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER))
                lm.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, 15000, 0f, this, Looper.getMainLooper());
        } catch (Exception ignored) {}
    }

    @SuppressWarnings("MissingPermission")
    private Location bestKnown() {
        Location best = last;
        for (String p : new String[]{LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER}) {
            try {
                Location l = lm.getLastKnownLocation(p);
                if (l != null && (best == null || l.getTime() > best.getTime())) best = l;
            } catch (Exception ignored) {}
        }
        return best;
    }

    private boolean gpsEnabled() {
        try { return lm.isProviderEnabled(LocationManager.GPS_PROVIDER); } catch (Exception e) { return false; }
    }

    private void checkGps() {
        boolean on = gpsEnabled();
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (!on && !gpsOffReported) {
            gpsOffReported = true;
            Prefs.of(this).edit().putString("gps", "off").apply();
            final String code = Prefs.code(this);
            net.execute(() -> Api.state(code, "off"));
            nm.notify(N_ALERT, alertNotification());
            nm.notify(N_RUN, runningNotification("الـ GPS مطفأ!", "شغّل الموقع حالًا. الإدارة تم إبلاغها"));
        } else if (!on) {
            nm.notify(N_ALERT, alertNotification()); // keep nagging every heartbeat
        } else if (gpsOffReported) {
            gpsOffReported = false;
            Prefs.of(this).edit().putString("gps", "ok").apply();
            nm.cancel(N_ALERT);
            nm.notify(N_RUN, runningNotification("التتبع شغّال", "موقعك يوصل للإدارة"));
            requestUpdates();
        }
    }

    @Override
    public void onLocationChanged(Location l) {
        boolean better = last == null
                || LocationManager.GPS_PROVIDER.equals(l.getProvider())
                || System.currentTimeMillis() - last.getTime() > 20000;
        if (!better) return;
        last = l;
        if (System.currentTimeMillis() - lastSentAt >= SEND_EVERY_MS - 500) send(l, false);
    }

    private void send(Location l, boolean fromHeartbeat) {
        final String code = Prefs.code(this);
        if (code == null) { stopSelf(); return; }
        lastSentAt = System.currentTimeMillis();
        final double lat = l.getLatitude(), lng = l.getLongitude();
        final Float spd = l.hasSpeed() ? l.getSpeed() : null;
        final Float acc = l.hasAccuracy() ? l.getAccuracy() : null;
        final Float hd = l.hasBearing() ? l.getBearing() : null;
        final Integer bat = battery();
        net.execute(() -> {
            try {
                Api.ping(code, lat, lng, spd, acc, hd, bat);
                Prefs.of(this).edit()
                        .putLong("sentAt", System.currentTimeMillis())
                        .putFloat("acc", acc == null ? -1f : acc)
                        .putFloat("spd", spd == null ? 0f : spd)
                        .putInt("count", Prefs.of(this).getInt("count", 0) + 1)
                        .putString("err", "")
                        .apply();
            } catch (Api.ApiError e) {
                Prefs.of(this).edit().putString("err", e.getMessage()).apply();
                if (e.getMessage() != null && e.getMessage().contains("رمز")) {
                    // Code was revoked or the car stopped by the admin: sign out and stop.
                    Prefs.of(this).edit().remove("code").apply();
                    h.post(this::stopSelf);
                }
            } catch (Exception e) {
                Prefs.of(this).edit().putString("err", "لا يوجد إنترنت، سيُعاد الإرسال تلقائيًا").apply();
            }
        });
    }

    private Integer battery() {
        try {
            BatteryManager bm = (BatteryManager) getSystemService(BATTERY_SERVICE);
            int v = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
            return v > 0 ? v : null;
        } catch (Exception e) { return null; }
    }

    private void channels() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        NotificationChannel run = new NotificationChannel(CH_RUN, "التتبع", NotificationManager.IMPORTANCE_LOW);
        run.setShowBadge(false);
        nm.createNotificationChannel(run);
        NotificationChannel alert = new NotificationChannel(CH_ALERT, "تنبيه إطفاء الـ GPS", NotificationManager.IMPORTANCE_HIGH);
        alert.enableVibration(true);
        alert.setVibrationPattern(new long[]{0, 600, 250, 600, 250, 600});
        alert.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                new AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build());
        nm.createNotificationChannel(alert);
    }

    private Notification runningNotification(String title, String text) {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CH_RUN)
                .setSmallIcon(R.drawable.ic_car)
                .setContentTitle(title)
                .setContentText(text)
                .setOngoing(true)
                .setContentIntent(open)
                .build();
    }

    private Notification alertNotification() {
        PendingIntent settings = PendingIntent.getActivity(this, 1,
                new Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CH_ALERT)
                .setSmallIcon(R.drawable.ic_car)
                .setContentTitle("⚠ الـ GPS مطفأ")
                .setContentText("اضغط هنا وشغّل الموقع. الإدارة تشوف إنك طفيته.")
                .setCategory(Notification.CATEGORY_ALARM)
                .setOngoing(true)
                .setContentIntent(settings)
                .setFullScreenIntent(settings, true)
                .build();
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        // Swiping the app away from recents must not stop tracking.
        if (Prefs.of(this).getBoolean("on", false)) start(getApplicationContext());
        super.onTaskRemoved(rootIntent);
    }

    @Override
    public void onDestroy() {
        alive = false;
        h.removeCallbacksAndMessages(null);
        try { lm.removeUpdates(this); } catch (Exception ignored) {}
        try { unregisterReceiver(providers); } catch (Exception ignored) {}
        if (wake != null && wake.isHeld()) wake.release();
        Prefs.of(this).edit().putBoolean("running", false).apply();
        try { getSystemService(NotificationManager.class).cancel(N_ALERT); } catch (Exception ignored) {}
        final String code = Prefs.code(this);
        final String why = Prefs.of(this).getBoolean("on", false) ? "closed" : "stopped";
        if (code != null) new Thread(() -> Api.state(code, why)).start();
        super.onDestroy();
    }

    @Override public void onProviderEnabled(String p) { checkGps(); }
    @Override public void onProviderDisabled(String p) { checkGps(); }
    @Override public void onStatusChanged(String p, int s, Bundle b) {}
    @Override public IBinder onBind(Intent i) { return null; }
}
