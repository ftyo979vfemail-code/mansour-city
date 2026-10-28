# المنصور ستي — نظام المخازن والمشتريات

Mansour City warehouse & purchasing system. Static site on GitHub Pages + Supabase.

## موقع حضور العمال (مستقل)
`attendance/` = نفس النظام بوضع الحضور فقط (نفس قاعدة البيانات والحسابات).
يُبنى من `index.html` — بعد أي تعديل على `index.html` أو `sw.js` شغّل:

    python3 scripts/build-attendance.py
