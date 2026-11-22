# Subscriptions / recurring orders — standing orders with recurring billing

**Scope:** a first-class **subscription** (standing/repeat order) that auto-generates a normal order on a schedule — e.g. a B2B client who needs 100 brackets every month — and optionally bills each cycle. Implements [roadmap](./KHAYT-3.0-ROADMAP.md) recurring-revenue track. Reuses the quote-follow-up automation shape (`lib/quote-followup.js` + the `startQuoteFollowUpTimer` timer in `renderer/operations-extras.js`), the order factory (`renderer/order-flows.js → logPrint`), and the existing payment/invoicing rails. Can ship independent of cloud.

**Governing principle:** **local, opt-in, generates normal orders.**

- **Local-first.** The recurrence engine runs in the renderer on the shop's machine via the same `setInterval` + on-load sweep pattern as quote-follow-up. No cloud, no server cron, no AI required. A cloud-off, single-shop user gets the full feature.
- **Opt-in per subscription.** No subscription exists until the owner creates one; each can be paused or cancelled at any time. Nothing auto-charges unless the owner explicitly chose auto-charge for that subscription.
- **Generated orders are normal orders.** Each cycle materializes through the *same* `logPrint`/order model, so it flows through kanban, invoicing, ZATCA, payments, analytics with **zero special-casing downstream**. Single-writer: the engine is the only thing that creates cycle orders, and it writes them exactly as the calculator would.

> **Supersedes** the two legacy mechanisms: `processRecurringOrders` (`operations-extras.js` — clones a whole order via `order.isRecurring`/`nextDueDate`, no billing, no catch-up) and `clients[].recurring` (`notifications.js` — reminder-only). Both are migrated in §8; we keep `parentRecurringId` semantics for back-compat but route through the new model.

---

## 1. Data model

New store key `K.SUBSCRIPTIONS` (array; same `loadJSON`/`saveAll`/export plumbing as the other collections in `app-state.js`). One **subscription definition**:

```
subscription = {
  id,                  // uid('SUB')
  clientId,            // → clients[].id (required; billing/VAT need a party)
  label,               // human name, e.g. "Acme — 100 brackets / month"
  status,              // 'active' | 'paused' | 'cancelled'
  // ── contents (one of) ──
  items: [{ productId, qty }],   // preferred: catalog products (price re-resolved each cycle)
  build:  [ ...part ],           // fallback: frozen parts snapshot (same shape as currentBuild)
  margin, discountPct, shippingCost, extraLines,  // pricing knobs passed to the order
  // ── schedule ──
  interval,            // 'weekly' | 'biweekly' | 'monthly' | 'quarterly'
  anchorDay,           // optional day-of-month (1–28) or weekday for stable cadence
  startAt,             // 'YYYY-MM-DD' first run
  nextRunAt,           // 'YYYY-MM-DD' next scheduled materialization (the engine's cursor)
  endAt,               // optional 'YYYY-MM-DD' auto-cancel
  // ── billing ──
  billingMode,         // 'invoice_collect' | 'auto_charge'  (default 'invoice_collect')
  paymentMethodRef,    // for auto_charge: { service:'tabby'|'tamara'|'stripe', token? } or saved-card ref
  depositPct,          // optional per-cycle deposit (0–100), mirrors logPrint depositAmount
  // ── bookkeeping ──
  generatedOrderIds: [],   // back-links to every cycle order created
  lastRunAt,               // ISO timestamp of last successful generation
  createdAt, notes
}
```

Each **generated order** carries `subscriptionId` (back-link) and `subscriptionCycle` (1-based counter). `subscription.generatedOrderIds` is the forward link. We **also** set `parentRecurringId = subscription.id` so the legacy "recent child" guard and any existing UI keep working.

---

## 2. Recurrence engine (mirror quote-follow-up)

A **pure selector** `lib/subscriptions.js` (testable, side-effect-free), mirroring `lib/quote-followup.js`:

- `subscriptionConfig(settings)` → `{ enabled, maxCatchUp }` from `settings.subscriptions` with defaults `{ enabled:false, maxCatchUp:6 }` (added to `defaultSettings()` in `app-state.js`, OFF by default like `quoteFollowUp`).
- `advanceDate(ymd, interval, anchorDay)` → next `YYYY-MM-DD` (monthly clamps to ≤28 like `expenses.js:calcNextDueDate`; quarterly = +3 months).
- `isDueForCycle(sub, now)` → `status==='active'` and `nextRunAt <= today` and (no `endAt` or `today<=endAt`).
- `selectSubscriptionsDue(subscriptions, now)` → due list, soonest `nextRunAt` first.
- `markCyclePatch(sub, now)` → `{ nextRunAt: advanceDate(...), lastRunAt: ISO }` (writer; caller persists).

The **driver** lives beside `processQuoteFollowUps`/`startQuoteFollowUpTimer` in `operations-extras.js`:

