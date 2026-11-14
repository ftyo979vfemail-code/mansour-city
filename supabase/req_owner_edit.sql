-- صاحب الطلب يعدّل أو يلغي طلبه قبل أي إجراء من غيره + المخزن يحدد الكمية المستلمة فعلاً
-- طُبّق على قاعدة البيانات كترحيل: req_owner_edit_and_recv_qty
--  * private.req_own_ok(r)            : الحالة store_check/proj/pur_ok/buy، بلا شراء ولا عروض، وكل السجل باسم صاحب الطلب
--  * public.req_own_edit(p_req,p_patch): يعدّل item/qty/unit/area/priority/notes ويكتب التغيير بالسجل
--  * public.req_own_cancel(p_req,p_reason): status=rejected + cancelled=<وقت> + السبب بالسجل
--  * public.issue_receipt_code(p_req,p_qty,p_note): الكمية المستلمة تنحفظ ويّا الباركود (receipt_codes.qty/note)
--  * public.confirm_receipt: يكتب recvQty و receipt.qty بالطلب، والإشعار يبين الكمية المستلمة والمطلوبة
alter table public.receipt_codes add column if not exists qty numeric, add column if not exists note text;
