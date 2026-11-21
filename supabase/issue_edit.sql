-- تعديل الصرف: إرجاع كمية للمخزون عند تقليل كمية صرف سابق
-- نفس صلاحيات issue_stock (المخزن الرئيسي لمدير المخزن، مخزن الآليات لمدير وأمين مخزن الآليات)
create or replace function public.return_stock(p_item text, p_qty numeric)
returns numeric
language plpgsql
security definer
set search_path to 'public'
as $function$
declare rl text := public.my_role(); it public.inventory; w text; new_qty numeric;
begin
  if rl not in ('store','mstore','keeper','project','owner') then raise exception 'غير مسموح'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'الكمية غير صحيحة'; end if;
  select * into it from public.inventory where id = p_item and branch = public.cur_branch() for update;
  if it.id is null then raise exception 'المادة غير موجودة'; end if;
  w := case when it.data->>'wh' = 'mach' then 'mach' else 'main' end;
  if rl = 'store' and w <> 'main' then raise exception 'هذه المادة تخص مخزن الآليات'; end if;
  if rl in ('mstore','keeper') and w <> 'mach' then raise exception 'هذه المادة تخص المخزن الرئيسي'; end if;
  new_qty := round((coalesce((it.data->>'qty')::numeric, 0) + p_qty)::numeric, 3);
  update public.inventory set data = jsonb_set(data, '{qty}', to_jsonb(new_qty)), updated_at = now()
   where id = p_item and branch = public.cur_branch();
  return new_qty;
end $function$;

revoke all on function public.return_stock(text, numeric) from public, anon;
grant execute on function public.return_stock(text, numeric) to authenticated;
