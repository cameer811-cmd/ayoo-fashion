import { PDFDocument, StandardFonts, rgb } from "npm:pdf-lib@1.17.1";
import fontkit from "npm:@pdf-lib/fontkit@1.1.1";
import { drawArabicText } from "npm:arabic-bidi-shaper@0.1.1/pdf-lib";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_FROM_EMAIL = Deno.env.get("RESEND_FROM_EMAIL") ?? "";
const META_ACCESS_TOKEN = Deno.env.get("META_WHATSAPP_ACCESS_TOKEN") ?? "";
const META_PHONE_NUMBER_ID = Deno.env.get("META_WHATSAPP_PHONE_NUMBER_ID") ?? "";
const META_GRAPH_API_VERSION = Deno.env.get("META_GRAPH_API_VERSION") ?? "";
const WA_INVOICE_TEMPLATE = Deno.env.get("AYOO_WHATSAPP_INVOICE_TEMPLATE") ?? "";
const WA_STATUS_TEMPLATE = Deno.env.get("AYOO_WHATSAPP_STATUS_TEMPLATE") ?? "";
const WA_TEMPLATE_LANGUAGE = Deno.env.get("AYOO_WHATSAPP_TEMPLATE_LANGUAGE") ?? "en_US";
const FONT_URL = "https://raw.githubusercontent.com/jenskutilek/free-fonts/master/Noto/Noto%20Naskh%20Arabic/TTF/NotoNaskhArabic-Regular.ttf";

const WINE = rgb(0.25, 0.10, 0.16);
const INK = rgb(0.16, 0.15, 0.15);
const MUTED = rgb(0.42, 0.40, 0.39);
const PAPER = rgb(0.985, 0.976, 0.957);
const LINE = rgb(0.86, 0.83, 0.79);

type Order = {
  id: string; order_number: string; customer_name: string; customer_email: string;
  customer_phone: string; shipping_country_code: string; shipping_address: Record<string, unknown>;
  customer_note: string | null; currency: string; subtotal: number | string;
  shipping_amount: number | string; total_amount: number | string; payment_method: string;
  payment_status: string; order_status: string; whatsapp_opt_in: boolean; created_at: string;
};
type OrderItem = {
  product_name: string; color_name: string; size: string; quantity: number;
  unit_price: number | string; line_total: number | string; currency: string;
};
type Job = { job_id: string; order_id: string; event_type: "order_created" | "order_status"; status_value: string | null; attempt_count: number; };
type Delivery = {
  delivery_id: string; channel: "email" | "whatsapp"; provider: "resend" | "whatsapp";
  status: string; attempt_count: number; idempotency_key: string; provider_message_id: string | null;
};

class DeliveryError extends Error {
  retryable: boolean; uncertain: boolean; retryAfterSeconds: number;
  constructor(message: string, opts: { retryable?: boolean; uncertain?: boolean; retryAfterSeconds?: number } = {}) {
    super(message); this.name = "DeliveryError";
    this.retryable = opts.retryable ?? false;
    this.uncertain = opts.uncertain ?? false;
    this.retryAfterSeconds = opts.retryAfterSeconds ?? 300;
  }
}

let arabicFontBytesPromise: Promise<Uint8Array> | null = null;

