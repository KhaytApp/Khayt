'use strict';
/**
 * The figures behind three of Simple mode's reduced screens (S4, lib/feature-tiers.js
 * SIMPLE_MAP rows `loyalty`, `expenses` and `money`; Figma 7Iqw0GcrLLRW7CLDEhTa1P
 * "S4 · Simple mode (desktop)", cards 3–5).
 *
 * NOT A SECOND RULE BOOK. Each figure is an existing module's answer, narrowed
 * to what the smaller screen shows:
 *
 *   loyalty  — the tiers in settings.loyaltyTiers, as lib/loyalty.js keeps
 *              them (`cleanTiers`). Simple edits a tier's name, completed
 *              orders and discount, up to MAX_SIMPLE_TIERS. A tier Professional
 *              gave a spend threshold or a points multiplier is shown READ-ONLY
 *              and is never dropped or rewritten (Figma card 3 notes).
 *   expenses — this month's expenses, newest first, and their total
 *              (lib/expense-book.js `totals`).
 *   money    — earned this month (net of tax: lib/order-money.js
 *              `orderEarnedBase`, the ZATCA rule), what is owed and how much of
 *              it is overdue (lib/receivables.js `aged`, gross on purpose — a
 *              customer owes what they were charged), spent this month, the VAT
 *              due for the current return period (lib/vat-return.js `boxes`,
 *              only for a registered shop), who owes the most, the best
 *              customers this year (lib/top-lists.js `topClients`) and the
 *              products asked for most this month (`topProducts`).
 *
 * PURE: no DOM, no clock — `today` is handed in as a book day (YYYY-MM-DD).
 * Sibling modules are read from their globals in the renderer and through
 * `require` under Node.
 */
