# Shipping & fulfillment — Saudi carriers

**Scope:** close the order lifecycle (quote → print → ship → deliver) by integrating Saudi carriers (**SMSA, Aramex, Saudi Post / SPL**): generate shipping labels + tracking numbers, attach them to orders, and surface live tracking to the customer via the existing tracking-token portal. Builds on [Phase 2](./KHAYT-3.0-PHASE2-SPEC.md).

**Governing principle:** **cloud-optional, manual-first.** Core fulfillment tracking is a local order field that works with zero internet and zero API keys — a user can always type a carrier + tracking number by hand. Carrier API calls (label generation, status polling) are an **opt-in** enhancement layered on top, never a dependency. Carrier credentials are opt-in and stored with the **existing encrypted-secret pattern** (`secretInputSave` / `redactSettingsForExport`). Offline, no key, or carrier down → graceful degradation to manual entry; nothing in the order flow breaks.

**Big reuse win:** the customer tracking surface **already exists** (`ensureTrackingToken` / `buildLanOrderTrackingUrl` → `lib/lan-quote-page.js`), and the inbound-carrier-webhook + secret-storage plumbing **already exists** for Salla/Zid (`lib/lan-server.js`, `renderer/settings.js`). Shipping reuses both — it does not reinvent tokens, webhooks, or secret handling.

---

## Data model changes

