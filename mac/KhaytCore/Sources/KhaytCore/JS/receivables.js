'use strict';
/**
 * Who owes the shop money, and how long they have owed it.
 *
 * Lifted out of renderer/analytics.js's `renderAgedReceivables`, which
 * computed the whole thing inline — so the Mac app could show what a shop was
 * owed in total and not who, or since when, which is the half a shop acts on.
 *
 * PURE: no DOM, no clock beyond the `now` it is handed. `KhaytOrderMoney` and
 * `KhaytOrderPayment` are consulted through the globals they assign
 * themselves to, present in both apps.
 *
 * WHAT THE RULE IS, and every line of it was a decision in the original:
 *
 * * A VOIDED order is not a receivable. It is a cancelled invoice, and dunning
 *   a customer for one is the worst thing this screen could cause.
 * * An order on an INSTALMENT PLAN is aged by each unpaid instalment's OWN due
 *   date, not by the order's. A plan agreed in January with a payment due in
 *   June is not six months overdue in July; it is one month overdue.
 * * Everything else ages from the order's date, because that is when the shop
 *   did the work.
 * * The amount owed is `orderOwedBase` — the price less credit notes, less
 *   what has been paid, in the shop's own currency — so a foreign order is
 *   comparable with the rest.
 */
(function (global) {

  const DAY_MS = 86400000;
  /** The buckets a shop reads, oldest last. */
  const BUCKETS = ['0-30', '31-60', '61-90', '90+'];

  const money = () => (typeof global.KhaytOrderMoney !== 'undefined') ? global.KhaytOrderMoney : null;
  const payment = () => (typeof global.KhaytOrderPayment !== 'undefined') ? global.KhaytOrderPayment : null;
  /** The content-language rules, however this file happens to be loaded. */
  function languages() {
    if (typeof global.KhaytContentLanguages !== 'undefined') return global.KhaytContentLanguages;
    try { return require('./content-languages.js'); } catch (e) { return null; }
  }

  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };

  /** Which bucket a number of days outstanding falls in. */
  function bucketFor(days) {
    if (days <= 30) return BUCKETS[0];
    if (days <= 60) return BUCKETS[1];
    if (days <= 90) return BUCKETS[2];
    return BUCKETS[3];
  }

  /** Whole days between a `YYYY-MM-DD` and the day `now` falls on, never negative. */
  function daysSince(dateStr, now) {
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const from = new Date(String(dateStr || '').slice(0, 10) + 'T00:00:00');
    if (isNaN(from.getTime())) return 0;
    return Math.max(0, Math.floor((today - from) / DAY_MS));
  }

  /**
   * What the shop is owed, aged.
   *
   * `ctx`: `{ settings, clients, currencies, now, language }`.
   * Returns `{ rows, buckets, total }` — every unpaid amount with its age and
   * bucket, the totals per bucket, and what it all comes to.
   */
  function aged(orders, ctx) {
    const c = ctx || {};
    const now = c.now instanceof Date ? c.now : new Date();
    const M = money();
    const P = payment();
    const moneyCtx = { settings: c.settings || {}, clients: c.clients || [] };
    const known = c.currencies || null;
    const clients = Array.isArray(c.clients) ? c.clients : [];

    const statusOf = (o) => (P ? P.statusOf(o, moneyCtx) : (o.paymentStatus || 'unpaid'));
    const owedOf = (o) => (M ? M.orderOwedBase(o, moneyCtx, known) : Math.max(0, num(o.price) - num(o.paidAmount)));

    const rows = [];
    let total = 0;
    for (const o of (orders || [])) {
      if (!o || o.voidedAt) continue;
      const status = statusOf(o);
      if (status !== 'unpaid' && status !== 'partial') continue;

      const client = o.clientId ? clients.find((x) => x && x.id === o.clientId) : null;
      // The customer's name in the language the SHOP writes, by the shared
      // fallback. `nameEn || nameAr` is blank for a shop that writes Turkish,
      // and the name is the only thing on this row a person can act on.
      const name = (client && named(client, c)) || o.client || '';

      if (Array.isArray(o.instalments) && o.instalments.length > 0) {
        for (const ins of o.instalments) {
          if (!ins || ins.paid) continue;
          const owed = Math.max(0, num(ins.amount));
          if (owed <= 0) continue;
          const days = daysSince(ins.dueDate || o.date, now);
          rows.push({ id: o.id, project: o.project || '', client: name, owed, days,
                      bucket: bucketFor(days), payStatus: status, instalment: true });
          total += owed;
        }
        continue;
      }
      const owed = owedOf(o);
      if (owed <= 0) continue;
      const days = daysSince(o.date || o.timestamp, now);
      rows.push({ id: o.id, project: o.project || '', client: name, owed, days,
                  bucket: bucketFor(days), payStatus: status, instalment: false });
      total += owed;
    }

    const buckets = BUCKETS.map((label) => {
      const items = rows.filter((r) => r.bucket === label);
      return { label, count: items.length, total: items.reduce((s, r) => s + r.owed, 0) };
    });
    // Oldest first: what a shop chases is the top of this list.
    rows.sort((a, b) => b.days - a.days || b.owed - a.owed);
    return { rows, buckets, total };
  }

  /**
   * A customer's name, as the shop's own content languages decide it.
   *
   * Nothing when the rule is not there to ask — the caller falls back to the
   * name denormalised onto the order, which is a real name somebody typed. A
   * hand-rolled `nameEn || nameAr` here would be blank for a shop that writes
   * Turkish, and the name is the only thing on this row a person can act on.
   */
  function named(client, c) {
    const L = languages();
    if (!L) return '';
    return L.read(client, 'name', c.language || 'en', c.settings || {}) || '';
  }

  const api = { BUCKETS, bucketFor, daysSince, aged };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytReceivables = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
