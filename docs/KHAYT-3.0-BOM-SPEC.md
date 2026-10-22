# Assembly / Bill of Materials (BOM) — spec

**Scope:** support products that are **assembled from multiple printed parts** plus **non-printed components** (consumables — magnets, screws, inserts, packaging), so a single order line tracks a multi-part assembly with correct material deduction, cost rollup, and per-part production/QC status. Local-first, SAR, BYO nothing.

**Governing principle:** Khayt already models an order/product as `parts[]` and a part already costs through `computePartBaseCost` and deducts through `deductFilamentForOrder` / `partGramsConsumed`. A BOM is **not a new structure** — it is the existing `parts[]` (the printed parts) **plus** a sibling `components[]` that references the existing `consumables` collection. We **formalize** `parts[]` into the printed half of a BOM and add the non-printed half; we **reuse** the cost helper and the deduction path unchanged for parts, and extend the consumable side of `deductFilamentForOrder` to honor explicit per-component quantities. The calculator still computes the price; the BOM only decides *what set of parts + components* gets summed and deducted.

---

## 1. What already exists (extend, do not rebuild)

- **Parts as a list** — `order.parts[]` and `product.parts[]` (`renderer/app-state.js`, `renderer/order-flows.js:93`). `currentBuild[]` (`renderer/build.js`) builds an order from N parts; `renderBuild()` already renders a multi-part cart and `updateGrandTotal()` already rolls cost across all cart parts via `computePartBreakdown` (build.js ~337).
- **Per-part cost** — `computePartBaseCost(part)` / `computePartBreakdown(part)` (`lib/calculator-cost.js`). A `part` already carries `qty`, `filamentId`, `printWeight`, `supportWeight`, `printTime`, rates, `extraMaterials[]`, `priceTiers[]`.
- **Per-part material deduction** — `deductFilamentForOrder(order)` loops `order.parts[]`, deducts `partGramsConsumed(part) = (printWeight+supportWeight)×qty` from the part's spool (location-preferred), then deducts consumables **by print hours** and packaging (`renderer/inventory.js:1842`, `:1139`, `:1920`).
- **Consumables collection** — `consumables[]` `{id,name,stock,unit,cost,minStock,usagePerHour,isPackaging}` (`renderer/inventory.js:1968`, `app-state.js:238`).
- **Per-part status** — each part already gets `partStatus` (default `'pending'`) at order create (`order-flows.js:93`); order-level QC lives in `KHAYT-3.0-QC-SPEC.md` (qc-pass/qc-fail, `order-flows.js:372`).
- **Print files per part** — `part.fileRef` / `printFileRef` (`KHAYT-3.0-PRINTFILES-SPEC.md`) — one gcode/3MF per BOM part.

**Gaps this spec closes:** (1) consumables only deduct by *hours/packaging* — no way to say "this assembly uses 4 magnets"; (2) no concept of "assembly complete" rolled up from part statuses; (3) a product BOM can't be saved/reused as a unit; (4) no per-part reprint when one part fails QC.

---

## 2. Concepts

- **Assembly** = a product (or order line) whose BOM = **N printed parts** (`parts[]`) **+ M non-printed components** (`components[]`).
- **Printed part** = the existing `part` object; `qty` = how many of that part the order (or product) prints in all — the whole line, not a count per assembly.
- **Component** = a reference to a `consumables[]` row + a quantity per assembly unit (e.g. `{consumableId, qtyPerUnit}`).
- A **standalone product** is just an assembly with `components[] = []` and one part — fully backward compatible.

---

## 3. Data model (additive, no schema break — `store-validate.js` accepts unknown keys)

