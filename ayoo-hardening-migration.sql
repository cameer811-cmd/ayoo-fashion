-- AYOO hardening migration — 2026-11-11
-- Apply only after reviewing on a Supabase development branch.
-- Preserves existing orders and products; no table data is deleted.

begin;

-- Recreate both checkout overloads with an unambiguous PostgREST signature.
drop function if exists public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,numeric);
drop function if exists public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,numeric,text);
drop function if exists public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,text,numeric);

-- 1) Private idempotency ledger. No browser role receives table privileges.
create table if not exists public.ayoo_checkout_requests (
  idempotency_key text primary key,
  request_fingerprint text not null,
  order_id uuid not null references public.orders(id) on delete restrict,
  created_at timestamptz not null default now()
);
create index if not exists ayoo_checkout_requests_order_id_idx on public.ayoo_checkout_requests(order_id);
alter table public.ayoo_checkout_requests enable row level security;
revoke all on public.ayoo_checkout_requests from public, anon, authenticated;

-- 2) Add a key-bearing checkout signature.
-- Keep the legacy signature operational during the rollout; it forwards to the
-- hardened implementation with a fresh key so the already-live storefront does
-- not lose checkout while the new frontend is being deployed.

create or replace function public.ayoo_create_order(
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_shipping_country_code text,
  p_shipping_address jsonb,
  p_payment_method text,
  p_items jsonb,
  p_idempotency_key text,
  p_customer_note text default null,
  p_shipping_amount numeric default 0
)
returns table(order_id uuid, order_number text, total_amount numeric, currency text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order_id uuid;
  v_order_number text;
  v_country text := upper(trim(coalesce(p_shipping_country_code,'')));
  v_method text := lower(trim(coalesce(p_payment_method,'')));
  v_currency text;
  v_subtotal numeric(12,2) := 0;
  v_total numeric(12,2);
  v_item record;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_base numeric(12,2);
  v_unit numeric(12,2);
  v_line numeric(12,2);
  v_discount numeric(12,2);
  v_fingerprint text;
  v_existing public.ayoo_checkout_requests%rowtype;
begin
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 16
     or length(p_idempotency_key) > 128 then
    raise exception 'A valid checkout idempotency key is required.';
  end if;

  if v_country <> 'TR' or v_method <> 'cash_on_delivery' then
    raise exception 'AYOO currently accepts cash-on-delivery orders in Türkiye only.';
  end if;
  if coalesce(p_shipping_amount,0) <> 0 then
    raise exception 'Shipping cost is confirmed separately and must be zero at checkout.';
  end if;

  if length(trim(coalesce(p_customer_name,''))) < 2
     or length(trim(coalesce(p_customer_email,''))) < 5
     or position('@' in coalesce(p_customer_email,'')) < 2
     or length(trim(coalesce(p_customer_phone,''))) < 6 then
    raise exception 'Please provide valid customer name, email, and phone.';
  end if;
  if coalesce(jsonb_typeof(p_shipping_address),'') <> 'object'
     or length(trim(coalesce(p_shipping_address->>'address_line1',''))) < 4
     or length(trim(coalesce(p_shipping_address->>'city',''))) < 2
     or length(trim(coalesce(p_shipping_address->>'postal_code',''))) < 2 then
    raise exception 'A complete Turkish shipping address is required.';
  end if;
  if coalesce(jsonb_typeof(p_items),'') <> 'array' then
    raise exception 'Your bag must contain between 1 and 30 item lines.';
  end if;
  if jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 30 then
    raise exception 'Your bag must contain between 1 and 30 item lines.';
  end if;

  v_fingerprint := md5(jsonb_build_object(
    'name',trim(p_customer_name),'email',lower(trim(p_customer_email)),
    'phone',trim(p_customer_phone),'country',v_country,
    'address',p_shipping_address,'method',v_method,'items',p_items,
    'note',nullif(trim(coalesce(p_customer_note,'')),''),
    'shipping',0
  )::text);

  -- Serialize identical keys so concurrent retries cannot create two orders.
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));
  select * into v_existing from public.ayoo_checkout_requests
    where idempotency_key = p_idempotency_key;
  if found then
    if v_existing.request_fingerprint <> v_fingerprint then
      raise exception 'This checkout key was already used for different order details. Refresh checkout and try again.';
    end if;
    return query
      select o.id,o.order_number,o.total_amount,o.currency
      from public.orders o where o.id=v_existing.order_id;
    return;
  end if;

  v_order_id := gen_random_uuid();
  v_order_number := 'AY-' || to_char(now() at time zone 'UTC','YYMMDD') || '-' ||
    upper(substr(replace(v_order_id::text,'-',''),1,8));

  insert into public.orders(
    id,order_number,customer_name,customer_email,customer_phone,
    shipping_country_code,shipping_address,customer_note,currency,
    subtotal,shipping_amount,total_amount,payment_method
  ) values (
    v_order_id,v_order_number,trim(p_customer_name),lower(trim(p_customer_email)),
    trim(p_customer_phone),'TR',p_shipping_address,
    nullif(trim(coalesce(p_customer_note,'')),''),'USD',0,0,0,'cash_on_delivery'
  );

  for v_item in
    select x.variant_id::uuid as variant_id, sum(x.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as x(variant_id text, quantity integer)
    group by x.variant_id order by x.variant_id
  loop
    if v_item.variant_id is null or v_item.quantity < 1 or v_item.quantity > 20 then
      raise exception 'Each item quantity must be between 1 and 20.';
    end if;
    select * into v_variant from public.product_variants
      where id=v_item.variant_id and active=true for update;
    if not found then raise exception 'A selected size or colour is no longer available.'; end if;
    if coalesce(v_variant.stock_quantity,0)-coalesce(v_variant.reserved_quantity,0)<v_item.quantity then
      raise exception 'Insufficient stock for % / %.',v_variant.color_name,v_variant.size;
    end if;
    select * into v_product from public.products
      where id=v_variant.product_id and published=true;
    if not found then raise exception 'A product in your bag is no longer available.'; end if;

    v_base := coalesce(v_variant.price_override,v_product.price,0);
    if v_base < 0 then raise exception 'Invalid product price.'; end if;
    v_unit := v_base;
    select min(case
      when pr.discount_type='percent' then greatest(0,v_base*(1-pr.discount_value/100))
      when pr.discount_type='fixed'
        and coalesce(pr.currency,v_product.currency,'USD')=coalesce(v_product.currency,'USD')
        then greatest(0,v_base-pr.discount_value)
      else v_base end)
    into v_discount
    from public.promotions pr
    where pr.active=true and now() between pr.starts_at and pr.ends_at
      and (pr.scope='all'
        or (pr.scope='collection' and pr.collection_name=v_product.collection)
        or (pr.scope='products' and v_product.id=any(pr.product_ids)));
    if v_discount is not null then v_unit:=least(v_base,v_discount); end if;

    if v_currency is null then v_currency:=coalesce(v_product.currency,'USD');
    elsif v_currency<>coalesce(v_product.currency,'USD') then
      raise exception 'Please order items in one currency at a time.';
    end if;
    v_line:=round(v_unit*v_item.quantity,2);
    v_subtotal:=v_subtotal+v_line;
    insert into public.order_items(
      order_id,product_id,variant_id,product_name,color_name,size,
      quantity,unit_price,line_total,currency
    ) values (
      v_order_id,v_product.id,v_variant.id,v_product.name,v_variant.color_name,
      v_variant.size,v_item.quantity,round(v_unit,2),v_line,coalesce(v_product.currency,'USD')
    );
    update public.product_variants
      set reserved_quantity=coalesce(reserved_quantity,0)+v_item.quantity
      where id=v_variant.id;
  end loop;

  v_total:=round(v_subtotal,2);
  update public.orders set currency=coalesce(v_currency,'USD'),
    subtotal=round(v_subtotal,2),total_amount=v_total,updated_at=now()
    where id=v_order_id;
  insert into public.ayoo_checkout_requests(idempotency_key,request_fingerprint,order_id)
    values(p_idempotency_key,v_fingerprint,v_order_id);

  return query select v_order_id,v_order_number,v_total,coalesce(v_currency,'USD');
end;
$$;

revoke all on function public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,text,numeric)
  from public;
