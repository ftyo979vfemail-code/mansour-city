package iq.mansour.taxi;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/** Thin client for the Supabase RPC functions used by the taxi system. */
final class Api {
    static final String URL_BASE = "https://azvpzlsgzaglerapuayc.supabase.co/rest/v1/rpc/";
    static final String KEY = "sb_publishable_LSh2trzuxWteNF4ltsBDZA_otyI__gu";

    static String call(String fn, JSONObject body) throws Exception {
        HttpURLConnection c = (HttpURLConnection) new URL(URL_BASE + fn).openConnection();
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
