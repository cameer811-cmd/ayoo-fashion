const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const META_APP_SECRET = Deno.env.get("META_APP_SECRET") ?? "";
const META_WEBHOOK_VERIFY_TOKEN = Deno.env.get("META_WEBHOOK_VERIFY_TOKEN") ?? "";
const RESEND_WEBHOOK_SECRET = Deno.env.get("RESEND_WEBHOOK_SECRET") ?? "";
const encoder = new TextEncoder();

async function rpc<T = unknown>(name: string, args: Record<string, unknown>): Promise<T> {
  const response = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: { apikey: SERVICE_ROLE_KEY, Authorization: "Bearer " + SERVICE_ROLE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const raw = await response.text();
  if (!response.ok) throw new Error("Supabase RPC " + name + " failed (" + response.status + "): " + raw.slice(0, 400));
  return (raw ? JSON.parse(raw) : null) as T;
}

function hex(bytes: Uint8Array): string {
  return [...bytes].map((value) => value.toString(16).padStart(2, "0")).join("");
}
function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
async function hmacHex(secret: string, payload: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(payload))));
}
async function verifyMeta(raw: string, signature: string | null): Promise<boolean> {
  if (!META_APP_SECRET || !signature?.startsWith("sha256=")) return false;
  const expected = await hmacHex(META_APP_SECRET, raw);
  return constantTimeEqual(expected, signature.slice(7).toLowerCase());
}
function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  return Uint8Array.from(binary, (char) => char.charCodeAt(0));
}
async function verifyResend(raw: string, req: Request): Promise<boolean> {
  if (!RESEND_WEBHOOK_SECRET) return false;
  const id = req.headers.get("svix-id") ?? "";
  const timestamp = req.headers.get("svix-timestamp") ?? "";
  const signature = req.headers.get("svix-signature") ?? "";
  if (!id || !timestamp || !signature) return false;
  const seconds = Number(timestamp);
  if (!Number.isFinite(seconds) || Math.abs(Date.now() / 1000 - seconds) > 300) return false;
  const secretValue = RESEND_WEBHOOK_SECRET.startsWith("whsec_") ? RESEND_WEBHOOK_SECRET.slice(6) : RESEND_WEBHOOK_SECRET;
  let secret: Uint8Array;
  try { secret = decodeBase64(secretValue); } catch { return false; }
  const secretBuffer = new Uint8Array(secret).buffer as ArrayBuffer;
  const key = await crypto.subtle.importKey("raw", secretBuffer, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const digest = btoa(String.fromCharCode(...new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(id + "." + timestamp + "." + raw)))));
  const candidates = signature.split(" ").map((part) => part.trim()).filter(Boolean);
  return candidates.some((part) => {
    const pieces = part.split(",");
    return pieces.length === 2 && pieces[0] === "v1" && constantTimeEqual(digest, pieces[1]);
  });
}

async function handleMetaWebhook(payload: any): Promise<number> {
  let updated = 0;
  for (const entry of payload.entry ?? []) {
    for (const change of entry.changes ?? []) {
      const value = change.value ?? {};
      for (const status of value.statuses ?? []) {
        const providerStatus = status.status === "delivered" || status.status === "read"
          ? "delivered"
          : status.status === "failed"
            ? "failed"
            : status.status === "sent" ? "accepted" : null;
        if (!providerStatus || !status.id) continue;
        const errorText = (status.errors ?? []).map((e: any) => e.title || e.message || e.code || "WhatsApp delivery failed").join("; ");
        updated += await rpc<number>("ayoo_record_delivery_webhook", {
          p_provider: "whatsapp",
          p_provider_message_id: String(status.id),
          p_status: providerStatus,
          p_error: errorText || null,
        });
      }
    }
  }
  return updated;
}

async function handleResendWebhook(payload: any): Promise<number> {
  const eventType = String(payload.type ?? "");
  const data = payload.data ?? {};
  const messageId = data.email_id ?? data.id;
  if (!messageId) return 0;
  let providerStatus: string | null = null;
  if (eventType === "email.delivered") providerStatus = "delivered";
  else if (["email.bounced", "email.failed", "email.complained", "email.suppressed"].includes(eventType)) providerStatus = "failed";
  else if (eventType === "email.delivery_delayed") providerStatus = "accepted";
  if (!providerStatus) return 0;
  const reason = data.reason ?? data.bounce?.message ?? data.error ?? null;
  return await rpc<number>("ayoo_record_delivery_webhook", {
    p_provider: "resend",
    p_provider_message_id: String(messageId),
    p_status: providerStatus,
    p_error: reason ? String(reason).slice(0, 1000) : null,
  });
}

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);
  if (req.method === "GET") {
    const mode = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const challenge = url.searchParams.get("hub.challenge");
    if (mode === "subscribe" && token && META_WEBHOOK_VERIFY_TOKEN && constantTimeEqual(token, META_WEBHOOK_VERIFY_TOKEN) && challenge) {
      return new Response(challenge, { status: 200, headers: { "Content-Type": "text/plain" } });
    }
    return new Response("Forbidden", { status: 403 });
  }

  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const raw = await req.text();
  try {
    if (req.headers.has("x-hub-signature-256")) {
      if (!await verifyMeta(raw, req.headers.get("x-hub-signature-256"))) return Response.json({ error: "Invalid Meta signature" }, { status: 401 });
      const count = await handleMetaWebhook(JSON.parse(raw));
      return Response.json({ ok: true, provider: "whatsapp", updated: count });
    }

    if (req.headers.has("svix-id")) {
      if (!await verifyResend(raw, req)) return Response.json({ error: "Invalid Resend signature" }, { status: 401 });
      const count = await handleResendWebhook(JSON.parse(raw));
      return Response.json({ ok: true, provider: "resend", updated: count });
    }

    return Response.json({ error: "Unsupported webhook source" }, { status: 400 });
  } catch (error) {
    return Response.json({ error: String(error).slice(0, 500) }, { status: 500 });
  }
});