grant execute on function public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,text,numeric)
  to anon, authenticated;

-- Backward-compatible RPC for the currently deployed storefront.
create or replace function public.ayoo_create_order(
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_shipping_country_code text,
  p_shipping_address jsonb,
  p_payment_method text,
  p_items jsonb,
  p_customer_note text default null,
  p_shipping_amount numeric default 0
)
returns table(order_id uuid, order_number text, total_amount numeric, currency text)
language plpgsql
security definer
set search_path = public, pg_temp
as $wrapper$
begin
  return query
    select * from public.ayoo_create_order(
      p_customer_name,p_customer_email,p_customer_phone,p_shipping_country_code,
      p_shipping_address,p_payment_method,p_items,gen_random_uuid()::text,
      p_customer_note,p_shipping_amount
    );
end;
$wrapper$;
revoke all on function public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,numeric)
  from public;
grant execute on function public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,numeric)
  to anon, authenticated;

-- 3) Cancellation releases exactly the reserved quantity or aborts the whole transaction.
create or replace function public.ayoo_cancel_order(p_order_id uuid)
returns table(order_id uuid, order_number text, order_status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_item record;
  v_updated integer;
begin
  if auth.uid() is distinct from '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid then
    raise exception 'Not authorized to cancel AYOO orders.';
  end if;
  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.order_status='cancelled' then
    return query select v_order.id,v_order.order_number,v_order.order_status; return;
  end if;
  if v_order.order_status in ('shipped','delivered') then
    raise exception 'A shipped or delivered order cannot be cancelled here.';
  end if;

  for v_item in
    select oi.variant_id,oi.quantity from public.order_items oi
    where oi.order_id=v_order.id order by oi.variant_id
  loop
    update public.product_variants
      set reserved_quantity=reserved_quantity-v_item.quantity
      where id=v_item.variant_id
        and coalesce(reserved_quantity,0)>=v_item.quantity;
    get diagnostics v_updated = row_count;
    if v_updated <> 1 then
      raise exception 'Reserved stock mismatch for variant %. Cancellation was rolled back.',v_item.variant_id;
    end if;
  end loop;

  update public.orders set order_status='cancelled',updated_at=now() where id=v_order.id;
  return query select v_order.id,v_order.order_number,'cancelled'::text;
end;
$$;
revoke all on function public.ayoo_cancel_order(uuid) from public,anon;
grant execute on function public.ayoo_cancel_order(uuid) to authenticated;

-- 4) Guarded forward-only status transitions.
create or replace function public.ayoo_update_order_status(p_order_id uuid,p_new_status text)
returns table(order_id uuid,order_number text,order_status text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_next_status text;
  v_item record;
  v_updated integer;
begin
  if auth.uid() is distinct from '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid then
    raise exception 'Not authorized to update AYOO orders.';
  end if;
  if p_new_status is null or p_new_status not in ('confirmed','processing','shipped','delivered') then
    raise exception 'Unsupported order status transition.';
  end if;
  select * into v_order from public.orders where id=p_order_id for update;
  if not found then raise exception 'Order not found.'; end if;
  v_next_status:=case v_order.order_status
    when 'pending' then 'confirmed' when 'confirmed' then 'processing'
    when 'processing' then 'shipped' when 'shipped' then 'delivered' else null end;
  if v_next_status is null or p_new_status<>v_next_status then
    raise exception 'Invalid order status transition: % -> %.',v_order.order_status,p_new_status;
  end if;
  -- On dispatch, convert each reservation into a physical stock deduction exactly once.
  if v_order.order_status='processing' and p_new_status='shipped' then
    for v_item in
      select variant_id,quantity from public.order_items
      where order_id=v_order.id order by variant_id
    loop
      update public.product_variants
        set stock_quantity=stock_quantity-v_item.quantity,
            reserved_quantity=reserved_quantity-v_item.quantity
        where id=v_item.variant_id
          and coalesce(stock_quantity,0)>=v_item.quantity
          and coalesce(reserved_quantity,0)>=v_item.quantity;
      get diagnostics v_updated = row_count;
      if v_updated <> 1 then
        raise exception 'Stock or reservation mismatch for variant %. Dispatch was rolled back.',v_item.variant_id;
      end if;
    end loop;
  end if;

  update public.orders set order_status=p_new_status,updated_at=now() where id=v_order.id;
  return query select v_order.id,v_order.order_number,p_new_status;
end;
$$;
revoke all on function public.ayoo_update_order_status(uuid,text) from public,anon;
grant execute on function public.ayoo_update_order_status(uuid,text) to authenticated;

-- No direct browser writes to orders; writes go through the guarded RPCs.
revoke insert,update,delete on public.orders from anon,authenticated;
grant select on public.orders to authenticated;
drop policy if exists "AYOO owner updates orders" on public.orders;

-- 5) Public catalogue variant access: expose availability, never raw stock counts.
alter table public.product_variants
  add column if not exists in_stock boolean
  generated always as (coalesce(stock_quantity,0)>coalesce(reserved_quantity,0)) stored;