- `processSubscriptions()` — bail if `!subscriptionConfig(settings).enabled`. For each due subscription, **materialize one order per missed cycle** (catch-up, §2.1) via `materializeSubscriptionOrder(sub)` (§4), then apply `markCyclePatch` and `saveAll()` once. Surface a toast: "Created N subscription order(s)" (same as recurring/follow-up toasts).
- `startSubscriptionTimer()` — idempotent `setInterval` every ~6h guarded by `window.__khaytSubscriptionTimer`, identical to `startQuoteFollowUpTimer`.
- On load: `app-state.js` already calls the recurring sweep + `startQuoteFollowUpTimer()` around line 590–595; add `processSubscriptions()` and `startSubscriptionTimer()` there.

### 2.1 Catch-up (app was closed over due dates)

Because the engine only runs while the app is open, `nextRunAt` may be days/weeks stale. `processSubscriptions` **loops `advanceDate` from `nextRunAt` until it passes today**, generating one order per crossed boundary, capped at `maxCatchUp` (default 6) to avoid a flood after a long closure. On hitting the cap, fast-forward `nextRunAt` to the next future date and toast a warning ("Skipped K older cycles for <label>") so the owner can decide whether to backfill manually. A per-cycle dedupe key (`subscriptionId + cycle target date`) prevents a double-open if the timer and the load-sweep race.

---

## 3. Billing (per-cycle invoice; auto-charge vs invoice-and-collect; deposits)

Each cycle order is a **normal invoice** — VAT-inclusive pricing and ZATCA QR/XML come for free via `renderer/invoicing.js → renderInvoiceForOrder` / `maybeAutoSubmitZatca` because the order looks identical to a calculator-made one (SAR base currency, `settings.vatRate`/`enableVat` applied exactly as today).

- **`invoice_collect` (default):** order is created `pending`/`unpaid` (deposit honored, §below). The owner sends the invoice/payment link exactly as now: WhatsApp via `sendPaymentReminder`/`shareInvoiceWhatsApp` (`invoicing.js`), or a BNPL/Stripe link via `openBnplModal` (`integrations.js`). No silent money movement.
- **`auto_charge`:** if `paymentMethodRef.service` has an API (`tabby`/`tamara`/`stripe`, the `hasApi:true` rows in `BNPL_CATALOG`), the engine calls the same `hubAPI.bnplTabby/bnplTamara/bnplStripe` used by `openBnplModal` to mint a charge/payment link for the cycle amount and records it on the order. We **do not** invent a new charge transport. (True card-on-file is provider-dependent; v1 mints a per-cycle link and, where the provider confirms capture, marks `paymentStatus`. Otherwise it degrades to a generated link + `invoice_collect` semantics.)
- **Deposits:** `depositPct` maps to the order's `depositAmount`/`paymentStatus`/`paidAmount` fields exactly as `logPrint` computes them today (deposit ≥ price → `paid`, >0 → `partial`).

---

## 4. Materializing a cycle (reuse `logPrint`)

`materializeSubscriptionOrder(sub)` must produce an order **identical in shape** to `logPrint`'s output (`order-flows.js`) without going through DOM inputs. Two options, prefer the first:

1. **Headless path (recommended):** load `sub.items`/`sub.build` into the calculator state (`currentBuild`, `currentBuildFromProductId`, `currentClientId`, `currentExtraLines` from `build.js`) and the pricing inputs (`#margin`, `#discountPct`, `#shippingCost`, `#depositAmount`), then call `logPrint(false)`. This guarantees one writer and one numbering path (`nextInvoiceNumber`), and fires the existing `order_created` webhook + email. After it returns, stamp `subscriptionId`/`subscriptionCycle`/`parentRecurringId` on `printLog[0]` and push its id into `sub.generatedOrderIds`.
2. **Factory extraction (cleaner, larger change):** refactor `logPrint` to accept an optional `opts` object (build, client, pricing, deposit) defaulting to reading the DOM. The engine passes `opts`; interactive use is unchanged. This removes the fragile DOM round-trip but touches the hot path — gate behind tests.

Either way, **products are re-priced at generation time** (price changes between cycles, §7): when `sub.items` is used, re-resolve each product → parts/cost from the live catalog so a price update is reflected. A frozen `sub.build` deliberately holds last-known pricing.

---

## 5. UX

- **Create:** from a client (`clients.js` editor, replacing the thin `c.recurring` toggle) or from the calculator cart ("Save as subscription" beside "Save quote/order"). Captures contents, interval, anchor/start, billing mode, deposit.
- **Manage list:** a Subscriptions panel (new tab or a Clients sub-view) showing label, client, interval, `nextRunAt`, billing mode, status, lifetime value (sum of `generatedOrderIds` revenue).
- **Pause / Resume:** `status` flips `active`↔`paused`; paused subs are skipped by the selector and do **not** accrue catch-up while paused (on resume, `nextRunAt` is fast-forwarded past today — no retroactive backfill).
- **Skip a cycle:** advances `nextRunAt` by one interval without generating an order (records a skip note).
- **Cancel:** `status='cancelled'` (terminal; kept for history/back-links, never deleted to preserve generated-order provenance).
- **Upcoming schedule view:** project the next ~6 `nextRunAt` dates per active subscription (pure `advanceDate` loop) so the owner sees what's coming — surfaced on the dashboard near the existing recurring/quote-follow-up cards, and as a notification (extend `notifications.js` recurring group rather than add a new transport).