async function rpc<T = unknown>(name: string, args: Record<string, unknown>): Promise<T> {
  const response = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + name, {
    method: "POST",
    headers: { apikey: SERVICE_ROLE_KEY, Authorization: "Bearer " + SERVICE_ROLE_KEY, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const raw = await response.text();
  if (!response.ok) throw new Error("Supabase RPC " + name + " failed (" + response.status + "): " + raw.slice(0, 500));
  return (raw ? JSON.parse(raw) : null) as T;
}

async function restGet<T>(path: string): Promise<T> {
  const response = await fetch(SUPABASE_URL + "/rest/v1/" + path, {
    headers: { apikey: SERVICE_ROLE_KEY, Authorization: "Bearer " + SERVICE_ROLE_KEY },
  });
  const raw = await response.text();
  if (!response.ok) throw new Error("Supabase read failed (" + response.status + "): " + raw.slice(0, 500));
  return JSON.parse(raw) as T;
}

async function loadOrder(orderId: string): Promise<{ order: Order; items: OrderItem[] }> {
  const orders = await restGet<Order[]>("orders?id=eq." + encodeURIComponent(orderId) + "&select=*");
  const order = orders[0];
  if (!order) throw new Error("Order not found.");
  const items = await restGet<OrderItem[]>("order_items?order_id=eq." + encodeURIComponent(orderId) + "&select=*&order=created_at.asc");
  if (!items.length) throw new Error("Order has no line items; invoice generation was stopped.");
  return { order, items };
}

function firstRow<T>(value: T | T[] | null): T | null {
  return Array.isArray(value) ? (value[0] ?? null) : value;
}
function money(value: number | string, currency: string): string {
  const amount = Number(value ?? 0);
  try { return new Intl.NumberFormat("en-US", { style: "currency", currency: currency || "USD" }).format(amount); }
  catch { return amount.toFixed(2) + " " + (currency || "USD"); }
}
function formatDate(value: string): string {
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric", timeZone: "Europe/Istanbul" }).format(new Date(value));
}
function isArabic(value: string): boolean {
  return /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]/.test(value);
}
function safeText(value: unknown): string {
  return String(value ?? "").replace(/[\r\n\t]+/g, " ").trim();
}
function escapeHtml(value: unknown): string {
  return safeText(value).replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!);
}
async function arabicFontBytes(): Promise<Uint8Array> {
  if (!arabicFontBytesPromise) {
    arabicFontBytesPromise = fetch(FONT_URL, { signal: AbortSignal.timeout(20000) })
      .then(async (response) => {
        if (!response.ok) throw new Error("Arabic font download failed (" + response.status + ").");
        return new Uint8Array(await response.arrayBuffer());
      })
      .catch((error) => {
        arabicFontBytesPromise = null;
        throw error;
      });
  }
  return await arabicFontBytesPromise;
}
function drawInvoiceText(page: any, text: string, x: number, y: number, size: number, latinFont: any, arabicFont: any, color = INK, align: "left" | "right" = "right") {
  if (isArabic(text)) drawArabicText(page, text, { font: arabicFont, size, x, y, color });
  else {
    const textWidth = latinFont.widthOfTextAtSize(text, size);
    page.drawText(text, { x: align === "right" ? x - textWidth : x, y, size, font: latinFont, color });
  }
}

