'use strict';
(function () {

/**
 * A quote's revision history.
 *
 * "Revise" keeps what the quote said before the shop changes it: the price,
 * the parts, the notes, the material and the print time, filed under the
 * version they were, and the quote moves on to the next version. The history
 * is read back as a table, newest first.
 *
 * Lifted out of `renderer/invoicing.js` `reviseQuote`, unchanged, so the Mac
 * app keeps the same history in the same fields — `quoteRevisions[]` and
 * `quoteVersion` on the order — and a quote revised on one computer reads the
 * same on the other.
 *
 * PURE: the moment is handed in.
 */

/** Only a quote is revised; a job the customer has accepted is changed by an edit. */
function canRevise(order) {
  return !!order && order.status === 'quote';
}

/** The version a quote is on now (1 before it was ever revised). */
function currentVersion(order) {
  return (order && order.quoteVersion) || 1;
}

/** What the quote says now, as a revision row. */
function snapshot(order, nowIso) {
  return {
    version:     order.quoteVersion || 1,
    snapshotAt:  nowIso,
    price:       order.price,
    parts:       (order.parts || []).map(p => ({ ...p })),
    notes:       order.notes || '',
    material:    order.material || '',
    printTime:   order.printTime || 0,
  };
}

/**
 * Keep what the quote says now and move it on a version. Mutates and returns
 * `order`, as the desktop always has; a non-quote is returned untouched.
 */
function revise(order, now = Date.now()) {
  if (!canRevise(order)) return order;
  const row = snapshot(order, new Date(now).toISOString());
  if (!order.quoteRevisions) order.quoteRevisions = [];
  order.quoteRevisions.push(row);
  order.quoteVersion = (order.quoteVersion || 1) + 1;
  return order;
}

/** The kept versions, newest first, as the history table lists them. */
function history(order) {
  const rows = Array.isArray(order && order.quoteRevisions) ? order.quoteRevisions : [];
  return [...rows].reverse();
}

const api = { canRevise, currentVersion, snapshot, revise, history };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytQuoteRevision = api;

})();