---

## 6. Integration points (exact files / functions)

| Concern | File · symbol |
|---|---|
| Pure selector + date math | **new** `lib/subscriptions.js` (`selectSubscriptionsDue`, `advanceDate`, `markCyclePatch`) — mirrors `lib/quote-followup.js` |
| Driver + timer | `renderer/operations-extras.js` — `processSubscriptions`, `startSubscriptionTimer` (beside `processQuoteFollowUps`/`startQuoteFollowUpTimer`) |
| Order creation | `renderer/order-flows.js → logPrint` (headless reuse, §4) |
| Build/contents | `renderer/build.js` — `currentBuild`, `currentBuildFromProductId`, `snapshotPartFromForm`, product→parts |
| Collection + settings | `renderer/app-state.js` — `K.SUBSCRIPTIONS`, `defaultSettings().subscriptions`, on-load `processSubscriptions()` + `startSubscriptionTimer()` (near line 590) |
| Billing — links/charges | `renderer/integrations.js` — `BNPL_CATALOG`, `openBnplModal`, `hubAPI.bnplTabby/bnplTamara/bnplStripe` |
| Invoice / VAT / ZATCA | `renderer/invoicing.js` — `renderInvoiceForOrder`, `maybeAutoSubmitZatca`, `sendPaymentReminder` |
| Client model | `renderer/clients.js` — replace `c.recurring` toggle with a "create subscription" affordance |
| Reminders / upcoming | `renderer/notifications.js` — recurring group + dashboard card |

---

## 7. Edge cases

- **App closed over a due date:** catch-up loop (§2.1), capped by `maxCatchUp`; older skipped cycles warned, not silently dropped.
- **Price changes between cycles:** `sub.items` re-resolves catalog pricing each cycle (new price applies); `sub.build` freezes last-known pricing. Document the difference in the create UI.
- **Out-of-stock at generation:** the order is still created (we never block a standing order), but if `deductFilamentForOrder` would go negative the engine flags the order (existing low-stock toast/notification path) so the owner restocks — generation never silently consumes phantom inventory.
- **Failed payment (auto_charge):** record the failure on the order, leave it `unpaid`, and **do not** advance billing punitively — the cycle order still exists for fulfillment; the owner is notified to collect manually (degrade to `invoice_collect`). No retry storm.
- **Pause/resume:** paused subs skipped; no catch-up accrues while paused; resume fast-forwards `nextRunAt` past today.
- **Cancelled client / deleted product:** if `clientId` is gone, the sub is auto-paused with a warning (billing needs a party); if a referenced `productId` is gone, fall back to `sub.build` snapshot or pause with a fix-me notice.
- **Timer/load-sweep race:** per-cycle dedupe key (`subscriptionId + target date`) prevents double generation.
- **Clock/timezone:** all schedule dates are local `YYYY-MM-DD` compared at local midnight (same convention as `quote-followup.js` and `expenses.js`).

---

## 8. Migration

- `clients[].recurring{enabled,interval,nextDue}` → one `subscription` per enabled client (best-effort; contents left empty → owner completes before first run). Keep the old field readable but stop driving generation from it.
- Orders with `isRecurring`/`nextDueDate` → offer a one-click "convert to subscription"; the legacy `processRecurringOrders` is retained read-only for one release then removed. `parentRecurringId` semantics preserved throughout.

---

## 9. Test plan & Definition of Done

**Unit (`lib/subscriptions.js`, no DOM):**
- `advanceDate` for weekly/biweekly/monthly(28-clamp)/quarterly, and across month/year boundaries.
- `isDueForCycle` / `selectSubscriptionsDue`: respects `status`, `endAt`, `nextRunAt` ordering.
- Catch-up: N missed cycles → N targets, capped at `maxCatchUp`; dedupe key blocks doubles.
- `markCyclePatch` advances exactly one interval and stamps `lastRunAt`.

**Integration (renderer):**
- `processSubscriptions` with one due monthly sub creates exactly one `pending` order carrying `subscriptionId`/`subscriptionCycle`, links it into `generatedOrderIds`, advances `nextRunAt`.
- Generated order renders a valid VAT-inclusive invoice + ZATCA QR (reuses `renderInvoiceForOrder`) with no subscription-specific branching.
- `invoice_collect` order is `unpaid` (or `partial`/`paid` per `depositPct`); `auto_charge` mints a link via the existing BNPL path and records it.
- Pause → no generation; resume → no backfill; skip → advances without an order; cancel → terminal, history intact.

**DoD:**
- Off by default (`settings.subscriptions.enabled === false`); cloud-off / no-key user can create, pause, skip, cancel, and generate cycles.
- Every generated order is indistinguishable downstream from a calculator order (kanban, payments, analytics, ZATCA) — verified by asserting no new required field anywhere except the additive `subscriptionId`/`subscriptionCycle`.
- No double-generation across timer + load-sweep; catch-up cap honored; failed auto-charge degrades gracefully.
- `lib/subscriptions.js` is pure and unit-tested; the driver mirrors the quote-follow-up structure; `i18n` keys (en + ar) added for all new strings.