export async function buildInvoicePdf(order: Order, items: OrderItem[], invoiceNumber: string): Promise<Uint8Array> {
  if (items.length > 30) throw new Error("This invoice contains more than 30 lines; multi-page invoices are not enabled yet.");
  const pdf = await PDFDocument.create();
  pdf.registerFontkit(fontkit);
  const latin = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const arabic = await pdf.embedFont(await arabicFontBytes(), { subset: true });
  const page = pdf.addPage([595.28, 841.89]);
  const width = page.getWidth();

  page.drawRectangle({ x: 0, y: 0, width, height: page.getHeight(), color: PAPER });
  page.drawRectangle({ x: 0, y: 735, width, height: 107, color: WINE });
  page.drawText("AYOO", { x: 46, y: 785, size: 29, font: bold, color: rgb(1, 1, 1) });
  drawInvoiceText(page, "فاتورة طلب", 548, 790, 20, bold, arabic, rgb(1, 1, 1));
  page.drawText("ORDER INVOICE", { x: 48, y: 760, size: 9, font: latin, color: rgb(0.93, 0.88, 0.86) });
  page.drawText("Invoice: " + invoiceNumber, { x: 48, y: 710, size: 10, font: bold, color: INK });
  page.drawText("Order: " + safeText(order.order_number), { x: 48, y: 692, size: 10, font: latin, color: MUTED });
  page.drawText("Date: " + formatDate(order.created_at), { x: 48, y: 674, size: 10, font: latin, color: MUTED });
  drawInvoiceText(page, "بيانات العميل", 548, 710, 13, bold, arabic, WINE);
  drawInvoiceText(page, safeText(order.customer_name), 548, 690, 11, latin, arabic);
  page.drawText(safeText(order.customer_email).slice(0, 48), { x: 48, y: 650, size: 9, font: latin, color: MUTED });
  page.drawText(safeText(order.customer_phone), { x: 48, y: 634, size: 9, font: latin, color: MUTED });
  const address = order.shipping_address || {};
  const addressLine = [address.address_line1, address.city, address.postal_code].map(safeText).filter(Boolean).join(", ");
  page.drawText(addressLine.slice(0, 78), { x: 48, y: 618, size: 9, font: latin, color: MUTED });

  page.drawLine({ start: { x: 46, y: 594 }, end: { x: width - 46, y: 594 }, thickness: 0.8, color: LINE });
  page.drawText("ITEM", { x: 48, y: 572, size: 8, font: bold, color: WINE });
  page.drawText("COLOUR / SIZE", { x: 300, y: 572, size: 8, font: bold, color: WINE });
  page.drawText("QTY", { x: 414, y: 572, size: 8, font: bold, color: WINE });
  page.drawText("UNIT", { x: 447, y: 572, size: 8, font: bold, color: WINE });
  page.drawText("TOTAL", { x: 510, y: 572, size: 8, font: bold, color: WINE });
  page.drawLine({ start: { x: 46, y: 560 }, end: { x: width - 46, y: 560 }, thickness: 0.6, color: LINE });

  let y = 538;
  for (const item of items.slice(0, 30)) {
    drawInvoiceText(page, safeText(item.product_name).slice(0, 34), 295, y, 8, latin, arabic);
    drawInvoiceText(page, safeText(item.color_name).slice(0, 14) + " / " + safeText(item.size), 405, y, 8, latin, arabic, MUTED);
    page.drawText(String(item.quantity), { x: 414, y, size: 9, font: latin, color: INK });
    page.drawText(money(item.unit_price, item.currency).slice(0, 14), { x: 447, y, size: 8, font: latin, color: INK });
    page.drawText(money(item.line_total, item.currency).slice(0, 14), { x: 510, y, size: 8, font: bold, color: INK });
    page.drawLine({ start: { x: 46, y: y - 7 }, end: { x: width - 46, y: y - 7 }, thickness: 0.35, color: LINE });
    y -= 12;
  }

  const summaryY = Math.max(78, y - 18);
  page.drawText("PRODUCT SUBTOTAL", { x: 340, y: summaryY, size: 9, font: latin, color: MUTED });
  page.drawText(money(order.subtotal, order.currency), { x: 470, y: summaryY, size: 10, font: bold, color: INK });
  page.drawText("SHIPPING", { x: 340, y: summaryY - 20, size: 9, font: latin, color: MUTED });
  page.drawText("To be confirmed", { x: 470, y: summaryY - 20, size: 8, font: latin, color: MUTED });
  page.drawLine({ start: { x: 330, y: summaryY - 30 }, end: { x: width - 46, y: summaryY - 30 }, thickness: 0.8, color: WINE });
  page.drawText("AMOUNT FOR ITEMS", { x: 340, y: summaryY - 49, size: 9, font: bold, color: WINE });
  page.drawText(money(order.total_amount, order.currency), { x: 465, y: summaryY - 50, size: 12, font: bold, color: WINE });
  page.drawText("PAYMENT: CASH ON DELIVERY", { x: 48, y: 92, size: 8, font: bold, color: MUTED });
  page.drawText("Shipping is not included. AYOO will confirm the delivery fee before dispatch.", { x: 48, y: 74, size: 7.5, font: latin, color: MUTED });
  drawInvoiceText(page, "شكراً لاختياركم AYOO", 548, 45, 11, latin, arabic, WINE);
  page.drawText("AYOO · A VISION IN FORM", { x: 48, y: 45, size: 7, font: latin, color: MUTED });

  pdf.setTitle("AYOO Invoice " + invoiceNumber);
  pdf.setAuthor("AYOO");
  pdf.setSubject("Order " + order.order_number);
  return await pdf.save({ useObjectStreams: false });
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  return btoa(binary);
}

async function storageRequest(path: string, init: RequestInit): Promise<Response> {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  return await fetch(SUPABASE_URL + "/storage/v1/object/ayoo-invoices/" + encodedPath, {
    ...init,
    headers: { apikey: SERVICE_ROLE_KEY, Authorization: "Bearer " + SERVICE_ROLE_KEY, ...(init.headers || {}) },
  });
}

