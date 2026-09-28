'use strict';
/**
 * What a machine loses in value as it is used, and what that means per print hour.
 *
 * ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
 *
 * Shop owners asked how Khayt handles depreciation. The honest answer was: it
 * does not. `lib/calculator-cost.js` charges `printTime × wearRate`, and the
 * wear rate is a flat per-hour figure the shop types in (0.75 unless it says
 * otherwise, `lib/print-rates.js`). Nothing knew what the printer cost, how
 * long it is meant to last or what it will sell for afterwards.
 *
 * ── WHAT A SHOP WRITES DOWN ─────────────────────────────────────────────────
 *
 * `machine.depreciation`, and every field is optional except the price:
 *
 *     price         what the machine cost
 *     purchaseDate  YYYY-MM-DD, when it was bought
 *     life          how long it is expected to last …
 *     lifeUnit      … in `hours` (of printing) or `years` — the shop's choice
 *     residual      what it should sell for at the end
 *     method        `perHour` (units of production) or `straightLine` (by time)
 *     monthlyHours  how many hours a month it is expected to print
 *
 * ── THE TWO METHODS ─────────────────────────────────────────────────────────
 *
 * perHour       rate    = (price − residual) ÷ life in hours
 *               to date = rate × hours it has printed, capped at price − residual
 *
 * straightLine  monthly = (price − residual) ÷ (years × 12)
 *               to date = monthly × months since it was bought, capped the same
 *
 * The two units and the two methods are independent, because a shop can think
 * of a printer's life in years and still want its cost spread per hour. When a
 * life is given in the other unit it is converted through the machine's hours a
 * month; when that is not known either, the figure is withheld (null) rather
 * than guessed.
 *
 * ── WHAT A QUOTE IS CHARGED ─────────────────────────────────────────────────
 *
 * `hourlyRate` is the wear rate `lib/print-rates.js` uses for a machine that has
 * depreciation set, in place of the flat default. For straightLine it is the
 * monthly amount spread over the machine's expected hours a month: the field
 * the shop typed, else its actual recent hours (`recentMonthlyHours`, which the
 * caller works out from finished jobs), else its daily target × 365.25 ÷ 12.
 *
 * The rate is NOT cut to zero once the machine is fully written down. A quote
 * is not the books: a printer that has paid for itself still needs replacing,
 * and a price that drops the day the accounting says "fully depreciated" is a
 * price that cannot pay for the next one.
 *
 * ── AND THE REPORTS ─────────────────────────────────────────────────────────
 *
 * THE P&L COUNTS MACHINE WEAR ONCE, AND HERE. The maintainer's decision
 * (2026-09-28): cost of goods in the P&L is what was INVENTORIED — material,
 * extra materials, packaging — and the wear a quote charges stays in the
 * quote. Machine wear enters the P&L only as this module's depreciation line,
 * for both methods:
 *
 *   perHour       the hourly rate × the hours the machine printed in the period
 *   straightLine  the monthly amount, pro-rated for the days of the period
 *
 * `periodCharges` works that out per period for `lib/pnl-report.js`, and
 * `periodCharge` per range for `lib/machine-pl.js`. `wearInCost` says how much
 * wear a frozen part cost carries, for any report that still has to take it
 * out.
 *
 * PURE: no DOM, no clock. `today` is always passed in.
 */
