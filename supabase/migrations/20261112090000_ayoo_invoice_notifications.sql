-- AYOO invoice PDF + email/WhatsApp notification outbox.
-- Apply only after the Edge Function is deployed and its secrets are configured.
-- This migration is intentionally staged in a PR; it has not been applied to production.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
grant usage on schema private to service_role;

alter table public.orders
  add column if not exists whatsapp_opt_in boolean not null default false,
  add column if not exists whatsapp_opt_in_at timestamptz;

create table if not exists private.ayoo_invoice_records (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique references public.orders(id) on delete restrict,
  invoice_number text not null unique,
  storage_path text,
  sha256 text,
  status text not null default 'pending'
    check (status in ('pending','generating','ready','failed')),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists private.ayoo_notification_jobs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  event_key text not null unique,
  event_type text not null check (event_type in ('order_created','order_status')),
  status_value text,
  status text not null default 'pending'
    check (status in ('pending','processing','retry','completed','dead','unknown')),
  attempt_count integer not null default 0,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  completed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);

create index if not exists ayoo_notification_jobs_ready_idx
  on private.ayoo_notification_jobs(status, available_at, created_at);

create table if not exists private.ayoo_notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references private.ayoo_notification_jobs(id) on delete cascade,
  channel text not null check (channel in ('email','whatsapp')),
  provider text not null check (provider in ('resend','whatsapp')),
  idempotency_key text not null unique,
  status text not null default 'pending'
    check (status in ('pending','processing','retry','accepted','delivered','failed','skipped','unknown')),
  attempt_count integer not null default 0,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  provider_message_id text,
  last_error text,
  sent_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (job_id, channel)
);

create index if not exists ayoo_notification_deliveries_ready_idx
  on private.ayoo_notification_deliveries(status, available_at);

create table if not exists private.ayoo_provider_webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('resend','whatsapp')),
  provider_message_id text not null,
  provider_status text not null check (provider_status in ('accepted','delivered','failed')),
  error_text text,
  received_at timestamptz not null default now(),
  unique (provider, provider_message_id, provider_status)
);
alter table private.ayoo_provider_webhook_events enable row level security;
revoke all on private.ayoo_provider_webhook_events from public, anon, authenticated;
grant all on private.ayoo_provider_webhook_events to service_role;

create unique index if not exists ayoo_notification_provider_message_uidx
  on private.ayoo_notification_deliveries(provider, provider_message_id)
  where provider_message_id is not null;

alter table private.ayoo_invoice_records enable row level security;
alter table private.ayoo_notification_jobs enable row level security;
alter table private.ayoo_notification_deliveries enable row level security;

revoke all on all tables in schema private from public, anon, authenticated;
grant all on all tables in schema private to service_role;

create table if not exists private.ayoo_worker_config (
  id smallint primary key check (id = 1),
  worker_secret text not null,
  created_at timestamptz not null default now()
);

insert into private.ayoo_worker_config(id, worker_secret)
values (1, encode(gen_random_bytes(32), 'hex'))
on conflict (id) do nothing;

