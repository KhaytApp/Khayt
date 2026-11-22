'use strict';

/**
 * A one-line summary of another branch's store, for the organisation overview.
 *
 * Pure: a decrypted snapshot in, counts out. It lives here rather than in the
 * renderer so only the SUMMARY crosses IPC — a branch store can be megabytes, and
 * the overview needs a handful of numbers from it.
 *
 * THE TWO THINGS THIS USED TO REFUSE, AND THE TERMS THEY CAME BACK ON
 *
 * **Money.** Refused because revenue here is not "sum of price": voided
 * invoices, refunds and credit notes all subtract, and getting that subtly wrong
 * across branches would produce a chain total that disagrees with every branch's
 * own reporting — a number the owner cannot reconcile and has no reason to
 * distrust. The condition set then was that a roll-up "must reuse the same code
 * the branch itself uses, not a second implementation that happens to look
 * right", and [`branch-money.js`](./branch-money.js) does exactly that: the
 * branch's own `orderNetRevenueBase`, `orderOwedBase` and `payStatus`, run
 * against that branch's own settings and exchange rates. Nothing in this file
 * knows what a credit note is.
 *
 * **Dates.** Refused because "due today" needs a calendar day, and the branch may
 * be in another timezone than the person reading. That is still true, and the
 * resolution is that this module never invents the day: the caller passes the
 * reader's own `today` (`YYYY-MM-DD`), and with no `today` the date fields are
 * simply absent. Orders carry `dueDate` as a plain `YYYY-MM-DD`, so the
 * comparison is lexicographic and no timezone arithmetic happens anywhere —
 * which is the same thing `formatDueDateBadge` does on the branch's own screen.
 * `lastActivity` stays a raw ISO timestamp for the renderer to format.
 *
 * What it reports is what a chain owner asks at a glance: how much work is
 * moving, how much is stuck, how much is late, what it earned, what it is owed,
 * and when it last did anything.
 */

const { moneyForBranch } = require('./branch-money');

/** Statuses that mean the order is still work, not history. */
const IN_FLIGHT = new Set(['pending', 'printing', 'post', 'qc']);

/**
 * Count orders by what the shop would call their state, ignoring archived ones.
 *
 * @param {object} store   a decrypted branch store
 * @param {object} [opts]
 * @param {string} [opts.today]  the READER's calendar day, `YYYY-MM-DD`. Supply
 *   it and `overdue` / `dueToday` are counted; omit it and they are absent
 *   rather than guessed — this process must not decide which day it is for
 *   someone who may be in another timezone than the branch.
 */
function summarizeBranch(store, { today } = {}) {
  const out = {
    orders: 0, inFlight: 0, printing: 0, onHold: 0, quotes: 0, done: 0,
    lastActivity: null, clients: 0, unreadable: false,
  };
  if (!store || typeof store !== 'object') { out.unreadable = true; return out; }

  // `YYYY-MM-DD` and nothing else. A malformed day would compare lexicographically
  // against every dueDate and quietly call the whole branch overdue.
  const day = /^\d{4}-\d{2}-\d{2}$/.test(String(today || '')) ? String(today) : null;
  if (day) { out.overdue = 0; out.dueToday = 0; }

  const log = Array.isArray(store.printLog) ? store.printLog : [];
  for (const o of log) {
    if (!o || typeof o !== 'object') continue;
    // Archived orders are the shop's own "put this away" — every active-order
    // view in the app excludes them, so a cross-branch view that counted them
    // would report more work in flight than the branch's own screen does.
    if (o.archived) continue;
    out.orders++;
    const st = String(o.status || '');
    if (IN_FLIGHT.has(st)) out.inFlight++;
    if (st === 'printing') out.printing++;
    if (st === 'on_hold') out.onHold++;
    if (st === 'quote') out.quotes++;
    if (st === 'completed' || st === 'delivered') out.done++;

    // Late only counts against work still in flight: a delivered order that
    // missed its date is a fact about last month, and the branch's own board
    // stops badging it too.
    if (day && IN_FLIGHT.has(st) && typeof o.dueDate === 'string' && o.dueDate) {
      if (o.dueDate < day) out.overdue++;
      else if (o.dueDate === day) out.dueToday++;
    }

    // Raw ISO, highest wins. Formatting is the renderer's job — it has the
    // locale-aware helpers, and this module must not guess at a calendar day.
    const ts = typeof o.updatedAt === 'string' ? o.updatedAt : null;
    if (ts && (!out.lastActivity || ts > out.lastActivity)) out.lastActivity = ts;
  }

  out.clients = Array.isArray(store.clients) ? store.clients.length : 0;

  // Money, by the branch's own reckoning. null when its code could not be run
  // against this store — the overview then shows counts and says nothing about
  // money for that branch, which is the only honest option.
  out.money = moneyForBranch(store);
  return out;
}

/**
 * Add up several branch summaries. Only the countable things — deliberately no
 * lastActivity roll-up, because "the chain last did something at X" is a fact
 * about one branch dressed up as a fact about all of them.
 */
function totalBranches(summaries) {
  const total = { branches: 0, reachable: 0, orders: 0, inFlight: 0, printing: 0, onHold: 0, quotes: 0, clients: 0 };
  let dated = false;
  for (const s of summaries || []) {
    total.branches++;
    if (!s || s.unreadable) continue;
    total.reachable++;
    for (const k of ['orders', 'inFlight', 'printing', 'onHold', 'quotes', 'clients']) {
      total[k] += Number(s[k]) || 0;
    }
    // Only present when the caller supplied a day, and then present on every
    // readable branch — so summing is safe, and absent stays absent.
    if (typeof s.overdue === 'number') {
      if (!dated) { total.overdue = 0; total.dueToday = 0; dated = true; }
      total.overdue += s.overdue;
      total.dueToday += Number(s.dueToday) || 0;
    }
  }
  total.money = totalMoney(summaries);
  return total;
}

/**
 * Add up the branches' money — or refuse, and say why.
 *
 * **Two branches on different base currencies cannot be added.** Doing it would
 * mean applying somebody's exchange rates to somebody else's books, and the
 * result would be a headline figure that reconciles against no branch and no
 * bank. `settings.exchangeRates` is per shop and set by hand, so the HQ's rates
 * are not more authoritative than the branch's — there is no rate here that is
 * the right one to use.
 *
 * So: one base currency across every readable branch, or `mixed`. A `mixed`
 * result still names the currencies, because "we cannot total this" is only
 * useful to an owner who can see why.
 *
 * A branch whose money could not be read at all (`money === null`) makes the
 * total `partial`: the number is real but it is not the whole chain, and an
 * owner reading a chain total has every right to assume it is.
 */
function totalMoney(summaries) {
  const list = (summaries || []).filter((s) => s && !s.unreadable);
  if (!list.length) return null;

  const withMoney = list.filter((s) => s.money && typeof s.money === 'object');
  if (!withMoney.length) return null;

  const currencies = [...new Set(withMoney.map((s) => String(s.money.currency || '')))];
  if (currencies.length > 1) {
    return { mixed: true, currencies: currencies.sort(), partial: withMoney.length !== list.length };
  }

  let revenue = 0;
  let outstanding = 0;
  for (const s of withMoney) {
    revenue += Number(s.money.revenue) || 0;
    outstanding += Number(s.money.outstanding) || 0;
  }
  return {
    mixed: false,
    currency: currencies[0],
    revenue,
    outstanding,
    partial: withMoney.length !== list.length,
  };
}

module.exports = { summarizeBranch, totalBranches, totalMoney, IN_FLIGHT };