async function ensureInvoice(order: Order, items: OrderItem[]): Promise<{ invoiceNumber: string; pdf: Uint8Array }> {
  const record = firstRow(await rpc<any[] | any>("ayoo_get_invoice_record", { p_order_id: order.id }));
  if (!record) throw new Error("Invoice record is missing for this order.");
  if (record.status === "ready" && record.storage_path) {
    const download = await storageRequest(record.storage_path, { method: "GET" });
    if (download.ok) return { invoiceNumber: record.invoice_number, pdf: new Uint8Array(await download.arrayBuffer()) };
  }
  await rpc("ayoo_set_invoice_record", { p_order_id: order.id, p_status: "generating", p_error: null });
  try {
    const pdf = await buildInvoicePdf(order, items, record.invoice_number);
    const pdfBuffer = new Uint8Array(pdf).buffer as ArrayBuffer;
    const digest = await crypto.subtle.digest("SHA-256", pdfBuffer);
    const sha256 = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    const path = order.id + "/" + record.invoice_number + ".pdf";
    const upload = await storageRequest(path, { method: "POST", headers: { "Content-Type": "application/pdf", "x-upsert": "true" }, body: new Blob([pdfBuffer], { type: "application/pdf" }) });
    if (!upload.ok) throw new Error("Invoice storage upload failed (" + upload.status + "): " + (await upload.text()).slice(0, 400));
    await rpc("ayoo_set_invoice_record", { p_order_id: order.id, p_status: "ready", p_storage_path: path, p_sha256: sha256, p_error: null });
    return { invoiceNumber: record.invoice_number, pdf };
  } catch (error) {
    await rpc("ayoo_set_invoice_record", { p_order_id: order.id, p_status: "failed", p_error: String(error).slice(0, 1000) }).catch(() => null);
    throw error;
  }
}

async function sendEmail(order: Order, job: Job, delivery: Delivery, invoice: { invoiceNumber: string; pdf: Uint8Array } | null): Promise<string> {
  if (!RESEND_API_KEY || !RESEND_FROM_EMAIL) throw new DeliveryError("Resend is not configured: add RESEND_API_KEY and RESEND_FROM_EMAIL.", { retryable: true, retryAfterSeconds: 3600 });
  const statusLabel = safeText(job.status_value || order.order_status);
  const isInvoice = job.event_type === "order_created";
  const subject = isInvoice ? "Your AYOO invoice " + invoice!.invoiceNumber : "AYOO order " + order.order_number + ": " + statusLabel;
  const html = isInvoice
    ? '<div style="font-family:Arial,sans-serif;color:#292526;max-width:600px;margin:auto"><h1 style="color:#401a29">AYOO</h1><h2>Your order invoice</h2><p>Thank you, ' + escapeHtml(order.customer_name) + '.</p><p>Your order <strong>' + escapeHtml(order.order_number) + '</strong> has been received.</p><p>Items total: <strong>' + escapeHtml(money(order.total_amount, order.currency)) + '</strong></p><p>Shipping is not included; our team will confirm the delivery fee before dispatch.</p><p>The PDF invoice is attached.</p><p dir="rtl">شكراً لاختياركم AYOO. تجدون فاتورة الطلب مرفقة بهذه الرسالة.</p></div>'
    : '<div style="font-family:Arial,sans-serif;color:#292526;max-width:600px;margin:auto"><h1 style="color:#401a29">AYOO</h1><h2>Order update</h2><p>Your order <strong>' + escapeHtml(order.order_number) + '</strong> is now: <strong>' + escapeHtml(statusLabel) + '</strong>.</p><p>Thank you for shopping with AYOO.</p></div>';
  const payload: Record<string, unknown> = { from: RESEND_FROM_EMAIL, to: [order.customer_email], subject, html };
  if (invoice) payload.attachments = [{ filename: invoice.invoiceNumber + ".pdf", content: bytesToBase64(invoice.pdf), content_type: "application/pdf" }];

  let response: Response;
  try {
    response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: "Bearer " + RESEND_API_KEY, "Content-Type": "application/json", "Idempotency-Key": delivery.idempotency_key },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(25000),
    });
  } catch (error) {
    throw new DeliveryError("Resend network error: " + String(error), { uncertain: true });
  }
  const raw = await response.text();
  if (!response.ok) {
    throw new DeliveryError("Resend rejected the email (" + response.status + "): " + raw.slice(0, 500), {
      retryable: response.status === 429 || response.status >= 500,
      retryAfterSeconds: response.status === 429 ? 300 : 120,
    });
  }
  const data = raw ? JSON.parse(raw) : {};
  if (!data.id) throw new DeliveryError("Resend returned no email ID; delivery status is uncertain.", { uncertain: true });
  return String(data.id);
}

