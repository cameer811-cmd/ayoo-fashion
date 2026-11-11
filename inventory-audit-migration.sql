-- AYOO inventory audit trail
-- Run once in Supabase SQL Editor after the existing product/variant schema migrations.
-- Logs stock, reservations and variant activation changes. No customer data is stored.

create table if not exists public.inventory_audit (
  id bigint generated always as identity primary key,
  variant_id uuid not null,
  product_id uuid not null,
  product_name text not null,
  color_name text not null,
  size text not null,
  event_type text not null check (event_type in (
    'variant_created','stock_adjusted','reservation_changed',
    'stock_and_reservation_changed','variant_activated','variant_deactivated'
  )),
  old_stock integer not null default 0,
  new_stock integer not null default 0,
  old_reserved integer not null default 0,
  new_reserved integer not null default 0,
  available_before integer not null default 0,
  available_after integer not null default 0,
  actor_id uuid,
  occurred_at timestamptz not null default now()
);

create index if not exists inventory_audit_occurred_at_idx
  on public.inventory_audit(occurred_at desc);
create index if not exists inventory_audit_product_idx
  on public.inventory_audit(product_id, occurred_at desc);

alter table public.inventory_audit enable row level security;
drop policy if exists "AYOO owner reads inventory audit" on public.inventory_audit;
create policy "AYOO owner reads inventory audit"
  on public.inventory_audit for select to authenticated
  using (auth.uid() = '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);

revoke all on public.inventory_audit from anon, authenticated;
grant select on public.inventory_audit to authenticated;

create or replace function public.ayoo_log_inventory_change()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_old_stock integer := 0;
  v_new_stock integer := 0;
  v_old_reserved integer := 0;
  v_new_reserved integer := 0;
  v_event text;
begin
  if tg_op = 'INSERT' then
    v_new_stock := coalesce(new.stock_quantity,0);
    v_new_reserved := coalesce(new.reserved_quantity,0);
    v_event := 'variant_created';
    insert into public.inventory_audit(
      variant_id, product_id, product_name, color_name, size, event_type,
      old_stock, new_stock, old_reserved, new_reserved,
      available_before, available_after, actor_id
    )
    select new.id, new.product_id, coalesce(p.name,'(deleted product)'),
      new.color_name, new.size, v_event, 0, v_new_stock, 0, v_new_reserved,
      0, greatest(0,v_new_stock-v_new_reserved), auth.uid()
    from (select 1) seed
    left join public.products p on p.id = new.product_id;
    return new;
  end if;

  v_old_stock := coalesce(old.stock_quantity,0);
  v_new_stock := coalesce(new.stock_quantity,0);
  v_old_reserved := coalesce(old.reserved_quantity,0);
  v_new_reserved := coalesce(new.reserved_quantity,0);

  if v_old_stock = v_new_stock
     and v_old_reserved = v_new_reserved
     and old.active is not distinct from new.active then
    return new;
  end if;

  if old.active is distinct from new.active then
    v_event := case when new.active then 'variant_activated' else 'variant_deactivated' end;
  elsif v_old_stock <> v_new_stock and v_old_reserved <> v_new_reserved then
    v_event := 'stock_and_reservation_changed';
  elsif v_old_stock <> v_new_stock then
    v_event := 'stock_adjusted';
  else
    v_event := 'reservation_changed';
  end if;

  insert into public.inventory_audit(
    variant_id, product_id, product_name, color_name, size, event_type,
    old_stock, new_stock, old_reserved, new_reserved,
    available_before, available_after, actor_id
  )
  select new.id, new.product_id, coalesce(p.name,'(deleted product)'),
    new.color_name, new.size, v_event,
    v_old_stock, v_new_stock, v_old_reserved, v_new_reserved,
    greatest(0,v_old_stock-v_old_reserved),
    greatest(0,v_new_stock-v_new_reserved), auth.uid()
  from (select 1) seed
  left join public.products p on p.id = new.product_id;

  return new;
end;
$$;

revoke all on function public.ayoo_log_inventory_change() from public, anon, authenticated;

drop trigger if exists ayoo_inventory_audit_trigger on public.product_variants;
create trigger ayoo_inventory_audit_trigger
after insert or update of stock_quantity, reserved_quantity, active
on public.product_variants
for each row execute function public.ayoo_log_inventory_change();

comment on table public.inventory_audit is
  'Owner-readable audit history for AYOO variant stock, reservations and activation changes.';
