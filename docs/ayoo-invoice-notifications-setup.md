# AYOO invoice PDF and notification setup

Status: implementation staged in `feature/ayoo-invoice-notifications`. Nothing in this change has been applied to the live Supabase project, no Edge Function has been deployed, and no customer message has been sent.

## What this adds

The PDF is an order invoice/receipt for customer communication. It is **not** a Turkish e-Fatura/e-Arşiv fiscal invoice or a substitute for a registered invoicing provider/accountant review. Confirm AYOO's legal invoicing requirements before using it as a statutory tax document. The first renderer supports up to 30 order-item lines per PDF; larger orders are stopped safely rather than silently truncated.


- A private `ayoo-invoices` Storage bucket. Invoice PDFs are private and are never published as public URLs.
- One invoice record per order, with a stable invoice number and SHA-256 checksum.
- An idempotent notification outbox. New orders enqueue email and WhatsApp deliveries; order-status changes enqueue status notifications.
- A worker Edge Function that creates a real bilingual PDF, attaches it to Resend email, uploads it to Meta's WhatsApp media endpoint, and sends the approved WhatsApp document template.
- Retry/backoff for explicit temporary failures, and an `unknown` state for network timeouts where blindly retrying could send a duplicate.
- Resend and Meta delivery webhooks with signature verification. Early webhooks are buffered until the worker has stored the provider message ID.
- A one-minute Supabase Cron poller using a random worker secret kept in the private database schema.
- An optional WhatsApp consent checkbox at checkout. WhatsApp is skipped unless the customer explicitly opts in.

## Required Supabase Function secrets

Set these under **Supabase Dashboard → Edge Functions → Secrets** before applying the migration:

| Secret | Purpose |
| --- | --- |
| `RESEND_API_KEY` | Resend API key |
| `RESEND_FROM_EMAIL` | Verified sender, e.g. `AYOO <orders@your-verified-domain>` |
| `RESEND_WEBHOOK_SECRET` | Signing secret returned when creating the Resend webhook |
| `META_WHATSAPP_ACCESS_TOKEN` | Long-lived System User access token with WhatsApp permissions |
| `META_WHATSAPP_PHONE_NUMBER_ID` | ID of the sending business/test phone number |
| `META_GRAPH_API_VERSION` | Graph API version shown by Meta for the app, e.g. `vXX.X` |
| `META_APP_SECRET` | Meta app secret used to verify webhook signatures |
| `META_WEBHOOK_VERIFY_TOKEN` | Random string you choose for Meta webhook verification |
| `AYOO_WHATSAPP_INVOICE_TEMPLATE` | Approved invoice template name |
| `AYOO_WHATSAPP_STATUS_TEMPLATE` | Approved order-status template name |
| `AYOO_WHATSAPP_TEMPLATE_LANGUAGE` | Template language code; default in code is `en_US` |

Supabase injects `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` into Edge Functions. Do not copy the service-role key into the storefront, GitHub, or a message. The migration generates its own worker secret inside the private database schema; it is not a function secret.

## Resend setup

