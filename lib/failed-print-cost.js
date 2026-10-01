'use strict';
/**
 * What a failed print really cost: the filament, the machine's time, and the
 * electricity.
 *
 * ── WHY ────────────────────────────────────────────────────────────────────
 *
 * A failed print has always been recorded by its FILAMENT alone
 * (`lib/qc-failure.js`, `lib/waste-entry.js`): grams, and what they cost off
 * the spool. But a print that fails at hour six of eight also took six hours
 * of the machine and six hours of power, and a shop that reads "12.40 wasted"
 * on a failure that really cost it 31.00 is deciding what to fix from a third
 * of the picture.
 *
 * ── INFORMATION, NOT A P&L FIGURE ─────────────────────────────────────────
 *
 * The maintainer's decision (2026-09-28): the breakdown is stored on the waste
 * row and shown on the Waste screen as the true cost of failures, for the
 * shop's information. The P&L's waste line stays MATERIAL ONLY — `cost` on the
 * row keeps meaning exactly what it always meant — because the machine's wear
 * and the electricity bill already reach the P&L as the shop's real expenses
 * and fixed costs, and adding them again here would count them twice.
 *
 * So this module never changes `cost`. It adds, beside it:
 *
 *   costMaterial   the filament (= `cost`, repeated so the three sum)
 *   costMachine    hours × the machine's hourly rate
 *   costPower      measured Wh × tariff, else hours × watts × tariff
 *   costFull       the three together
 *   failedHours    the hours it is worked out from, and `hoursSource`
 *   energyWh       when a plug measured it, and `powerSource`
 *
 * ── THE HOURS ─────────────────────────────────────────────────────────────
 *
 * In order: what the PRINTER said the failed print ran for; else the job's
 * estimate × the fraction printed when the printer's progress at failure is
 * known; else nothing — and a row with no hours gets no machine or power cost
 * rather than the whole estimate, because a print that stopped at 10% did not
 * use the whole job's time and a figure certainly too big is worse than none.
 *
 * ── THE MACHINE'S HOURLY RATE ─────────────────────────────────────────────
 *
 * `KhaytPrintRates.ratesFor({ machine, preset, settings })` — the rule every quote uses
 * — and its `depreciationRate` when the rates carry one, else `wearRate`. A
 * depreciation-per-hour figure, if the rates ever grow one, is a better
 * answer to "what did an hour of this machine cost" than a typed wear rate,
 * and reading it here first means nothing in this file changes when it lands.
 *
 * Pure. Opt-in: a caller that passes nothing gets back exactly what it gave.
 */
