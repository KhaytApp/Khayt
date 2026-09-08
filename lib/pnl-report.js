/**
 * P&L summary — turn a period's orders + expenses into an income-statement
 * summary and a spreadsheet-ready CSV. Pure (no DOM / no currency lookups) so
 * it is unit-testable; the renderer scopes the data to the selected analytics
 * date range, converts to base currency, then hands plain numbers in here.
 */
(function (global) {
  const round2 = (n) => Math.round((+n || 0) * 100) / 100;

  /**
   * @param {object} input
   * @param {Array<{revenue:number, cogs:number, vat?:number}>} input.orders base-currency per order
   * @param {Array<{amount:number, category?:string}>} input.expenses base-currency
   * @param {string} [input.label] period label (e.g. "This month")
   * @returns {object} summary with totals + expenses grouped by category
   */
  function computePnl(input) {
    input = input || {};
    const orders = Array.isArray(input.orders) ? input.orders : [];
    const expenses = Array.isArray(input.expenses) ? input.expenses : [];

    let revenue = 0, cogs = 0, vatCollected = 0;
    for (const o of orders) {
      revenue += +o.revenue || 0;
      cogs += +o.cogs || 0;
      vatCollected += +o.vat || 0;
    }
    const byCat = {};
    let expensesTotal = 0;
    for (const e of expenses) {
      const amt = +e.amount || 0;
      const cat = (e.category && String(e.category).trim()) || 'Uncategorized';
      byCat[cat] = (byCat[cat] || 0) + amt;
      expensesTotal += amt;
    }
    const grossProfit = revenue - cogs;
    const netProfit = grossProfit - expensesTotal;
    return {
      label: input.label || '',
      orderCount: orders.length,
      revenue: round2(revenue),
      cogs: round2(cogs),
      grossProfit: round2(grossProfit),
      grossMargin: revenue > 0 ? Math.round((grossProfit / revenue) * 1000) / 10 : 0,
      expensesTotal: round2(expensesTotal),
      expensesByCategory: Object.keys(byCat).sort((a, b) => byCat[b] - byCat[a])
        .map((category) => ({ category, amount: round2(byCat[category]) })),
      vatCollected: round2(vatCollected),
      netProfit: round2(netProfit),
    };
  }

  // Spreadsheet-safe cell: quoted + quote-escaped. Numbers pass through as-is
  // (a leading "-" is a real value); only text gets formula-neutralized.
  function cell(v) {
    if (typeof v === 'number') return '"' + v + '"';
    const s = v == null ? '' : String(v);
    const safe = /^[=+\-@\t\r]/.test(s) ? "'" + s : s;
    return '"' + safe.replace(/"/g, '""') + '"';
  }

  /** Render a computed summary to a two-column CSV (Item, Amount). */
  function pnlToCsv(summary, opts) {
    opts = opts || {};
    const cur = opts.currency || '';
    const L = opts.labels || {};
    const lab = (k, d) => L[k] || d;
    const amtHeader = cur ? `${lab('amount', 'Amount')} (${cur})` : lab('amount', 'Amount');
    const rows = [
      [lab('title', 'P&L summary'), summary.label || ''],
      [lab('item', 'Item'), amtHeader],
      [lab('orders', 'Orders'), summary.orderCount],
      [lab('revenue', 'Revenue'), summary.revenue],
      [lab('cogs', 'Cost of goods sold'), -summary.cogs],
      [lab('gross', 'Gross profit'), summary.grossProfit],
      [lab('gross_margin', 'Gross margin %'), summary.grossMargin],
      ['', ''],
      [lab('opex', 'Operating expenses'), -summary.expensesTotal],
    ];
    for (const e of summary.expensesByCategory) rows.push(['  ' + e.category, -e.amount]);
    rows.push(['', '']);
    rows.push([lab('vat', 'VAT collected'), summary.vatCollected]);
    rows.push([lab('net', 'Net profit'), summary.netProfit]);
    return '﻿' + rows.map((r) => r.map(cell).join(',')).join('\r\n');
  }

  /**
   * The shop's quarters: what it earned, what it spent, what it kept.
   *
   * Lifted out of renderer/analytics.js's `renderPnLSection`, which built the
   * whole table inline — so the Mac app had no P&L at all and no way to have
   * one without a second opinion about which orders count.
   *
   * WHAT THE RULES ARE, each of which was a comment on the original:
   *
   * * A VOIDED order is skipped. Voiding keeps `status: 'completed'` by design
   *   (invoicing.js) and only sets `voidedAt`, so a status-only filter books a
   *   cancelled invoice as full revenue AND full VAT collected.
   * * Revenue is `orderNetRevenueBase` — the price less credit notes, in the
   *   shop's own currency.
   * * VAT is `computeTax(...).taxTotal`, not tax extracted from the revenue.
   *   Extracting is right only when prices include tax; computeTax extracts
   *   under inclusive pricing and ADDS under exclusive, which is right either
   *   way.
   * * Fixed overhead applies to EVERY quarter with activity, not just the
   *   current one. Charging it only to the current quarter overstated profit
   *   in every historical quarter, so the present always looked worse than the
   *   past — which invalidates quarter-over-quarter comparison, the table's
   *   whole purpose. The quarter in progress is pro-rated by days elapsed so
   *   it is not charged a full quarter's rent on day three.
   *
   * `ctx`: `{ settings, clients, currencies, now }`. The siblings are consulted
   * through the globals they assign themselves to, present in both apps.
   *
   * Returns rows newest first: `{ period, orders, revenue, shipping, expenses,
   * fixed, vatCollected, net }`.
   */
  function pnlByPeriod(orders, expenses, ctx) {
    const c = ctx || {};
    const now = c.now instanceof Date ? c.now : new Date();
    const money = (typeof global !== 'undefined' && global.KhaytOrderMoney) || null;
    const tax = (typeof global !== 'undefined' && global.KhaytTax) || null;
    const moneyCtx = { settings: c.settings || {}, clients: c.clients || [] };
    const known = c.currencies || null;
    const profile = tax ? tax.profileFromSettings(c.settings || {}) : null;

    const quarterOf = (dateStr) => {
      const d = new Date(String(dateStr || '') + 'T00:00:00');
      if (isNaN(d)) return null;
      return `${d.getFullYear()}-Q${Math.ceil((d.getMonth() + 1) / 3)}`;
    };

    const byQuarter = {};
    const at = (key) => {
      if (!byQuarter[key]) {
        byQuarter[key] = {
          period: key, orders: 0, revenue: 0, shipping: 0, expenses: 0,
          vatCollected: 0, vatReclaimable: 0,
        };
      }
      return byQuarter[key];
    };

    for (const o of orders || []) {
      if (!o || o.status !== 'completed' || o.voidedAt) continue;
      const key = quarterOf(o.date);
      if (!key) continue;
      const row = at(key);
      // WHAT THE CUSTOMER PAID, which is not what the shop earned.
      const charged = money ? money.orderNetRevenueBase(o, moneyCtx, known) : (+o.price || 0);
      // REVENUE IS NET OF TAX. ZATCA and IFRS 15 both treat tax collected on a
      // sale as money held for the government — a liability until it is
      // remitted, and never income. This report showed the charged figure as
      // revenue and subtracted only expenses from it, so an inclusive-VAT shop
      // read its own VAT as profit: 20,664.08 where 17,337.45 was kept, in the
      // quarter it would look at to decide whether it was making money.
      //
      // The accountant export next door has always split it correctly
      // (`vatSplit` in `lib/accounting-export.js`), so the same book answered
      // one way to the shop and another to its accountant.
      //
      // `netOfTax` is mode-aware: an exclusive-VAT shop's price IS the net
      // figure and comes back unchanged, and a shop that is not registered has
      // nothing to take out.
      const revenue = (tax && profile) ? tax.netOfTax(charged, profile) : charged;
      row.orders += 1;
      row.revenue += revenue;
      row.shipping += money
        ? money.convertToBase(+o.shippingCost || 0, money.orderCurrency(o, moneyCtx, known), moneyCtx)
        : (+o.shippingCost || 0);
      // On what was CHARGED, not on the net figure above — computing tax on a
      // figure the tax has already been taken out of understates it.
      row.vatCollected += (tax && profile) ? tax.computeTax(charged, profile).taxTotal : 0;
    }
    for (const e of expenses || []) {
      if (!e) continue;
      const key = quarterOf(e.date);
      if (!key) continue;
      const paid = +e.amount || 0;
      // THE TAX ON A PURCHASE IS NOT A COST — for a registered shop. It is
      // reclaimed from the authority, so it belongs against the tax collected
      // on sales and not in the profit and loss. A shop that is NOT registered
      // reclaims nothing, and every riyal it paid is a cost.
      //
      // `vatAmount` is what the supplier's invoice says, because that is what a
      // shop has in front of it: rates differ by line, imports and exempt
      // purchases carry none, and a rate typed once would be wrong for the
      // receipt with two of them on it. An expense that does not carry the
      // field — which is every expense recorded before this — reclaims nothing,
      // and nothing about an old book changes.
      const claimable = (tax && profile && profile.rates && profile.rates.length)
        ? Math.min(paid, Math.max(0, +e.vatAmount || 0))
        : 0;
      at(key).expenses += paid - claimable;
      at(key).vatReclaimable += claimable;
    }

    const fixedPerQuarter = ((c.settings || {}).fixedCosts || [])
      .reduce((s, fc) => s + (+((fc && fc.amount)) || 0), 0) * 3;
    const nowQuarter = `${now.getFullYear()}-Q${Math.ceil((now.getMonth() + 1) / 3)}`;
    const elapsed = (() => {
      const startMonth = Math.floor(now.getMonth() / 3) * 3;
      const start = new Date(now.getFullYear(), startMonth, 1);
      const end = new Date(now.getFullYear(), startMonth + 3, 0);
      const total = Math.round((end - start) / 86400000) + 1;
      const done = Math.round((now - start) / 86400000) + 1;
      return Math.max(0, Math.min(1, done / total));
    })();

    return Object.keys(byQuarter).sort().reverse().map((key) => {
      const row = byQuarter[key];
      const fixed = key === nowQuarter ? fixedPerQuarter * elapsed : fixedPerQuarter;
      return {
        period: key,
        orders: row.orders,
        revenue: round2(row.revenue),
        shipping: round2(row.shipping),
        expenses: round2(row.expenses),
        fixed: round2(fixed),
        vatCollected: round2(row.vatCollected),
        vatReclaimable: round2(row.vatReclaimable),
        // What the shop actually owes the authority for the quarter: the tax it
        // charged, less the tax it paid. Negative means a refund is due, which
        // is a real position for a quarter that bought a printer.
        vatDue: round2(row.vatCollected - row.vatReclaimable),
        net: round2(row.revenue - row.expenses - fixed),
      };
    });
  }

  const api = { computePnl, pnlToCsv, pnlByPeriod };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPnl = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
