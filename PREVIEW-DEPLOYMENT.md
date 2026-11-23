# AYOO private staging deployment

This branch is for a **private preview**, not public launch.

## Cloudflare Pages setup
1. Connect GitHub repository `cameer811-cmd/ayoo-fashion` to Cloudflare Pages.
2. Choose branch `preview/staging` for staging deployment, framework preset `None`, build command blank, output directory `/` (repository root).
3. **Before sharing or using the deployment**, configure Cloudflare Zero Trust Access to protect the preview hostname with an email allowlist (one-time PIN or identity provider). Cover the entire hostname, including `/admin.html` and `/policies.html`. Do not treat `robots.txt`, `X-Robots-Tag`, or client-side password prompts as access control.
4. Test unauthenticated access in a private window: it must be denied before the site is served. Test authorized access, assets, product listing, translations, and admin login.
5. Keep real orders disabled during testing; use an isolated staging Supabase project or a carefully controlled test plan before testing checkout. The current config points to production Ayoo-catalog and the current published products are demos.
6. Confirm Cloudflare Access coverage of any default `*.pages.dev` host and custom preview host. If a host cannot be protected, disable it.

## Release blockers
- Replace five published demo products with real catalog content before public launch.
- Verify all security advisor findings, especially privileged order RPC functions, and enable leaked-password protection.
- Test order creation, idempotency, cancellation, shipping transition, stock reservation and role permissions safely.
- Finalize shipping, legal policies, checkout currencies and customer support contact.

Do not publish this branch as a publicly accessible production store.