**On `product` and `order` (the BOM):**
- `parts[]` — unchanged (the printed BOM). Each part keeps `qty`, `partStatus`, `fileRef`/`printFileRef`.
- `components[]` (new) — `{ id, consumableId, qtyPerUnit, name? }`. `qtyPerUnit` = units of the consumable per **one** assembly. `name` cached for display if the consumable is later deleted.
- `assemblyQty` (new, on the product and the order; absent, zero or negative reads as 1) — how many finished assemblies this order makes. It scales the **components only**: component draw = `qtyPerUnit × assemblyQty`, and component cost = one assembly's `computeComponentsCost` × `assemblyQty` (`lib/order-new.js` `componentsCost`, and `lib/product-pricing.js` for the catalogue). Printed parts are **not** multiplied by it — each part's own `qty` is already its total count (see Edge cases).
- `assemblyStatus` (new, order only, **derived not stored as truth**) — rollup of `parts[].partStatus`; see §5.

**On `consumables[]`** — unchanged. Components point at existing rows by `consumableId`.

**Migration:** orders/products without `components[]` → treated as `[]` (standalone). Existing `partStatus` already present. No data rewrite needed.

---

## 4. Cost & material rollup

**Cost** (extends the existing cart rollup in `updateGrandTotal`, build.js ~337):
- Printed parts: `Σ partTotalCost(part)` (`lib/calculator-cost.js`) — the piece cost (`computePartBaseCost`) × `part.qty` (1 when absent), with the shop's packaging spread across the line once rather than once a piece. The catalogue (`lib/product-pricing.js`) and a job (the cart) use this same line cost, so a product and a job taken from it agree.
- Components: `Σ (consumable.cost × qtyPerUnit)` over `components[]` for ONE assembly (`computeComponentsCost`), where `consumable.cost` is the per-unit cost on the `consumables` row — then × `assemblyQty`. Add this as a new bucket folded into the **material** chip (same pattern as `extraMaterials`/packaging in `computePartBreakdown`), so the breakdown still sums to the committed base.
- Total assembly base = printed-parts base + components base, then margin/tiers/discount apply exactly as today (build.js).

**Material deduction** (extends `deductFilamentForOrder`):
- Printed parts: **unchanged** — each part's filament deducts via `partGramsConsumed × spool draw` (inventory.js:1852).
- Components (new block, alongside the existing hours/packaging deduction at inventory.js:1899): for each `components[]` entry, `consumable.stock -= qtyPerUnit × assemblyQty`, clamp at 0, fire the existing low-stock toast (`cons.low`) when `stock <= minStock`. Guard with the existing `order.materialDeducted` flag so re-runs never double-deduct.

---

## 5. Production tracking

- **Per-part progress** — each `part.partStatus` ∈ `pending | printing | printed | qc_pass | qc_fail` (extends the existing `'pending'` default). UI: in the order/Kanban detail, render one row per part with its status chip (reuse the per-part rows already in `order-flows.js` ~941 / ~2101).
- **Assembly rollup** — `assemblyStatus` derived: `pending` if any part `pending/printing`; `printed` when all parts `printed`/`qc_pass`; `assembled` only when all parts are `qc_pass` **and** the owner ticks an "Assembled" gate.
- **Completion gate** — an order with `components[]` or >1 distinct part **cannot move to `completed`** until `assemblyStatus === 'assembled'`. Hook this into the existing status transition in `order-flows.js` (`updateOrderStatus`, ~213/276) — same place the QC gate lives.
- **Ties to QC spec** — per-part QC reuses `KHAYT-3.0-QC-SPEC.md` handlers; a part-level qc-fail sets `part.partStatus='qc_fail'` instead of failing the whole order (see Edge cases).

---

## 6. Integration points (exact files / functions)

