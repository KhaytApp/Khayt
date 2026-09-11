'use strict';
(function (global) {
/**
 * What actually came in, and what actually went out, month by month.
 *
 * NOT the same question as the P&L. A quarter's net says what the shop EARNED;
 * this says what reached and left the bank. A shop can be profitable and unable
 * to pay the rent, and that gap is the whole reason this exists — so it is
 * counted on the day money moved, never on the day a job finished.
 *
 * ── THREE THINGS THE VERSION THIS REPLACES GOT WRONG ──────────────────────
 *
 * 1. IT COUNTED A JOB'S WHOLE REVENUE ON THE DAY OF ITS FIRST PAYMENT.
 *    `paidAt` is set by `recordPayment` on ANY payment, a deposit included. So
 *    a 10% deposit in June on a 20,000 job put 20,000 of "cash in" in June —
 *    money the shop had not received, on the one chart whose entire subject is
 *    money it has. Collected revenue is scaled by the share actually paid.
 *
 * 2. IT COUNTED VOIDED ORDERS. No `voidedAt` check at all, on a screen where
 *    every neighbouring figure excludes them.
 *
 * 3. IT IGNORED THE BUSINESS SCOPE, so a job marked as not the shop's trade
 *    still moved the line — again unlike every other money figure in the app.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** The `YYYY-MM` a stored date falls in. */
function monthOf(v) {
  const s = String(v == null ? '' : v);
  return s.length >= 7 ? s.slice(0, 7) : '';
}

/** The `count` months ending at `endMonth`, oldest first. */
function monthsEnding(endMonth, count) {
  const m = /^(\d{4})-(\d{2})$/.exec(String(endMonth || ''));
  if (!m) return [];
  let year = Number(m[1]);
  let month = Number(m[2]);
  const out = [];
  for (let i = 0; i < Math.max(0, count); i++) {
    out.unshift(`${year}-${String(month).padStart(2, '0')}`);
    month -= 1;
    if (month === 0) { month = 12; year -= 1; }
  }
  return out;
}

/**
 * @param {object} input
 *   orders     every order; this filters them itself, because the rule about
 *              WHICH orders are cash is part of the answer
 *   expenses   [{ date, amount }] already in the base currency
 *   endMonth   `YYYY-MM` — the last month on the chart, usually this one
 *   months     how many to draw, ending at `endMonth`
 * @param {object} deps
 *   revenueOf         (order) => net revenue in base currency, for the WHOLE order
 *   countsForBusiness (order) => is this the shop's trade?
 * @returns {{rows: Array<{month, collected, paidOut, net}>, totals: object}}
 */
function cashFlow(input, deps) {
  const i = input || {};
  const d = deps || {};
  const revenueOf = typeof d.revenueOf === 'function' ? d.revenueOf : () => 0;
  const countsForBusiness = typeof d.countsForBusiness === 'function'
    ? d.countsForBusiness : () => true;

  const wanted = monthsEnding(i.endMonth, i.months == null ? 6 : i.months);
  const byMonth = new Map(wanted.map((m) => [m, { month: m, collected: 0, paidOut: 0, net: 0 }]));

  // MONEY THAT WAS PAID ON A DAY NOBODY RECORDED.
  //
  // `paidAt` was added after Khayt had been in use, so a shop's older orders
  // carry a `paidAmount` and no date — and a timeline cannot place them. The
  // honest options are to invent a date or to leave them out, and leaving them
  // out SILENTLY is the one thing that must not happen: a shop that has been
  // paid thirty times would read "collected nothing" and believe it.
  //
  // So they are counted, separately, and the caller is expected to say so.
  let undated = 0;

  for (const order of (Array.isArray(i.orders) ? i.orders : [])) {
    if (!order || order.voidedAt) continue;
    if (!countsForBusiness(order)) continue;

    // THE SHARE ACTUALLY PAID, not the whole job. `revenueOf` owns the tax and
    // the currency — scaling its answer keeps both rules in the module that has
    // them rather than re-deriving either here.
    const price = num(order.price);
    const paid = Math.min(num(order.paidAmount), price);
    if (paid <= 0) continue;
    const share = price > 0 ? paid / price : 0;
    const collected = num(revenueOf(order)) * share;

    if (!order.paidAt) { undated += collected; continue; }
    const row = byMonth.get(monthOf(order.paidAt));
    if (!row) continue;
    row.collected += collected;
  }

  for (const expense of (Array.isArray(i.expenses) ? i.expenses : [])) {
    if (!expense) continue;
    const row = byMonth.get(monthOf(expense.date));
    if (row) row.paidOut += num(expense.amount);
  }

  const rows = wanted.map((m) => {
    const row = byMonth.get(m);
    row.net = row.collected - row.paidOut;
    return row;
  });

  return {
    rows,
    totals: {
      collected: rows.reduce((s, r) => s + r.collected, 0),
      paidOut: rows.reduce((s, r) => s + r.paidOut, 0),
      net: rows.reduce((s, r) => s + r.net, 0),
      // Whether there is anything to draw at all. A chart of six empty months
      // is not a chart, and a caller needs to be able to tell that apart from
      // six months that genuinely netted nothing.
      anyMovement: rows.some((r) => r.collected !== 0 || r.paidOut !== 0),
      /// Collected money that carries no payment date, so no month can hold it.
      /// Not part of `collected` or `net` — those are what the timeline shows,
      /// and adding an unplaceable figure to them would make the columns
      /// disagree with the total printed under them.
      undated,
    },
  };
}

const api = { cashFlow, monthsEnding };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytCashFlow = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
