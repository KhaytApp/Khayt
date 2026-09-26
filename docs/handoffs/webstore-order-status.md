# Handoff: web-store orders, in as jobs and back out as progress

**From:** Khayt Mac (branch `mac-webstore-orders-to-jobs`)
**For:** Khayt Cloud (`khayt-cloud`, both backends) and the athartuwaiq3d storefront (Medusa backend)
**Mac side:** done and shipped behind a seam. It goes quiet on a 404, so nothing breaks
before either of you ships.

## What the Mac now does

1. **In.** Every 2 minutes, on the Mac that holds the book, it reads
   `GET /v1/shops/{shopId}/intake` and turns each **paid** web-store order into a job by itself:
   catalogue-priced parts, the customer found by email or phone (or created with
   `source: 'online'`), ready-made stock taken off `settings.storefront.stockQty`, and the job
   recorded as paid in full. Then it `DELETE`s the queue item. It is idempotent: an order the
   book already holds, by `source` + `sourceOrderId` (the intake `ref`, e.g. `medusa:#1042`) or
   by queue item id, is never written twice. The rule is `lib/webstore-order.js`.
2. **Out.** When a web-store job's state changes, the Mac POSTs it to the route below. That
   route **does not exist yet**. Until it does, the Mac gets a 404, stops trying until it next
   starts, and says so on the Online orders sheet.

## Khayt Cloud

### A. Carry more of the order through the intake (small; `mapPlatformOrder` + `sanitizeIntake`)

The Mac reads all of these **if present** and falls back to today's behaviour if not. Add
them to the intake payload whitelist in both `index.php` and `src/store-import.js` /
`src/server.js`:

| Field | Type | Meaning |
|---|---|---|
| `paid` | boolean | The store has taken the money. Wins over everything else. |
| `paymentStatus` | string ≤32 | The platform's own word (`captured`, `authorized`, `not_paid`, `refunded` …). Used when `paid` is absent. |
| `email` | string ≤200 | Kept apart from `contact`, so a customer with both is matched by either. |
| `phone` | string ≤40 | Likewise. |
| `lines` | array ≤200 | The basket as data: `[{ name ≤200, qty int ≥1, productId? ≤100, options? { name ≤60: value ≤120 } (≤12) }]`. |

For **Medusa**: `paid` = `body.payment_status` is `captured` or `authorized` (or
`partially_captured`); `lines[]` from `body.items`: `name` = `title`, `qty` = `quantity`,
`productId` = `product.external_id` (the storefront's product sync stores the Khayt
catalogue item id there, and in `metadata.khayt_id`), `options` from the variant's options
(`variant.options[].option.title` → `value`), or from `subtitle` as `{ Variant: subtitle }`.

Keep writing `description` exactly as now. Older Macs and the desktop read the bullet block.

Why it matters: without `lines[]`, a line is matched to a product by its **exact name**, and
the customer's chosen colour is lost. Without `paid`, only Medusa orders become jobs
automatically, because a placed Medusa order cannot be unpaid. Salla, Zid and the rest wait for
a person, since they can place cash-on-delivery orders.

### B. `POST /v1/shops/{shopId}/order-status` (shop token, write role)

This is what the Mac sends (`WebStoreStatusPublisher`, `mac/KhaytCore/Sources/KhaytApp/WebStoreOrders.swift`):

```json
{ "updates": [ {
  "ref": "medusa:#1042",
  "platform": "medusa",
  "jobId": "INV-2026-0042",
  "status": "shipped",
  "trackingNumber": "SM123456",
  "carrier": "smsa",
  "carrierName": "SMSA Express",
  "trackingUrl": "https://www.smsaexpress.com/trackingdetails?tracknumbers=SM123456",
  "shippedAt": "2026-09-27T10:00:00Z",
  "deliveredAt": null,
  "updatedAt": "2026-09-27T10:00:00Z"
} ] }
```

- `status` is one of `received | printing | ready | shipped | delivered | cancelled`. Reject
  anything else **per update**, not the whole batch.