- `renderer/build.js` → `snapshotPartFromForm` / `addPart` — unchanged for parts; add a **components editor** (mirrors `renderExtraMaterials`, build.js ~625) writing `currentComponents[]`; `updateGrandTotal` adds the components cost bucket.
- `renderer/build.js` → `updateGrandTotal` (~337) — fold `Σ consumable.cost × qtyPerUnit` into the `material` breakdown bucket.
- `renderer/order-flows.js` → order create (~93) — carry `components: currentComponents.map(...)` and `assemblyQty` onto the order; keep `partStatus` init.
- `renderer/order-flows.js` → `updateOrderStatus` (~213) — add the assembly completion gate; add per-part status setters and a part-level reprint action.
- `renderer/inventory.js` → `deductFilamentForOrder` (~1899) — add the `components[]` deduction block (qty × assemblyQty), reuse `cons.low` toast + `materialDeducted` guard.
- `renderer/inventory.js` → `consumables` editor — unchanged; components reference these rows.
- `lib/calculator-cost.js` — **unchanged** (it costs one `part`; the rollup lives in build.js, as today).
- `renderer/app-state.js` — document `components[]`/`assemblyQty` on the product/order shape (no key change).
- Locale keys (`en.js`/`ar.js`): `bom.components`, `bom.add_component`, `bom.qty_per_unit`, `bom.assembly_qty`, `bom.assembled`, `bom.assembly_incomplete`, `bom.reprint_part`.

---

## 7. Edge cases

- **Shared part across products** — parts are copied by value into each product/order (build.js `{ ...p }`), so a shared part is duplicated, not linked; editing one product's BOM never mutates another. (A future "part library" is out of scope.)
- **Partial assembly** — some parts `qc_pass`, others still `printing` → `assemblyStatus` stays `printed`/`pending`; the completion gate blocks `completed` and the detail shows which parts remain.
- **One part fails QC → reprint just that part** — set `part.partStatus='qc_fail'`; a "Reprint part" action re-queues *only* that part (its `printWeight×qty` re-reserves via `partGramsConsumed`); the rest of the assembly is untouched. The order does **not** revert to `pending` wholesale.
- **Consumable stock-out** — at deduction, if `qtyPerUnit×assemblyQty > stock`, clamp to 0 and warn (`cons.low`); do not block completion (mirrors current filament under-stock behavior — deducts what's there, flags low). Surface a pre-flight check in the editor (like `checkSpoolOvercommit`).
- **Deleted consumable** — `components[].name` cache renders a "missing component" badge; cost contribution → 0; no crash.
- **assemblyQty vs part.qty** — `part.qty` is the **total** number of that part printed, and `assemblyQty` multiplies the components only. Building 3 of an assembly that needs 2 of part X and 4 magnets sets `part.qty=6`, `assemblyQty=3`: 6 prints of X (cost `partTotalCost` at qty 6) and 12 magnets (`4 × 3`). Setting `part.qty=2` there costs and prints 2 of X, not 6 — nothing multiplies a part by `assemblyQty`.

---

## 8. Test plan & Definition of Done

- **Cost rollup:** product with 2 parts + 2 components → assembly base == `Σ partTotalCost(part) + Σ consumable.cost×qtyPerUnit × assemblyQty`; breakdown chips still sum to base.
- **Deduction:** complete an assembly order → each part's filament deducts via existing `deductFilamentForOrder` path (reuse those tests) **and** each component's consumable `stock -= qtyPerUnit×assemblyQty`; `materialDeducted` prevents double-deduct on re-run.
- **Status rollup:** all parts `qc_pass` + Assembled tick → `assemblyStatus='assembled'`; otherwise `completed` is blocked.
- **Reprint:** fail one part → only that part re-queues; sibling parts' status and the order's other parts unchanged.
- **Stock-out:** component qty > stock → clamps to 0, fires `cons.low`, does not throw; pre-flight warning shown in editor.
- **Backward compat:** a standalone product (no `components[]`, one part) prices, deducts, and completes exactly as in 2.x.
- **Migration:** load a pre-3.0 store → `components` absent → treated as `[]`, no rewrite, no validation error.

**DoD:** a product can be defined as N printed parts + M consumable components; an order built from it prices via the unchanged calculator with both parts and components in the rollup, deducts every part's filament and every component's consumable on completion, tracks per-part print/QC status, and can only be marked complete once all parts pass QC and the assembly is marked assembled — all local-first, in SAR, with zero behavior change for single-part products.
