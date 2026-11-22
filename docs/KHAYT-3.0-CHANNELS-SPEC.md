# Global sales channels — Shopify / WooCommerce / Etsy connectors

**Scope:** add opt-in connectors that import orders from **Shopify**, **WooCommerce**, and **Etsy** into Khayt's order queue, extending the existing **Salla**/**Zid** (Saudi) integrations — using the *same* LAN webhook, secret-storage, and order-mapping mechanics, with **no Khayt Cloud dependency**.

**Governing principle:** each channel is a **drop-in adapter** over the proven Salla/Zid path. Inbound order webhooks land on the shop's own LAN server (`lib/lan-server.js`) exactly as today: HMAC-verified, replay-guarded, brute-force-locked, secret stored encrypted. **Cloud-optional** — works fully offline-of-cloud; if a key is missing or the server is off, the channel is simply inert. Cloud Phase 1+ *may later* relay these webhooks to the desktop (same payload, same handler), but that is an optimization, **not a requirement** for 3.0.

---

## 1. Channel adapter interface

Today Salla and Zid are two near-identical hand-written `else if` blocks in `lib/lan-server.js` (`/api/webhook/salla`, `/api/webhook/zid`). To make Shopify/Woo/Etsy pluggable, factor that shared shape into a small registry so adding a channel = adding one descriptor, not a new branch.

```js
// lib/channels.js — one descriptor per channel
{
  id:           'shopify',                 // matches source tag + settings key prefix
  path:         '/api/webhook/shopify',    // added to the public-path allowlist
  sigHeader:    'x-shopify-hmac-sha256',   // header carrying the HMAC
  sigEncoding:  'base64',                  // 'hex' (Salla/Zid) | 'base64' (Shopify)
  sigPrefix:    '',                        // 'sha256=' for Salla/Zid, '' for Shopify
  secretKey:    'shopifyWebhookSecret',    // settings.lanApi.<secretKey>
  mapOrder(parsed) { /* → Khayt order, see §3 */ },
  externalId(parsed) { /* stable dedup key, see §3 */ },
}
```

The LAN server iterates the registry: for a matching `pathname`, it runs the *identical* pipeline (`isWebhookAuthLocked` → require secret → HMAC compare via `safeTokenEqual` → `isReplayedWebhook` → `safeJsonParse` → `mapOrder` → `persistLanStoreUpdate` → `lan-order-updated`). Salla/Zid become two more registry entries; behavior is unchanged.

> Adapters are **pure mapping + verification config**. They do not open sockets, hold state, or call out — the LAN server owns transport, the registry owns per-channel quirks.

---

## 2. Auth per channel

Each channel is opt-in; nothing activates until its secret is saved in **Settings → LAN API**, stored encrypted via the existing pattern (`secretInputSave` / `secretInputValue` in `renderer/app-state.js`, encrypted at rest in `lib/store-io.js`, redacted on export in `renderer/store.js`).

| Channel | Inbound auth | Header verified | Encoding | Secret field (`settings.lanApi.*`) |
|---|---|---|---|---|
| Salla *(existing)* | HMAC-SHA256 | `x-salla-signature` | `sha256=`+hex | `sallaWebhookSecret` |
| Zid *(existing)* | HMAC-SHA256 | `x-zid-signature` | `sha256=`+hex | `zidWebhookSecret` |
| **Shopify** | HMAC-SHA256 (app webhook secret) | `x-shopify-hmac-sha256` | base64 | `shopifyWebhookSecret` |
| **WooCommerce** | HMAC-SHA256 (webhook secret) | `x-wc-webhook-signature` | base64 | `wooWebhookSecret` |
| **Etsy** | HMAC-SHA256 (verification token) | `x-etsy-signature` *(or shared bearer)* | base64 | `etsyWebhookSecret` |

- **OAuth note:** Shopify (OAuth/app install) and Etsy (OAuth2) issue a webhook signing secret/verification token at app-connect time — Khayt stores **that signing secret**, not the OAuth access token, because 3.0 only *receives* orders. (Pulling historical orders or pushing fulfillment back would need the OAuth token + a periodic poll; out of scope, noted for 3.1.) WooCommerce uses a webhook secret configured in WP admin; consumer key/secret are only needed for the optional REST backfill (also 3.1).
- Verification reuses `safeTokenEqual` (constant-time). Missing secret ⇒ `403` and the webhook is rejected (no unauthenticated order injection), identical to Salla/Zid.

---

## 3. Order mapping (external → Khayt order)

Each `mapOrder(parsed)` returns the same shape Salla/Zid produce today (an entry pushed onto `STORE().printLog`):

| Khayt field | Source (per channel) | Notes |
|---|---|---|
| `id` | `uniqueLanId(channel.id)` | e.g. `shopify-…`; collision-safe |
| `source` | `channel.id` | drives the badge/color in `renderer/integrations.js` (`sources` + color map) |
| `project` | `"Shopify: " + (name / line-item title)` | sliced to 100 chars |
| `client` | buyer first+last / `customer_name` | sliced to 200 chars |
| `status` | `'pending'` | enters the queue like a new Khayt order |
| `date` | `new Date().toISOString().split('T')[0]` | import date |
| `price` | order total → **converted to base** | see currency, below |
| `currency` *(new)* | external currency code (`USD`, `EUR`, …) | retained for display |
| `notes` | `"<Channel> order #<external ref>"` | carries the external reference |
| `externalKey` *(new)* | `channel.id + ':' + externalId(parsed)` | **dedup key**, see below |

