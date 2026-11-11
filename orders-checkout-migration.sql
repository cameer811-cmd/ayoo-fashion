-- AYOO Phase 2: orders, checkout foundation, and atomic stock reservation
-- Run once in Supabase Dashboard > SQL Editor.
-- This migration creates pending orders only. It does not charge cards or create shipping labels.

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique,
  customer_name text not null,
  customer_email text not null,
  customer_phone text not null,
  shipping_country_code text not null,
  shipping_address jsonb not null,
  customer_note text,
  currency text not null check (currency in ('USD','TRY','EUR','GBP','SAR','AED')),
  subtotal numeric(12,2) not null check (subtotal >= 0),
  shipping_amount numeric(12,2) not null default 0 check (shipping_amount >= 0),
  total_amount numeric(12,2) not null check (total_amount >= 0),
  payment_method text not null check (payment_method in ('online','cash_on_delivery')),
  payment_status text not null default 'pending' check (payment_status in ('pending','paid','failed','refunded')),
  order_status text not null default 'pending' check (order_status in ('pending','confirmed','processing','shipped','delivered','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete restrict,
  variant_id uuid not null references public.product_variants(id) on delete restrict,
  product_name text not null,
  color_name text not null,
  size text not null,
  quantity integer not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(12,2) not null check (line_total >= 0),
  currency text not null check (currency in ('USD','TRY','EUR','GBP','SAR','AED')),
  created_at timestamptz not null default now()
);

create index if not exists orders_created_at_idx on public.orders(created_at desc);
create index if not exists orders_status_idx on public.orders(order_status, created_at desc);
create index if not exists order_items_order_id_idx on public.order_items(order_id);
create index if not exists order_items_variant_id_idx on public.order_items(variant_id);

alter table public.orders enable row level security;
alter table public.order_items enable row level security;

drop policy if exists "AYOO owner reads orders" on public.orders;
create policy "AYOO owner reads orders" on public.orders
  for select to authenticated
  using (auth.uid() = '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);

drop policy if exists "AYOO owner updates orders" on public.orders;
create policy "AYOO owner updates orders" on public.orders
  for update to authenticated
  using (auth.uid() = '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check (auth.uid() = '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);

drop policy if exists "AYOO owner reads order items" on public.order_items;
create policy "AYOO owner reads order items" on public.order_items
  for select to authenticated
  using (exists (
    select 1 from public.orders o
    where o.id = order_items.order_id
      and auth.uid() = '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid
  ));

revoke all on public.orders from anon, authenticated;
revoke all on public.order_items from anon, authenticated;
grant select, update on public.orders to authenticated;
grant select on public.order_items to authenticated;

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
as $$
declare
  v_order_id uuid := gen_random_uuid();
  v_order_number text;
  v_country text := upper(trim(coalesce(p_shipping_country_code,'')));
  v_method text := lower(trim(coalesce(p_payment_method,'')));
  v_currency text;
  v_subtotal numeric(12,2) := 0;
  v_total numeric(12,2);
  v_shipping numeric(12,2) := coalesce(p_shipping_amount,0);
  v_item record;
  v_product public.products%rowtype;
  v_variant public.product_variants%rowtype;
  v_base numeric(12,2);
  v_unit numeric(12,2);
  v_line numeric(12,2);
  v_discount numeric(12,2);
begin
  if length(trim(coalesce(p_customer_name,''))) < 2
     or length(trim(coalesce(p_customer_email,''))) < 5
     or position('@' in coalesce(p_customer_email,'')) < 2
     or length(trim(coalesce(p_customer_phone,''))) < 6 then
    raise exception 'Please provide valid customer name, email, and phone.';
  end if;

  if jsonb_typeof(p_shipping_address) <> 'object'
     or length(trim(coalesce(p_shipping_address->>'address_line1',''))) < 4
     or length(trim(coalesce(p_shipping_address->>'city',''))) < 2
     or length(trim(coalesce(p_shipping_address->>'postal_code',''))) < 2 then
    raise exception 'A complete shipping address is required.';
  end if;

  if v_country not in (
    'TR','SA','AE','KW','QA','BH','OM',
    'AT','BE','BG','HR','CY','CZ','DK','EE','FI','FR','DE','GR','HU','IS','IE','IT','LV','LI','LT','LU','MT','MC','NL','NO','PL','PT','RO','SM','SK','SI','ES','SE','CH','GB','AD'
  ) then
    raise exception 'Shipping to this country is not enabled yet.';
  end if;

  if v_method not in ('online','cash_on_delivery') then
    raise exception 'Unsupported payment method.';
  end if;
  if v_method = 'cash_on_delivery' and v_country <> 'TR' then
    raise exception 'Cash on delivery is currently available only in Türkiye.';
  end if;
  if v_method = 'online' and v_country <> 'TR' and v_country not in (
    'SA','AE','KW','QA','BH','OM',
    'AT','BE','BG','HR','CY','CZ','DK','EE','FI','FR','DE','GR','HU','IS','IE','IT','LV','LI','LT','LU','MT','MC','NL','NO','PL','PT','RO','SM','SK','SI','ES','SE','CH','GB','AD'
  ) then
    raise exception 'Online payment destination is not enabled.';
  end if;

  if v_shipping < 0 or v_shipping > 100000 then
    raise exception 'Invalid shipping amount.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your shopping bag is empty.';
  end if;
  if jsonb_array_length(p_items) > 30 then
    raise exception 'A maximum of 30 different items can be ordered at once.';
  end if;

  -- Aggregate duplicate variant IDs so stock cannot be reserved twice through duplicate lines.
  for v_item in
    select x.variant_id::uuid as variant_id, sum(x.quantity)::integer as quantity
    from jsonb_to_recordset(p_items) as x(variant_id text, quantity integer)
    group by x.variant_id
    order by x.variant_id
  loop
    if v_item.quantity < 1 or v_item.quantity > 20 then
      raise exception 'Each item quantity must be between 1 and 20.';
    end if;

    select * into v_variant
    from public.product_variants
    where id = v_item.variant_id and active = true
    for update;

    if not found then
      raise exception 'A selected size or colour is no longer available.';
    end if;

    if coalesce(v_variant.stock_quantity,0) - coalesce(v_variant.reserved_quantity,0) < v_item.quantity then
      raise exception 'Insufficient stock for % / %.', v_variant.color_name, v_variant.size;
    end if;

    select * into v_product
    from public.products
    where id = v_variant.product_id and published = true;

    if not found then
      raise exception 'A product in your bag is no longer available.';
    end if;

    v_base := coalesce(v_variant.price_override, v_product.price, 0);
    if v_base < 0 then
      raise exception 'Invalid product price.';
    end if;

    v_unit := v_base;
    select min(
      case
        when pr.discount_type = 'percent' then greatest(0, v_base * (1 - pr.discount_value / 100))
        when pr.discount_type = 'fixed' and coalesce(pr.currency, v_product.currency, 'USD') = coalesce(v_product.currency, 'USD')
          then greatest(0, v_base - pr.discount_value)
        else v_base
      end
    ) into v_discount
    from public.promotions pr
    where pr.active = true
      and now() between pr.starts_at and pr.ends_at
      and (
        pr.scope = 'all'
        or (pr.scope = 'collection' and pr.collection_name = v_product.collection)
        or (pr.scope = 'products' and v_product.id = any(pr.product_ids))
      );

    if v_discount is not null then
      v_unit := least(v_base, v_discount);
    end if;

    if v_currency is null then
      v_currency := coalesce(v_product.currency,'USD');
    elsif v_currency <> coalesce(v_product.currency,'USD') then
      raise exception 'Please order items in one currency at a time.';
    end if;

    v_line := round(v_unit * v_item.quantity, 2);
    v_subtotal := v_subtotal + v_line;

    insert into public.order_items(
      order_id, product_id, variant_id, product_name, color_name, size,
      quantity, unit_price, line_total, currency
    ) values (
      v_order_id, v_product.id, v_variant.id, v_product.name,
      v_variant.color_name, v_variant.size, v_item.quantity,
      round(v_unit,2), v_line, coalesce(v_product.currency,'USD')
    );

    update public.product_variants
    set reserved_quantity = coalesce(reserved_quantity,0) + v_item.quantity
    where id = v_variant.id;
  end loop;

  v_total := round(v_subtotal + v_shipping, 2);
  v_order_number := 'AY-' || to_char(now() at time zone 'UTC','YYMMDD') || '-' || upper(substr(replace(v_order_id::text,'-',''),1,8));

  insert into public.orders(
    id, order_number, customer_name, customer_email, customer_phone,
    shipping_country_code, shipping_address, customer_note, currency,
    subtotal, shipping_amount, total_amount, payment_method
  ) values (
    v_order_id, v_order_number, trim(p_customer_name), lower(trim(p_customer_email)),
    trim(p_customer_phone), v_country, p_shipping_address, nullif(trim(coalesce(p_customer_note,'')),''),
    coalesce(v_currency,'USD'), round(v_subtotal,2), round(v_shipping,2), v_total, v_method
  );

  return query select v_order_id, v_order_number, v_total, coalesce(v_currency,'USD');
end;
$$;

revoke all on function public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,numeric) from public;
grant execute on function public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,numeric) to anon, authenticated;

comment on table public.orders is 'AYOO customer orders. Card payments are not captured by this table.';
comment on table public.order_items is 'Immutable product and price snapshots for each AYOO order.';
comment on function public.ayoo_create_order(text,text,text,text,jsonb,text,jsonb,text,numeric) is 'Creates a pending AYOO order and reserves stock atomically. Does not process payment.';
