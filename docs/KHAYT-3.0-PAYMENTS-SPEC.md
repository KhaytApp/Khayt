# Deposits & flexible payment plans — unify deposits, installments & BNPL

**Scope:** one coherent payment-plan model that consolidates the three money flows that are currently parallel: ad-hoc **deposits** (`order.depositAmount`, seeded into `paidAmount` at creation), **milestone invoices** (`order.milestoneInvoices[]`, billing-only %), and **BNPL** (`settings.bnpl.*` → Tabby/Tamara/Stripe payment links). The goal is a single `order.paymentPlan` schedule that *records* money against the one balance the app already trusts — never a second ledger. **Local-first**, Saudi-first (SAR, VAT-inclusive prices, ZATCA). Implements the 3.0 roadmap payments item.

---

## 1. Governing principle

**`payStatus(order)` stays the single source of truth.** It already derives paid/partial/unpaid/voided from `price`, `paidAmount`, `giftCardDiscount`, and `creditNotes[]` (`renderer/app-helpers.js`); `orderOwedBase(o)` (`renderer/currency.js`) computes the balance from the same fields. The 2.7 work made these correct (credit notes reduce the *effective price*, never `paidAmount`; full credit sets `creditedAt`). **This spec adds NO new way to compute paid/owed.** A payment plan is a *schedule and a UI* over `paidAmount`; collecting an installment ⇒ increases `paidAmount` ⇒ `payStatus`/`orderOwedBase` already react. If the plan and `paidAmount` ever disagree, `paidAmount` wins.

---

## 2. Concepts (one model)

- **Deposit** — money received *before completion*. Today: `depositAmount` set at order creation, copied into `paidAmount`. Becomes plan installment #1 with `paidAt` set immediately.
- **Milestone** — a *billing* event ("50% to start, 50% on delivery"): issues a partial invoice (`generateMilestoneInvoice`) but does **not** record cash. Becomes a plan installment whose `dueDate` is event-driven and whose `invoicedAt` mirrors today's `milestone.issuedAt`.
- **Installment** — a *collection* event: scheduled `{dueDate, amount}` that, when collected, raises `paidAmount`. This is the existing order-editor `instalments[]` (`{amount, paid}`) given dates and a home on the order.
- **BNPL (Tabby/Tamara/Stripe)** — the customer pays the shop in full *now* via a link; the *provider* handles the customer's installments. To Khayt it is **one payment**, not a schedule.

These collapse into **one schedule of dated amounts**. The only axis that differs is *what each entry means*: invoice-only (milestone) vs. cash-recording (deposit/installment) vs. external-settled (BNPL). `planType` captures intent; `schedule[].paidAt` captures reality.

---

## 3. Data model

Additive fields on the order (all optional; absent ⇒ legacy behavior unchanged):

```
order.paymentPlan = {
  planType: 'deposit' | 'installments' | 'milestones' | 'bnpl' | null,
  depositAmount: Number,          // mirrors existing order.depositAmount (keep both in sync)
  schedule: [ {
    id, label,                    // e.g. "Deposit", "On delivery"
    amount: Number,               // SAR, VAT-inclusive (same basis as order.price)
    percentage?: Number,          // optional; amount is authoritative if both set
    dueDate?: 'YYYY-MM-DD',       // null for event-driven milestones
    invoicedAt?: 'YYYY-MM-DD',    // mirrors milestoneInvoices[].issuedAt when an invoice was generated
    paidAt?: 'YYYY-MM-DD',        // set ⇒ collected; drives paidAmount
    method?: String,              // reuse pay.method.* (cash/mada/transfer/stcpay/…)
    bnplProvider?: 'tabby'|'tamara'|'stripe',
    bnplUrl?: String,
  } ],
}
```

**Composition rule (the only invariant that matters):**
`order.paidAmount === Σ schedule[i].amount where schedule[i].paidAt is set`, then clamped to `[0, price]` exactly as today. `giftCardDiscount` and `creditNotes[]` are untouched and continue to be subtracted by `payStatus`/`orderOwedBase`. `order.milestoneInvoices[]` is kept as the render-time projection of milestone-type entries so `generateMilestoneInvoice` keeps working unchanged; the plan owns the truth, milestones are derived.

Persistence: plan rides inside the order in the existing store; **no secrets** added (BNPL keys already live in `settings.bnpl.*`, encrypted/masked in `lib/store-io.js`). Nothing new to redact.

---

## 4. Flows

