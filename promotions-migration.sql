-- AYOO timed promotions migration
-- Run once in Supabase Dashboard > SQL Editor.
create table if not exists public.promotions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  discount_type text not null check (discount_type in ('percent','fixed')),
  discount_value numeric(12,2) not null check (discount_value > 0),
  currency text null check (currency is null or currency in ('USD','TRY','EUR','GBP','SAR','AED')),
  scope text not null default 'all' check (scope in ('all','collection','products')),
  collection_name text null,
  product_ids uuid[] not null default '{}',
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint promotions_valid_period check (ends_at > starts_at),
  constraint promotions_scope_fields check (
    (scope = 'all' and collection_name is null and cardinality(product_ids) = 0) or
    (scope = 'collection' and collection_name is not null and cardinality(product_ids) = 0) or
    (scope = 'products' and cardinality(product_ids) > 0 and collection_name is null)
  )
);
alter table public.promotions enable row level security;
drop policy if exists "Public can read active promotions" on public.promotions;
create policy "Public can read active promotions" on public.promotions
  for select to anon, authenticated using (active = true);
drop policy if exists "AYOO owner manages promotions" on public.promotions;
create policy "AYOO owner manages promotions" on public.promotions
  for all to authenticated
  using (auth.uid() = '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid)
  with check (auth.uid() = '03b2c71f-23d6-4968-8b4b-ca9d1681f91c'::uuid);
grant select on public.promotions to anon, authenticated;
grant insert, update, delete on public.promotions to authenticated;
create index if not exists promotions_active_period_idx on public.promotions(active, starts_at, ends_at);
