package iq.mansour.taxi;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Restarts tracking after the phone reboots or the app is updated. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        if (Prefs.code(ctx) != null && TrackService.hasLocation(ctx) && Prefs.of(ctx).getBoolean("on", false)) {
            TrackService.start(ctx);
        }
        if (MonitorService.pin(ctx) != null) MonitorService.start(ctx);
    }
}