function normalizePhone(phone: string): string {
  let digits = phone.replace(/\D/g, "");
  if (digits.startsWith("00")) digits = digits.slice(2);
  if (digits.startsWith("0")) digits = "90" + digits.slice(1);
  else if (digits.length === 10 && digits.startsWith("5")) digits = "90" + digits;
  if (digits.length < 8 || digits.length > 15) throw new Error("Customer WhatsApp number is invalid.");
  return digits;
}

async function metaPost(path: string, body: unknown): Promise<any> {
  if (!META_ACCESS_TOKEN || !META_PHONE_NUMBER_ID || !META_GRAPH_API_VERSION) throw new DeliveryError("WhatsApp Cloud API is not configured.", { retryable: true, retryAfterSeconds: 3600 });
  const isForm = body instanceof FormData;
  let response: Response;
  try {
    response = await fetch("https://graph.facebook.com/" + META_GRAPH_API_VERSION + "/" + path, {
      method: "POST",
      headers: { Authorization: "Bearer " + META_ACCESS_TOKEN, ...(isForm ? {} : { "Content-Type": "application/json" }) },
      body: isForm ? body : JSON.stringify(body),
      signal: AbortSignal.timeout(25000),
    });
  } catch (error) {
    throw new DeliveryError("WhatsApp network error: " + String(error), { uncertain: true });
  }
  const raw = await response.text();
  if (!response.ok) throw new DeliveryError("WhatsApp API rejected the request (" + response.status + "): " + raw.slice(0, 500), {
    retryable: response.status === 429, uncertain: response.status >= 500, retryAfterSeconds: 300,
  });
  return raw ? JSON.parse(raw) : {};
}

async function uploadWhatsappPdf(pdf: Uint8Array, filename: string): Promise<string> {
  const form = new FormData();
  form.append("messaging_product", "whatsapp");
  form.append("type", "application/pdf");
  const pdfBuffer = new Uint8Array(pdf).buffer as ArrayBuffer;
  form.append("file", new Blob([pdfBuffer], { type: "application/pdf" }), filename);
  const result = await metaPost(META_PHONE_NUMBER_ID + "/media", form);
  if (!result.id) throw new DeliveryError("WhatsApp media upload returned no media ID.", { uncertain: true });
  return String(result.id);
}

async function sendWhatsApp(order: Order, job: Job, invoice: { invoiceNumber: string; pdf: Uint8Array } | null): Promise<{ skipped: true } | { messageId: string }> {
  if (!order.whatsapp_opt_in) return { skipped: true };
  if (!META_ACCESS_TOKEN || !META_PHONE_NUMBER_ID || !META_GRAPH_API_VERSION) throw new DeliveryError("WhatsApp Cloud API is not configured.", { retryable: true, retryAfterSeconds: 3600 });
  const to = normalizePhone(order.customer_phone);
  let template: Record<string, unknown>;

  if (job.event_type === "order_created") {
    if (!WA_INVOICE_TEMPLATE || !invoice) throw new DeliveryError("Set AYOO_WHATSAPP_INVOICE_TEMPLATE to an approved document-header template.", { retryable: true, retryAfterSeconds: 3600 });
    const mediaId = await uploadWhatsappPdf(invoice.pdf, invoice.invoiceNumber + ".pdf");
    template = {
      name: WA_INVOICE_TEMPLATE,
      language: { code: WA_TEMPLATE_LANGUAGE },
      components: [
        { type: "header", parameters: [{ type: "document", document: { id: mediaId, filename: invoice.invoiceNumber + ".pdf" } }] },
        { type: "body", parameters: [
          { type: "text", text: order.order_number },
          { type: "text", text: money(order.total_amount, order.currency) },
        ] },
      ],
    };
  } else {
    if (!WA_STATUS_TEMPLATE) throw new DeliveryError("Set AYOO_WHATSAPP_STATUS_TEMPLATE to an approved order-status template.", { retryable: true, retryAfterSeconds: 3600 });
    template = {
      name: WA_STATUS_TEMPLATE,
      language: { code: WA_TEMPLATE_LANGUAGE },
      components: [{ type: "body", parameters: [
        { type: "text", text: order.order_number },
        { type: "text", text: safeText(job.status_value || order.order_status) },
      ] }],
    };
  }

  const result = await metaPost(META_PHONE_NUMBER_ID + "/messages", {
    messaging_product: "whatsapp", recipient_type: "individual", to, type: "template", template,
  });
  const messageId = result.messages?.[0]?.id;
  if (!messageId) throw new DeliveryError("WhatsApp returned no message ID; delivery status is uncertain.", { uncertain: true });
  return { messageId: String(messageId) };
}