- **`externalId` per channel:** Shopify `id`/`order_number`; Woo `id`; Etsy `receipt_id`. This is the stable upstream order id (not the body signature).
- **Dedup:** before push, scan `printLog` for an existing entry with the same `externalKey`; if found, **skip** (return `200 {ok:true, deduped}`). This survives process restart (unlike the in-memory signature LRU, which only stops byte-identical replays) and protects against the platform re-sending the same order under a new signature (Shopify/Woo retry semantics).
- **Currency (multi-currency):** orders may arrive in any currency. Store the raw `currency`, and compute `price` in the shop's base currency via `renderer/currency.js` `convertToBase(amount, currency)` using `settings.exchangeRates`. If no rate is configured for that currency, keep the original amount, tag `currency`, and surface a "set exchange rate" hint rather than silently mis-pricing.

---

## 4. Integration points (exact files / functions)

| Concern | File · function | Change |
|---|---|---|
| Webhook handlers | `lib/lan-server.js` — the `/api/webhook/salla` & `/api/webhook/zid` blocks | Replace the two blocks with a loop over `lib/channels.js`; reuse `isWebhookAuthLocked` / `recordWebhookAuthFailure` (line ~535), `isReplayedWebhook` (line ~40), `safeTokenEqual`, `safeJsonParse`, `persistLanStoreUpdate`, `uniqueLanId`, `lan-order-updated` |
| Public-path allowlist | `lib/lan-server.js` (~line 414) + 404 `endpoints` list (~line 1999) | Add `/api/webhook/{shopify,woocommerce,etsy}` so they bypass PIN auth like the Salla/Zid paths |
| Channel registry | `lib/channels.js` *(new)* | Descriptors incl. Salla/Zid (refactor target) |
| Secret at rest | `lib/store-io.js` (encrypt ~51, decrypt ~90, mask lists ~123/214, legacy migrate ~243) | Add `shopifyWebhookSecret`, `wooWebhookSecret`, `etsyWebhookSecret` to the encrypt/decrypt/mask arrays |
| Secret in UI | `renderer/settings.js` (LAN API section ~640, save ~1438) | Add three `secretInputValue` inputs + `secretInputSave` on save |
| Export redaction | `renderer/store.js` `redactSettingsForExport` (~line 23) | Add the three new secret keys |
| Source badge | `renderer/integrations.js` (`sources` array ~1140, color map ~1151) | Add `shopify`/`woocommerce`/`etsy` ids + brand colors |
| Currency | `renderer/currency.js` `convertToBase` / `fmtMoneyIn` | Used by `mapOrder` for non-base-currency totals |
| Imported-order behavior | `renderer/order-flows.js` `logPrint` | No change — imported orders are normal `printLog` entries and flow through the existing queue/print path |

---

## 5. Edge cases

- **Currency:** unknown/missing currency → keep raw amount + `currency` tag + UI hint (§3); never coerce to base with a phantom rate. Zero/NaN total → `price: 0` (matches current `isFinite` guard).
- **Refunds / cancellations:** 3.0 imports `orders/create`-class events only. Cancellation/refund webhooks (Shopify `orders/cancelled`, Woo `order.updated`, Etsy refund) are **verified and acknowledged `200`** but, for matched `externalKey`, only annotate the order's `notes` (e.g. "cancelled upstream") — they do **not** auto-delete or auto-refund (single-writer desktop stays in control). Owner decides. Full status sync is 3.1.
- **Duplicate webhooks:** two layers — (a) in-memory signature LRU (`isReplayedWebhook`) drops byte-identical replays; (b) persistent `externalKey` scan (§3) drops re-sends of the same order with a fresh signature. Either ⇒ `200`/`409`, never a second queue entry.
- **Offline / no key:** secret unset ⇒ `403` (channel inert, no crash). LAN server off ⇒ platform retries; on Shopify/Woo this self-heals when the shop PC is back, but a long outage may exhaust upstream retries — documented as expected (no cloud relay in 3.0). App with cloud off behaves identically to today.
- **Malformed / oversized body:** existing `MAX_BODY` 413 guard and `safeJsonParse` apply unchanged.

---

## 6. Test plan & Definition of Done

- **Adapter parity:** signed Shopify/Woo/Etsy fixtures → one `pending` order each with correct `source`, `client`, `project`, `price`, `currency`, `externalKey`; bad signature → `401` + `recordWebhookAuthFailure`; missing secret → `403`.
- **Dedup:** same order delivered twice (identical body, then re-signed body) → exactly one queue entry; assert across a simulated process restart for the persistent path.
- **Currency:** non-base currency with a configured rate → `price` in base via `convertToBase`; no rate → raw amount retained + hint; assert no silent mis-pricing.
- **Replay & lockout:** replayed signature → dropped; N failed sigs → `429` lock; reuse the Salla/Zid lockout tests as a template.
- **Secret lifecycle:** save secret → encrypted at rest (`lib/store-io.js`), masked in UI re-render, **redacted** in export (`redactSettingsForExport`).
- **Cancellation:** cancellation webhook for a known order annotates `notes`, does not delete; unknown order → `200` no-op.
- **Cloud-off / offline:** all of the above pass with no cloud; server-off → no crash, retries resume on restart.

**DoD:** an owner can paste a Shopify, WooCommerce, or Etsy webhook secret into LAN settings and have that store's orders land in the Khayt queue — HMAC-verified, dedup'd, currency-correct — using the **same** mechanism as Salla/Zid, with **zero** Khayt Cloud dependency and graceful behavior when offline or unconfigured. Adding a fourth channel later requires only a new `lib/channels.js` descriptor.