- `ref` is the platform-scoped reference the intake was filed under (`{platform}:{ref}`), ≤160.
- `trackingNumber`, `carrier`, `carrierName` and `trackingUrl` are non-null only for
  `shipped` / `delivered`. Accept `trackingUrl` only if it is http(s).
- At most **100** updates per request, and a body of at most 64 KB (→ 413).
- **Upsert** one row per `(shop, ref)`, keeping the newest by `updatedAt`. An older or equal
  `updatedAt` for the same ref is ignored. The Mac resends after losing its memory, and a
  resend must be harmless. Store a server-side `seq` (monotonic per shop) on every row that
  changes.
- Answers: **200** `{ ok: true, accepted: n, ignored: n }`, **400** `Not an order status` (the
  body is not `{updates:[…]}`), **401**, **403** viewer.
- **Never 404 for a real shop.** The Mac reads 404 (and 405) as "this cloud does not take
  order statuses" and goes quiet.
- The Mac sends the `x-delta-capable` header like every other route (it builds the request
  on `CloudReader.request`).

### C. `GET /v1/shops/{shopId}/order-status[?since={seq}]` (shop token, any role)

For the storefront, which signs in as a **viewer** member, the way it already reads
`/quote-sheet`.

- **200** `{ items: [ <update as stored, plus "seq"> ], nextSince: <max seq> }`, oldest first,
  at most 200. `Cache-Control: private, no-store`.
- `since` absent means everything that is kept. Keep rows 90 days after `delivered` /
  `cancelled`.

Add both routes to `docs/api-contract.md` and the contract suite. PHP is what serves
production, so it has to be in both backends.

## athartuwaiq3d storefront (Medusa backend)

1. **Send more from the subscriber** (`src/subscribers/khayt-order-placed.ts`, and Khayt's
   template `lib/medusa-subscriber.js` gets the same change from the Khayt lane). Add
   `payment_status`, `items.variant.options.*`, `items.variant.options.option.*` and
   `items.product.external_id` to the graph fields, so the cloud can build `paid` and `lines[]`
   (A above). No change is needed before the cloud ships A: today's payload already becomes a
   job on the Mac.
2. **A job `src/jobs/sync-khayt-order-status.ts`**, every 5 minutes, beside the catalogue sync:
   `GET /v1/shops/{KHAYT_SHOP_ID}/order-status?since=<last seq>` with the viewer token. Hold
   `since` somewhere durable, such as a one-row table or the store's metadata. Unlike the
   catalogue's ETag, losing it replays every status, which is harmless but noisy. For each
   item whose `platform` is `medusa`, find the order by `display_id` (the digits after `#` in
   `ref`), then:
   - `printing` / `ready`: set `metadata.khayt_status` (and `khayt_job`) and show it on the
     customer's order page. No fulfilment change.
   - `shipped`: if the order has no fulfilment, run `createOrderFulfillmentWorkflow` for all
     items, then `createOrderShipmentWorkflow` with `labels: [{ tracking_number,
     tracking_url, label_url: "" }]`. Medusa's shipment-created notification (the store's
     Resend provider) then tells the customer, with the tracking link.
   - `delivered`: `markOrderFulfillmentAsDeliveredWorkflow`.
   - `cancelled`: do **not** cancel or refund automatically. Flag it in admin
     (`metadata.khayt_status = cancelled`). Money back is the studio's decision.
   - Make each step idempotent against the order's current state. The same item can arrive
     twice.
3. **Tell the customer.** Email on `shipped` (with tracking) and `delivered`, in the order's
   locale, through the existing Resend provider. This is the only channel. The Mac
   deliberately does not also publish the job to Khayt's customer portal, so a web-store
   customer hears from one place.

## Checking it end to end

- The Mac's Online orders sheet lists "Became jobs" (store reference → job number, stage,
  paid). Its footnote says "Khayt Cloud cannot pass order progress to the web store yet"
  until B ships, and "Told the web store where N orders have got to" after.
- `node --test test/webstore-order.test.js` pins the update shape; the Swift suite
  `WebStoreOrdersTests` pins the request.
