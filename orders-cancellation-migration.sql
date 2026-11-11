-- AYOO Phase 2.1: safe order cancellation and stock release
-- Run once in Supabase Dashboard > SQL Editor after orders-checkout-migration.sql.
-- Only the AYOO owner can cancel. Shipped/delivered orders cannot be cancelled here.
create or replace function public.ayoo_cancel_order(p_order_id uuid)
returns table(order_id uuid, order_number text, order_status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_item record;
begin
  if auth.uid() is distinct from '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid then
    raise exception 'Not authorized to cancel AYOO orders.';
  end if;

  select * into v_order
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'Order not found.';
  end if;

  if v_order.order_status = 'cancelled' then
    return query select v_order.id, v_order.order_number, v_order.order_status;
    return;
  end if;

  if v_order.order_status in ('shipped','delivered') then
    raise exception 'A shipped or delivered order cannot be cancelled here.';
  end if;

  for v_item in
    select variant_id, quantity
    from public.order_items
    where order_id = v_order.id
    order by variant_id
  loop
    update public.product_variants
    set reserved_quantity = greatest(0, coalesce(reserved_quantity,0) - v_item.quantity)
    where id = v_item.variant_id;
  end loop;

  update public.orders
  set order_status = 'cancelled',
      updated_at = now()
  where id = v_order.id;

  return query select v_order.id, v_order.order_number, 'cancelled'::text;
end;
$$;

revoke all on function public.ayoo_cancel_order(uuid) from public, anon;
grant execute on function public.ayoo_cancel_order(uuid) to authenticated;
comment on function public.ayoo_cancel_order(uuid) is
  'Cancels an AYOO order for the owner and releases its reserved variant stock exactly once.';