-- Private storage: service_role only. No public invoice URLs are created.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('ayoo-invoices', 'ayoo-invoices', false, 10485760, array['application/pdf'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.enqueue_ayoo_order_created()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_job_id uuid;
begin
  insert into private.ayoo_invoice_records(order_id, invoice_number, status)
  values (new.id, 'AYOO-' || new.order_number, 'pending')
  on conflict (order_id) do nothing;

  insert into private.ayoo_notification_jobs(order_id, event_key, event_type)
  values (new.id, 'order_created:' || new.id::text, 'order_created')
  on conflict (event_key) do nothing
  returning id into v_job_id;

  if v_job_id is not null then
    insert into private.ayoo_notification_deliveries(
      job_id, channel, provider, idempotency_key
    ) values
      (v_job_id, 'email', 'resend', 'order_created:' || new.id::text || ':email'),
      (v_job_id, 'whatsapp', 'whatsapp', 'order_created:' || new.id::text || ':whatsapp');
  end if;
  return new;
end;
$$;

create or replace function private.enqueue_ayoo_order_status()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_job_id uuid;
  v_event_key text;
begin
  if new.order_status is not distinct from old.order_status then
    return new;
  end if;

  v_event_key := 'order_status:' || new.id::text || ':' || new.order_status;
  insert into private.ayoo_notification_jobs(
    order_id, event_key, event_type, status_value
  ) values (
    new.id, v_event_key, 'order_status', new.order_status
  )
  on conflict (event_key) do nothing
  returning id into v_job_id;

  if v_job_id is not null then
    insert into private.ayoo_notification_deliveries(
      job_id, channel, provider, idempotency_key
    ) values
      (v_job_id, 'email', 'resend', v_event_key || ':email'),
      (v_job_id, 'whatsapp', 'whatsapp', v_event_key || ':whatsapp');
  end if;
  return new;
end;
$$;

drop trigger if exists ayoo_enqueue_order_created on public.orders;
create trigger ayoo_enqueue_order_created
after insert on public.orders
for each row execute function private.enqueue_ayoo_order_created();

drop trigger if exists ayoo_enqueue_order_status on public.orders;
create trigger ayoo_enqueue_order_status
after update of order_status on public.orders
for each row
when (old.order_status is distinct from new.order_status)
execute function private.enqueue_ayoo_order_status();

-- A wrapper adds explicit WhatsApp consent without exposing direct table writes.
-- The existing idempotent checkout RPC remains the single source of order pricing/stock logic.
create or replace function public.ayoo_create_order_with_consent(
  p_customer_name text,
  p_customer_email text,
  p_customer_phone text,
  p_shipping_country_code text,
  p_shipping_address jsonb,
  p_payment_method text,
  p_items jsonb,
  p_idempotency_key text,
  p_customer_note text default null,
  p_shipping_amount numeric default 0,
  p_whatsapp_opt_in boolean default false
)
returns table(order_id uuid, order_number text, total_amount numeric, currency text)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order record;
begin
  select * into v_order
  from public.ayoo_create_order(
    p_customer_name,
    p_customer_email,
    p_customer_phone,
    p_shipping_country_code,
    p_shipping_address,
    p_payment_method,
    p_items,
    p_idempotency_key,
    p_customer_note,
    p_shipping_amount
  );

  if v_order.order_id is null then
    raise exception 'The order could not be created.';
  end if;

  update public.orders
  set whatsapp_opt_in = coalesce(p_whatsapp_opt_in, false),
      whatsapp_opt_in_at = case
        when coalesce(p_whatsapp_opt_in, false) then coalesce(whatsapp_opt_in_at, now())
        else null
      end
  where id = v_order.order_id
    and created_at = transaction_timestamp();

  return query
  select v_order.order_id, v_order.order_number, v_order.total_amount, v_order.currency;
end;
$$;

revoke all on function public.ayoo_create_order_with_consent(
  text,text,text,text,jsonb,text,jsonb,text,text,numeric,boolean
) from public;
grant execute on function public.ayoo_create_order_with_consent(
  text,text,text,text,jsonb,text,jsonb,text,text,numeric,boolean
) to anon, authenticated;

create or replace function public.ayoo_validate_worker_secret(p_secret text)
returns boolean
language sql
security definer
set search_path = private, pg_temp
as $$
  select p_secret is not null
     and length(p_secret) >= 32
     and p_secret = (select worker_secret from private.ayoo_worker_config where id = 1);
$$;

create or replace function public.ayoo_claim_notification_jobs(p_limit integer default 10)
returns table(job_id uuid, order_id uuid, event_type text, status_value text, attempt_count integer)
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  update private.ayoo_notification_jobs j
  set status = 'dead',
      last_error = coalesce(j.last_error, 'Maximum job attempts reached'),
      locked_at = null
  where j.status in ('pending','retry','processing')
    and j.attempt_count >= 12
    and (j.available_at <= now() or j.status = 'processing');

  return query
  with picked as (
    select j.id
    from private.ayoo_notification_jobs j
    where (
      (j.status in ('pending','retry') and j.available_at <= now())
      or (j.status = 'processing' and j.locked_at < now() - interval '5 minutes')
    )
    and j.attempt_count < 12
    order by j.created_at
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 10), 20))
  )
  update private.ayoo_notification_jobs j
  set status = 'processing',
      locked_at = now(),
      attempt_count = j.attempt_count + 1
  from picked
  where j.id = picked.id
  returning j.id, j.order_id, j.event_type, j.status_value, j.attempt_count;
end;
$$;

create or replace function public.ayoo_get_notification_deliveries(p_job_id uuid)
returns table(
  delivery_id uuid,
  channel text,
  provider text,
  status text,
  attempt_count integer,
  idempotency_key text,
  provider_message_id text
)
language sql
security definer
set search_path = private, pg_temp
as $$
  select d.id, d.channel, d.provider, d.status, d.attempt_count,
         d.idempotency_key, d.provider_message_id
  from private.ayoo_notification_deliveries d
  where d.job_id = p_job_id
  order by d.channel;
$$;

create or replace function public.ayoo_claim_notification_delivery(p_delivery_id uuid)
returns boolean
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare
  v_count integer;