(function (global) {

  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : null; };
  const pos = (v) => { const n = num(v); return n !== null && n > 0 ? n : null; };
  const r2 = (v) => Math.round(v * 100) / 100;

  function rates() {
    return global.KhaytPrintRates
      || (typeof require === 'function' ? (() => { try { return require('./print-rates.js'); } catch (e) { return null; } })() : null);
  }
  function energy() {
    return global.KhaytPrintEnergy
      || (typeof require === 'function' ? (() => { try { return require('./print-energy.js'); } catch (e) { return null; } })() : null);
  }

  /** The machine's cost per hour: depreciation when the rates carry it, else wear. */
  function hourlyRateOf(resolved) {
    const r = resolved || {};
    const dep = pos(r.depreciationRate);
    if (dep !== null) return dep;
    const wear = num(r.wearRate);
    return wear !== null && wear >= 0 ? wear : 0;
  }

  /**
   * How long the failed print ran, and how that is known.
   *
   * @param {object} order  the job (for its estimate, `printTime`, hours)
   * @param {object} at     `{ actualHours, progress }` — the printer's own
   *   duration of THIS attempt, and its progress (0–100) when it stopped
   * @returns {{ hours: number|null, source: 'printer'|'progress'|null }}
   */
  function hoursFor(order, at) {
    const a = at || {};
    const actual = pos(a.actualHours);
    if (actual !== null) return { hours: actual, source: 'printer' };
    const est = pos(order && order.printTime);
    const p = num(a.progress);
    if (est !== null && p !== null && p > 0) {
      return { hours: est * Math.min(100, p) / 100, source: 'progress' };
    }
    return { hours: null, source: null };
  }

  /**
   * The breakdown for one failed print.
   *
   * @param {object} order  the job that failed (null for a row on no job)
   * @param {object} input  `{ materialCost, actualHours, progress, energy }` —
   *   `energy` is a plug reading (`KhaytPrintEnergy.reading`) of the attempt
   * @param {object} ctx    `{ machine, preset, settings }` for the rates —
   *   `settings` carries the shop's own tariff (`settings.elecRate`)
   */
  function breakdown(order, input, ctx) {
    const i = input || {};
    const c = ctx || {};
    const R = rates();
    const E = energy();
    const resolved = R ? R.ratesFor({ machine: c.machine || null, preset: c.preset || null, settings: c.settings || null }) : {};
    const material = Math.max(0, num(i.materialCost) || 0);
    const { hours, source } = hoursFor(order, i);
    const tariff = E ? E.tariffOf(order || {}, resolved) : Math.max(0, num(resolved.elecRate) || 0);

    let machine = 0;
    let power = 0;
    let wh = null;
    let powerSource = null;
    if (hours !== null) {
      machine = hours * hourlyRateOf(resolved);
    }
    // A plug reading of the attempt beats any wattage, and needs no hours.
    const metered = E && i.energy ? E.energyWhOf({ energyWh: i.energy.wh, energy: i.energy }) : null;
    if (metered !== null) {
      wh = metered;
      power = (wh / 1000) * tariff;
      powerSource = 'plug';
    } else if (hours !== null) {
      power = hours * (Math.max(0, num(resolved.powerDraw) || 0) / 1000) * tariff;
      powerSource = 'rate';
    }
    return {
      material: r2(material),
      machine: r2(machine),
      power: r2(power),
      full: r2(material + machine + power),
      hours: hours === null ? null : r2(hours),
      hoursSource: source,
      energyWh: wh,
      powerSource,
    };
  }

  /**
   * The waste row, with the breakdown written beside `cost`.
   *
   * `cost` is NOT changed — it is the P&L's material figure. Mutates and
   * returns `entry`.
   */
  function attach(entry, order, input, ctx) {
    if (!entry || typeof entry !== 'object') return entry;
    const b = breakdown(order, Object.assign({ materialCost: entry.cost }, input || {}), ctx);
    entry.costMaterial = b.material;
    entry.costMachine = b.machine;
    entry.costPower = b.power;
    entry.costFull = b.full;
    if (b.hours !== null) { entry.failedHours = b.hours; entry.hoursSource = b.hoursSource; }
    if (b.powerSource) entry.powerSource = b.powerSource;
    if (b.energyWh !== null) entry.energyWh = b.energyWh;
    return entry;
  }

  /** A row's full cost: the breakdown's when it has one, its material when not. */
  function fullCostOf(w) {
    if (!w) return 0;
    const full = num(w.costFull);
    if (full !== null && full >= 0) return full;
    return Math.max(0, num(w.cost) || 0);
  }

  /**
   * The log's three costs, summed — for the Waste screen's totals.
   * A row written before the breakdown counts its `cost` as material and
   * nothing else: that is all anybody ever knew about it.
   */
  function totals(wasteLog) {
    let material = 0, machine = 0, power = 0, energyWh = 0, costed = 0;
    for (const w of Array.isArray(wasteLog) ? wasteLog : []) {
      if (!w) continue;
      const hasBreakdown = num(w.costFull) !== null;
      material += Math.max(0, num(hasBreakdown ? w.costMaterial : w.cost) || 0);
      machine += Math.max(0, num(w.costMachine) || 0);
      power += Math.max(0, num(w.costPower) || 0);
      energyWh += Math.max(0, num(w.energyWh) || 0);
      if (hasBreakdown) costed += 1;
    }
    return {
      material: r2(material), machine: r2(machine), power: r2(power),
      full: r2(material + machine + power), energyWh: Math.round(energyWh * 10) / 10, costed,
    };
  }

  const api = { hourlyRateOf, hoursFor, breakdown, attach, fullCostOf, totals };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytFailedPrintCost = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
