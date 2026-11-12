import { PDFDocument } from "npm:pdf-lib@1.17.1";
import { buildInvoicePdf } from "./index.ts";

Deno.test("AYOO creates a readable one-page PDF invoice with Arabic and Latin text", async () => {
  const order = {
    id: "00000000-0000-4000-8000-000000000001",
    order_number: "AY-TEST-20261112",
    customer_name: "عميل اختبار AYOO",
    customer_email: "invoice-test@example.invalid",
    customer_phone: "+96893313009",
    shipping_country_code: "TR",
    shipping_address: { address_line1: "Test Street 1", city: "Istanbul", postal_code: "34000" },
    customer_note: null,
    currency: "USD",
    subtotal: 49.99,
    shipping_amount: 0,
    total_amount: 49.99,
    payment_method: "cash_on_delivery",
    payment_status: "pending",
    order_status: "pending",
    whatsapp_opt_in: true,
    created_at: "2026-11-12T07:00:00.000Z",
  };
  const items = [{
    product_name: "جاكيت شتوي تجريبي Winter Jacket",
    color_name: "أسود",
    size: "L",
    quantity: 1,
    unit_price: 49.99,
    line_total: 49.99,
    currency: "USD",
  }];

  const bytes = await buildInvoicePdf(order, items, "AYOO-TEST-20261112");
  if (bytes.length < 4000) throw new Error("Generated invoice PDF is unexpectedly small.");
  const signature = new TextDecoder().decode(bytes.slice(0, 5));
  if (signature !== "%PDF-") throw new Error("Generated file is not a PDF.");
  const parsed = await PDFDocument.load(bytes);
  if (parsed.getPageCount() !== 1) throw new Error("Expected a one-page test invoice.");
  if (parsed.getTitle() !== "AYOO Invoice AYOO-TEST-20261112") throw new Error("Invoice PDF metadata title is missing.");
});
