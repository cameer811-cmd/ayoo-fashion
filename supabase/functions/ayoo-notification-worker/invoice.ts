import { jsPDF } from "npm:jspdf@3.0.2";

export type InvoiceOrder = {
  id: string;
  order_number: string;
  customer_name: string;
  customer_email: string;
  customer_phone: string;
  shipping_address: Record<string, unknown>;
  currency: string;
  subtotal: number | string;
  total_amount: number | string;
  created_at: string;
};

export type InvoiceItem = {
  product_name: string;
  color_name: string;
  size: string;
  quantity: number;
  unit_price: number | string;
  line_total: number | string;
  currency: string;
};

const FONT_URL = "https://raw.githubusercontent.com/jenskutilek/free-fonts/master/Noto/Noto%20Naskh%20Arabic/TTF/NotoNaskhArabic-Regular.ttf";
const WINE: [number, number, number] = [64, 26, 41];
const INK: [number, number, number] = [41, 38, 38];
const MUTED: [number, number, number] = [107, 102, 100];
const PAPER: [number, number, number] = [251, 249, 244];
const LINE: [number, number, number] = [219, 212, 203];
const WHITE: [number, number, number] = [255, 255, 255];
let arabicFontBytesPromise: Promise<Uint8Array> | null = null;

function safeText(value: unknown): string {
  return String(value ?? "").replace(/[\r\n\t]+/g, " ").trim();
}
function isArabic(value: string): boolean {
  return /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF]/.test(value);
}
function money(value: number | string, currency: string): string {
  const amount = Number(value ?? 0);
  try { return new Intl.NumberFormat("en-US", { style: "currency", currency: currency || "USD" }).format(amount); }
  catch { return amount.toFixed(2) + " " + (currency || "USD"); }
}
function formatDate(value: string): string {
  return new Intl.DateTimeFormat("en-GB", { day: "2-digit", month: "short", year: "numeric", timeZone: "Europe/Istanbul" }).format(new Date(value));
}
function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let i = 0; i < bytes.length; i += chunkSize) binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  return btoa(binary);
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
function drawInvoiceText(doc: any, text: string, x: number, y: number, size: number, color: [number, number, number] = INK, align: "left" | "right" = "right") {
  doc.setFontSize(size);
  doc.setTextColor(color[0], color[1], color[2]);
  if (isArabic(text)) {
    doc.setFont("NotoNaskhArabic", "normal");
    doc.setR2L(true);
    doc.text(text, x, y, { align });
    doc.setR2L(false);
  } else {
    doc.setFont("helvetica", "normal");
    doc.text(text, x, y, { align });
  }
}