(function (global) {

  const METHODS = ['perHour', 'straightLine'];
  const UNITS = ['hours', 'years'];
  /** An average month, in days: 365.25 ÷ 12. */
  const MONTH_DAYS = 30.4375;
  const FINISHED = new Set(['completed', 'delivered']);

  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };
  const positive = (v) => { const n = num(v); return n > 0 ? n : null; };
  const round = (n, dp) => { const f = Math.pow(10, dp); return Math.round(n * f) / f; };
  const trim = (v) => String(v == null ? '' : v).trim();

  /** Days since 1970 for a `YYYY-MM-DD`, or null. UTC, so no zone can move it. */
  function dayNumber(s) {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(trim(s));
    if (!m) return null;
    const t = Date.UTC(+m[1], +m[2] - 1, +m[3]);
    if (!Number.isFinite(t)) return null;
    const d = new Date(t);
    // 2026-02-31 is not a date, and Date.UTC would quietly make it March.
    if (d.getUTCMonth() !== +m[2] - 1 || d.getUTCDate() !== +m[3]) return null;
    return Math.round(t / 86400000);
  }

  /**
   * What the machine sheet sends, as the record keeps it. Null when there is no
   * price: depreciation without a cost is not depreciation, and a machine that
   * carries none is priced exactly as it always was.
   */
  function clean(input) {
    const d = input || {};
    const price = positive(d.price);
    if (price === null) return null;
    const lifeUnit = UNITS.includes(d.lifeUnit) ? d.lifeUnit : 'hours';
    const out = {
      price,
      purchaseDate: dayNumber(d.purchaseDate) !== null ? trim(d.purchaseDate).slice(0, 10) : '',
      life: positive(d.life),
      lifeUnit,
      // Never more than the price: a machine cannot be worth more at the end of
      // its life than it cost, and a negative depreciable amount would pay the
      // shop for running it.
      residual: Math.min(price, Math.max(0, num(d.residual))),
      method: METHODS.includes(d.method) ? d.method : (lifeUnit === 'years' ? 'straightLine' : 'perHour'),
      monthlyHours: positive(d.monthlyHours),
    };
    return out;
  }

  /** The machine's settings, cleaned, or null when it has none. */
  function settingsOf(machine) {
    return machine && machine.depreciation ? clean(machine.depreciation) : null;
  }

  /**
   * How many hours a month this machine prints, from the best thing known.
   *
   * The shop's own figure, then what it has actually done lately, then its
   * daily target. Null when none is known.
   */
  function hoursPerMonth(machine, opts) {
    const s = settingsOf(machine);
    const o = opts || {};
    if (s && s.monthlyHours) return s.monthlyHours;
    const recent = positive(o.recentMonthlyHours) || positive(machine && machine.recentMonthlyHours);
    if (recent) return recent;
    const target = positive(machine && machine.targetHoursPerDay);
    return target ? target * 365.25 / 12 : null;
  }

  function lifeHours(s, hpm) {
    if (!s.life) return null;
    if (s.lifeUnit === 'hours') return s.life;
    return hpm ? s.life * 12 * hpm : null;
  }

  function lifeMonths(s, hpm) {
    if (!s.life) return null;
    if (s.lifeUnit === 'years') return s.life * 12;
    return hpm ? s.life / hpm : null;
  }

  /**
   * The monthly charge, for straightLine. Null for perHour, whose cost follows
   * the hours the machine runs rather than the calendar.
   */
  function monthlyCharge(machine, opts) {
    const s = settingsOf(machine);
    if (!s || s.method !== 'straightLine') return null;
    const months = lifeMonths(s, hoursPerMonth(machine, opts));
    return months ? (s.price - s.residual) / months : null;
  }

  /**
   * The per-print-hour figure a quote charges for this machine's wear, or null
   * when it cannot be worked out — in which case the flat wear rate stands.
   */
  function hourlyRate(machine, opts) {
    const s = settingsOf(machine);
    if (!s) return null;
    const hpm = hoursPerMonth(machine, opts);
    const depreciable = s.price - s.residual;
    if (s.method === 'perHour') {
      const hours = lifeHours(s, hpm);
      return hours ? round(depreciable / hours, 4) : null;
    }
    const monthly = monthlyCharge(machine, opts);
    return (monthly !== null && hpm) ? round(monthly / hpm, 4) : null;
  }

  /**
   * How long a finished job occupied its machine: the measured time where
   * there is one, the estimate where there is not. The same rule
   * `lib/machine-pl.js` counts a machine's hours by.
   */
  function hoursOf(order) {
    const actual = num(order && order.actualPrintTime);
    return actual > 0 ? actual : Math.max(0, num(order && order.printTime));
  }

  /** The day a job finished, as a day number. */
  function finishedDay(order) {
    return dayNumber(order && order.completedAt) ?? dayNumber(order && order.date);
  }

  /**
   * Hours this machine has printed on finished work, from `sinceDay` (a day
   * number, inclusive) up to and including `untilDay`. Either may be null.
   */
  function hoursRun(orders, machineId, sinceDay, untilDay) {
    let total = 0;
    for (const o of Array.isArray(orders) ? orders : []) {
      if (!o || !FINISHED.has(o.status) || o.voidedAt) continue;
      if (String(o.machineId || '') !== String(machineId || '') || !machineId) continue;
      const day = finishedDay(o);
      if (sinceDay != null && (day == null || day < sinceDay)) continue;
      if (untilDay != null && day != null && day > untilDay) continue;
      total += hoursOf(o);
    }
    return total;
  }

  /**
   * What the machine has actually printed a month, lately: finished hours over
   * the last `days` (90 by default), as a monthly figure. Null when it printed
   * nothing, which says "not known" rather than "never runs".
   */
  function recentMonthlyHours(orders, machineId, opts) {
    const o = opts || {};
    const today = dayNumber(o.today);
    if (today === null) return null;
    const days = Math.max(1, Math.round(num(o.days) || 90));
    const hours = hoursRun(orders, machineId, today - days + 1, today);
    return hours > 0 ? round(hours / days * MONTH_DAYS, 2) : null;
  }

  /**
   * Where a machine stands: what it has lost, what it is worth, what is left.
   *
   * `opts`: `{ today, hoursRun, recentMonthlyHours }`. `hoursRun` is what it has
   * printed since it was bought — the caller counts it, because only the caller
   * has the jobs.
   *
   * Null for a machine with no depreciation set.
   */
  function status(machine, opts) {
    const s = settingsOf(machine);
    if (!s) return null;
    const o = opts || {};
    const hpm = hoursPerMonth(machine, o);
    const depreciable = s.price - s.residual;
    const ran = Math.max(0, num(o.hoursRun));
    const lh = lifeHours(s, hpm);
    const lm = lifeMonths(s, hpm);
    const rate = hourlyRate(machine, o);
    const monthly = monthlyCharge(machine, o);

    let toDate = null;
    let remainingHours = null;
    let remainingMonths = null;
    let monthsOwned = null;
    const bought = dayNumber(s.purchaseDate);
    const today = dayNumber(o.today);
    if (bought !== null && today !== null) monthsOwned = Math.max(0, (today - bought) / MONTH_DAYS);

    if (s.method === 'perHour') {
      if (lh) {
        toDate = Math.min(depreciable, depreciable / lh * ran);
        remainingHours = Math.max(0, lh - ran);
      }
    } else if (monthly !== null && monthsOwned !== null) {
      toDate = Math.min(depreciable, monthly * monthsOwned);
      remainingMonths = Math.max(0, lm - monthsOwned);
    }

    return {
      method: s.method,
      price: s.price,
      residual: s.residual,
      depreciable: round(depreciable, 2),
      hourlyRate: rate,
      monthly: monthly === null ? null : round(monthly, 2),
      hoursPerMonth: hpm === null ? null : round(hpm, 2),
      hoursRun: round(ran, 2),
      lifeHours: lh === null ? null : round(lh, 1),
      lifeMonths: lm === null ? null : round(lm, 1),
      // Null, not zero, when it cannot be said: a straight-line machine with no
      // purchase date has lost SOMETHING, and 0 would read as "nothing yet".
      toDate: toDate === null ? null : round(toDate, 2),
      bookValue: toDate === null ? null : round(s.price - toDate, 2),
      remainingHours: remainingHours === null ? null : round(remainingHours, 1),
      remainingMonths: remainingMonths === null ? null : round(remainingMonths, 1),
      fullyDepreciated: toDate !== null && toDate >= depreciable - 0.005,
      // What is missing for the figures above to be complete, so a screen can
      // say what to fill in rather than showing a dash.
      needs: s.method === 'straightLine'
        ? (!s.life ? 'life' : bought === null ? 'purchaseDate' : (rate === null ? 'monthlyHours' : null))
        : (!s.life ? 'life' : (lh === null ? 'monthlyHours' : null)),
    };
  }

  /**
   * Every machine's standing, from the book's finished jobs, in one pass.
   *
   * Returns `{ [machineId]: status + { recentMonthlyHours } }`, leaving out any
   * machine without depreciation set.
   */
  function machineValues(machines, orders, opts) {
    const o = opts || {};
    const out = {};
    for (const m of Array.isArray(machines) ? machines : []) {
      if (!m || !m.id || !settingsOf(m)) continue;
      const s = settingsOf(m);
      const recent = recentMonthlyHours(orders, m.id, { today: o.today, days: o.days });
      const ran = hoursRun(orders, m.id, dayNumber(s.purchaseDate), dayNumber(o.today));
      const st = status(m, { today: o.today, hoursRun: ran, recentMonthlyHours: recent });
      out[String(m.id)] = Object.assign(st, { recentMonthlyHours: recent });
    }
    return out;
  }

  /**
   * The depreciation that belongs to one period, for a report.
   *
   * `range`: `{ from, to }` as `YYYY-MM-DD`, both inclusive, and `hours` — what
   * the machine printed in it, which is what a perHour machine is charged on.
   *
   * straightLine: the monthly amount for the days of the period the machine was
   * owned and still inside its life. perHour: hours × rate, never beyond what is
   * left to depreciate when `hoursBefore` (printed before the period) is given.
   */
  function periodCharge(machine, range, opts) {
    const s = settingsOf(machine);
    if (!s) return 0;
    const r = range || {};
    const o = opts || {};
    const depreciable = s.price - s.residual;
    if (s.method === 'perHour') {
      const lh = lifeHours(s, hoursPerMonth(machine, o));
      if (!lh) return 0;
      const before = Math.max(0, num(o.hoursBefore));
      const hours = Math.max(0, num(r.hours));
      return round(Math.min(hours, Math.max(0, lh - before)) * depreciable / lh, 2);
    }
    const monthly = monthlyCharge(machine, o);
    const bought = dayNumber(s.purchaseDate);
    const from = dayNumber(r.from), to = dayNumber(r.to);
    if (monthly === null || bought === null || from === null || to === null || to < from) return 0;
    const lm = lifeMonths(s, hoursPerMonth(machine, o));
    const end = bought + Math.round(lm * MONTH_DAYS) - 1;
    const a = Math.max(from, bought), z = Math.min(to, end);
    if (z < a) return 0;
    return round(monthly * (z - a + 1) / MONTH_DAYS, 2);
  }

  /**
   * Depreciation for several periods at once, for the P&L.
   *
   * `periods`: `[{ key, from, to }]`, dates `YYYY-MM-DD` inclusive — `to`
   * already cut to today for a period still in progress, so its straight-line
   * share is pro-rated by the days elapsed, as fixed overhead is.
   *
   * A perHour machine is charged on the hours it printed in each period: its
   * finished jobs, placed by `date` exactly as the P&L places their revenue,
   * counted only from its purchase date, and never beyond its life.
   *
   * Returns `{ [key]: { total, byMachine: { [machineId]: amount } } }`. A
   * machine without depreciation set contributes nothing, so a book that has
   * never filled the fields gets an empty object.
   */
  /* ONLY PERIODS THAT HAVE A ROW ARE CHARGED, as with fixed overhead.
   * pnlByPeriod makes a row for a period with some activity (a finished job
   * or an expense); a straight-line machine's month with neither carries no
   * depreciation in the P&L, although the machine lost that value all the
   * same. The machine card's "depreciation to date" is the complete figure. */
  function periodCharges(machines, orders, periods, opts) {
    const o = opts || {};
    const list = (Array.isArray(periods) ? periods : [])
      .map((p) => ({ key: p.key, from: p.from, to: p.to, a: dayNumber(p.from), z: dayNumber(p.to) }))
      .filter((p) => p.key && p.a !== null && p.z !== null && p.z >= p.a)
      .sort((x, y) => x.a - y.a);
    const out = {};
    for (const m of Array.isArray(machines) ? machines : []) {
      const s = m && m.id ? settingsOf(m) : null;
      if (!s) continue;
      const id = String(m.id);
      const bought = dayNumber(s.purchaseDate);
      const recent = positive(o.recentMonthlyHours && o.recentMonthlyHours[id]);
      const mo = { recentMonthlyHours: recent };
      for (const p of list) {
        let amount;
        if (s.method === 'perHour') {
          const since = bought;
          const before = since === null ? 0 : hoursRunByDate(orders, id, since, p.a - 1);
          const hours = hoursRunByDate(orders, id, since === null ? p.a : Math.max(p.a, since), p.z);
          amount = periodCharge(m, { hours }, Object.assign({ hoursBefore: before }, mo));
        } else {
          amount = periodCharge(m, { from: p.from, to: p.to }, mo);
        }
        if (!(amount > 0)) continue;
        if (!out[p.key]) out[p.key] = { total: 0, byMachine: {} };
        out[p.key].byMachine[id] = amount;
        out[p.key].total = round(out[p.key].total + amount, 2);
      }
    }
    return out;
  }

  /** Finished hours on a machine between two day numbers, placed by `date`. */
  function hoursRunByDate(orders, machineId, fromDay, toDay) {
    if (fromDay !== null && toDay !== null && toDay < fromDay) return 0;
    let total = 0;
    for (const o of Array.isArray(orders) ? orders : []) {
      if (!o || !FINISHED.has(o.status) || o.voidedAt) continue;
      if (String(o.machineId || '') !== String(machineId)) continue;
      const day = dayNumber(o.date);
      if (day === null) continue;
      if (fromDay !== null && day < fromDay) continue;
      if (toDay !== null && day > toDay) continue;
      total += hoursOf(o);
    }
    return total;
  }

  /**
   * The machine wear inside one part's frozen cost — what the P&L would take
   * out of cost of goods to show depreciation once instead of twice.
   *
   * `computePartBaseCost` charges `printTime × wearRate` and then puts the
   * failure allowance on top of the WHOLE base, wear included, and the part's
   * cost is per unit. So this is `printTime × wearRate × (1 + failure%) × qty`.
   */
  function wearInCost(part) {
    const p = part || {};
    const wear = Math.max(0, num(p.printTime)) * Math.max(0, num(p.wearRate));
    const buffer = 1 + Math.max(0, num(p.failureRate)) / 100;
    return round(wear * buffer * Math.max(1, num(p.qty) || 1), 4);
  }

  const api = {
    METHODS, UNITS, clean, settingsOf, hoursPerMonth, hourlyRate, monthlyCharge,
    status, machineValues, hoursRun, recentMonthlyHours, periodCharge, periodCharges, wearInCost,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytDepreciation = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