begin
  update private.ayoo_notification_deliveries d
  set status = 'failed',
      last_error = coalesce(d.last_error, 'Maximum delivery attempts reached'),
      locked_at = null,
      updated_at = now()
  where d.id = p_delivery_id
    and d.attempt_count >= 8
    and (
      (d.status in ('pending','retry') and d.available_at <= now())
      or (d.status = 'processing' and d.locked_at < now() - interval '5 minutes')
    );

  update private.ayoo_notification_deliveries d
  set status = 'processing',
      locked_at = now(),
      attempt_count = d.attempt_count + 1,
      updated_at = now()
  where d.id = p_delivery_id
    and d.attempt_count < 8
    and (
      (d.status in ('pending','retry') and d.available_at <= now())
      or (d.status = 'processing' and d.locked_at < now() - interval '5 minutes')
    );
  get diagnostics v_count = row_count;
  return v_count = 1;
end;
$$;

create or replace function public.ayoo_get_invoice_record(p_order_id uuid)
returns table(invoice_number text, storage_path text, status text, sha256 text)
language sql
security definer
set search_path = private, pg_temp
as $$
  select i.invoice_number, i.storage_path, i.status, i.sha256
  from private.ayoo_invoice_records i
  where i.order_id = p_order_id;
$$;

create or replace function public.ayoo_set_invoice_record(
  p_order_id uuid,
  p_status text,
  p_storage_path text default null,
  p_sha256 text default null,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = private, pg_temp
as $$
begin
  if p_status not in ('pending','generating','ready','failed') then
    raise exception 'Invalid invoice status.';
  end if;
  update private.ayoo_invoice_records
  set status = p_status,
      storage_path = coalesce(p_storage_path, storage_path),
      sha256 = coalesce(p_sha256, sha256),
      last_error = p_error,
      updated_at = now()
  where order_id = p_order_id;
end;
$$;

create or replace function public.ayoo_finish_notification_delivery(
  p_delivery_id uuid,
  p_status text,
  p_provider_message_id text default null,
  p_error text default null,
  p_retry_seconds integer default 0
)
returns void
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare
  v_provider text;
  v_message_id text;
  v_event record;
begin
  if p_status not in ('accepted','delivered','failed','skipped','retry','unknown') then
    raise exception 'Invalid notification delivery status.';
  end if;
  update private.ayoo_notification_deliveries
  set status = p_status,
      provider_message_id = coalesce(p_provider_message_id, provider_message_id),
      last_error = p_error,
      available_at = case when p_status = 'retry'
        then now() + make_interval(secs => greatest(30, least(coalesce(p_retry_seconds, 60), 86400)))
        else available_at end,
      sent_at = case when p_status in ('accepted','delivered') then coalesce(sent_at, now()) else sent_at end,
      locked_at = null,
      updated_at = now()
  where id = p_delivery_id
  returning provider, provider_message_id into v_provider, v_message_id;

  -- A provider webhook can arrive before the worker saves the provider message ID.
  if v_provider is not null and v_message_id is not null then
    select * into v_event
    from private.ayoo_provider_webhook_events
    where provider = v_provider and provider_message_id = v_message_id
    order by case provider_status when 'delivered' then 3 when 'failed' then 2 else 1 end desc, received_at desc
    limit 1;
    if found then
      update private.ayoo_notification_deliveries
      set status = v_event.provider_status, last_error = v_event.error_text, updated_at = now()
      where id = p_delivery_id;
      delete from private.ayoo_provider_webhook_events
      where provider = v_provider and provider_message_id = v_message_id;
    end if;
  end if;
end;
$$;

create or replace function public.ayoo_finish_notification_job(p_job_id uuid, p_error text default null)
returns void
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare
  v_retry boolean;
  v_processing boolean;
  v_unknown boolean;
begin
  select
    coalesce(bool_or(status in ('pending','retry')), false),
    coalesce(bool_or(status = 'processing'), false),
    coalesce(bool_or(status = 'unknown'), false)
  into v_retry, v_processing, v_unknown
  from private.ayoo_notification_deliveries
  where job_id = p_job_id;

  update private.ayoo_notification_jobs j
  set status = case
        when v_retry then 'retry'
        when v_processing then 'processing'
        when v_unknown then 'unknown'
        else 'completed'
      end,
      available_at = case when v_retry then
        coalesce(
          (select min(available_at) from private.ayoo_notification_deliveries
           where job_id = p_job_id and status in ('pending','retry')),
          j.available_at
        )
        else j.available_at end,
      locked_at = case when v_processing then j.locked_at else null end,
      completed_at = case when v_retry or v_processing then null else coalesce(j.completed_at, now()) end,
      last_error = p_error
  where j.id = p_job_id;
end;
$$;

create or replace function public.ayoo_record_delivery_webhook(
  p_provider text,
  p_provider_message_id text,
  p_status text,
  p_error text default null
)
returns integer
language plpgsql
security definer
set search_path = private, pg_temp
as $$
declare
  v_count integer;
  v_job_id uuid;
  v_retry boolean;
  v_processing boolean;
  v_unknown boolean;
begin
  if p_provider not in ('resend','whatsapp') then
    raise exception 'Unsupported delivery provider.';
  end if;
  if p_status not in ('accepted','delivered','failed') then
    raise exception 'Unsupported provider status.';
  end if;

  update private.ayoo_notification_deliveries
  set status = case
        when status = 'delivered' then 'delivered'
        when p_status = 'delivered' then 'delivered'
        when status = 'failed' then 'failed'
        when p_status = 'failed' then 'failed'
        else 'accepted'
      end,
      last_error = case when p_status = 'failed' then p_error else last_error end,
      updated_at = now()
  where provider = p_provider
    and provider_message_id = p_provider_message_id;
  get diagnostics v_count = row_count;

  if v_count = 0 then
    insert into private.ayoo_provider_webhook_events(provider, provider_message_id, provider_status, error_text)
    values (p_provider, p_provider_message_id, p_status, p_error)
    on conflict (provider, provider_message_id, provider_status) do nothing;
  else
    select d.job_id into v_job_id
    from private.ayoo_notification_deliveries d
    where d.provider = p_provider
      and d.provider_message_id = p_provider_message_id
    limit 1;

    select
      coalesce(bool_or(status in ('pending','retry')), false),
      coalesce(bool_or(status = 'processing'), false),
      coalesce(bool_or(status = 'unknown'), false)
    into v_retry, v_processing, v_unknown
    from private.ayoo_notification_deliveries
    where job_id = v_job_id;

    update private.ayoo_notification_jobs j
    set status = case
          when v_retry then 'retry'
          when v_processing then 'processing'
          when v_unknown then 'unknown'
          else 'completed'
        end,
        available_at = case when v_retry then
          coalesce(
            (select min(available_at) from private.ayoo_notification_deliveries
             where job_id = v_job_id and status in ('pending','retry')),
            j.available_at
          )
          else j.available_at end,
        locked_at = case when v_processing then j.locked_at else null end,
        completed_at = case when v_retry or v_processing then null else coalesce(j.completed_at, now()) end,
        last_error = case when v_retry or v_processing or v_unknown then j.last_error else null end
    where j.id = v_job_id;
  end if;

  return v_count;
end;
$$;

revoke all on function public.ayoo_validate_worker_secret(text) from public, anon, authenticated;
revoke all on function public.ayoo_claim_notification_jobs(integer) from public, anon, authenticated;
revoke all on function public.ayoo_get_notification_deliveries(uuid) from public, anon, authenticated;
revoke all on function public.ayoo_claim_notification_delivery(uuid) from public, anon, authenticated;
revoke all on function public.ayoo_get_invoice_record(uuid) from public, anon, authenticated;
revoke all on function public.ayoo_set_invoice_record(uuid,text,text,text,text) from public, anon, authenticated;
revoke all on function public.ayoo_finish_notification_delivery(uuid,text,text,text,integer) from public, anon, authenticated;
revoke all on function public.ayoo_finish_notification_job(uuid,text) from public, anon, authenticated;
revoke all on function public.ayoo_record_delivery_webhook(text,text,text,text) from public, anon, authenticated;

grant execute on function public.ayoo_validate_worker_secret(text) to service_role;
grant execute on function public.ayoo_claim_notification_jobs(integer) to service_role;
grant execute on function public.ayoo_get_notification_deliveries(uuid) to service_role;
grant execute on function public.ayoo_claim_notification_delivery(uuid) to service_role;
grant execute on function public.ayoo_get_invoice_record(uuid) to service_role;
grant execute on function public.ayoo_set_invoice_record(uuid,text,text,text,text) to service_role;
grant execute on function public.ayoo_finish_notification_delivery(uuid,text,text,text,integer) to service_role;
grant execute on function public.ayoo_finish_notification_job(uuid,text) to service_role;
grant execute on function public.ayoo_record_delivery_webhook(text,text,text,text) to service_role;

-- pg_cron + pg_net poll the outbox. Deploy the worker function before applying this migration.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

do $$
declare
  v_job record;
begin
  for v_job in select jobid from cron.job where jobname = 'ayoo-notification-worker'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;

  perform cron.schedule(
    'ayoo-notification-worker',
    '* * * * *',
    $job$
      select net.http_post(
        url := 'https://jfmhbmcrcbatoregunmk.supabase.co/functions/v1/ayoo-notification-worker',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-ayoo-worker-secret',
          (select worker_secret from private.ayoo_worker_config where id = 1)
        ),
        body := jsonb_build_object('source','pg_cron')
      );
    $job$
  );
end;
$$;
