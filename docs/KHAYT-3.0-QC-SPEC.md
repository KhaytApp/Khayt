# Quality control, reprint & RMA workflow — spec

**Scope:** promote the existing QC badge/status into a real pass/fail inspection stage with defect tracking, link reprints back to their original order with a reason, and handle customer RMA/warranty reprints — all on the **existing** kanban stage, `qc*` order fields, `reprintOrder`, and status lifecycle. Implements [roadmap](./KHAYT-3.0-ROADMAP.md) QC line.

**Governing principle:** QC is a **decision recorded on the order**, not a parallel system. The `qc` kanban stage stays the single inspection gate; **pass** advances to `completed` (deducting material once, as today), **fail** logs a defect + waste and offers a linked reprint. A reprint is a **new order that points back** at the one it replaces; it never edits or "un-deducts" the failed job. Everything is opt-in and local-first — no cloud required; cloud only relays the same fields if a tenant is connected.

---

## 1. Data model (expand existing fields, do not rename)

Today an order carries `status`, `statusHistory[]`, `qcNotes`, `qcPassedAt`, `qcFailedAt`, `materialDeducted` (`renderer/order-flows.js` `logPrint`, `qcPassOrder`, `qcFailOrder`). Add **non-breaking** optional fields:

```
// QC result (set by the qc stage)
qcStatus:    'pending' | 'pass' | 'fail' | null   // explicit, derived-compatible with qcPassedAt/qcFailedAt
defects:     [ { type, severity:'minor'|'major', note, photoRef?, at } ]  // type = waste failureType vocab
inspector:   operatorId | null                    // reuse operators[] (operatorBadge)
qcAt:        ISO string                            // alias of qcPassedAt/qcFailedAt for the active decision

// Reprint linkage (on the NEW order produced by a reprint)
reprintOf:    originalOrderId | null
reprintReason:'qc_fail' | 'rma' | 'manual'
reprintCost:  'shop' | 'billable'                  // who eats material/labor; drives pricing + analytics
reprintChain: rootOrderId | null                   // first order in a reprint→reprint chain (for SLA roll-up)

// On the ORIGINAL order (back-reference, mirror of duplicate/split pattern)
reprintedInto:[ newOrderId, ... ]                  // like splitInto[]

// RMA / warranty (on the original delivered order)
rma: { reportedAt, reportedBy, reason, withinWarranty:bool, resolution:'reprint'|'refund'|'declined', reprintId? } | null
```

Backfill: `qcStatus` is derived on read when absent — `qcPassedAt → 'pass'`, `qcFailedAt → 'fail'`, in `qc` stage → `'pending'`. No migration needed; new fields are written lazily. `defaultSettings.qc = { enabled:false, requireInspector:false, warrantyDays:30, requirePhotoOnFail:false }` added to `renderer/app-state.js` next to `staleHours`/`wipLimits` (which already reference `qc`).

---

## 2. QC flow (kanban `qc` stage → pass / fail)

The `qc` stage already exists in the lifecycle (`pending→printing→post→qc→completed`; see `clients.js` `statusSteps`, `app-state.js` `staleHours.qc`/`wipLimits.qc`). Cards entering `qc` get a **QC action group** (reuse the existing pass/fail handlers):

1. **Inspect** — `qcPassOrder` / `qcFailOrder` modals gain (a) optional inspector select (operators), (b) defect rows on fail (type from the existing `waste.ft.*` vocab + severity + note + optional photo).
2. **Pass** (`qcPassOrder`, order-flows.js ~372): set `qcStatus='pass'`, `inspector`, `qcAt`, advance to `completed`, deduct material/packaging **once** (existing idempotent `deductFilamentForOrder`/`deductPackagingConsumables`, guarded by `materialDeducted`). Unchanged behavior, new fields recorded.
3. **Fail** (`qcFailOrder`, order-flows.js ~422): keep current waste-entry creation (`wasteLog` row with `failureType`, weight, cost) and set `qcStatus='fail'`, push `defects[]`, set `qcAt`. **Change:** instead of silently flipping `status='pending'`, present two choices — **Scrap** (stop here; order stays terminal-failed) or **Reprint** (§3). The wasted filament was already deducted on print completion and the waste row already captures it — that accounting is **not** reversed.

