-- تسديد دفعة/قسط معيّن يدوياً (نقداً أو من المحفظة) بدل التوزيع التلقائي على الأقدم
-- طُبّق كترحيل: targeted_installment_payments
-- cash.inst / sales_wallet.inst = مفتاح الدفعة بالجدول: "<k>|<yyyy-mm-dd>|<label>"
-- الواجهة (kState): المربوط بدفعة ينحسب عليها أول، وغير المربوط أو الزايد يتوزع على الأقدم
-- wallet_op صار بيه p_inst (اختياري) لاستقطاع المحفظة على دفعة معيّنة
alter table public.cash add column if not exists inst text;
alter table public.sales_wallet add column if not exists inst text;
