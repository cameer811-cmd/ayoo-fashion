-- AYOO Phase 2.2: enforce owner-only, forward-only order status transitions.
-- Review this file before running it in Supabase SQL Editor.
-- Does not modify existing order records.

create or replace function public.ayoo_update_order_status(
  p_order_id uuid,
  p_new_status text
)
returns table(order_id uuid, order_number text, order_status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_next_status text;
begin
  if auth.uid() is distinct from '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid then
    raise exception 'Not authorized to update AYOO orders.';
  end if;

  if p_new_status not in ('confirmed','processing','shipped','delivered') then
    raise exception 'Unsupported order status transition.';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found.';
  end if;

  v_next_status := case v_order.order_status
    when 'pending' then 'confirmed'
    when 'confirmed' then 'processing'
    when 'processing' then 'shipped'
    when 'shipped' then 'delivered'
    else null
  end;

  if v_next_status is null or p_new_status <> v_next_status then
    raise exception 'Invalid order status transition: % -> %.',
      v_order.order_status, p_new_status;
  end if;

  update public.orders
  set order_status = p_new_status,
      updated_at = now()
  where id = v_order.id;

  return query
  select v_order.id, v_order.order_number, p_new_status;
end;
$$;

-- Prevent direct browser-side updates; status changes must use the guarded RPC.
revoke update on public.orders from anon, authenticated;
revoke all on function public.ayoo_update_order_status(uuid, text) from public, anon;
grant execute on function public.ayoo_update_order_status(uuid, text) to authenticated;

comment on function public.ayoo_update_order_status(uuid, text) is
  'Owner-only forward status transition: pending -> confirmed -> processing -> shipped -> delivered. Cancellation uses ayoo_cancel_order.';
