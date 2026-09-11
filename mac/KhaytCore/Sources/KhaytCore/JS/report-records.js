'use strict';

(function (global) {
/**
 * One order, flattened into the row a report is built from.
 *
 * ── WHY THIS IS NOT IN THE RENDERER ANY MORE ──────────────────────────────
 *
 * `report-builder.js` selects columns, filters and renders — it is pure, it is
 * tested, and it says of itself that the caller "flattens orders into plain
 * records (resolving client/machine names + base-currency amounts)". That
 * flattening was the renderer's, inline, twenty lines in the middle of a modal.
 *
 * So a shop's custom report existed in one app and could not exist in the other
 * without writing those twenty lines a second time — and they are not twenty
 * lines of formatting. `price` is revenue converted to the shop's base
 * currency, `balance` is what is still owed after credits, `paymentStatus` is
 * the rule that decides what "paid" means. Reimplementing those is how two apps
 * come to disagree about a shop's money, which is the one thing this codebase
 * spends most of its comments preventing.
 *
 * Every figure here therefore comes from a module that already owns it:
 * `order-money.js` for the three amounts and the currency, `order-payment.js`
 * for the status. This assembles; it decides nothing.
 *
 * ── VOIDED ORDERS ARE NOT ROWS ────────────────────────────────────────────
 *
 * They are dropped before anything is counted, which is what the renderer did
 * and is worth keeping explicit: a voided order is not a sale that happened and
 * a report that lists it invites somebody to add up a column that includes it.
 */

/** `name` for a record the shop may have written in more than one language. */
function plainName(row, localName) {
  if (!row) return '';
  if (typeof localName === 'function') return localName(row) || '';
  return row.name || '';
}

/**
 * Flatten orders into report records.
 *
 * @param {Array} orders the print log
 * @param {object} deps
 *   money      lib/order-money.js
 *   payment    lib/order-payment.js
 *   clients    the shop's clients, for resolving a name
 *   machines   the shop's machines, likewise
 *   ctx        what order-money needs to convert — { settings, clients }
 *   localName  optional: picks a language out of a multi-language name
 * @returns {Array<object>} one record per order, in the shape report-builder
 *   expects — see FIELDS there, which is the list this must satisfy.
 */
function reportRecords(orders, deps = {}) {
  const list = Array.isArray(orders) ? orders : [];
  const money = deps.money;
  const payment = deps.payment;
  if (!money || !payment) return [];
  const clients = Array.isArray(deps.clients) ? deps.clients : [];
  const machines = Array.isArray(deps.machines) ? deps.machines : [];
  const ctx = deps.ctx || {};
  const localName = deps.localName;

  return list
    .filter((o) => o && !o.voidedAt)
    .map((o) => {
      const client = o.clientId ? clients.find((c) => c && c.id === o.clientId) : null;
      const machine = o.machineId ? machines.find((m) => m && m.id === o.machineId) : null;
      return {
        id: o.id,
        // The DAY, not the timestamp. A report grouped by date must not put
        // two of the same day in different buckets because one carried a time.
        date: String(o.date || '').slice(0, 10),
        project: o.project || '',
        client: plainName(client, localName),
        status: o.status,
        material: o.material || '',
        printTime: +o.printTime || 0,
        machine: machine ? (machine.name || '') : '',
        // Rounded to whole units, as the renderer has always shown them: a
        // report is read across a row, and two decimal places on every money
        // column is noise in a table nobody sums by hand.
        price: Math.round(money.orderRevenueBase(o, ctx)),
        paidAmount: Math.round(money.convertToBase(+o.paidAmount || 0, money.orderCurrency(o, ctx), ctx)),
        balance: Math.round(money.orderOwedBase(o, ctx)),
        paymentStatus: payment.statusOf(o),
        dueDate: o.dueDate || '',
        tags: Array.isArray(o.tags) ? o.tags : [],
      };
    });
}

const api = { reportRecords, plainName };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytReportRecords = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