export async function buildInvoicePdf(order: InvoiceOrder, items: InvoiceItem[], invoiceNumber: string): Promise<Uint8Array> {
  if (items.length > 30) throw new Error("This invoice contains more than 30 lines; multi-page invoices are not enabled yet.");
  const fontBytes = await arabicFontBytes();
  const doc: any = new jsPDF({ unit: "mm", format: "a4", compress: true });
  if (typeof doc.processArabic !== "function" || typeof doc.setR2L !== "function") {
    throw new Error("The jsPDF Arabic text module is unavailable.");
  }
  doc.addFileToVFS("NotoNaskhArabic-Regular.ttf", bytesToBase64(fontBytes));
  doc.addFont("NotoNaskhArabic-Regular.ttf", "NotoNaskhArabic", "normal");

  doc.setFillColor(PAPER[0], PAPER[1], PAPER[2]);
  doc.rect(0, 0, 210, 297, "F");
  doc.setFillColor(WINE[0], WINE[1], WINE[2]);
  doc.rect(0, 0, 210, 38, "F");

  doc.setFont("helvetica", "bold");
  doc.setFontSize(28);
  doc.setTextColor(255, 255, 255);
  doc.text("AYOO", 16, 22);
  drawInvoiceText(doc, "فاتورة طلب", 194, 18, 18, WHITE, "right");
  doc.setFont("helvetica", "normal");
  doc.setFontSize(8);
  doc.setTextColor(239, 226, 229);
  doc.text("ORDER INVOICE", 16, 31);

  doc.setFont("helvetica", "bold");
  doc.setFontSize(9);
  doc.setTextColor(INK[0], INK[1], INK[2]);
  doc.text("Invoice: " + invoiceNumber, 16, 52);
  doc.setFont("helvetica", "normal");
  doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
  doc.text("Order: " + safeText(order.order_number), 16, 59);
  doc.text("Date: " + formatDate(order.created_at), 16, 66);
  drawInvoiceText(doc, "بيانات العميل", 194, 52, 12, WINE, "right");
  drawInvoiceText(doc, safeText(order.customer_name), 194, 61, 10, INK, "right");
  doc.setFont("helvetica", "normal");
  doc.setFontSize(8);
  doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
  doc.text(safeText(order.customer_email).slice(0, 58), 16, 75);
  doc.text(safeText(order.customer_phone), 16, 81);
  const address = order.shipping_address || {};
  const addressLine = [address.address_line1, address.city, address.postal_code].map(safeText).filter(Boolean).join(", ");
  drawInvoiceText(doc, addressLine.slice(0, 72), 194, 72, 8, MUTED, "right");

  doc.setDrawColor(LINE[0], LINE[1], LINE[2]);
  doc.setLineWidth(0.3);
  doc.line(16, 89, 194, 89);
  doc.setFont("helvetica", "bold");
  doc.setFontSize(7);
  doc.setTextColor(WINE[0], WINE[1], WINE[2]);
  doc.text("ITEM", 16, 99);
  doc.text("COLOUR / SIZE", 105, 99);
  doc.text("QTY", 150, 99);
  doc.text("UNIT", 168, 99);
  doc.text("TOTAL", 194, 99, { align: "right" });
  doc.line(16, 102, 194, 102);

  let y = 109;
  for (const item of items) {
    drawInvoiceText(doc, safeText(item.product_name).slice(0, 34), 96, y, 7.5, INK, "right");
    drawInvoiceText(doc, safeText(item.color_name).slice(0, 14), 140, y, 7, MUTED, "right");
    doc.setFont("helvetica", "normal");
    doc.setFontSize(7);
    doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
    doc.text(safeText(item.size), 143, y);
    doc.setTextColor(INK[0], INK[1], INK[2]);
    doc.text(String(item.quantity), 150, y);
    doc.text(money(item.unit_price, item.currency).slice(0, 14), 168, y);
    doc.setFont("helvetica", "bold");
    doc.text(money(item.line_total, item.currency).slice(0, 14), 194, y, { align: "right" });
    doc.setDrawColor(LINE[0], LINE[1], LINE[2]);
    doc.line(16, y + 2.5, 194, y + 2.5);
    y += 4.5;
  }

  const summaryY = Math.max(136, y + 7);
  doc.setFont("helvetica", "normal");
  doc.setFontSize(8);
  doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
  doc.text("PRODUCT SUBTOTAL", 125, summaryY);
  doc.setFont("helvetica", "bold");
  doc.setTextColor(INK[0], INK[1], INK[2]);
  doc.text(money(order.subtotal, order.currency), 194, summaryY, { align: "right" });
  doc.setFont("helvetica", "normal");
  doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
  doc.text("SHIPPING", 125, summaryY + 7);
  doc.text("To be confirmed", 194, summaryY + 7, { align: "right" });
  doc.setDrawColor(WINE[0], WINE[1], WINE[2]);
  doc.setLineWidth(0.4);
  doc.line(120, summaryY + 11, 194, summaryY + 11);
  doc.setFont("helvetica", "bold");
  doc.setTextColor(WINE[0], WINE[1], WINE[2]);
  doc.text("AMOUNT FOR ITEMS", 125, summaryY + 18);
  doc.setFontSize(10);
  doc.text(money(order.total_amount, order.currency), 194, summaryY + 18, { align: "right" });

  doc.setFont("helvetica", "bold");
  doc.setFontSize(7);
  doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
  doc.text("PAYMENT: CASH ON DELIVERY", 16, 280);
  doc.setFont("helvetica", "normal");
  doc.text("Shipping is not included. AYOO will confirm the delivery fee before dispatch.", 16, 285);
  drawInvoiceText(doc, "شكراً لاختياركم", 194, 291, 9, WINE, "right");
  doc.setFont("helvetica", "bold");
  doc.setFontSize(6);
  doc.setTextColor(MUTED[0], MUTED[1], MUTED[2]);
  doc.text("AYOO · A VISION IN FORM", 16, 291);

  doc.setProperties({
    title: "AYOO Invoice " + invoiceNumber,
    subject: "Order " + order.order_number,
    author: "AYOO",
    creator: "AYOO Store",
  });
  return new Uint8Array(doc.output("arraybuffer"));
}