`qcBadge` (kanban.js ~157/634): extend so it reflects `qcStatus` — green ✅ pass (as today), red ❌ fail, grey ⏳ awaiting QC. Inspector initials shown when `requireInspector`.

---

## 3. Reprint flow (clone + link, with correct material accounting)

`reprintOrder` (order-flows.js ~1666) already clones an order's parts into the calculator cart. Extend it (and add an internal `createLinkedReprint(original, reason, costMode)` used by both QC-fail and RMA) so the resulting order, when saved via `logPrint`, carries:

- `reprintOf = original.id`, `reprintReason`, `reprintCost`, `reprintChain = original.reprintChain || original.id`.
- Push `original.id` into `original.reprintedInto[]` (mirror of `splitInto[]`).

**Material/cost — the core correctness rule.** The failed print's filament is *already gone* (deducted at completion, recorded in `wasteLog`). The reprint is a **fresh order** that will deduct its **own** filament when *it* passes QC. So total filament consumed = failed job + reprint, which is physically correct — **do not** touch `materialDeducted` on the original. Who pays:

| `reprintCost` | When | Price to customer | Material cost lands as |
|---|---|---|---|
| `shop` | shop's fault (warping, nozzle jam, operator error, design issue) | **0 SAR** (no new invoice line; or zero-priced) | shop waste/COGS — the original waste row already books the loss |
| `billable` | customer-caused (changed spec, customer-supplied bad file) | normal calculator price | new revenue order |

QC-fail defaults `reprintCost='shop'` (internal defect); the modal lets the owner override to `billable`. The reprint is a normal order from there on — queue, print, QC again — so chains are handled by the same loop.

---

## 4. RMA / warranty flow (customer-reported defect)

For a **delivered** order a customer reports a problem after the fact. Add **Open RMA** to the order actions (delivered orders only):

