package iq.mansour.taxi;

import android.content.Context;
import android.content.SharedPreferences;

final class Prefs {
    static SharedPreferences of(Context c) {
        return c.getSharedPreferences("taxi", Context.MODE_PRIVATE);
    }
    static String code(Context c) { return of(c).getString("code", null); }
}