function retryDelay(attempt: number): number {
  return Math.min(3600, 60 * (2 ** Math.max(0, attempt - 1)));
}

async function processJob(job: Job) {
  const loaded = await loadOrder(job.order_id);
  const order = loaded.order;
  const items = loaded.items;
  const deliveries = await rpc<Delivery[]>("ayoo_get_notification_deliveries", { p_job_id: job.job_id });
  let invoice: { invoiceNumber: string; pdf: Uint8Array } | null = null;
  let jobError: string | null = null;

  for (const delivery of deliveries) {
    if (["accepted", "delivered", "failed", "skipped", "unknown"].includes(delivery.status)) continue;
    const claimed = await rpc<boolean>("ayoo_claim_notification_delivery", { p_delivery_id: delivery.delivery_id });
    if (!claimed) continue;

    try {
      if (delivery.channel === "email") {
        if (job.event_type === "order_created") invoice ??= await ensureInvoice(order, items);
        const providerId = await sendEmail(order, job, delivery, invoice);
        await rpc("ayoo_finish_notification_delivery", {
          p_delivery_id: delivery.delivery_id, p_status: "accepted", p_provider_message_id: providerId, p_error: null, p_retry_seconds: 0,
        });
      } else {
        if (!order.whatsapp_opt_in) {
          await rpc("ayoo_finish_notification_delivery", {
            p_delivery_id: delivery.delivery_id, p_status: "skipped", p_provider_message_id: null,
            p_error: "Customer did not opt in to WhatsApp notifications.", p_retry_seconds: 0,
          });
          continue;
        }
        if (job.event_type === "order_created") invoice ??= await ensureInvoice(order, items);
        const result = await sendWhatsApp(order, job, invoice);
        await rpc("ayoo_finish_notification_delivery", {
          p_delivery_id: delivery.delivery_id, p_status: "skipped" in result ? "skipped" : "accepted",
          p_provider_message_id: "messageId" in result ? result.messageId : null, p_error: null, p_retry_seconds: 0,
        });
      }
    } catch (error) {
      const err = error instanceof DeliveryError ? error : new DeliveryError(String(error), { retryable: true, retryAfterSeconds: retryDelay(delivery.attempt_count + 1) });
      const status = err.uncertain ? "unknown" : err.retryable && delivery.attempt_count < 8 ? "retry" : "failed";
      jobError = [jobError, delivery.channel + ": " + err.message].filter(Boolean).join(" | ");
      await rpc("ayoo_finish_notification_delivery", {
        p_delivery_id: delivery.delivery_id, p_status: status, p_provider_message_id: null,
        p_error: err.message.slice(0, 1000), p_retry_seconds: err.retryAfterSeconds || retryDelay(delivery.attempt_count + 1),
      });
    }
  }
  await rpc("ayoo_finish_notification_job", { p_job_id: job.job_id, p_error: jobError });
}

if (import.meta.main) {
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) throw new Error("Supabase server environment is incomplete.");
  Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  const workerSecret = req.headers.get("x-ayoo-worker-secret") ?? "";
  if (!workerSecret) return Response.json({ error: "Unauthorized" }, { status: 401 });
  try {
    const valid = await rpc<boolean>("ayoo_validate_worker_secret", { p_secret: workerSecret });
    if (valid !== true) return Response.json({ error: "Unauthorized" }, { status: 401 });
    const jobs = await rpc<Job[]>("ayoo_claim_notification_jobs", { p_limit: 2 });
    const results: Array<{ job_id: string; status: string; error?: string }> = [];
    for (const job of jobs) {
      try {
        await processJob(job);
        results.push({ job_id: job.job_id, status: "processed" });
      } catch (error) {
        const message = String(error);
        await rpc("ayoo_finish_notification_job", { p_job_id: job.job_id, p_error: message.slice(0, 1000) }).catch(() => null);
        results.push({ job_id: job.job_id, status: "error", error: message.slice(0, 300) });
      }
    }
    return Response.json({ ok: true, claimed: jobs.length, results });
  } catch (error) {
    return Response.json({ ok: false, error: String(error).slice(0, 500) }, { status: 500 });
  }
  });
}
