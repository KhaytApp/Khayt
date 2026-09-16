'use strict';

/**
 * What a shop spends, grouped by what it spent it on.
 *
 * ── THE TAX ON A PURCHASE IS NOT A COST ───────────────────────────────────
 *
 * For a registered shop it is reclaimed from the authority, so it belongs
 * against the tax collected on sales and not in what a category cost. The
 * P&L has always known that — `lib/pnl-report.js` charges `paid - claimable`
 * — and `renderExpenseCategoryChart` did not: it summed `e.amount` gross.
 *
 * So the two disagreed by the whole of the reclaimable tax, which at the
 * Saudi rate is 15% of every category with a receipt. A shop reading its
 * expenses by category and then its P&L saw two different totals for the
 * same money, with nothing to say which was which.
 *
 * The reclaim rule is the same one, in the same words: `vatAmount` is what
 * the supplier's invoice says, because that is what a shop has in front of
 * it; an expense that does not carry the field reclaims nothing, so nothing
 * about an older book changes; and a shop that is not registered reclaims
 * nothing at all, which is most shops.
 *
 * PURE: the range is filtered by the caller, and the labels are the caller's
 * too — this module does not know which language the shop reads.
 */
(function (global) {

  const num = (v) => (Number.isFinite(+v) ? +v : 0);

  /**
   * @param {Array} expenses  already filtered to the period the screen shows
   * @param {object} opts     { reclaimsTax: boolean }
   * @returns {{rows: Array<{category, amount, share, reclaimed}>, total: number,
   *            reclaimed: number, biggest: number}}
   */
  function byCategory(expenses, opts) {
    const o = opts || {};
    const list = Array.isArray(expenses) ? expenses : [];
    const totals = new Map();
    let reclaimedAll = 0;

    for (const e of list) {
      if (!e) continue;
      const paid = num(e.amount);
      // Never more than was paid: a receipt that claims more tax than total
      // is a typo, and a negative category is worse than a wrong one.
      const claimable = o.reclaimsTax ? Math.min(paid, Math.max(0, num(e.vatAmount))) : 0;
      // `other` is the bucket the editor itself falls back to.
      const key = e.category || 'other';
      const had = totals.get(key) || { category: key, amount: 0, reclaimed: 0 };
      had.amount += paid - claimable;
      had.reclaimed += claimable;
      totals.set(key, had);
      reclaimedAll += claimable;
    }

    const rows = [...totals.values()].sort((a, b) => b.amount - a.amount);
    const total = rows.reduce((s, r) => s + r.amount, 0);
    // The share of what the categories came to, against the chart's own
    // denominator: `total || 1`. The `|| 1` is there so a book that nets to
    // nothing divides by one instead of by zero — a shop whose only expense
    // was entirely reclaimable is a real case, not an error. A book that nets
    // NEGATIVE keeps its sign, which is what the chart has always drawn and
    // is not this module's to change.
    const denominator = total || 1;
    for (const r of rows) r.share = r.amount / denominator;
    return { rows, total, reclaimed: reclaimedAll, biggest: rows.length ? rows[0].amount : 0 };
  }

  const api = { byCategory };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytExpenseCategories = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
