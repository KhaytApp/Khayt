'use strict';
(function () {

/**
 * Detect purchase orders carrying the per-spool/per-gram unit-price defect.
 *
 * resolveReorderPrice() is documented as returning a per-GRAM rate, but its
 * item.cost fallback returned the cost of a WHOLE SPOOL undivided. `qty` on a
 * purchase order is measured in grams, so every PO drafted through that path
 * was priced roughly 1000x too high — 750 g of an 85 SAR/kg spool asked for
 * 63,750 SAR instead of 63.75.
 *
 * The code is fixed, but stores written before the fix still hold those POs.
 * This module FINDS them and proposes a correction; it never applies one.
 * A purchase order is a commercial document the owner may have already sent to
 * a supplier — silently rewriting an amount would be worse than the bug.
 *
 * Pure (no DOM, no store access) so the detection can be unit-tested.
 */

/**
 * Above this many currency units per GRAM, a unit price is not a real filament
 * price. Ordinary filament runs roughly 0.02–0.5 /g (20–500 per kg); even an
 * exotic engineering resin does not reach 5 /g (5,000 per kg). The defect
 * produced whole-spool figures — typically 50–200 — so the two populations are
 * separated by two orders of magnitude and the threshold does not need to be
 * finely tuned.
 */
const IMPLAUSIBLE_PER_GRAM = 5;

/** A PO is only suspect while it can still be corrected without confusing a supplier. */
const CORRECTABLE_STATUSES = new Set(['draft', 'ordered']);

/**
 * Consumable orders cannot carry this defect, and must never be flagged for it.
 *
 * The whole audit rests on one assumption: `qty` is in GRAMS and `unitPrice` is
 * therefore a per-gram rate, so anything above a few currency units per unit is
 * a whole-spool figure in the wrong field. That assumption is filament-only.
 * A consumable order is measured in the shop's own unit — boxes, sheets, pcs,
 * litres — and its unit price is the price of one of those. A 12/box mailer bag
 * or a 40/pc build plate is an ordinary price, not a 1000x error.
 *
 * Left unguarded, every consumable priced above IMPLAUSIBLE_PER_GRAM raised a
 * permanent banner telling the owner their amounts were 1000x too high. The
 * proposed correction was worse: correctedUnitPrice() divides by a spool weight,
 * so "correcting" a 12/box order would have written 0.012/box — introducing the
 * very error the banner claimed to find. It only escaped doing so because a
 * consumable is not in `inventory`, so the item lookup missed and the row fell
 * back to "set the price by hand".
 */
function isFilamentOrder(po) {
  return !po.kind || po.kind === 'filament';
}

/**
 * The corrected per-gram price for a PO, derived the way the fixed
 * resolveReorderPrice does: whole-spool cost divided by spool weight.
 * @returns {number|null} null when the item is unknown or carries no cost.
 */
function correctedUnitPrice(po, item) {
  if (!item) return null;
  const perSpool = +item.cost || 0;
  if (perSpool > 0) return perSpool / Math.max(1, +item.spoolWeight || 1000);
  if (+item.costPerKg > 0) return +item.costPerKg / 1000;
  return null;
}

/**
 * Purchase orders whose unit price looks like a whole-spool cost.
 *
 * Deliberately conservative — it reports only what it can justify:
 *  - the order must be a filament order, the only kind that can hold the defect, AND
 *  - the unit price must be implausible as a per-gram rate, AND
 *  - the PO must still be in a status where changing the amount is sensible.
 *
 * `suggested` is null when the item was deleted or has no cost recorded; the
 * owner still sees the PO flagged, just without a proposed figure.
 *
 * @returns {Array<{po, item, unitPrice, suggested, currentTotal, suggestedTotal}>}
 */
function findSuspectPurchaseOrders(purchaseOrders, inventory) {
  const items = new Map();
  for (const i of (Array.isArray(inventory) ? inventory : [])) {
    if (i && i.id) items.set(i.id, i);
  }
  const out = [];
  for (const po of (Array.isArray(purchaseOrders) ? purchaseOrders : [])) {
    if (!po || !CORRECTABLE_STATUSES.has(po.status)) continue;
    if (!isFilamentOrder(po)) continue;
    const unitPrice = +po.unitPrice || 0;
    if (unitPrice <= IMPLAUSIBLE_PER_GRAM) continue;
    const item = items.get(po.itemId) || null;
    const suggested = correctedUnitPrice(po, item);
    const qty = +po.qty || 0;
    out.push({
      po,
      item,
      unitPrice,
      suggested,
      // Rounded to cents: these are money figures shown side by side, and
      // 750 * 0.085 lands on 63.75000000000001 in binary floating point.
      currentTotal: Math.round(qty * unitPrice * 100) / 100,
      suggestedTotal: suggested == null ? null : Math.round(qty * suggested * 100) / 100,
    });
  }
  // Worst overstatement first — that is the one most likely to have been sent.
  return out.sort((a, b) => b.currentTotal - a.currentTotal);
}

/**
 * Apply a correction to ONE purchase order, in place. Owner-initiated only.
 * Refuses rather than guesses: returns {ok:false} when there is no defensible
 * figure to write.
 */
function applyCorrection(entry) {
  if (!entry || !entry.po) return { ok: false, error: 'no purchase order' };
  if (entry.suggested == null || !(entry.suggested > 0)) {
    return { ok: false, error: 'no cost on the linked item to derive a price from' };
  }
  const before = +entry.po.unitPrice || 0;
  entry.po.unitPrice = Math.round(entry.suggested * 1000) / 1000;
  return { ok: true, before, after: entry.po.unitPrice };
}

const api = {
  IMPLAUSIBLE_PER_GRAM,
  CORRECTABLE_STATUSES,
  isFilamentOrder,
  correctedUnitPrice,
  findSuspectPurchaseOrders,
  applyCorrection,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPoAudit = api;

})();