(function (global) {
  const MAX_SIMPLE_TIERS = 3;

  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };

  function sibling(name, path) {
    if (typeof global[name] !== 'undefined' && global[name]) return global[name];
    if (typeof require === 'function') { try { return require(path); } catch (_) { /* renderer / JSC */ } }
    return null;
  }

  /* ── Loyalty ───────────────────────────────────────────────────────── */

  /** Does this tier use anything Simple does not show? Then Simple keeps it
   *  as it is: a spend threshold, or a points multiplier other than 1. */
  function isProTier(tier) {
    if (!tier || typeof tier !== 'object') return false;
    if (num(tier.minSpend) > 0) return true;
    const mult = num(tier.pointsMultiplier);
    return mult > 0 && mult !== 1;
  }

  /** What Simple's loyalty card draws: one row per tier, in the order saved. */
  function loyaltyView(tiers) {
    const list = (Array.isArray(tiers) ? tiers : []).filter((t) => t && typeof t === 'object');
    const rows = list.map((t, index) => ({
      index,
      name: String(t.name == null ? '' : t.name),
      minOrders: Math.max(0, Math.floor(num(t.minOrders))),
      discountPct: Math.min(100, Math.max(0, num(t.discountPct))),
      readOnly: isProTier(t),
    }));
    return { rows, count: rows.length, max: MAX_SIMPLE_TIERS, canAdd: rows.length < MAX_SIMPLE_TIERS };
  }

  /** Change one tier's name, completed orders or discount. Everything else on
   *  the tier is kept; a read-only tier, an empty name or an unknown row
   *  changes nothing (an emptied name would make `cleanTiers` drop the tier). */
  function editTier(tiers, index, patch) {
    const list = Array.isArray(tiers) ? tiers.slice() : [];
    const tier = list[index];
    if (!tier || isProTier(tier) || !patch) return list;
    const next = { ...tier };
    if ('name' in patch) {
      const name = String(patch.name == null ? '' : patch.name).trim();
      if (name) next.name = name;
    }
    if ('minOrders' in patch) next.minOrders = Math.max(0, Math.floor(num(patch.minOrders)));
    if ('discountPct' in patch) next.discountPct = Math.min(100, Math.max(0, num(patch.discountPct)));
    list[index] = next;
    return list;
  }

  /** A new tier after the last, while there are fewer than three: named
   *  `name`, one order bar past the highest, with no discount yet. */
  function addTier(tiers, name) {
    const list = Array.isArray(tiers) ? tiers.slice() : [];
    if (list.length >= MAX_SIMPLE_TIERS) return list;
    const top = list.reduce((m, t) => Math.max(m, Math.floor(num(t && t.minOrders))), 0);
    list.push({ name: String(name || '').trim() || `Tier ${list.length + 1}`,
      minOrders: top > 0 ? top + 5 : 3, minSpend: 0, discountPct: 0 });
    return list;
  }

  /** Remove one tier — never a read-only one. */
  function removeTier(tiers, index) {
    const list = Array.isArray(tiers) ? tiers.slice() : [];
    if (!list[index] || isProTier(list[index])) return list;
    list.splice(index, 1);
    return list;
  }

  /* ── Expenses ──────────────────────────────────────────────────────── */

  /** This month's expenses, newest first, and what they come to. */
  function expensesThisMonth(expenses, today) {
    const month = String(today || '').slice(0, 7);
    const Book = sibling('KhaytExpenseBook', './expense-book.js');
    const rows = (Array.isArray(expenses) ? expenses : [])
      .filter((e) => e && String(e.date || '').slice(0, 7) === month)
      .sort((a, b) => String(b.date || '').localeCompare(String(a.date || '')));
    const total = Book ? Book.totals(rows).total : rows.reduce((s, e) => s + num(e.amount), 0);
    return { month, rows, total, count: rows.length };
  }

  /* ── Money ─────────────────────────────────────────────────────────── */

  /** The last day of the month after a period ends: when a Saudi return is due. */
  function saudiFilingDeadline(periodTo) {
    const m = /^(\d{4})-(\d{2})/.exec(String(periodTo || ''));
    if (!m) return '';
    const d = new Date(Date.UTC(+m[1], +m[2] + 1, 0));
    return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${String(d.getUTCDate()).padStart(2, '0')}`;
  }

  /**
   * The one-page Money summary.
   *
   * @param {object} book  { orders, expenses, clients, products }
   * @param {object} ctx   { settings, today, now?, currencies?, language?,
   *                         revenueOf?(order) — what the order charged, in the
   *                         shop's currency (renderer: orderNetRevenueBase) }
   */
  function moneySummary(book, ctx) {
    const b = book || {};
    const c = ctx || {};
    const settings = c.settings || {};
    const today = String(c.today || '').slice(0, 10);
    const month = today.slice(0, 7);
    const year = today.slice(0, 4);
    const orders = Array.isArray(b.orders) ? b.orders : [];
    const clients = Array.isArray(b.clients) ? b.clients : [];
    const moneyCtx = { settings, clients };

    const Money = sibling('KhaytOrderMoney', './order-money.js');
    const Status = sibling('KhaytOrderStatus', './order-status.js');
    const Scope = sibling('KhaytBusinessScope', './business-scope.js');
    const Receivables = sibling('KhaytReceivables', './receivables.js');
    const Top = sibling('KhaytTopLists', './top-lists.js');
    const VatReturn = sibling('KhaytVatReturn', './vat-return.js');
    const Periods = sibling('KhaytVatPeriods', './vat-periods.js');

    const counts = (o) => !Scope || Scope.countsForBusiness(o);
    const finished = (o) => (Status ? Status.isFinished(o) : (o.status === 'completed' || o.status === 'delivered'));
    const trade = orders.filter((o) => o && finished(o) && !o.voidedAt && counts(o));

    // Earned this month: finished jobs dated this month, net of tax.
    const monthJobs = trade.filter((o) => String(o.date || '').slice(0, 7) === month);
    const earned = monthJobs.reduce((s, o) => s + num(Money ? Money.orderEarnedBase(o, moneyCtx, c.currencies) : o.price), 0);

    // Owed: every unpaid amount, aged by its own due date.
    const aged = Receivables
      ? Receivables.aged(orders, { settings, clients, currencies: c.currencies, now: c.now, language: c.language })
      : { rows: [], total: 0 };
    const overdueJobs = new Set(aged.rows.filter((r) => r.overdue).map((r) => r.id));
    // Who owes me: summed per customer (orders carry the id, rows the name).
    const byOrder = new Map(orders.filter(Boolean).map((o) => [o.id, o]));
    const owers = new Map();
    for (const r of aged.rows) {
      const o = byOrder.get(r.id);
      const key = (o && o.clientId) || `name:${r.client}`;
      const row = owers.get(key) || { clientId: (o && o.clientId) || '', name: r.client || '', owed: 0 };
      row.owed += num(r.owed);
      owers.set(key, row);
    }
    const whoOwes = [...owers.values()].filter((r) => r.owed > 0).sort((a, b2) => b2.owed - a.owed).slice(0, 3);

    // Spent this month.
    const spent = expensesThisMonth(b.expenses, today);

    // VAT due for the return period holding today — a registered shop only.
    let vat = null;
    if (VatReturn && Periods) {
      const period = Periods.periodKeyOf(today, Periods.frequencyOf(settings));
      const bounds = period ? Periods.periodBounds(period) : null;
      if (bounds) {
        const boxes = VatReturn.boxes(orders, b.expenses || [], {
          settings, clients, currencies: c.currencies, from: bounds.from, to: bounds.to,
          revenueOf: typeof c.revenueOf === 'function' ? c.revenueOf
            : (o) => (Money ? Money.orderNetRevenueBase(o, moneyCtx, c.currencies) : num(o.price)),
        });
        if (boxes.vatRegistered) {
          vat = { period, from: bounds.from, to: bounds.to, due: Math.max(0, boxes.netVat), net: boxes.netVat,
            taxName: boxes.taxName, deadline: boxes.isSaudiForm ? saudiFilingDeadline(bounds.to) : '' };
        }
      }
    }

    const topCtx = { settings, clients, products: b.products || [], currencies: c.currencies, language: c.language };
    const yearJobs = trade.filter((o) => String(o.date || '').slice(0, 4) === year);
    const bestCustomers = Top ? Top.topClients(yearJobs, topCtx, { limit: 3 }) : [];
    // Top products this month: the same rule as Simple Analytics had
    // (lib/top-lists.js topSellers, UI review X14): a job is its catalogue
    // product when it has one and otherwise its project name; tags never.
    const topProducts = Top ? Top.topSellers(monthJobs, topCtx, { limit: 3 }) : [];

    return {
      month, year,
      earned: { total: earned, jobs: monthJobs.length },
      owed: { total: aged.total, overdue: overdueJobs.size },
      spent: { total: spent.total, count: spent.count },
      vat,
      whoOwes,
      bestCustomers: bestCustomers.map((r) => ({ clientId: r.id, name: r.name, revenue: r.revenue })),
      topProducts: topProducts.map((r) => ({ productId: r.productId, name: r.name, count: r.count, revenue: r.revenue })),
    };
  }

  const api = { MAX_SIMPLE_TIERS, isProTier, loyaltyView, editTier, addTier, removeTier,
    expensesThisMonth, saudiFilingDeadline, moneySummary };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSimpleScreens = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
