'use strict';
/**
 * What an hour of printing has to carry of the rent.
 *
 * ── WHY ───────────────────────────────────────────────────────────────────
 *
 * Shop owners kept saying the same thing: they priced every job on filament,
 * wear, power and their own time, and forgot the money that goes out whether
 * anything prints — rent, the internet, the slicer subscription. Khayt already
 * holds those figures (`settings.fixedCosts`, monthly), but they only ever fed
 * the break-even target and the P&L, never a quote. A shop could do everything
 * the calculator asked and still be under water at the end of the month.
 *
 * So, OPT-IN: when the shop turns it on, a quote gets one more cost line,
 *
 *     overhead = (monthly fixed costs ÷ expected monthly print hours) × print hours
 *
 * and it is marked up like every other cost. Off — which is every book that
 * exists today — nothing about any price changes.
 *
 * ── WHICH COSTS ───────────────────────────────────────────────────────────
 *
 * A fixed cost is `{ id, name, amount }` and nothing more: there is no
 * category and no "this is overhead" flag. So it is ALL of them, with one
 * exception: a row that reads as PAY (salaries, wages — `KhaytPnl.looksLikePayroll`,
 * the P&L's own words for it) is LEFT OUT. The calculator already charges
 * people's time as its own labour line (prep and post-processing × labour
 * rate); spreading the same wages over the print hours as well would bill the
 * customer for them twice. What was left out is returned, by name, so the
 * settings screen can say so rather than leave the shop wondering why its
 * total does not match.
 *
 * ── HOW MANY HOURS ────────────────────────────────────────────────────────
 *
 * The divisor decides everything, so it is taken from the best thing known:
 *
 *   1. the shop's own figure (`settings.overheadPerHour.monthlyHours`);
 *   2. otherwise the sum over its working machines of
 *      `KhaytDepreciation.hoursPerMonth` — the rule that already answers
 *      "how many hours a month does this machine print" for depreciation:
 *      its typed monthly hours, else what it actually printed in the last
 *      ninety days, else its daily target × 365.25 ÷ 12. One rule, not two.
 *
 * And then a FLOOR. Twenty hours a month is less than an hour a day across the
 * whole shop. Below it the rate stops being a price and becomes a punishment —
 * 2,100 of rent over the ten measured hours of a quiet month is 210 an hour on
 * the next quote — so there is NO RATE, and the reason says why, rather than an
 * absurd one written silently into a customer's price.
 *
 * ── WHAT IT DOES NOT TOUCH ────────────────────────────────────────────────
 *
 * A part's frozen cost (`calculator-cost.js`). The overhead is a QUOTE line
 * (`pricing.js` `quoteTotal`), recorded on the job as `overheadCost`, and never
 * inside `baseCost` — because the P&L and the break-even target already count
 * the fixed costs themselves, once, and a part cost carrying a slice of them
 * would count them a second time.
 *
 * PURE: no DOM, no clock. `today` is passed in.
 */
