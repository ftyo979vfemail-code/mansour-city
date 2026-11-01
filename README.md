# المنصور ستي — نظام المخازن والمشتريات

Mansour City warehouse & purchasing system. Static site on GitHub Pages + Supabase.

## موقع حضور العمال (مستقل)
`attendance/` = نفس النظام بوضع الحضور فقط (نفس قاعدة البيانات والحسابات).
يُبنى من `index.html` — بعد أي تعديل على `index.html` أو `sw.js` شغّل:

    python3 scripts/build-attendance.py

## المواقع (Multi-site)
نفس النظام يخدم موقعين ببيانات منفصلة: **المنصور ستي** (`mansour`) و**مجمع الأميرات ستي — الفلوجة** (`alamirat`).
- كل جدول بيانات بيه عمود `branch`، وكل حساب عنده `branch` (موقعه) و`branches` (المواقع المسموحة) و`cur_branch` (الموقع الحالي).
- `public.cur_branch()` يحدد موقع المستخدم، وكل سياسات RLS والدوال مقيدة بيه. التبديل عن طريق `set_branch()`.
- المالك يحدد مواقع كل حساب من شاشة الحسابات. الإشعارات توصل بس لموظفين نفس الموقع.
- الترحيل: `supabase/branches.sql`. لإضافة موقع ثالث: أضف صف بجدول `branches` وبـ `BRANCHES` بـ index.html.