drop policy if exists "Public can view active published variants" on public.product_variants;
create policy "Public can view active published variants"
  on public.product_variants for select to anon,authenticated
  using (active=true and exists (
    select 1 from public.products p
    where p.id=product_variants.product_id and p.published=true
  ));
revoke all on public.product_variants from anon;
grant select (id,product_id,color_name,color_hex,size,image_url,active,in_stock)
  on public.product_variants to anon;

-- The invoker view now checks caller RLS and only needs the safe generated availability field.
create or replace view public.public_product_variants
with (security_invoker=true) as
select v.id,v.product_id,v.color_name,v.color_hex,v.size,v.image_url,v.active,v.in_stock
from public.product_variants v
join public.products p on p.id=v.product_id
where p.published=true and v.active=true;

-- 6) Event trigger remains callable by PostgreSQL event-trigger machinery only.
revoke all on function public.rls_auto_enable() from public,anon,authenticated;

-- 7) Avoid per-row auth.uid() re-evaluation in owner RLS policies.
alter policy "AYOO owner manages products" on public.products
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner manages collections" on public.collections
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner manages collection translations" on public.collection_translations
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner manages product_variants" on public.product_variants
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner manages product_images" on public.product_images
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner manages product_translations" on public.product_translations
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner manages inventory_movements" on public.inventory_movements
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner manages promotions" on public.promotions
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner reads orders" on public.orders
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
alter policy "AYOO owner reads order items" on public.order_items
  using (exists (select 1 from public.orders o
    where o.id=order_items.order_id
      and (select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid));
alter policy "AYOO owner reads inventory audit" on public.inventory_audit
  using ((select auth.uid())='03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);

-- 8) Missing FK indexes found by the advisor.
create index if not exists inventory_movements_created_by_idx
  on public.inventory_movements(created_by);
create index if not exists inventory_movements_variant_id_idx
  on public.inventory_movements(variant_id);
create index if not exists order_items_product_id_idx on public.order_items(product_id);
create index if not exists product_images_product_id_idx on public.product_images(product_id);
create index if not exists product_images_variant_id_idx on public.product_images(variant_id);

commit;
