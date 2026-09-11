'use strict';
(function (global) {
/**
 * Is the shop growing, or serving the same people?
 *
 * Revenue split between customers buying for the FIRST time and customers
 * coming back. A shop living on returning customers is stable and not growing;
 * one living on new ones is growing and keeping nobody. Both are worth knowing
 * and the split says which.
 *
 * ── FOUR THINGS THE VERSION THIS REPLACES GOT WRONG ───────────────────────
 *
 * 1. IT COMPARED DATES AS STRINGS to decide who was new: `firstOrderDate[id]
 *    === o.date`. A customer whose first TWO jobs landed on the same day
 *    counted as new twice, so a shop taking two jobs from one new customer
 *    recorded two new-customer sales. Identity is the ORDER, not the day.
 * 2. It counted voided orders.
 * 3. It ignored the business scope every other figure applies.
 * 4. It counted `completed` only, so a job that reached the customer —
 *    `delivered` — was in neither half.
 *
 * And it counted ORDERS rather than customers, so "12 from new clients" could
 * be twelve people or one person ordering twelve times. Both counts are
 * reported.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function day(v) { return String(v == null ? '' : v).slice(0, 10); }

const FINISHED = ['completed', 'delivered'];

/**
 * @param {object} input
 *   orders  every order — history decides who is new, so it cannot be
 *           pre-filtered to the window
 *   from    `YYYY-MM-DD` inclusive, or '' for all time
 *   to      `YYYY-MM-DD` inclusive, or ''
 * @param {object} deps
 *   revenueOf         (order) => net revenue in base currency
 *   countsForBusiness (order) => is this the shop's trade?
 *   inWindow          (order) => is it inside the period being reported?
 *                     OPTIONAL, and it overrides `from`/`to`. The other app's
 *                     range picker offers named periods — "this quarter" — and
 *                     owns a predicate for them rather than a pair of dates;
 *                     re-deriving the bounds out here would be a second answer
 *                     to a question `lib/date-range.js` already answers.
 * @returns {{fresh: object, returning: object, totals: object}}
 */
function customerMix(input, deps) {
  const i = input || {};
  const d = deps || {};
  const revenueOf = typeof d.revenueOf === 'function' ? d.revenueOf : (o) => num(o && o.price);
  const countsForBusiness = typeof d.countsForBusiness === 'function'
    ? d.countsForBusiness : () => true;

  const from = day(i.from);
  const to = day(i.to);

  const counted = (Array.isArray(i.orders) ? i.orders : []).filter((o) =>
    o && !o.voidedAt && o.clientId && day(o.date)
    && FINISHED.includes(String(o.status || ''))
    && countsForBusiness(o));

  // WHICH ORDER WAS EACH CUSTOMER'S FIRST — by identity, not by date. Sorted by
  // day and then by id so the choice is stable when two land on one day, and
  // the SECOND of them is then correctly a returning sale.
  const firstOrderId = new Map();
  for (const order of [...counted].sort((a, b) =>
    day(a.date).localeCompare(day(b.date)) || String(a.id).localeCompare(String(b.id)))) {
    const client = String(order.clientId);
    if (!firstOrderId.has(client)) firstOrderId.set(client, String(order.id));
  }

  const insideWindow = typeof d.inWindow === 'function'
    ? d.inWindow
    : (o) => {
        const at = day(o.date);
        if (from && at < from) return false;
        if (to && at > to) return false;
        return true;
      };
  const inWindow = counted.filter((o) => insideWindow(o));

  const side = () => ({ revenue: 0, jobs: 0, clients: new Set() });
  const fresh = side();
  const returning = side();

  for (const order of inWindow) {
    const client = String(order.clientId);
    const isFirst = firstOrderId.get(client) === String(order.id);
    const bucket = isFirst ? fresh : returning;
    bucket.revenue += num(revenueOf(order));
    bucket.jobs += 1;
    bucket.clients.add(client);
  }

  const revenue = fresh.revenue + returning.revenue;
  const shape = (b) => ({
    revenue: b.revenue, jobs: b.jobs, clients: b.clients.size,
    // Null rather than zero when there is nothing at all: 0% of nothing reads
    // as "none of your money came from new customers", which is a claim.
    shareOfRevenue: revenue > 0 ? b.revenue / revenue : null,
  });

  return {
    fresh: shape(fresh),
    returning: shape(returning),
    totals: {
      revenue,
      jobs: fresh.jobs + returning.jobs,
      // DISTINCT, not the two halves added.
      //
      // A customer whose first sale AND a repeat both fall inside the window is
      // in BOTH sets — it was new and then it came back, which is the best
      // thing that can happen and must not be counted as two people. The first
      // version of this line added the two sizes and carried a comment saying
      // they could not overlap, which was simply untrue.
      clients: new Set([...fresh.clients, ...returning.clients]).size,
      /// The average new customer's first order. What a shop is buying when it
      /// spends on getting found.
      firstOrderValue: fresh.jobs > 0 ? fresh.revenue / fresh.jobs : null,
    },
  };
}

const api = { customerMix, FINISHED };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytCustomerMix = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
