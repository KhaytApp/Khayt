'use strict';

/**
 * The money figures for one branch, computed by **the branch's own code**.
 *
 * [`branch-summary.js`](./branch-summary.js) refused to report money, and the
 * reason it gave is the reason this file exists rather than a few lines of
 * arithmetic next to the counts:
 *
 * > Revenue in this app is not "sum of price": voided invoices, refunds and
 * > credit notes all subtract, and getting that subtly wrong across branches
 * > would produce a chain total that disagrees with every branch's own
 * > reporting — a number the owner cannot reconcile and has no reason to
 * > distrust. If a revenue roll-up is wanted later it must reuse the same code
 * > the branch itself uses, not a second implementation that happens to look
 * > right.
 *
 * So it reuses it literally. `orderNetRevenueBase`, `orderOwedBase` and
 * `payStatus` are the same functions the branch's own dashboard and analytics
 * call, loaded from `renderer/currency.js` and `renderer/app-helpers.js`.
 * Nothing here re-derives what a credit note does.
 *
 * ## Why a vm context and not require()
 *
 * Both modules are `require`-able — the unit tests do it — but they end with
 * `Object.assign(global, api)`, so requiring them in the MAIN process would
 * define `payStatus`, `downloadBlob`, `getAllTags` and a dozen more on the main
 * process's `globalThis`. That is a collision waiting to happen in a file the
 * size of main.js.
 *
 * The deeper reason is per-branch state. `convertToBase` reads
 * `global.settings.currency` and `global.settings.exchangeRates` at CALL time,
 * and every branch has its own — so a single shared global would have to be
 * swapped around each branch and restored, and the first `await` threaded
 * through that region later would silently attribute one branch's money at
 * another branch's rates. A context per branch cannot have that bug: the
 * branch's settings and clients ARE the sandbox's globals, and they are gone
 * when it is.
 *
 * ## What it deliberately does not do
 *
 * **No cross-currency total.** Each figure is in that branch's own base
 * currency, and this module reports which. Two branches on different bases
 * cannot be added without applying somebody's exchange rates to somebody else's
 * books — see `totalMoney` in branch-summary.js, which refuses instead.
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');

/**
 * Loaded once and reused. Reading is the expensive part; compiling into a fresh
 * context per branch is not, and it is what keeps the branches apart.
 */
let SOURCES = null;
function sources() {
  if (SOURCES) return SOURCES;
  /* order-money.js FIRST, and from lib/ rather than renderer/.
   *
   * currency.js's money rules moved there so the Mac app could use the same
   * ones; currency.js now delegates to `global.KhaytOrderMoney`. Inside this
   * sandbox there is no `require` and no shared global, which is the whole
   * point of the sandbox — so the dependency has to be run in here too, before
   * the file that needs it. Without it every branch reports null. */
  const files = [
    ['lib', 'order-money.js'],
    ['renderer', 'currency.js'],
    ['renderer', 'app-helpers.js'],
  ];
  SOURCES = files.map(([dir, f]) => {
    // require.resolve so this follows the same path resolution as a require()
    // would — including from inside app.asar, where a hand-built path can miss.
    const full = require.resolve(path.join(__dirname, '..', dir, f));
    return { file: f, script: new vm.Script(fs.readFileSync(full, 'utf8'), { filename: full }) };
  });
  return SOURCES;
}

/**
 * A context holding one branch's money code bound to one branch's state.
 * Returns null if either module fails to load — the caller then reports no
 * money for that branch rather than a wrong number.
 */
function contextFor(store) {
  const sandbox = {
    // What the money functions actually read.
    settings: (store && store.settings) || {},
    clients: (store && Array.isArray(store.clients)) ? store.clients : [],
    printLog: (store && Array.isArray(store.printLog)) ? store.printLog : [],
    // The modules check for these before using them; give them somewhere
    // harmless to land rather than letting the load throw.
    module: { exports: {} },
    console,
  };
  vm.createContext(sandbox);
  try {
    for (const { script } of sources()) script.runInContext(sandbox);
  } catch (e) {
    return null;
  }
  if (typeof sandbox.orderNetRevenueBase !== 'function'
    || typeof sandbox.orderOwedBase !== 'function'
    || typeof sandbox.payStatus !== 'function') return null;
  return sandbox;
}

/**
 * Money for one decrypted branch store.
 *
 * `revenue` and `outstanding` reproduce the two totals the branch itself shows,
 * filter for filter:
 *
 * - **revenue** — `renderer/analytics.js`'s KPI total: completed or delivered,
 *   not voided, netted of credit notes.
 * - **outstanding** — the dashboard's: every order `payStatus` does not call
 *   paid, summed by `orderOwedBase`.
 *
 * Matching those filters matters more than improving them. A chain figure that
 * "corrects" a branch's own screen is a figure the owner cannot reconcile
 * against anything, and they have no way to know which of the two to believe.
 *
 * @returns {{currency: string, revenue: number, outstanding: number} | null}
 */
function moneyForBranch(store) {
  if (!store || typeof store !== 'object') return null;
  const ctx = contextFor(store);
  if (!ctx) return null;

  const log = Array.isArray(store.printLog) ? store.printLog : [];
  let revenue = 0;
  let outstanding = 0;
  try {
    for (const o of log) {
      if (!o || typeof o !== 'object') continue;
      const st = String(o.status || '');
      if ((st === 'completed' || st === 'delivered') && !o.voidedAt) {
        revenue += ctx.orderNetRevenueBase(o);
      }
      if (ctx.payStatus(o) !== 'paid') outstanding += ctx.orderOwedBase(o);
    }
  } catch (e) {
    return null;
  }

  return {
    currency: String((store.settings && store.settings.currency) || 'SAR'),
    revenue,
    outstanding,
  };
}

module.exports = { moneyForBranch };
