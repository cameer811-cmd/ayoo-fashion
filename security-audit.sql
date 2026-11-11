-- AYOO Phase 1: READ-ONLY security audit
-- Run in Supabase Dashboard > SQL Editor.
-- This script only inspects configuration. It does not change tables, policies, data, or storage.

-- 1) Public tables and whether Row Level Security is enabled/forced.
select
  n.nspname as schema_name,
  c.relname as table_name,
  c.relrowsecurity as rls_enabled,
  c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('r', 'p')
order by c.relname;

-- 2) Existing policies: who can read/write and under what conditions.
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd,
  qual as using_expression,
  with_check
from pg_policies
where schemaname in ('public', 'storage')
order by schemaname, tablename, policyname;

-- 3) Table-level grants for browser-facing roles.
select
  table_schema,
  table_name,
  grantee,
  privilege_type
from information_schema.role_table_grants
where table_schema = 'public'
  and grantee in ('anon', 'authenticated')
order by table_name, grantee, privilege_type;

-- 4) Storage bucket configuration. Public read access may be intentional for product images;
-- uploads, updates, and deletes should still be owner-restricted.
select
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
from storage.buckets
where id = 'ayoo-media';

-- 5) Storage object policies are included in section 2 above.
-- 6) Security-definer functions in public/storage deserve manual review.
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as arguments,
  p.prosecdef as security_definer,
  p.proconfig as function_settings
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'storage')
  and p.prosecdef = true
order by n.nspname, p.proname;