1. Modal records `rma = { reportedAt, reportedBy, reason, withinWarranty, resolution }`. `withinWarranty` is auto-suggested from `deliveredAt + settings.qc.warrantyDays` (Saudi market: dates/labels Arabic-aware, amounts SAR).
2. Resolution **reprint** → `createLinkedReprint(original, 'rma', 'shop')` (no charge) and set `rma.reprintId`. Resolution **refund**/**declined** just record the outcome.
3. The RMA reprint flows through the normal queue → `qc` → pass like any order; its own material deducts when it passes. The original delivered order is untouched (revenue stays recognized; the reprint is a cost of warranty).

---

## 5. Integration points (exact files / functions)

- `renderer/order-flows.js` — `qcPassOrder` (~372): write `qcStatus/inspector/qcAt`. `qcFailOrder` (~422): add `defects[]`, severity, photo; replace auto-requeue with Scrap/Reprint choice; keep `wasteLog` write. `reprintOrder` (~1666) → add `createLinkedReprint()`; set `reprintOf/reprintReason/reprintCost/reprintChain` so `logPrint` persists them. `updateStatus` (~230): keep the reopen guard that clears `materialDeducted` — **must not** run for linked reprints (they are new orders, not reopens).
- `renderer/app-state.js` — add `settings.qc` defaults near `staleHours`/`wipLimits` (~145/185); document new order fields.
- `renderer/kanban.js` — `qcBadge` (~157/201/634): render pass/fail/awaiting from `qcStatus`; reprint cards show `↳ reprint of #orig` (reuse `kanbanSubBadge` style).
- `renderer/clients.js` — `statusSteps` stepper (~1048) unchanged; client view lists that client's RMAs / reprint chains (extends the existing per-client order list, ~1046).
- `renderer/analytics.js` — §6.
- `renderer/integrations.js` — webhooks/Telegram: fire `qc_failed` and `rma_opened` alongside existing order events (reuse `fireOrderCompletionEvents` pattern); no new transport.

---

## 6. Analytics tie-in

The waste failure chart in `renderer/analytics.js` (~833, `failureColors` / `failureType`) already aggregates `wasteLog.failureType` — QC-fail rows feed it unchanged. Add:

- **QC pass/fail rate** — count `qcStatus` over orders that reached `qc`, by week/month; surface near the SLA section (`renderSLASection`, ~1708).
- **First-pass yield** — orders passing QC on the first attempt (`reprintOf == null && qcStatus=='pass'`) ÷ all QC'd. Reprint chains (`reprintChain`) collapse to one root so a multi-reprint job counts once.
- **Defect categories** — reuse the existing failure-type breakdown chart, now sourced from `defects[].type` (richer than waste rows alone).
- **Warranty/RMA rate & cost** — count of `rma` records and summed material cost of `reprintReason=='rma'` orders (shop cost), in SAR.
- **SLA tie-in:** a reprinted job's due date is measured against the **root** order so reprints don't artificially reset on-time stats.

---

## 7. Edge cases

- **Reprint of a reprint** — chain links via `reprintChain` to the root; analytics/SLA roll up to root.
- **Material on the failed job** — never reversed; the waste row is the single source of the loss. Verified: reopening (not used here) clears `materialDeducted`; linked reprints are *new* orders, so the guard is bypassed and double-deduction can't happen.
- **Fail with zero recoverable weight** — waste row allows `weight=0` (existing); cost 0; still logs the defect.
- **Pass after a prior fail on the same order** — only via reopen; the new `qcStatus='pass'` overwrites and `qcAt` updates; `defects[]` history retained.
- **RMA outside warranty** — `withinWarranty=false`; owner may still reprint but defaults to `billable`, or choose decline/refund.
- **QC disabled** (`settings.qc.enabled=false`) — `qc` stage behaves as today (pass/fail still available; new fields simply optional). Opt-in means no forced inspector.
- **Cloud off** — all fields are plain order fields; they sync if/when a tenant connects, same as any order field. No standalone QC store.
- **Inspector required but none selected** — block pass/fail save when `requireInspector` (mirror existing modal validation).

---

## 8. Test plan & Definition of Done

- **Pass path:** order in `qc` → pass → `qcStatus='pass'`, advances to `completed`, material deducted exactly once (assert `materialDeducted` guard); badge green.
- **Fail → scrap:** fail with defect + weight → `wasteLog` row created (existing), `qcStatus='fail'`, `defects[]` populated, order not requeued; badge red.
- **Fail → reprint (shop):** new order has `reprintOf`/`reprintChain`, price 0, original gets `reprintedInto`; **original's deduction unchanged**; reprint deducts its own filament only when it passes. Assert total filament = original + reprint.
- **Fail → reprint (billable):** new order priced normally; counts as revenue, not warranty cost.
- **RMA:** delivered order → Open RMA → reprint at no charge → `rma.reprintId` set, original untouched, reprint flows through QC.
- **Analytics:** first-pass yield collapses a 2-reprint chain to one root; defect categories sourced from `defects[]`; RMA rate/cost in SAR.
- **i18n/market:** all new labels have Arabic strings; amounts render SAR; RTL intact.
- **Cloud-off regression:** no behavior change vs today when `qc.enabled=false`.

**DoD:** an owner can inspect a job at the `qc` stage, record a pass or a defect-tagged fail, spin off a **linked** reprint (shop-cost or billable) without corrupting filament accounting, handle a customer warranty claim as a no-charge linked reprint, and see pass/fail rate, first-pass yield, defect categories and RMA cost in analytics — all reusing the existing QC badge, kanban stage, reprint, and status lifecycle, with cloud entirely optional.
