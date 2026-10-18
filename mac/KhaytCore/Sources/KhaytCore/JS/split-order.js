'use strict';
/**
 * Dividing one job's money across the sub-orders it was split into.
 *
 * `splitOrderAcrossMachines` creates one sub-order per machine, each with a
 * proportional share of the price. Money already TAKEN has to travel with the
 * price it was taken against: every sub-order used to be created
 * `paidAmount: 0`, so a job with a deposit came out the other side owing its
 * full value again and the customer was invoiced for money they had paid.
 *
 * The arithmetic lives here rather than inside that DOM-heavy async function so
 * it can be driven directly — the rounding rule is the part worth testing, and a
 * test that re-implements it proves nothing about the code that ships.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  /**
   * Split `price`, `paid` and `credited` across groups weighted by `costs`.
   *
   * The shares add back up to exactly what the customer was charged and exactly
   * what they paid — splitting SAR 1,000.03 three ways must not quietly become
   * SAR 1,000.02 — and NO SHARE IS EVER NEGATIVE.
   *
   * Largest remainder, in whole cents: every group gets the cents its weight
   * rounds DOWN to, and the cents left over go one each to the groups whose
   * weight lost the most to that rounding. It used to round every share
   * half-up and hand the LAST group whatever remained, so three heavy groups
   * that each rounded up left the last one owing a negative amount: 100.01
   * over weights [1, 1, 1, 0.0001] gave the last machine -0.01.
   *
   * @param {{price:number, paid:number, credited:number, costs:number[]}} input
   * @returns {{price:number, paidAmount:number, credited:number}[]} one per group
   */
  /** `amounts` moved so none is above its `caps`, keeping the total where it fits. */
  function within(amounts, caps) {
    const cents = amounts.map((a) => Math.round(a * 100));
    const room = caps.map((c, i) => Math.round(c * 100) - cents[i]);
    let spare = 0;
    for (let i = 0; i < cents.length; i++) {
      if (room[i] < 0 && cents[i] > 0) { const over = Math.min(-room[i], cents[i]); cents[i] -= over; spare += over; room[i] += over; }
    }
    for (let i = 0; i < cents.length && spare > 0; i++) {
      if (room[i] > 0) { const give = Math.min(room[i], spare); cents[i] += give; room[i] -= give; spare -= give; }
    }
    // Paid more than the whole price: what is left stays on the last part, as
    // it always has, rather than vanishing.
    if (spare > 0) cents[cents.length - 1] += spare;
    return cents.map((c) => c / 100);
  }

  function splitMoney({ price = 0, paid = 0, credited = 0, costs = [] } = {}) {
    const weights = costs.map((c) => Math.max(0, +c || 0));
    const total = weights.reduce((s, c) => s + c, 0);
    const n = weights.length;
    if (!n) return [];
    // Every part costed zero (or none of them carry a cost): split evenly rather
    // than putting the whole price on one arbitrary machine.
    const even = total <= 0;
    const fracs = weights.map((w) => (even ? 1 / n : w / total));

    const share = (whole) => {
      const cents = Math.round((+whole || 0) * 100);
      const sign = cents < 0 ? -1 : 1;
      const abs = Math.abs(cents);
      const exact = fracs.map((f) => abs * f);
      const out = exact.map((x) => Math.floor(x + 1e-9));
      let left = abs - out.reduce((s, c) => s + c, 0);
      const order = exact.map((x, i) => ({ i, rest: x - Math.floor(x + 1e-9) }))
        .sort((a, b) => b.rest - a.rest || a.i - b.i);
      for (let k = 0; left > 0 && order.length; k = (k + 1) % order.length, left -= 1) {
        out[order[k].i] += 1;
      }
      return out.map((c) => (sign * c) / 100);
    };

    const prices = share(price);
    // NEVER MORE PAID THAN PRICED. Shared out separately, the cents of the
    // payment and of the price could round apart, so a part priced 0.14 was
    // paid 0.15 — a sub-order "overpaid" by a cent the customer never gave.
    // The excess moves, cent by cent, to the parts that still have room.
    const paids = within(share(paid), prices);
    const credits = share(credited);
    return weights.map((_, i) => ({ price: prices[i], paidAmount: paids[i], credited: credits[i] }));
  }

  /**
   * What a sub-order's payment status must be.
   *
   * payStatus() derives this whenever price > 0, but falls back to the STORED
   * field at price 0 — so a costless part handed 'unpaid' would sit in
   * receivables forever, and one handed nothing at all would read as paid.
   */
  function paymentStatusFor(price, paid) {
    const owed = +price || 0;
    const got = +paid || 0;
    if (owed <= 0) return got > 0 ? 'paid' : 'unpaid';
    if (got <= 0) return 'unpaid';
    return got >= owed ? 'paid' : 'partial';
  }

  /**
   * Push a superseded parent's recorded payments down onto its children.
   *
   * A job split BEFORE the deposit fix left every sub-order at `paidAmount: 0`
   * with the money recorded on the parent. Excluding that parent from what is
   * owed — correct, its children carry the debt — then credited the deposit to
   * NOTHING, so a SAR 3,000 job with SAR 1,000 paid read as SAR 3,000
   * outstanding instead of SAR 2,000. Better than the SAR 5,000 it used to
   * report, and still money the shop would chase a customer for.
   *
   * Idempotent by an explicit marker, not by inspection: `depositSplitAt` on the
   * parent. A shop may legitimately have paid one sub-order by hand since, and
   * "no child has been paid" would then be false for a parent that still needs
   * migrating — while running twice would credit the deposit twice, which is the
   * direction that costs the shop money.
   *
   * Refuses in every uncertain case. A parent whose children are missing, or
   * whose children's prices do not add up to a positive total, is left exactly
   * as it is: an unmigrated deposit is a figure someone can still find, and a
   * wrongly split one is not.
   *
   * @param {object[]} orders the whole print log, mutated in place
   * @returns {{migrated: number, moved: number}} parents fixed, and money moved
   */
  function migrateSplitDeposits(orders) {
    if (!Array.isArray(orders)) return { migrated: 0, moved: 0 };
    const byId = new Map(orders.filter((o) => o && typeof o.id === 'string').map((o) => [o.id, o]));
    let migrated = 0;
    let moved = 0;

    for (const parent of orders) {
      if (!parent || typeof parent !== 'object') continue;
      if (parent.depositSplitAt) continue;                       // already done
      if (parent.status !== 'split' || !Array.isArray(parent.splitInto) || !parent.splitInto.length) continue;

      const paid = +parent.paidAmount || 0;
      const credited = (parent.creditNotes || []).reduce((sum, c) => sum + (+c.amount || 0), 0);
      if (paid <= 0 && credited <= 0) continue;                  // nothing to move

      const children = parent.splitInto.map((id) => byId.get(id)).filter(Boolean);
      if (children.length !== parent.splitInto.length) continue; // a child is gone: leave it alone
      const total = children.reduce((sum, c) => sum + (+c.price || 0), 0);
      if (!(total > 0)) continue;                                // nothing to weigh the shares by

      const shares = splitMoney({ price: 0, paid, credited, costs: children.map((c) => +c.price || 0) });
      children.forEach((child, i) => {
        const share = shares[i];
        if (share.paidAmount > 0) {
          child.paidAmount = Math.round(((+child.paidAmount || 0) + share.paidAmount) * 100) / 100;
          child.paymentStatus = paymentStatusFor(+child.price || 0, child.paidAmount);
        }
        if (share.credited > 0) {
          child.creditNotes = [...(child.creditNotes || []),
            { id: `CN-SPLIT-${parent.id}-${i}`, amount: share.credited, at: new Date().toISOString(),
              reason: `Carried from ${parent.id}` }];
        }
      });
      parent.depositSplitAt = new Date().toISOString();
      migrated += 1;
      moved += paid + credited;
    }
    return { migrated, moved: Math.round(moved * 100) / 100 };
  }

  const api = { splitMoney, paymentStatusFor, migrateSplitDeposits };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSplitOrder = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