1. **Take a deposit at quote-accept.** In `approveQuote` (`renderer/invoicing.js`) offer "Take deposit" → write `paymentPlan.planType='deposit'`, push one collected entry `{label:'Deposit', amount, paidAt:today}`, set `order.depositAmount` and recompute `paidAmount` from the schedule. The existing creation-time `depositAmount` path (`renderer/order-flows.js`) becomes a thin wrapper that seeds the same single-entry plan.
2. **Define an installment schedule.** Extend `openMilestoneInvoices` (`renderer/app-exports.js`) into a unified "Payment plan" editor: pick `planType`, add rows by % or amount (auto-amount from % already exists), assign `dueDate`. Validation: `Σ amount ≤ price` (warn, don't block — over-schedule is allowed for change orders), percentages need not sum to 100.
3. **Record / collect an installment.** Reuse `openPaymentModal` (`renderer/order-flows.js`): when a plan exists, show its rows with a "Collect" action per row; collecting sets `paidAt`+`method` and recomputes `paidAmount = Σ paid`. This replaces the order-editor's ad-hoc `instalments[]` recompute (lines ~1382-1388) with the same arithmetic over the plan. Manual "amount paid" still works and stays clamped to `price`.
4. **Balance + payStatus reflect it automatically.** No new computation — `paidAmount` changed, so `payStatus` (paid/partial/unpaid), `orderOwedBase`, client statement (`generateClientStatement`), dashboard outstanding, and accounting export (`exportAccountingCSV`, which already emits per-`paidAmount` payment rows) all update. Fire the existing `payment_received` webhook + `autoSendEmailNotification` on each collection.

---

## 5. Reminders (due-installment nudges)

Mirror `lib/quote-followup.js` exactly: add a **pure** selector `lib/payment-plan.js` →
`selectInstallmentsDue(orders, settings, now)` returning rows where `planType` is collecting, `paidAt` is unset, `dueDate` is within `windowDays`/`graceDays`, deduped by a per-entry `remindedAt`+`reminderCount` (cooldown/maxCount), and the order is not voided/credited/fully paid. Reuse `markFollowUpPatch`'s shape (`markReminderPatch`). Surface in `renderer/notifications.js` as a new "Installments due" group alongside Expiring Quotes, and send via the existing `sendPaymentReminder` transport (WhatsApp `hubAPI.shareWhatsApp` with wa.me fallback). Opt-in under `settings.paymentPlan = {enabled, windowDays, graceDays, cooldownDays, maxCount}`, off by default — same gating as `settings.quoteFollowUp`.

---

## 6. BNPL alignment

BNPL is `planType:'bnpl'` — a **single** schedule entry, not a multi-row schedule (the provider, not Khayt, splits it). `openBnplModal` (`renderer/integrations.js`) keeps generating Tabby/Tamara/Stripe links from `settings.bnpl.*`; on link generation, write `{bnplProvider, bnplUrl, amount: price}` onto the entry. Settlement is **manual** (local-first: no inbound webhook assumed) — marking the BNPL entry collected sets `paidAt` and raises `paidAmount` like any other collection, so the customer's provider-side installments never leak into Khayt's balance. The 23-service `BNPL_CATALOG` and non-API directory cards are unchanged.

---

## 7. Integration points (files / functions)

- `renderer/app-helpers.js` — `payStatus` (unchanged; the contract).
- `renderer/currency.js` — `orderOwedBase` (unchanged; the balance).
- `renderer/order-flows.js` — creation `depositAmount`→plan seed; `openPaymentModal` per-row collect; remove ad-hoc `instalments[]` recompute in the editor in favor of the plan.
- `renderer/app-exports.js` — `openMilestoneInvoices` → unified plan editor.
- `renderer/invoicing.js` — `approveQuote` (deposit-on-accept hook); `generateMilestoneInvoice` (now reads milestone-type entries), `generateCreditNote` (unchanged).
- `renderer/integrations.js` — `openBnplModal` writes the BNPL entry.
- `renderer/notifications.js` + new `lib/payment-plan.js` — due-installment selector & group.
- `renderer/app-state.js` — default `settings.paymentPlan`.
- `lib/store-io.js` — no change (no new secrets).

---

## 8. Edge cases

- **Overpayment / over-schedule.** `paidAmount` stays clamped to `price` (existing rule in `openPaymentModal` and the editor). Σ collected > price ⇒ clamp, surface "fully paid", don't error. Over-*scheduling* is allowed and only warned.
- **Refund / credit-note interaction.** Credit notes still reduce *effective price* via `creditNotes[]` only — never `paidAmount`, never a schedule entry. A refund of a collected installment = issue a credit note (don't un-set `paidAt`), preserving the 2.7 invariant and `orderOwedBase`. Full credit ⇒ `creditedAt` ⇒ `payStatus='voided'`; reminders must skip such orders.
- **VAT timing on deposits.** Prices are VAT-inclusive (`renderInvoiceForOrder` extracts the VAT portion). A deposit/milestone installment is a fraction of the inclusive total, so its VAT is the same inclusive fraction — no separate tax math. ZATCA submission still fires on the **completed full order** (`maybeAutoSubmitZatca`), not per installment; milestone invoices remain proforma-style partials, consistent with today.
- **Plan edit mid-stream.** Editing/deleting an *uncollected* entry is free. A *collected* entry is locked (un-collecting requires a credit note, per above). After any edit, recompute `paidAmount = Σ paid` and re-derive `payStatus`. Reducing `price` below Σ paid re-clamps `paidAmount` (existing editor logic).

---

## 9. Test plan & DoD

- **Composition invariant:** for any schedule, `paidAmount === Σ amount where paidAt set` (clamped); `payStatus`/`orderOwedBase` match a hand-computed balance.
- **No regression (2.7):** credit note reduces owed without touching `paidAmount`; full credit ⇒ `voided`; gift card still credits down. Reuse existing payStatus/credit-note tests.
- **Deposit-on-accept:** `approveQuote` + deposit ⇒ one collected entry, `partial` (or `paid`), correct balance.
- **Installments:** schedule of 3, collect 2 ⇒ `partial`, owed = remaining; collect 3rd ⇒ `paid`.
- **Reminders (pure):** `selectInstallmentsDue` honors window/grace/cooldown/maxCount, skips voided/credited/paid; no-network unit test like `quote-followup`.
- **BNPL:** generating a Tabby link writes one `bnpl` entry; manual settle ⇒ `paidAmount = price`, `paid`; provider split never appears in Khayt.
- **VAT/ZATCA:** installment carries proportional inclusive VAT; ZATCA submits once on completion, unchanged.
- **No-plan:** legacy orders (no `paymentPlan`) behave exactly as before; secrets export unchanged.

**DoD:** a single plan editor drives deposits, installments, milestones, and BNPL; every collection moves only `paidAmount`; `payStatus`/`orderOwedBase` remain the sole source of paid/owed with zero 2.7 regressions; due-installment nudges ship opt-in via the existing notification + WhatsApp path; no new secrets or parallel money model.
