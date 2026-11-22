'use strict';
(function () {

/**
 * The supplier's own invoice, against the purchase order it belongs to.
 *
 * A shop receives goods and then receives a bill for them, and the question
 * that matters is whether the two agree. `renderer/inventory.js` has asked it
 * since the feature was written, with the arithmetic inline in the save
 * handler — so the Mac app, which can draft, send and receive a purchase
 * order, had no way to record the bill or to be told when it did not match.
 *
 * Two apps answering "does this invoice match?" differently is the failure
 * this codebase keeps finding, so the answer lives here and both ask.
 *
 * Pure: no DOM, no store, no clock.
 */

/**
 * How far apart the two amounts may be and still count as agreeing.
 *
 * ONE currency unit, not a percentage. A supplier rounding halalas or a shop
 * typing 63.75 against a computed 63.7499 is not a discrepancy anybody wants
 * flagged; a real mispricing on a filament order is tens or hundreds. A
 * percentage would let a large order hide a large error inside it.
 */
const TOLERANCE = 1;

/** Statuses where a bill can sensibly be recorded: the goods have arrived. */
const BILLABLE = new Set(['received', 'partial']);

function num(v) {
  const n = +v;
  return Number.isFinite(n) ? n : 0;
}

/**
 * What the order said it would cost: quantity times the unit price.
 *
 * `qty` is in GRAMS for a filament order and `unitPrice` is the per-gram rate
 * — the same pair `lib/po-audit.js` exists to police. An earlier version of
 * this read `weightOrdered` and `unitCost`, which nothing ever writes, so the
 * expected amount was always 0 and a mismatch was never once flagged. That is
 * why this is a named function with a test rather than an expression inside a
 * save handler.
 */
function expectedAmount(po) {
  return num(po && po.qty) * num(po && po.unitPrice);
}

/** Can a bill be recorded against this order yet? */
function canRecord(po) {
  return !!po && BILLABLE.has(String(po.status || ''));
}

/**
 * Do the invoice and the order agree?
 *
 * An order with no expected amount — no quantity, or no unit price — cannot
 * disagree with anything, and saying it does would put a warning on every PO a
 * shop drafted by hand. Silence there is the honest answer.
 */
function discrepancy(po, amount) {
  const expected = expectedAmount(po);
  if (!(expected > 0)) return false;
  return Math.abs(num(amount) - expected) > TOLERANCE;
}

/**
 * The fields to write onto the order, given what the shop typed.
 *
 * Returns the two fields and nothing else, so a caller merges rather than
 * replaces: a purchase order carries plenty this does not know about.
 */
function record(po, invoice) {
  const inv = invoice || {};
  const amount = num(inv.amount);
  return {
    supplierInvoice: {
      number: String(inv.number || '').trim(),
      amount,
      date: String(inv.date || '').slice(0, 10),
    },
    invoiceDiscrepancy: discrepancy(po, amount),
  };
}

/**
 * What to say about an order that has been billed: matched, mismatched, or
 * nothing at all because no bill has been recorded.
 *
 * A WORD rather than a boolean, so a screen draws one of three states instead
 * of guessing what `false` means.
 */
function state(po) {
  if (!po || !po.supplierInvoice) return 'none';
  return po.invoiceDiscrepancy ? 'mismatch' : 'matched';
}

/**
 * Mark a bill settled, or un-settle one marked by mistake.
 *
 * `invoicePaid` was READ by the other app's AP aging bar and written by
 * nothing, in either app — `test/po-cost-fields.test.js` carried it on a
 * known-unwritten list — so every order that had been billed counted as owing
 * forever and the bar could only grow. This is the write.
 *
 * A boolean rather than a date. The question the aging bar asks is "is this
 * still owed", and a shop that knows WHEN it paid has that on its bank
 * statement; inventing a field for it here would be a second record of
 * something the bank already keeps.
 */
function settle(po, paid) {
  return { invoicePaid: !!paid };
}

/**
 * The orders that still want attention from whoever pays the bills: the goods
 * are here, and either no bill has been recorded or one has and is unpaid.
 *
 * The other app filtered for this inline while drawing its aging bar. It is
 * here so that the list a shop is shown and the bar it is measured by cannot
 * disagree — and so the Mac, which draws no bar, can still show the list.
 */
function owing(orders) {
  return (Array.isArray(orders) ? orders : []).filter((po) => {
    if (!po || !canRecord(po)) return false;      // not arrived: nothing to settle
    return !po.supplierInvoice || !po.invoicePaid;
  });
}

const api = { TOLERANCE, expectedAmount, canRecord, discrepancy, record, state,
              settle, owing };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytSupplierInvoice = api;

})();
