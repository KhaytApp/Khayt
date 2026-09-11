'use strict';
(function (global) {
/**
 * How many quotes turn into work, and how much of the money does.
 *
 * A shop quoting all day and winning a third of it has a different problem from
 * one winning nearly all of it and not quoting enough. No other screen answers
 * that, and the count alone does not either: ten small quotes won and one large
 * one lost is a very different month from the reverse.
 *
 * ── WHAT THE VERSION THIS REPLACES GOT WRONG ──────────────────────────────
 *
 * Its last step counted `status === 'completed'` only. `delivered` is PAST
 * completed in Khayt's pipeline — it is where finished work ends up — so every
 * job that reached a customer fell out of the funnel's final step, and the
 * conversion rate it printed was systematically too low for every shop that
 * marks work delivered.
 *
 * It also counted a CANCELLED order as converted (anything not still a quote
 * and not voided), and ignored the business scope every other figure applies.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function timeOf(v) {
  const s = String(v == null ? '' : v);
  if (!s) return null;
  const t = Date.parse(s.length === 10 ? s + 'T00:00:00Z' : s);
  return Number.isFinite(t) ? t : null;
}

/** The middle value, which a long tail of stale quotes cannot drag. */
function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

const FINISHED = ['completed', 'delivered'];
const DEAD = ['cancelled'];

/**
 * @param {object} input
 *   orders  every order; which ones were ever quoted is part of the answer
 *   now     ms, for how long the open ones have been waiting
 * @param {object} deps
 *   priceOf           (order) => what it is worth, in base currency.
 *                     NOT `valueOf`: every object inherits `Object.prototype
 *                     .valueOf`, so `typeof deps.valueOf === 'function'` is
 *                     true for `{}` and the default would never apply — the
 *                     inherited method runs instead and throws on a plain
 *                     order. Found by calling this with no deps at all.
 *   countsForBusiness (order) => is this the shop's trade?
 * @returns {{steps: Array, totals: object}}
 */
function quoteFunnel(input, deps) {
  const i = input || {};
  const d = deps || {};
  const priceOf = typeof d.priceOf === 'function' ? d.priceOf : (o) => num(o && o.price);
  const countsForBusiness = typeof d.countsForBusiness === 'function'
    ? d.countsForBusiness : () => true;
  const now = Number.isFinite(i.now) ? i.now : Date.now();

  const quoted = (Array.isArray(i.orders) ? i.orders : []).filter((o) =>
    o && !o.voidedAt && countsForBusiness(o)
    && (o.status === 'quote' || o.quoteSentAt || o.quoteAcceptedAt));

  const sent = quoted.filter((o) => o.quoteSentAt);
  const accepted = quoted.filter((o) => o.quoteAcceptedAt);
  // Agreed and under way. A CANCELLED order is not converted — the version this
  // replaces counted it, because it only asked whether the status had moved on
  // from `quote`.
  const converted = accepted.filter((o) => o.status !== 'quote'
    && !DEAD.includes(String(o.status || '')));
  // `delivered` as well as `completed`. Delivered is where finished work ends
  // up, and leaving it out is what made every win rate too low.
  const finished = converted.filter((o) => FINISHED.includes(String(o.status || '')));

  const step = (key, rows) => ({
    key,
    count: rows.length,
    value: rows.reduce((s, o) => s + num(priceOf(o)), 0),
  });

  const steps = [
    step('created', quoted),
    step('sent', sent),
    step('accepted', accepted),
    step('converted', converted),
    step('finished', finished),
  ];

  // How long a quote sat before the customer decided. The MEDIAN, because a
  // handful of quotes nobody ever answered would drag a mean into uselessness.
  const decided = accepted
    .map((o) => {
      const from = timeOf(o.quoteSentAt) ?? timeOf(o.date);
      const to = timeOf(o.quoteAcceptedAt);
      return from != null && to != null && to >= from ? (to - from) / 86400000 : null;
    })
    .filter((v) => v != null);

  // Quotes still waiting, and how long the oldest has been. This is the part a
  // shop can act on today — a funnel is a report, an open quote is a phone call.
  const open = quoted.filter((o) => o.status === 'quote' && !o.quoteAcceptedAt);
  const waiting = open
    .map((o) => timeOf(o.quoteSentAt) ?? timeOf(o.date))
    .filter((t) => t != null)
    .map((t) => Math.max(0, Math.floor((now - t) / 86400000)));

  const created = steps[0];
  return {
    steps,
    totals: {
      // BOTH RATES. Ten small quotes won and one large one lost is a very
      // different month from the reverse, and a count cannot tell them apart.
      winRateByCount: created.count > 0 ? finished.length / created.count : null,
      winRateByValue: created.value > 0
        ? finished.reduce((s, o) => s + num(priceOf(o)), 0) / created.value : null,
      medianDaysToDecide: median(decided),
      openCount: open.length,
      openValue: open.reduce((s, o) => s + num(priceOf(o)), 0),
      oldestOpenDays: waiting.length ? Math.max(...waiting) : null,
    },
  };
}

const api = { quoteFunnel, FINISHED };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytQuoteFunnel = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
