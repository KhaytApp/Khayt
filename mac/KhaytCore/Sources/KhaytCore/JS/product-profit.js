'use strict';
(function (global) {
/**
 * Which of the things the shop sells actually makes money.
 *
 * NOT the same question as which sells most, and a shop that confuses the two
 * prices the wrong thing. The best seller can be the worst earner — that is the
 * entire reason this table exists, and sorting it by revenue, which is what the
 * version this replaces did, hides exactly the row a shop opened it to find.
 *
 * ── AND THE FIGURE A PRINT SHOP SHOULD ACTUALLY OPTIMISE ──────────────────
 *
 * Profit per MACHINE HOUR. A print shop's constraint is not money or floor
 * space, it is the hours its printers can run — so two products at 40% margin
 * are not equal if one takes two hours and the other twenty. Nothing in either
 * app computed it, and it is the number that answers "what should we push".
 *
 * ── AND `delivered` IS FINISHED WORK ──────────────────────────────────────
 *
 * The version this replaces counted `status === 'completed'` only, so every
 * product that actually reached a customer dropped out of its own profitability
 * row. The same mistake the quote funnel made, in a second place.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

const FINISHED = ['completed', 'delivered'];

/**
 * @param {object} input
 *   orders    every order; which ones are finished is part of the answer
 *   products  [{ id }] — only to resolve a name
 *   expenses  expenses linked to an order by `orderId`
 *   untagged  what to call work that names no product
 * @param {object} deps
 *   revenueOf         (order) => net revenue in base currency
 *   partCostOf        (part)  => what that part cost to make
 *   hoursOf           (order) => machine hours it took
 *   nameOf            (product) => what to call it
 *   countsForBusiness (order) => is this the shop's trade?
 * @returns {{rows: Array, totals: object}} rows best-earning first
 */
function productProfit(input, deps) {
  const i = input || {};
  const d = deps || {};
  const revenueOf = typeof d.revenueOf === 'function' ? d.revenueOf : (o) => num(o && o.price);
  const partCostOf = typeof d.partCostOf === 'function' ? d.partCostOf : () => 0;
  const hoursOf = typeof d.hoursOf === 'function'
    ? d.hoursOf
    : (o) => (o && Array.isArray(o.parts) ? o.parts : [])
        .reduce((s, p) => s + num(p && p.printTime) * Math.max(1, num(p && p.qty) || 1), 0);
  const nameOf = typeof d.nameOf === 'function'
    ? d.nameOf : (p) => String((p && p.name) || '');
  const countsForBusiness = typeof d.countsForBusiness === 'function'
    ? d.countsForBusiness : () => true;

  const NONE = '__none__';
  const products = new Map();
  for (const p of (Array.isArray(i.products) ? i.products : [])) {
    if (p && p.id) products.set(String(p.id), p);
  }

  // Expenses booked against a specific job are part of that job's cost, and so
  // part of its product's. Indexed once: a shop with a thousand expenses and a
  // thousand orders would otherwise scan the list a thousand times.
  const linked = new Map();
  for (const e of (Array.isArray(i.expenses) ? i.expenses : [])) {
    const id = String((e && e.orderId) || '');
    if (!id) continue;
    linked.set(id, num(linked.get(id)) + num(e && e.amount));
  }

  const byProduct = new Map();
  for (const order of (Array.isArray(i.orders) ? i.orders : [])) {
    if (!order || order.voidedAt) continue;
    if (!FINISHED.includes(String(order.status || ''))) continue;
    if (!countsForBusiness(order)) continue;

    const key = String(order.productId || NONE);
    if (!byProduct.has(key)) {
      const product = products.get(key);
      byProduct.set(key, {
        productId: key,
        name: product ? nameOf(product) : String(i.untagged || ''),
        jobs: 0, revenue: 0, cost: 0, hours: 0,
        profit: 0, marginPct: null, profitPerHour: null,
      });
    }
    const row = byProduct.get(key);
    row.jobs += 1;
    row.revenue += num(revenueOf(order));
    row.cost += (Array.isArray(order.parts) ? order.parts : [])
      .reduce((s, p) => s + num(partCostOf(p)), 0) + num(linked.get(String(order.id || '')));
    row.hours += num(hoursOf(order));
  }

  const rows = [...byProduct.values()];
  for (const row of rows) {
    row.profit = row.revenue - row.cost;
    // Null, not zero: a product with no revenue has no margin, and 0% would
    // read as "it breaks even" rather than "nothing is known".
    row.marginPct = row.revenue > 0 ? (row.profit / row.revenue) * 100 : null;
    // And null when nobody recorded the hours, rather than dividing by zero
    // into Infinity — which sorts first and is not an answer.
    row.profitPerHour = row.hours > 0 ? row.profit / row.hours : null;
  }

  // BY PROFIT, NOT BY REVENUE. The row a shop opened this table to find is the
  // big seller that earns nothing, and ranking by revenue puts it at the top
  // looking like the best thing in the shop.
  rows.sort((a, b) => b.profit - a.profit || b.revenue - a.revenue
                      || a.name.localeCompare(b.name));

  const revenue = rows.reduce((s, r) => s + r.revenue, 0);
  const cost = rows.reduce((s, r) => s + r.cost, 0);
  const hours = rows.reduce((s, r) => s + r.hours, 0);
  return {
    rows,
    totals: {
      revenue, cost, hours,
      profit: revenue - cost,
      jobs: rows.reduce((s, r) => s + r.jobs, 0),
      marginPct: revenue > 0 ? ((revenue - cost) / revenue) * 100 : null,
      profitPerHour: hours > 0 ? (revenue - cost) / hours : null,
      /// The best earner per machine hour, which is what a print shop should
      /// push — and is very often not the top row by revenue.
      bestPerHour: rows.filter((r) => r.profitPerHour != null)
        .sort((a, b) => b.profitPerHour - a.profitPerHour)[0] || null,
    },
  };
}

const api = { productProfit, FINISHED };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytProductProfit = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
