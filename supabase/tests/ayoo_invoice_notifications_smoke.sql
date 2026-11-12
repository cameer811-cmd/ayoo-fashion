-- Run after applying 20261112090000_ayoo_invoice_notifications.sql.
-- Entire test is rolled back; no order, stock reservation, or notification survives.
begin;

do $$
declare
  v_variant uuid;
  v_order record;
  v_key text := encode(gen_random_bytes(16), 'hex');
  v_items jsonb;
  v_job_id uuid;
  v_invoice_count integer;
  v_delivery_count integer;
  v_opt_in boolean;
begin
  select pv.id into v_variant
  from public.product_variants pv
  join public.products p on p.id = pv.product_id
  where pv.active = true
    and p.published = true
    and coalesce(pv.stock_quantity,0) - coalesce(pv.reserved_quantity,0) > 0
  order by pv.created_at nulls last
  limit 1;

  if v_variant is null then
    raise exception 'No in-stock test variant is available.';
  end if;

  v_items := jsonb_build_array(jsonb_build_object('variant_id', v_variant::text, 'quantity', 1));

  select * into v_order
  from public.ayoo_create_order_with_consent(
    'AYOO Invoice Test',
    'invoice-test@example.invalid',
    '+905000000000',
    'TR',
    jsonb_build_object('address_line1','Test Street 1','city','Istanbul','postal_code','34000'),
    'cash_on_delivery',
    v_items,
    v_key,
    'Automated invoice outbox smoke test',
    0,
    true
  );

  if v_order.order_id is null then
    raise exception 'Test checkout did not return an order.';
  end if;

  select count(*) into v_invoice_count
  from private.ayoo_invoice_records where order_id = v_order.order_id;

  select count(*) into v_delivery_count
  from private.ayoo_notification_jobs j
  join private.ayoo_notification_deliveries d on d.job_id = j.id
  where j.order_id = v_order.order_id and j.event_type = 'order_created';

  select whatsapp_opt_in into v_opt_in from public.orders where id = v_order.order_id;

  if v_invoice_count <> 1 then raise exception 'Expected one invoice record, got %', v_invoice_count; end if;
  if v_delivery_count <> 2 then raise exception 'Expected email + WhatsApp deliveries, got %', v_delivery_count; end if;
  if v_opt_in is distinct from true then raise exception 'WhatsApp opt-in was not stored.'; end if;

  update public.orders set order_status = 'confirmed' where id = v_order.order_id;

  select count(*) into v_delivery_count
  from private.ayoo_notification_jobs j
  join private.ayoo_notification_deliveries d on d.job_id = j.id
  where j.order_id = v_order.order_id and j.event_type = 'order_status';

  if v_delivery_count <> 2 then raise exception 'Expected two status deliveries, got %', v_delivery_count; end if;
end;
$$;

rollback;
