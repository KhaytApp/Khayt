'use strict';
(function (global) {
/**
 * Which customers are actually worth keeping.
 *
 * What each one has been worth over its whole life with the shop, how often it
 * comes back, what a typical job is worth, and when it was last seen. A shop
 * uses this to decide who to chase, who to look after, and — the part the table
 * this replaces could not answer — how badly it would hurt to lose the top one.
 *
 * ── WHAT THE VERSION THIS REPLACES COUNTED ────────────────────────────────
 *
 * Every order with the client's id on it. No status check, no `voidedAt`, no
 * business scope. So:
 *
 *   • A QUOTE counted. A customer who asked for ten quotes and bought nothing
 *     sat at the top of "lifetime value", which is the one place on the screen
 *     that must not reward asking.
 *   • A voided order counted, as did work marked outside the shop's trade.
 *
 * Lifetime value here is revenue EARNED: finished, unvoided, in scope — the
 * same set `top-lists` and the P&L count, so a client's total cannot disagree
 * with the quarter it sits beside.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** Milliseconds for a stored day or timestamp, or null. */
function timeOf(v) {
  const s = String(v == null ? '' : v);
  if (!s) return null;
  const t = Date.parse(s.length === 10 ? s + 'T00:00:00Z' : s);
  return Number.isFinite(t) ? t : null;
}

/**
 * @param {object} input
 *   clients     [{ id, name, company }]
 *   orders      every order; the rule about which count is part of the answer
 *   now         ms — when "last seen" is measured from
 *   quietDays   how long without work before a customer is called quiet
 *   limit       how many rows to return, best first
 * @param {object} deps
 *   revenueOf         (order) => net revenue in base currency
 *   countsForBusiness (order) => is this the shop's trade?
 *   isFinished        (order) => has this been earned?
 *   nameOf            (client) => what to call them
 * @returns {{rows: Array, totals: object}}
 */
function clientValue(input, deps) {
  const i = input || {};
  const d = deps || {};
  const revenueOf = typeof d.revenueOf === 'function' ? d.revenueOf : () => 0;
  const countsForBusiness = typeof d.countsForBusiness === 'function'
    ? d.countsForBusiness : () => true;
  const isFinished = typeof d.isFinished === 'function'
    ? d.isFinished
    : (o) => o && (o.status === 'completed' || o.status === 'delivered');
  const nameOf = typeof d.nameOf === 'function'
    ? d.nameOf : (c) => String((c && (c.name || c.company)) || '');

  const now = Number.isFinite(i.now) ? i.now : Date.now();
  const quietMs = Math.max(0, num(i.quietDays == null ? 90 : i.quietDays)) * 86400000;

  const byClient = new Map();
  for (const c of (Array.isArray(i.clients) ? i.clients : [])) {
    if (!c || !c.id) continue;
    byClient.set(String(c.id), {
      clientId: String(c.id), name: nameOf(c),
      value: 0, jobs: 0, averageJob: 0, lastSeen: null, daysSince: null,
      quiet: false, shareOfRevenue: 0,
      // Work that is not earned yet — a live quote or a job on the bench. NOT
      // part of `value`, because lifetime value that rewards asking for a price
      // is the one thing this table must not do. Carried separately because a
      // customer with 40,000 in flight is exactly who a shop should not ignore.
      inFlight: 0,
    });
  }

  for (const order of (Array.isArray(i.orders) ? i.orders : [])) {
    if (!order || order.voidedAt) continue;
    const row = byClient.get(String(order.clientId || ''));
    if (!row) continue;
    if (!countsForBusiness(order)) continue;

    if (!isFinished(order)) {
      // A quote is not in flight either — nobody has agreed to it.
      if (order.status !== 'quote' && order.status !== 'cancelled') {
        row.inFlight += num(revenueOf(order));
      }
      continue;
    }
    row.value += num(revenueOf(order));
    row.jobs += 1;
    const seen = timeOf(order.completedAt || order.date);
    if (seen != null && (row.lastSeen == null || seen > row.lastSeen)) row.lastSeen = seen;
  }

  const all = [...byClient.values()];
  const earned = all.reduce((s, r) => s + r.value, 0);

  for (const row of all) {
    row.averageJob = row.jobs > 0 ? row.value / row.jobs : 0;
    row.shareOfRevenue = earned > 0 ? row.value / earned : 0;
    row.daysSince = row.lastSeen == null ? null
      : Math.max(0, Math.floor((now - row.lastSeen) / 86400000));
    // A customer who has never bought anything is not "quiet" — it has not
    // gone anywhere. Calling it churn risk would put every new name on a list
    // the shop is meant to act on.
    row.quiet = row.jobs > 0 && row.lastSeen != null && (now - row.lastSeen) > quietMs;
  }

  const ranked = all
    .filter((r) => r.value > 0 || r.inFlight > 0)
    .sort((a, b) => b.value - a.value || b.inFlight - a.inFlight
                    || a.name.localeCompare(b.name));
  const limit = i.limit == null ? 10 : Math.max(0, num(i.limit));

  return {
    rows: limit > 0 ? ranked.slice(0, limit) : ranked,
    totals: {
      earned,
      clients: ranked.length,
      // HOW BADLY IT WOULD HURT TO LOSE THE BIGGEST ONE. A shop with 60% of its
      // revenue in one customer has a different business from one with 6%, and
      // the table this replaces could not say which it was.
      topShare: ranked.length ? ranked[0].shareOfRevenue : 0,
      quiet: all.filter((r) => r.quiet).length,
    },
  };
}

const api = { clientValue };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytClientValue = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
