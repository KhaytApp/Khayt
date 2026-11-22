'use strict';
(function (global) {
/**
 * Do customers come back? (KhaytClientRetention)
 *
 * Of the customers who bought once, how many bought AGAIN within 30, 60 and
 * 90 days of their first order — and how long the ones who came back took.
 *
 * ── WHAT THE VERSION THIS REPLACES GOT WRONG ──────────────────────────────
 *
 * It lived inline in `renderClientRetention` (renderer/analytics.js):
 *
 * 1. IT COUNTED VOIDED AND NON-BUSINESS ORDERS. A voided job, or a print the
 *    shop marked "not business", made a customer look like a regular.
 * 2. A SECOND ORDER THE SAME DAY WAS A RETURN, "in 0 days". It took the
 *    second DATE in the customer's list, so a customer who placed two jobs on
 *    their first visit counted as having come back at once — the best possible
 *    figure, from a customer who never returned. A return is an order on a
 *    LATER DAY than the first one. (Customer mix decides "new" by order
 *    identity instead; here the question is about time, so the day is right —
 *    the bug was counting a zero-day gap as a gap.)
 * 3. IT ASKED NEW CUSTOMERS A QUESTION THEY COULD NOT YET ANSWER. Every
 *    customer was in the denominator of every window, so one who first ordered
 *    last week counted as "did not return within 90 days". A shop that was
 *    growing — lots of recent first orders — read as one losing its
 *    customers. A window now counts only the customers whose first order is at
 *    least that many days old.
 * 4. "×orders" was English on every language's screen (the caller now has a
 *    key for it).
 * 5. Top returning clients ranked by order count with no tie-break, so equal
 *    counts came out in whatever order the book held them — and a customer
 *    with two orders on one day appeared in a list of RETURNING customers.
 *
 * Pure: no DOM, no clock — `today` is handed in as the shop's local day.
 */

function day(v) { return String(v == null ? '' : v).slice(0, 10); }
const DAY_RE = /^\d{4}-\d{2}-\d{2}$/;
const DEFAULT_WINDOWS = [30, 60, 90];

/** Whole days from one `YYYY-MM-DD` to another. Both read as UTC midnight so a
 *  daylight-saving change between them cannot make a day 23 hours long. */
function daysBetween(a, b) {
  return Math.round((Date.parse(b + 'T00:00:00Z') - Date.parse(a + 'T00:00:00Z')) / 86400000);
}

/**
 * @param {object} input
 *   orders   every order in the book
 *   today    the shop's local day, `YYYY-MM-DD`
 *   windows  days, default [30, 60, 90]
 *   top      how many returning customers to list, default 5
 * @param {object} deps
 *   isFinished        (order) => did it reach the customer?
 *   countsForBusiness (order) => is this the shop's trade?
 * @returns {{
 *   clients: number, returned: number, enough: boolean,
 *   windows: {days: number, eligible: number, returned: number, rate: number|null}[],
 *   avgDaysToReturn: number|null,
 *   top: {clientId: string, orders: number, visits: number, firstDay: string}[]
 * }}
 */
function retention(input, deps) {
  const i = input || {};
  const d = deps || {};
  const isFinished = typeof d.isFinished === 'function'
    ? d.isFinished : (o) => o && (o.status === 'completed' || o.status === 'delivered');
  const countsForBusiness = typeof d.countsForBusiness === 'function'
    ? d.countsForBusiness : (o) => !!o && o.nonBusiness !== true;
  const today = day(i.today);
  const windows = Array.isArray(i.windows) && i.windows.length ? i.windows : DEFAULT_WINDOWS;
  const topN = Number.isFinite(i.top) ? Math.max(0, i.top) : 5;

  const byClient = new Map();
  for (const o of Array.isArray(i.orders) ? i.orders : []) {
    if (!o || o.voidedAt || o.archived || !o.clientId) continue;
    if (!isFinished(o) || !countsForBusiness(o)) continue;
    const at = day(o.date);
    if (!DAY_RE.test(at)) continue;
    const id = String(o.clientId);
    if (!byClient.has(id)) byClient.set(id, []);
    byClient.get(id).push(at);
  }

  const people = [...byClient.entries()].map(([clientId, days]) => {
    const sorted = days.slice().sort();
    const firstDay = sorted[0];
    const later = sorted.find((x) => x > firstDay) || null;
    return {
      clientId,
      firstDay,
      orders: sorted.length,
      visits: new Set(sorted).size,
      gap: later ? daysBetween(firstDay, later) : null,
    };
  });

  const back = people.filter((p) => p.gap !== null);
  const rows = windows.map((n) => {
    // Only customers who have HAD n days. Without a `today` nobody can be
    // judged, so every window is empty rather than wrong.
    const eligible = today ? people.filter((p) => daysBetween(p.firstDay, today) >= n) : [];
    const returned = eligible.filter((p) => p.gap !== null && p.gap <= n).length;
    return {
      days: n,
      eligible: eligible.length,
      returned,
      rate: eligible.length ? returned / eligible.length : null,
    };
  });

  const top = back.slice()
    .sort((a, b) => b.orders - a.orders || b.visits - a.visits
      || a.firstDay.localeCompare(b.firstDay) || a.clientId.localeCompare(b.clientId))
    .slice(0, topN)
    .map(({ clientId, orders, visits, firstDay }) => ({ clientId, orders, visits, firstDay }));

  return {
    clients: people.length,
    returned: back.length,
    // Two customers is the least that makes a rate anything but one person's
    // habit — the threshold the other app always used.
    enough: people.length >= 2,
    windows: rows,
    // Over the customers who came back. It says nothing about the ones who have
    // not, which is what the rates are for.
    avgDaysToReturn: back.length ? back.reduce((s, p) => s + p.gap, 0) / back.length : null,
    top,
  };
}

const api = { retention, daysBetween, DEFAULT_WINDOWS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytClientRetention = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
