
-- مدير مخزن الآليات (mstore) يعدّل كميات الكاز بأي وقت مثل المالك: private.guard_fuel_edit يتخطى الفحص لـ owner و mstore
-- حذف حركة كاز: مسموح لـ owner و mstore بأي وقت؛ غيرهم خلال 15 دقيقة لحركته (أو machines/project). تقليم أقدم حركة عند الإضافة طبيعي

-- ورقة الحضور (att-sheet edge function): جدول att_sheets + attendance.method 'sheet'
-- + public/private.att_sheet_apply(branch, day, wids[], by, start) — service_role فقط، يسجّل حاضر بدون ما يكتب فوق تسجيل يدوي،
--   ويحوّل الغياب التلقائي (method=auto) إلى حاضر. المطابقة بثقة ≥ 0.8 تنسجل تلقائياً، والباقي pending لمسؤول الإدارة.
-- on_notification: kind att_sheet يدز إشعار لـ hr, timekeeper, project, owner
-- att_close_day: ما يسجّل غياب تلقائي بعد (غير المسجلين يبقون غير مسجلين)؛ وانحذف الغياب التلقائي السابق (41 سجل 2026-11-03)
