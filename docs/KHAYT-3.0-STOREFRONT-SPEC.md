# Phase 3 (storefront) — Customer storefront / online ordering

**Scope:** an **opt-in**, link-accessed public catalog where a customer browses the shop's published standard products, adds them to a cart, and **places + pays for an order directly** — a self-serve sibling to the existing quote/intake flow. The order lands as a normal Khayt order via the single-writer relay. Implements the storefront slice of [Phase 2](./KHAYT-3.0-PHASE2-SPEC.md).

---

## Governing principle

The storefront is **inherently public/online**, but the shop must run **fully without it**. It is opt-in like the LAN API and Khayt Cloud: with it off, the app is byte-for-byte unchanged and no products are ever exposed. It is a **second public surface** alongside the [Phase 2 customer portal](./KHAYT-3.0-PHASE2-SPEC.md#part-b--customer-portal-web), and it **must obey the same rules**: consented per-order projection (the portal pattern, generalized to a *published-catalog* projection), unguessable tokens, per-IP throttling, and the desktop as the single writer. The public never sees the store — only what the owner deliberately publishes.

---

## What's published (the catalog projection)

A product today (`renderer/app-state.js` `products` / `K.PROD = 'hub_products_v1'`, authored in the Inventory tab — `renderer/inventory.js` ~2349) holds **cost-bearing internals**: `parts[]` with `priceTiers`, filament ids, print/prep/post times, wear/power/labor rates, failure rate, packaging, `defaultMargin`. **None of that may leave the device.** The storefront publishes a derived, owner-consented projection per published product:

| Published field | Source | Notes |
|---|---|---|
| `name` / `nameAr` | `localName(p)`, `p.nameEn` / `p.nameAr` | bilingual (Saudi market) |
| `image` | `p.thumbnail` / `p.imagePath` via `safeImageSrc` | re-hosted/data-projected; no local paths |
| `price` / **tiers** | computed from `priceTiers` × `defaultMargin` | the **customer price only** — the result of pricing, never the inputs |
| `leadTime` | new published field (see Reuse vs new) | shown as "ready in N days" |
| `description` | new published field | optional marketing copy |
| `availability` | published flag (in stock / made-to-order / hidden) | drives out-of-stock UI |

**Never projected:** `baseCost`, margin, `priceTiers.*` raw inputs, filament/material costs, times, rates, internal notes, other products' or orders' data. Pricing is computed **on the desktop** (reuse `getActivePriceTier` / the price-tier math in `lib/calculator-cost.js` and `renderer/build.js` ~320) and only the **final per-unit/tier customer price** is published. Only products explicitly marked **published** appear.

---

## Storefront flow (browse → cart → details → pay → order)

1. **Browse** — `GET /shop/:slug?t=…` (or Cloud `https://shop.khayt…/:slug`) renders the published catalog projection: grid of product cards (image, name, price/tiers, lead time, availability). Arabic/RTL + SAR by default.
2. **Cart** — client-side cart of `{ productId, qty }`. Line and order totals are **recomputed server-side** against the published projection on submit — never trusted from the client. Tier price applies by quantity (same tier semantics as the calculator).
3. **Customer details** — name, phone, optional email, delivery/pickup. This maps to the existing intake/client concept (`renderer/waiting-list.js` `resolveClientFromWaitingItem`); reuse it so a storefront customer becomes/links a client record on the desktop.
4. **VAT** — totals show 15% KSA VAT (reuse the order's existing VAT/ZATCA handling); the resulting order carries the ZATCA fields like any other.
5. **Pay** — create a payment intent via the **already-integrated rail** (`settings.bnpl` → Stripe / Tabby / Tamara, `renderer/integrations.js`). Provider secrets stay server-side; the client only gets the hosted-checkout/pay link.
6. **Order created** — on payment success (or "pay on pickup" if the owner allows), the storefront submits an **order intent** to the relay; the **desktop applies it** by running the normal creation path (`logPrint` in `renderer/order-flows.js`), producing a standard `printLog` order with `productId`, computed `price`, `paidAmount`/`paymentStatus`, `status: 'pending'`. The order then syncs/relays back; the customer sees a tracking link (reuse `ensureTrackingToken`).

---

## Reuse vs new

**Reuse (existing "catalog/cart"):** the existing catalog/cart in `renderer/build.js` (the banner ~694–711, `currentBuildFromProductId`, `quoteFromProduct`, `renderProductTierChips`) is the **internal quote-builder cart** — it appends a product's parts into `currentBuild` for the owner to quote. The storefront **does not reuse that UI** (it's owner-facing and cost-bearing), but it **reuses the same data and math**:
- the `products` collection + product authoring (Inventory tab) as the source catalog,
- the price-tier model + pricing math (`getActivePriceTier`, `calculator-cost.js`, `build.js`),
- the order-creation path `logPrint` (single source of order truth — `productId`, counters, ZATCA, payment fields),
- the public-page pattern (`lib/lan-quote-page.js` / `lib/lan-server.js`): token gen (`ensureQuoteApprovalToken`/`ensureTrackingToken`), `lanEscapeHtml`, per-IP throttle, expiry pages,
- the payment rails (`settings.bnpl`, `renderer/integrations.js`),
- the intake/client resolution (`renderer/waiting-list.js`).

**New (the public surface):**
- a **publish toggle + storefront fields** on the product (`published`, `leadTime`, `description`, `availability`) — additive to the `products` schema, defaulting off,
- a **public catalog projection** builder (analogous to Phase 2's per-order projection, generalized to "all published products"),
- the **storefront web app** (read catalog → cart → checkout) — a new public page/renderer, not the owner quote-builder,
- a **storefront order intent** → relay path (new intent type alongside Phase 2's approve/pay intents).

---

## Hosting

Two modes, same as the portal — the storefront **rides on whichever is connected**:

| Mode | Reaches | When | Status |
|---|---|---|---|
| **LAN-served** | shop PC on the same Wi-Fi (`lib/lan-server.js`) | walk-in / in-shop kiosk / same-network link | available today's model |
| **Cloud-served** | internet via Khayt Cloud | anywhere | Phase 2 |

LAN-served reuses the existing public-page routing in `lib/lan-server.js` (a new `GET /shop/...` family next to `/order/:id/quote`). Cloud-served reuses Phase 2's portal hosting + relay; the public URL becomes `https://shop.khayt…/:slug`. With **both off**, there is no storefront and the app is unaffected.

---

## Security (public surface — highest stakes; mirrors Phase 2)

- **Projection only:** the storefront serves the **published-catalog projection** and **nothing else** — never the store, never unpublished products, never cost/margin/internal fields. Asserted by construction + test.
- **Tokens:** the storefront link is gated by an unguessable, expiring storefront token (Cloud) or LAN intake-style token, reusing the existing `crypto.randomBytes` token pattern and `timingSafeEqual` verification.
- **Throttling / anti-abuse:** reuse the per-IP throttle (`lib/lan-server.js` ~1100) on the order-submitting route; bot protection / rate limits on checkout; request-size caps. Cart totals **recomputed server-side** — never trust client prices or quantities (negative/huge qty rejected).
- **Secrets server-side:** payment provider keys (`settings.bnpl`) and shop internals never reach the client. CSP, no inline secrets (Phase 2 §Security).
- **Single writer:** the public surface only emits **intents**; the desktop is the only writer. Tenant isolation (Phase 1 §8) applies to all Cloud routes.

---

## Payments

Reuse the configured rail (`settings.bnpl.{stripe|tabby|tamara}`, all SAR-capable per `renderer/integrations.js`). The storefront creates a payment intent via the active provider, redirects to hosted checkout / pay link, and the **webhook → relay → desktop** records `paidAmount`/`paymentStatus` on the order (same path as Phase 2 §B4). No new rail is added. If no rail is enabled, the owner may allow **pay-on-pickup** (order created `unpaid`) or the storefront refuses checkout.

---

## Integration points (exact files/functions)

- **Catalog source + publish fields:** `renderer/app-state.js` (`products`, `K.PROD`); authoring UI `renderer/inventory.js` (~2349 `renderProductCatalog`, `quoteFromProduct` ~2432) — add publish toggle + storefront fields.
- **Pricing projection:** `lib/calculator-cost.js` (`getActivePriceTier`, `computePartBreakdown`), `renderer/build.js` (~320 final-price math, `renderProductTierChips`) — compute customer price, drop internals.
- **Order creation:** `renderer/order-flows.js` `logPrint` (single creation path; `productId`, ZATCA, payment fields).
- **Public hosting/tokens/throttle:** `lib/lan-server.js` (route handling ~400/1100/1290; new `/shop/...` routes), `lib/lan-quote-page.js` (`ensureTrackingToken`, `lanEscapeHtml`, expiry).
- **Payments:** `renderer/integrations.js`, `settings.bnpl` (`renderer/app-state.js` ~118).
- **Client/intake:** `renderer/waiting-list.js` (`resolveClientFromWaitingItem`).
- **Relay (Cloud):** Phase 2 single-writer relay (intent → desktop apply → sync back).

---

## Edge cases

| Case | Behavior |
|---|---|
| Product unpublished / availability hidden | Not in projection; deep link → "unavailable" page |
| Out of stock / made-to-order | Show lead time ("ready in N days"); allow order if owner permits made-to-order, else disable add-to-cart |
| Lead time / due date | Projected `leadTime` shown; order's due date set on desktop at creation |
| Price/tier changed between browse and pay | Server recomputes against current projection at submit; if changed, re-confirm before charging |
| Currency / locale | SAR + Arabic/RTL default; reuse currency formatting (`fmtMoney`/`fmtPrice`) |
| VAT / ZATCA | 15% VAT shown on totals; created order carries ZATCA fields like any order |
| No payment rail enabled | Pay-on-pickup (unpaid order) if owner allows, else checkout disabled |
| Desktop offline (Cloud) | Order intent + payment queued in cloud; applies on next desktop sync; customer sees "received" + tracking link (Phase 2 failure modes) |
| Storefront off (both LAN+Cloud) | No public surface; app unaffected |
| Abandoned cart | Cart with captured contact (or started checkout) → surfaced to the owner / **ties into marketing** (follow-up nudge, mirroring the quote follow-up automation, commit `e21f98a`) |

---

## Test plan & Definition of Done

- **Projection isolation (critical):** storefront response contains **only** published fields; assert `baseCost`/margin/priceTiers-inputs/times/rates/internal notes and unpublished products **never** leak.
- **Browse → order:** published catalog renders (SAR/AR); cart → checkout → payment success → `logPrint` creates a normal `printLog` order with correct `productId`, server-recomputed price, VAT, `paymentStatus`; tracking link works.
- **Price integrity:** client-tampered price/qty rejected; tier price applied by qty server-side; price change between browse/pay forces re-confirm.
- **Payments:** intent via each enabled rail (Stripe/Tabby/Tamara); webhook → relay → `paidAmount` updates and syncs; pay-on-pickup path creates `unpaid` order.
- **Security:** unguessable/expiring token; per-IP throttle on submit; provider secrets never in client; CSP present.
- **Hosting parity:** LAN-served storefront works on-network; Cloud-served works off-network via relay; desktop-offline order queues and applies on reconnect.
- **Opt-in off:** storefront disabled → no public surface, no products exposed, app byte-for-byte unchanged.

**DoD:** with the storefront opted in, a customer can open a link, browse only the shop's **published** products (no cost/margin ever), build a cart, pay via an existing rail in SAR with VAT, and have a **normal Khayt order** created through `logPrint` via the single-writer relay — while the bulk store stays private and the shop runs fully unchanged with the storefront off.
