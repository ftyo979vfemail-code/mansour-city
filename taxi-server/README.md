# تكاسي المجمّع — التشغيل على سيرفر خاص

نظام التكاسي كامل على سيرفر واحد (Ubuntu 22.04 أو 24.04):

| الخدمة | الوظيفة |
|---|---|
| `db` | PostgreSQL 16، قاعدة البيانات (غير مكشوفة للإنترنت) |
| `api` | PostgREST، يشغّل دوال `taxi_*` فقط بصلاحيات محدودة |
| `web` | Caddy، يقدّم لوحة الإدارة وصفحة السائق ويطلع شهادة HTTPS تلقائيًا |
| `backup` | نسخة احتياطية يومية (تنحفظ 14 يوم) + تنظيف نقاط المسار الأقدم من 90 يوم |

## التنصيب
1. اشترِ سيرفر Ubuntu (1 GB رام تكفي)، وإذا عندك دومين اربطه بـ IP السيرفر (سجل A).
2. افتح طرفية السيرفر كـ root وشغّل:
   ```
   curl -fsSL https://raw.githubusercontent.com/ftyo979vfemail-code/mansour-city/main/taxi-server/install.sh | bash
   ```
3. السكربت يسألك عن الدومين (أو يستخدم عنوان `IP.sslip.io` مؤقت)، وينقل البيانات من النظام الحالي برمز المدير.

## بعد التنصيب
- التحديث: `taxi-update`
- السجلات: `cd /opt/taxi/app/taxi-server && docker compose logs -f`
- النسخ الاحتياطية: `/opt/taxi/app/taxi-server/backups`
- الاسترجاع من نسخة: `docker compose exec -T db pg_restore -U postgres -d taxi --clean < backups/<file>.dump`
- تغيير الدومين: عدّل `DOMAIN` بملف `.env` ثم `docker compose up -d`

## تحويل التطبيق والصفحات للسيرفر الجديد
- تطبيق الأندرويد يقرأ عنوان السيرفر من `taxi/config.json` (على GitHub Pages)، فغيّر `api` لعنوان السيرفر الجديد، والتطبيقات المنصّبة تتحول وحدها خلال دقائق بدون إعادة تنصيب.
- الصفحة على السيرفر الجديد تستخدم السيرفر نفسه تلقائيًا.