New fields on the `printLog` order object (set in `logPrint`'s order literal as nulls, populated at ship time). The order **already** carries free-text `courierName` / `trackingNumber` / `deliveryAddress` (see `openOrderEditor`); shipping formalizes and extends them — keep the existing fields, add the structured ones:

| Field | Type | Notes |
|-------|------|-------|
| `carrier` | string\|null | `'smsa' \| 'aramex' \| 'spl' \| 'manual' \| 'other'` (adapter id) |
| `trackingNumber` | string\|null | carrier AWB / waybill; reuses the existing free-text field |
| `labelUrl` | string\|null | local path to saved label PDF (under `userData/labels/<id>.pdf`) or data URL |
| `shippedAt` | ISO string\|null | set when shipment is created |
| `shippingStatus` | string\|null | `'unshipped' \| 'label_created' \| 'in_transit' \| 'out_for_delivery' \| 'delivered' \| 'exception'` |
| `shippingHistory` | array | `[{ status, at, note, source }]` — mirrors `statusHistory` shape; `source` = `'manual' \| 'webhook' \| 'poll'` |
| `shippingService` | string\|null | carrier service level (e.g. SMSA "Domestic Express") |
| `shipmentMeta` | object\|null | adapter-returned extras (zone, cost in SAR, piece count) — internal, never projected |

`deliveredAt` (already exists) remains the canonical "delivered" timestamp; a `delivered` shipping webhook also calls `markDelivered`. Arabic addresses: `deliveryAddress` is free-text UTF-8 already — adapters must send it verbatim and set request encoding/`Accept-Language` so carrier labels render Arabic.

---

## Flow / UX

1. **Create shipment** — new "Ship" action on a `completed` order (Kanban card + order editor). Opens a modal pre-filled with client address (reusing the existing address-book `<select>` in `openOrderEditor`), carrier dropdown, and service level. Carrier list is filtered to those with credentials configured, plus always-available **"Manual"**.
2. **Label + tracking** — on save:
   - *API path* (key present, online): call the carrier adapter `createShipment()` → returns `{ trackingNumber, labelUrl, service, meta }`; save label PDF to `userData/labels/`, set `shippingStatus='label_created'`, `shippedAt=now`.
   - *Manual path* (no key / offline / "Manual" / API error): user types carrier + tracking number; same fields persist, `labelUrl` null, `shippingStatus='label_created'`. A toast explains the API fallback when it triggers.
3. **Status sync** — `shippingStatus` advances via (a) carrier **webhook** (preferred, see Integration points) or (b) a manual "Update shipping status" picker. No polling required for v1; optional poll is best-effort and skipped offline.
4. **Customer portal** — the existing tracking page (`lib/lan-quote-page.js`, reached via `buildLanOrderTrackingUrl`) gains a shipping block: carrier name, tracking number, a deep link to the carrier's own tracking page, and the `shippingStatus` timeline. Projected fields are **status, carrier, tracking number, deep link only** — never `shipmentMeta`, cost, or internal notes (consistent with Phase 2 §B3 projection rules).

---

## Carrier integration (pluggable adapters)

A common adapter interface so SMSA / Aramex / SPL are interchangeable and a fourth carrier is a drop-in. New module `renderer/carriers.js` (renderer side, mirroring `integrations.js`), with network calls proxied through the main process (`window.hubAPI`) like `fireWebhook`.

```js
// Each adapter implements:
{
  id: 'smsa',                       // matches order.carrier
  label: { en: 'SMSA', ar: 'سمسا' },
  services: [{ id, label }],        // service levels for the dropdown
  configFields: [{ key:'apiKey', secret:true }, { key:'accountNumber' }],
  async createShipment(order, cfg) {// -> { trackingNumber, labelUrl, service, meta } or throws
  },
  trackingUrl(trackingNumber),      // carrier's public tracking deep link
  parseWebhook(body, headers, cfg), // -> { trackingNumber, shippingStatus, at } | null
}
```

- A registry `CARRIERS = { smsa, aramex, spl, manual }`; `manual` implements only `trackingUrl` (best-effort) and a no-op `createShipment` that just records the typed number.
- **Status normalization:** each adapter maps carrier-specific codes to the canonical `shippingStatus` enum above, so the portal and history are carrier-agnostic.
- **Secrets:** per-carrier config lives under `settings.shipping.<carrierId>` (e.g. `settings.shipping.smsa.apiKey`), saved via `secretInputSave` and rendered via `secretInputValue` / `secretFieldPlaceholder` in a new Shipping section of `renderer/settings.js`. Add each `apiKey` to `redactSettingsForExport` (alongside the `lanApi` / `bnpl` masks) so secrets are masked on export.

---

## Integration points (exact files / functions)

- **`renderer/order-flows.js`** — `logPrint`: add the new fields (nulls) to the order literal. `updateStatus`: shipping is **orthogonal** to print status (don't add a Kanban column); the "Ship" action lives off the `completed` state. A `delivered` shipping update calls the existing `markDelivered(orderId)`. Fire a new `fireWebhook('order_shipped', {...})` at shipment creation, mirroring the existing `order_created` / `status_changed` calls.
- **`renderer/util.js`** — reuse `ensureTrackingToken` / `buildLanOrderTrackingUrl` unchanged; the shipping block rides the same tokenized URL.
- **`lib/lan-quote-page.js`** — extend the tracking page render (after the status block) with the projected shipping fields; reuse its existing escaping and the dark-card layout.
- **`lib/lan-server.js`** — add inbound carrier webhook routes mirroring the Salla/Zid handlers exactly: HMAC verify against `settings.shipping.<carrier>.webhookSecret`, `isReplayedWebhook` guard, `isWebhookAuthLocked` / `recordWebhookAuthFailure` lockout, then `parseWebhook` → update the matching order's `shippingStatus` + `shippingHistory`. Routes: `/api/webhook/smsa`, `/api/webhook/aramex`, `/api/webhook/spl` (add to the public-path allowlist).
- **`renderer/settings.js`** — new Shipping settings section: per-carrier enable toggle, credential fields (encrypted), webhook secret, displayed webhook URL (reuse `updateWebhookUrlDisplay` pattern).
- **`renderer/store.js`** — `redactSettingsForExport`: mask `settings.shipping.<carrier>.apiKey` + `.webhookSecret`.

---

## Edge cases

- **Offline / no key:** "Ship" modal still opens; API carriers are visible but selecting one with no connectivity falls through to manual entry with a clear toast. No throw, no data loss.
- **Carrier API error / timeout:** caught in `createShipment`; the modal stays open and offers manual entry (tracking number field unlocked). Partial success (tracking number but no label) persists what came back.
- **Duplicate / replayed webhook:** `isReplayedWebhook` guard (already in `lan-server.js`) drops it; status only advances, never regresses (ignore an `in_transit` arriving after `delivered`).
- **Webhook for unknown/deleted order:** matched by `trackingNumber`; no match → 200 + ignore (don't leak existence).
- **Re-shipping / reprint:** re-opening a delivered order (existing `updateStatus` clears `completedAt`) must also clear `shippingStatus`/`trackingNumber` only if the user explicitly re-ships; otherwise keep the prior shipment.
- **Arabic address round-trip:** label and webhook payloads preserve UTF-8; assert no mojibake in the saved label and the portal.
- **Export:** redacted export must never contain a real carrier key (covered by the redaction mask).

## Test plan & Definition of Done

- **Manual path (no internet, no key):** ship a completed order with carrier=Manual + typed tracking number → fields persist, portal shows carrier + number + deep link; zero network calls.
- **API path (mocked adapter):** `createShipment` returns tracking + label → label saved under `userData/labels/`, `shippedAt`/`shippingStatus` set, `order_shipped` webhook fires.
- **API failure → fallback:** adapter throws → modal degrades to manual entry; order still ships.
- **Inbound webhook:** signed SMSA/Aramex/SPL payload → `shippingStatus` advances + `shippingHistory` appended; bad signature rejected; replayed delivery dropped; `delivered` triggers `markDelivered`.
- **Portal projection:** tracking page exposes only status/carrier/number/deep link — assert `shipmentMeta`, cost, internal notes never leak (Phase 2 §B3 parity).
- **Secret hygiene:** carrier keys masked in `exportData()`; redacted re-import doesn't clobber stored keys (`secretInputSave` mask behavior).
- **Adapter pluggability:** adding a stub fourth carrier requires only a registry entry — no changes to order-flows, util, or the portal renderer.

**DoD:** a user can mark a completed order shipped — by hand with no internet, or via a configured Saudi carrier that returns a real label + tracking number — and the customer sees live shipping status on the same tokenized tracking link, with carrier secrets encrypted, redacted on export, and the feature fully functional offline.