(function (global) {

  /** Below this many print hours a month there is no honest hourly figure. */
  const MIN_MONTHLY_HOURS = 20;
  /** A shop-typed figure above this is a typo, not a plan (100 machines × 24 h × 31 d is 74,400). */
  const MAX_MONTHLY_HOURS = 100000;

  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };
  const round = (n, dp) => { const f = Math.pow(10, dp); return Math.round(n * f) / f; };

  const sibling = (name, file) => {
    if (typeof global[name] !== 'undefined') return global[name];
    try { return typeof require === 'function' ? require(file) : null; } catch (e) { return null; }
  };
  const depreciation = () => sibling('KhaytDepreciation', './depreciation.js');
  const pnl = () => sibling('KhaytPnl', './pnl-report.js');

  /**
   * The setting as the book keeps it. Absent, or anything that is not an
   * object, is OFF with no figure: every book written before this existed.
   */
  function clean(input) {
    const o = input && typeof input === 'object' ? input : {};
    const hours = num(o.monthlyHours);
    return {
      enabled: o.enabled === true,
      monthlyHours: hours > 0 ? round(Math.min(hours, MAX_MONTHLY_HOURS), 2) : 0,
    };
  }

  /** Whether a fixed cost is pay — the P&L's rule, so the two cannot disagree. */
  function isPay(row) {
    const P = pnl();
    const text = (row && (row.name || row.label)) || '';
    return !!(P && typeof P.looksLikePayroll === 'function' && P.looksLikePayroll(text));
  }

  /**
   * The monthly costs an hour of printing carries: every fixed cost with an
   * amount, less pay. `left` names what was left out and why it was.
   */
  function monthlyCosts(settings) {
    const rows = Array.isArray(settings && settings.fixedCosts) ? settings.fixedCosts : [];
    const included = [];
    const left = [];
    for (const r of rows) {
      const amount = num(r && r.amount);
      if (!(amount > 0)) continue;
      const row = { name: String((r && (r.name || r.label)) || ''), amount };
      (isPay(r) ? left : included).push(row);
    }
    return {
      total: round(included.reduce((s, r) => s + r.amount, 0), 2),
      included,
      left,
    };
  }

  /**
   * How many hours a month the shop prints, and where that figure came from:
   * `shop` (typed), `machines` (summed per machine by the depreciation rule),
   * or null when nothing is known.
   */
  function expectedHours(ctx) {
    const c = ctx || {};
    const own = clean(c.settings && c.settings.overheadPerHour).monthlyHours;
    if (own > 0) return { hours: own, source: 'shop' };
    const D = depreciation();
    if (!D || typeof D.hoursPerMonth !== 'function') return { hours: null, source: null };
    const orders = Array.isArray(c.orders) ? c.orders : [];
    let total = 0;
    let counted = 0;
    for (const m of (Array.isArray(c.machines) ? c.machines : [])) {
      if (!m || !m.id || m.status === 'retired') continue;
      const recent = (c.today && typeof D.recentMonthlyHours === 'function')
        ? D.recentMonthlyHours(orders, m.id, { today: c.today }) : null;
      const hpm = D.hoursPerMonth(m, { recentMonthlyHours: recent });
      if (hpm > 0) { total += hpm; counted += 1; }
    }
    return counted > 0 ? { hours: round(total, 2), source: 'machines' } : { hours: null, source: null };
  }

  /**
   * Everything a screen needs to show the rate and where it comes from.
   *
   * `ctx`: `{ settings, machines, orders, today }` — `today` a `YYYY-MM-DD`;
   * without it the machines' recent hours are not measured and only their
   * typed figures and targets count.
   *
   * `rate` is the figure whether or not the shop has turned the line on, so
   * the settings screen can show what turning it on would do. `perHour` is
   * what a quote is charged: the rate when on, 0 otherwise. `reason` is null
   * when there is a rate, else one of:
   *   `no_costs`   no fixed costs to spread (or only pay, which is left out)
   *   `no_hours`   no figure for the hours: type one, or give a machine a target
   *   `few_hours`  fewer than MIN_MONTHLY_HOURS a month — see the header
   */
  function resolve(ctx) {
    const c = ctx || {};
    const setting = clean(c.settings && c.settings.overheadPerHour);
    const costs = monthlyCosts(c.settings);
    const h = expectedHours(c);
    let rate = null;
    let reason = null;
    if (!(costs.total > 0)) reason = 'no_costs';
    else if (!(h.hours > 0)) reason = 'no_hours';
    else if (h.hours < MIN_MONTHLY_HOURS) reason = 'few_hours';
    else rate = round(costs.total / h.hours, 4);
    return {
      enabled: setting.enabled,
      rate,
      perHour: setting.enabled && rate !== null ? rate : 0,
      monthlyCost: costs.total,
      hours: h.hours,
      source: h.source,
      reason,
      included: costs.included,
      left: costs.left,
      minHours: MIN_MONTHLY_HOURS,
    };
  }

  /** The figure a quote is charged per print hour: 0 unless on and known. */
  function perHour(ctx) {
    return resolve(ctx).perHour;
  }

  const api = { MIN_MONTHLY_HOURS, MAX_MONTHLY_HOURS, clean, monthlyCosts, expectedHours, resolve, perHour };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOverheadRate = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
