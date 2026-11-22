# Loyalty & store credit — spec

**Scope:** turn the **existing** loyalty tiers and gift cards into one coherent rewards system: clients **earn** loyalty points / store credit on completed, paid spend and **redeem** that balance on future orders through the same path gift cards already use. Adds **referrals** (a code that drops credit onto the referred client's first order). Implements the [roadmap](./KHAYT-3.0-ROADMAP.md) loyalty track; campaigns may target loyalty segments (see [marketing spec](./KHAYT-3.0-MARKETING-SPEC.md)).

**Governing principle:** **build on what exists, keep the payment math correct.** We do **not** replace loyalty tiers (`settings.loyaltyTiers`, `getClientTier`, `renderer/clients.js:888`) or gift cards (`giftCards`, `applyGiftCard`, `renderer/operations-extras.js:299`). Store credit redeems through the **same** mechanism as a gift card — it lands in `order.giftCardDiscount`, which already participates correctly in `payStatus` (`renderer/app-helpers.js:10`), `orderOwedBase` (`renderer/currency.js:74`), and the pay modal (`renderer/order-flows.js:613`). Local-first, opt-in: nothing earns or expires unless the owner enables it.

---

## 1. Concepts & relationship

Three instruments, one redemption rail:

| Instrument | Exists? | What it is | Earned how | Redeems via |
|---|---|---|---|---|
| **Loyalty tier** | yes | a status (`name` + `discountPct`) from lifetime orders/spend | computed live from `printLog` | `discountPct` at quote time (unchanged) |
| **Loyalty points** | new | integer reward units in a per-client wallet | per SAR of paid spend × tier multiplier | converted to store credit, then redeemed |
| **Store credit** | new | a SAR balance owed to the client (refunds, referral, points cash-out) | refunds, referrals, points conversion | `order.giftCardDiscount` (same as gift card) |
| **Gift card** | yes | a transferable SAR balance with a code | issued/sold | `order.giftCardDiscount` (unchanged) |

**Earn vs redeem.** Tiers are read-only status (no change). **Points** accrue and can be **converted** to store credit at a fixed rate (`settings.loyalty.pointsPerSar` to earn, `pointValueSar` to redeem). **Store credit** and **gift cards** are interchangeable at redemption — both pay an order down. Keeping points → credit → `giftCardDiscount` as the single flow means we touch the price/paid math in exactly **one** already-correct place.

---

## 2. Data model

New `settings.loyalty` block (opt-in; absent = legacy behavior):
```
settings.loyalty = {
  enabled: false,
  pointsPerSar: 1,        // points earned per 1 SAR of countable spend
  pointValueSar: 0.05,    // SAR value of 1 point when converting to credit
  earnBasis: 'exVat',     // 'exVat' | 'incVat' — see §5
  tierMultipliers: { /* tierName: 1.5 */ },  // keyed by settings.loyaltyTiers[].name
  expiryMonths: 12,       // 0 = never
  referral: { enabled:false, creditSar: 25, requirePaidOrder:true }
}
```

Per-client wallet (new fields on the client record, defaulted on read):
```
client.wallet = {
  points: 0,              // current point balance (integer)
  credit: 0,             // current store-credit balance (SAR, base currency)
  referralCode: 'KH-AB12', // generated once, stable
  referredBy: null,       // referralCode of the inviter (set at client creation)
}
```

**Ledger** — new top-level store collection `K.LOYALTY_LEDGER` (array, same `loadJSON`/`saveAll`/export plumbing as `giftCards`). Append-only; balances are the **sum** of the ledger so they can always be re-derived (audit-friendly, see [audit spec](./KHAYT-3.0-AUDIT-SPEC.md)):
```
entry = {
  id, clientId, at,
  kind,            // 'earn' | 'redeem' | 'convert' | 'refund_reversal' | 'referral' | 'expire' | 'adjust'
  points,          // signed (+earn, −convert/expire/reversal); 0 for pure-credit entries
  creditSar,       // signed SAR (+credit added, −credit redeemed)
  orderId,         // source/target order, when applicable
  note,
}
```
Redemption never invents a new field on the order — it reuses `order.giftCardDiscount` and tags provenance via a parallel `order.creditRedemption = { ledgerId, amount }` for reporting only (does **not** affect math).

---

## 3. Earning rules

On an order **transitioning to completed AND paid** (`status === 'completed'` and `payStatus(o) === 'paid'`):
1. Compute countable spend = `orderRevenueBase(o)` adjusted to `earnBasis` (strip VAT if `exVat`, §5).
2. Look up the client's current tier via `getClientTier(clientId)`; multiplier = `tierMultipliers[tier.name] || 1`.
3. `pointsEarned = floor(countableSpend × pointsPerSar × multiplier)`.
4. Append one `earn` ledger entry (`points:+`, `orderId`), idempotent per order: re-running on an already-earned order is a no-op (check ledger for an existing `earn` with that `orderId`). This is critical because `payStatus` is recomputed often.
5. `client.wallet.points += pointsEarned` (or recompute from ledger).

Tiers themselves stay computed live by `getClientTier` — points do **not** change tier qualification (tiers remain order-count/spend based, unchanged).

---

## 4. Redemption

Redemption is implemented as a thin sibling of `applyGiftCard` (`renderer/operations-extras.js:299`) so the order-side math is byte-for-byte identical:
```
applyStoreCredit(orderId, amountSar):
  outstanding = max(0, price − paidAmount − giftCardDiscount)   // same formula as applyGiftCard
  deduct = min(client.wallet.credit, amountSar, outstanding)
  if deduct <= 0: bail (toast 'fully covered')
  client.wallet.credit -= deduct
  order.giftCardDiscount = (order.giftCardDiscount || 0) + deduct   // ← shared rail
  ledger.push({ kind:'redeem', creditSar:-deduct, orderId })
  order.creditRedemption = { ledgerId, amount: deduct }            // reporting only
  saveAll()
```
Because it writes only `order.giftCardDiscount`, **`payStatus`, `orderOwedBase`, the pay modal's `outstandingAmount()`/`paySummaryHtml()`, and the invoice gift-credit row all keep working with no change.** Points are redeemed by first **converting** to credit (`convert` ledger entry: `points:−n`, `creditSar:+n×pointValueSar`) then calling `applyStoreCredit` — never deducted from an order directly. The pay modal (`renderer/order-flows.js:626`) gains a "Use store credit" control next to the existing gift-card input, calling the same `refreshSummary()`.

---

## 5. VAT treatment (Saudi market)

Prices in Khayt are **VAT-inclusive** (`order.price`; see `renderer/invoicing.js:704` — VAT is *extracted* from the total at rate `settings.vatRate`, default 15). Decision: **points are earned on the VAT-**_exclusive_** amount** (`earnBasis: 'exVat'`, the default), since VAT is collected for ZATCA, not shop revenue — rewarding it would over-reward. Compute the ex-VAT base exactly as invoicing does:
```
exVat = settings.enableVat ? price − price*rate/(100+rate) : price   // mirrors invoicing.js:705
```
**Store credit / gift-card redemption is VAT-inclusive** (it pays down `order.price`, which already includes VAT) — no change to existing gift-card behavior, which is correct today. The owner may switch earning to `incVat` in settings; the default is `exVat`.

---

## 6. Referrals

- Each client gets a stable `wallet.referralCode` (generated lazily on first display).
- New client can be created with `referredBy = <code>` (entered at client creation, or via a portal link param).
- When the referred client's **first** order goes completed+paid (and `referral.requirePaidOrder`), append a `referral` ledger entry crediting the **referred** client `referral.creditSar` (and optionally the inviter — out of scope v1; single-sided to start). Idempotent: only fires once per referred client (guard on existing `referral` ledger entry for that `clientId`).
- Self-referral and circular referral are rejected (`referredBy` cannot equal own code).

---

## 7. Integration points (exact files/functions)

- `renderer/app-state.js` — declare `loyaltyLedger = []`, add to load/save/export lists alongside `giftCards` (`:250`, `:335`, `:425`); default `client.wallet` and `settings.loyalty` on read.
- `renderer/operations-extras.js` — add `applyStoreCredit`, `convertPointsToCredit`; mirror `applyGiftCard` (`:299`). Reuse the same outstanding formula.
- `renderer/order-flows.js` — pay modal (`:626`): add store-credit control beside the gift-card input; both feed `order.giftCardDiscount` and `refreshSummary()`. Do **not** alter `onSave` paid math (`:690`).
- `renderer/clients.js` — `getClientTier` (`:888`) unchanged; surface wallet balance + tier badge in the client row (near `:184`); earn hook reads `getClientTier`.
- Earn trigger — a single `awardLoyaltyForOrder(order)` called wherever an order becomes completed+paid (status change handler and `recordPayment` `onSave`), idempotent per order.
- `renderer/settings.js` — extend the loyalty section (`renderLoyaltyTiersSettings`, `:433`) with the new `settings.loyalty` fields (points rate, point value, earn basis, per-tier multipliers, expiry, referral).
- `renderer/invoicing.js` — no math change; optionally show redeemed store credit using the **existing** gift-credit row (`:71`). `payStatus`/`orderOwedBase`/`zatcaInvoiceAmounts` untouched.
- `renderer/integrations.js` — accounting export: store-credit redemption mirrors the gift-card "liability/AR" rows (`:628`); see [accounting spec](./KHAYT-3.0-ACCOUNTING-SPEC.md).

---

## 8. Edge cases

- **Refund / credit note** (`generateCreditNote`, `renderer/invoicing.js:1099`): on credit, append a `refund_reversal` entry clawing back points earned on that order (proportional to the credited fraction), floored at 0 balance. Refund value itself may optionally be issued **as store credit** instead of cash (a `+creditSar` entry) — opt-in.
- **Order un-completed / voided** (`order.voidedAt`, `creditedAt`): reverse the matching `earn` entry; redeemed credit on a voided order is returned to the wallet (`+creditSar` reversal).
- **Expiry**: points/credit older than `expiryMonths` expire via a passive sweep on load (append `expire` entries); `0` = never. Never expire mid-session silently without a ledger record.
- **Partial redemption**: `deduct = min(balance, requested, outstanding)` — supports paying part of an order, leaving residual balance; combinable with gift cards and cash (all accumulate into `giftCardDiscount`).
- **Overpay guard**: redemption is clamped to `outstanding`, so `paidTotal` can never exceed price → `payStatus` cannot wrongly read 'paid' beyond the bill (matches `applyGiftCard` clamping today).
- **Idempotency**: earn/referral/reversal each guard on an existing ledger entry for the `(kind, orderId|clientId)` pair — safe under repeated `payStatus`/save cycles.
- **Currency**: balances stored in **base currency**; redemption applies in the order's currency via `convertToBase`/`curOf` like `orderOwedBase` already does.

---

## 9. Test plan & DoD

**Unit (pure):** `pointsEarned` (floor, tier multiplier, exVat vs incVat); `convertPointsToCredit` rounding; ledger-sum == wallet balance invariant; referral single-fire; refund proportional clawback.

**Integration / regression (must not break 2.7):**
- `payStatus` and `orderOwedBase` give identical results whether an order is paid down by gift card or by store credit (same `giftCardDiscount` value).
- Pay modal: applying store credit then cash → outstanding and `paymentStatus` match the existing gift-card path exactly.
- Overpay: requesting more credit than outstanding redeems only the outstanding amount; never 'paid' beyond price.
- Existing gift-card flow unchanged (snapshot test on `applyGiftCard`).
- VAT: earn on a 115 SAR (incl. 15% VAT) order at `pointsPerSar:1, exVat` = 100 points × multiplier.

**DoD:** loyalty disabled by default → zero behavior change; with it enabled, points earn on completed+paid orders, redeem through `giftCardDiscount` with payment math intact, referrals credit once, balances reconcile to the ledger, refunds/voids reverse correctly, and all 2.7 payment tests stay green.
