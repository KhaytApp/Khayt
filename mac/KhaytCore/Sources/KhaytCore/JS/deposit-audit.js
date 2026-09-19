'use strict';
(function () {

/**
 * Find — and recover — deposits erased by the instalment-save defect (#500).
 *
 * Before that fix, saving an order that had instalments did:
 *
 *     order.paidAmount = instPaid;
 *
 * unconditionally. `paidAmount` is the authoritative cash figure and holds the
 * deposit recorded at order creation, while the plan generator builds schedules
 * with depositAmount:0 spanning the full price — so a freshly generated plan has
 * instPaid = 0. Generating a plan and pressing Save turned a 500 deposit into 0,
 * moved the order from 'partial' to 'unpaid', and raised receivables by 500 with
 * no ledger entry and nothing on screen to say it had happened.
 *
 * I twice told the user this was unrecoverable. That was WRONG: `createOrder`
 * also writes a separate `depositAmount` field (order-flows.js:180) which the
 * defect never touched and which survives store normalization intact (verified).
 * So the original figure is still on disk and the damage can be undone.
 *
 * This module FINDS affected orders and can restore one at a time. It never
 * repairs silently — paidAmount drives receivables, payment status and the
 * payment webhooks, so a shop must see what is changing before it changes.
 *
 * Pure (no DOM, no store access) so the detection is unit-testable.
 */

/** Cent tolerance, so binary float drift never looks like a missing deposit. */
const EPSILON = 0.005;

/**
 * Was this order's deposit erased?
 *
 * The signature is narrow on purpose:
 *  - a deposit was recorded (`depositAmount` > 0), AND
 *  - `paidAmount` is now BELOW it, AND
 *  - the order carries instalments — the only code path that overwrote it.
 *
 * Without the instalment condition this would also flag orders whose paidAmount
 * an owner deliberately lowered by hand, and telling someone their own
 * correction was a bug is worse than staying quiet.
 */
function isAffected(order) {
  if (!order || typeof order !== 'object') return false;
  const deposit = +order.depositAmount || 0;
  if (!(deposit > 0)) return false;
  const paid = +order.paidAmount || 0;
  if (paid + EPSILON >= deposit) return false;
  return Array.isArray(order.instalments) && order.instalments.length > 0;
}

/**
 * The figure paidAmount should hold: the deposit, plus anything the instalment
 * rows record as paid. Both are real cash the shop received.
 */
function recoveredPaidAmount(order) {
  const deposit = +order.depositAmount || 0;
  const instPaid = (Array.isArray(order.instalments) ? order.instalments : [])
    .filter((i) => i && i.paid)
    .reduce((s, i) => s + (+i.amount || 0), 0);
  return Math.round((deposit + instPaid) * 100) / 100;
}

/**
 * Affected orders, worst loss first — the biggest gap is the one most likely to
 * have already been chased as an unpaid balance.
 * @returns {Array<{order, deposit, currentPaid, recovered, lost}>}
 */
function findErasedDeposits(printLog) {
  const out = [];
  for (const order of (Array.isArray(printLog) ? printLog : [])) {
    if (!isAffected(order)) continue;
    const currentPaid = +order.paidAmount || 0;
    const recovered = recoveredPaidAmount(order);
    out.push({
      order,
      deposit: +order.depositAmount || 0,
      currentPaid,
      recovered,
      lost: Math.round((recovered - currentPaid) * 100) / 100,
    });
  }
  return out.sort((a, b) => b.lost - a.lost);
}

/**
 * Restore ONE order's paid amount, in place. Owner-initiated only.
 *
 * Recomputes paymentStatus from the restored figure against the order price, so
 * an order does not sit at 'unpaid' with money against it. Returns the previous
 * values so the caller can offer an undo.
 */
function restoreDeposit(entry) {
  if (!entry || !entry.order) return { ok: false, error: 'no order' };
  const o = entry.order;
  if (!isAffected(o)) return { ok: false, error: 'this order no longer looks affected' };
  const before = { paidAmount: +o.paidAmount || 0, paymentStatus: o.paymentStatus };
  o.paidAmount = entry.recovered;
  const owed = +o.price || 0;
  o.paymentStatus = o.paidAmount <= 0
    ? 'unpaid'
    : (owed > 0 && o.paidAmount + EPSILON >= owed ? 'paid' : 'partial');
  return { ok: true, before, after: { paidAmount: o.paidAmount, paymentStatus: o.paymentStatus } };
}

/** Total cash currently unaccounted for across every affected order. */
function totalLost(entries) {
  return Math.round((entries || []).reduce((s, e) => s + (+e.lost || 0), 0) * 100) / 100;
}

const api = { EPSILON, isAffected, recoveredPaidAmount, findErasedDeposits, restoreDeposit, totalLost };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytDepositAudit = api;

})();
