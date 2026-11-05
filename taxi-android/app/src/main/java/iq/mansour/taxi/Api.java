package iq.mansour.taxi;

import android.content.Context;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Thin client for the Supabase RPC functions used by the taxi system. */
final class Api {
    static final String DEFAULT_BASE = "https://azvpzlsgzaglerapuayc.supabase.co";
    /** Tells installed apps which server to use, so moving servers needs no reinstall. */
    static final String CONFIG_URL = "https://ftyo979vfemail-code.github.io/mansour-city/taxi/config.json";
    static final String KEY = "sb_publishable_LSh2trzuxWteNF4ltsBDZA_otyI__gu";
    static volatile String base = DEFAULT_BASE;
    private static volatile long checkedAt = 0;

    /** Loads the saved server address, then refreshes it from config.json in the background (at most every 10 min). */
    static void init(Context ctx) {
        final Context app = ctx.getApplicationContext();
        base = Prefs.of(app).getString("api", DEFAULT_BASE);
        if (System.currentTimeMillis() - checkedAt < 10 * 60 * 1000) return;
        checkedAt = System.currentTimeMillis();
        new Thread(() -> {
            try {
                HttpURLConnection c = (HttpURLConnection) new URL(CONFIG_URL + "?t=" + System.currentTimeMillis()).openConnection();
                c.setConnectTimeout(8000);
                c.setReadTimeout(8000);
                c.setUseCaches(false);
                if (c.getResponseCode() == 200) {
                    String api = new JSONObject(read(c.getInputStream())).optString("api", "").trim();
                    while (api.endsWith("/")) api = api.substring(0, api.length() - 1);
                    if (api.startsWith("https://")) {
                        base = api;
                        Prefs.of(app).edit().putString("api", api).apply();
                    }
                }
                c.disconnect();
            } catch (Exception ignored) {}
        }).start();
    }

    static String call(String fn, JSONObject body) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(base + "/rest/v1/rpc/" + fn).openConnection();
        c.setConnectTimeout(12000);
        c.setReadTimeout(15000);
        c.setRequestMethod("POST");
        c.setDoOutput(true);
        c.setRequestProperty("apikey", KEY);
        c.setRequestProperty("Authorization", "Bearer " + KEY);
        c.setRequestProperty("Content-Type", "application/json");
        try (OutputStream o = c.getOutputStream()) {
            o.write(body.toString().getBytes(StandardCharsets.UTF_8));
        }
        int code = c.getResponseCode();
        String text = read(code >= 400 ? c.getErrorStream() : c.getInputStream());
        c.disconnect();
        if (code >= 400) {
            String msg = "تعذّر الاتصال بالخادم";
            try { msg = new JSONObject(text).optString("message", msg); } catch (Exception ignored) {}
            throw new ApiError(msg);
        }
        return text;
    }

    static JSONObject login(String code) throws Exception {
        return new JSONObject(call("taxi_driver_login", new JSONObject().put("p_code", code)));
    }

    static void ping(String code, double lat, double lng, Float speed, Float acc, Float heading, Integer battery) throws Exception {
        JSONObject b = new JSONObject()
                .put("p_code", code).put("p_lat", lat).put("p_lng", lng)
                .put("p_speed", speed == null ? JSONObject.NULL : speed)
                .put("p_acc", acc == null ? JSONObject.NULL : acc)
                .put("p_heading", heading == null ? JSONObject.NULL : heading)
                .put("p_battery", battery == null ? JSONObject.NULL : battery);
        call("taxi_ping", b);
    }

    static void state(String code, String state) {
        try { call("taxi_gps_state", new JSONObject().put("p_code", code).put("p_state", state)); }
        catch (Exception ignored) {}
    }

    private static String read(InputStream in) throws Exception {
        if (in == null) return "";
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] buf = new byte[4096];
        int n;
        while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
        in.close();
        return out.toString("UTF-8");
    }

    static final class ApiError extends Exception {
        ApiError(String m) { super(m); }
    }
}