1. Sign in to [Resend](https://resend.com/signup).
2. Create an API key with sending permission and store it as `RESEND_API_KEY` in Supabase Function secrets.
3. For production, add and verify a domain you control in [Resend Domains](https://resend.com/domains), then use a sender on that verified domain as `RESEND_FROM_EMAIL`.
4. Create a webhook at [Resend Webhooks](https://resend.com/webhooks) pointing to:
   `https://jfmhbmcrcbatoregunmk.supabase.co/functions/v1/ayoo-provider-webhooks`
5. Subscribe to `email.delivered`, `email.bounced`, `email.failed`, `email.complained`, and `email.delivery_delayed`. Save the signing secret as `RESEND_WEBHOOK_SECRET`.

**Domain constraint:** AYOO has not purchased/configured its own domain yet, by the user's earlier instruction. Resend's `onboarding@resend.dev` sender is suitable only for a restricted test to the Resend account's verified recipient. It is not a production sender for arbitrary customers. We will not buy a domain or change DNS as part of this work.

## WhatsApp Business Cloud API setup

1. Sign in to [Meta for Developers](https://developers.facebook.com/) with the Meta account that owns AYOO's business assets.
2. Create or select a Meta Business portfolio, create a Business-type app, and add the WhatsApp product.
3. Start with Meta's provided test number. In the WhatsApp API Setup panel, add the intended test recipient and complete its phone-number verification. The previously supplied test recipient is `+96893313009`; this is a recipient number, not the AYOO sending number.
4. For production, add/register an AYOO business phone number in WhatsApp Manager. Do not assume the personal WhatsApp number can be used as the sending number without completing Meta's migration/registration steps.
5. Create a System User and a long-lived access token with `whatsapp_business_messaging` and `whatsapp_business_management`. Do not use a short-lived user token for the production worker.
6. Store the token, sending Phone Number ID, Graph API version, and App Secret in Supabase Function secrets.

### Templates to submit for approval

Create two **UTILITY** templates in the same language configured in `AYOO_WHATSAPP_TEMPLATE_LANGUAGE`.

**Invoice template**
- Name: `ayoo_invoice` (or set the actual approved name in the secret)
- Header: Document
- Body: `Your AYOO order {{1}} has been received. Items total: {{2}}. Your PDF invoice is attached.`
- The worker supplies the PDF as the document header and the order number and item total as the two body parameters.

**Order status template**
- Name: `ayoo_order_status` (or set the actual approved name in the secret)
- Body: `AYOO order {{1}} status update: {{2}}.`
- The worker supplies the order number and new status.

Meta requires approved templates for business-initiated messages outside the 24-hour customer-service window. The worker uses templates for invoice and status messages, and only sends WhatsApp when the customer has opted in at checkout.

### Meta webhook

Configure the Meta app Webhooks product for WhatsApp and subscribe the WABA/app to the `messages` field. Use:

- Callback URL: `https://jfmhbmcrcbatoregunmk.supabase.co/functions/v1/ayoo-provider-webhooks`
- Verify token: the value stored in `META_WEBHOOK_VERIFY_TOKEN`

The function verifies `X-Hub-Signature-256` using `META_APP_SECRET` and records sent/delivered/read/failed statuses against the WhatsApp message ID.

## Deployment order (do not skip)

1. Set the provider secrets in Supabase.
2. Deploy `ayoo-notification-worker` and `ayoo-provider-webhooks` with JWT verification disabled; both validate their own shared-secret/signature mechanisms.
3. Apply `20261112090000_ayoo_invoice_notifications.sql`. It adds the private outbox/invoice tables, checkout consent wrapper, Storage bucket, triggers, extensions, and the one-minute cron job.
4. Verify the cron job and confirm the worker returns `claimed: 0` when the queue is empty.
5. Create a test order using a test stock variant, a Resend-verified recipient email, a WhatsApp test recipient, and the WhatsApp consent checkbox enabled.
6. Confirm that the PDF is attached to the email, the PDF arrives in WhatsApp, and both providers' webhooks update the delivery statuses.
7. Cancel the test order after verification so its reserved inventory is released. Check that the cancellation/status notification is recorded too.
8. Test duplicate worker invocations, provider 429/5xx responses, expired webhook signatures, and retry/unknown states.

## Current blockers before a real end-to-end send

- The saved browser profile is not signed in to Resend; the Resend dashboard showed its login screen, so there is no API key or verified sending domain visible.
- The saved browser profile is not signed in to Meta for Developers; no WhatsApp Business app or sending phone number is visible.
- No provider secrets or approved WhatsApp templates have been configured in Supabase.
- Because AYOO's custom domain is intentionally postponed, production email to arbitrary customer addresses cannot be enabled yet. We can first prove the PDF and delivery flow to a verified test email and Meta's test recipient.

Never paste API keys, access tokens, App Secrets, webhook signing secrets, or passwords into chat or commit them to GitHub.
