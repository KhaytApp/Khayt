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
   * One row's three costs — THE definition of "full" that `totals` and
   * `byGroup` both use, so a total and the groups it is split into add up
   * to the same figure.
   *
   * A row written before the breakdown (or logged with no job behind it)
   * counts its `cost` as material and nothing else: that is all anybody ever
   * knew about it. A row WITH the breakdown reads `costMaterial`, which
   * `attach` wrote from that same `cost`.
   */
  function partsOf(w) {
    const row = w || {};
    const hasBreakdown = num(row.costFull) !== null;
    return {
      material: Math.max(0, num(hasBreakdown ? row.costMaterial : row.cost) || 0),
      machine: Math.max(0, num(row.costMachine) || 0),
      power: Math.max(0, num(row.costPower) || 0),
      costed: hasBreakdown,
    };
  }

  /** The log's three costs, summed — for the Waste screen's totals. */
  function totals(wasteLog) {
    let material = 0, machine = 0, power = 0, energyWh = 0, costed = 0;
    for (const w of Array.isArray(wasteLog) ? wasteLog : []) {
      if (!w) continue;
      const p = partsOf(w);
      material += p.material;
      machine += p.machine;
      power += p.power;
      energyWh += Math.max(0, num(w.energyWh) || 0);
      if (p.costed) costed += 1;
    }
    return {
      material: r2(material), machine: r2(machine), power: r2(power),
      full: r2(material + machine + power), energyWh: Math.round(energyWh * 10) / 10, costed,
    };
  }

  const str = (v) => (v == null ? '' : String(v)).trim();
  const indexById = (rows) => {
    const out = new Map();
    for (const r of Array.isArray(rows) ? rows : []) {
      if (r && str(r.id)) out.set(str(r.id), r);
    }
    return out;
  };

  /**
   * WHERE the failures cost: the log grouped by printer, by material or by
   * customer — each group's three costs and how many failures it holds.
   *
   * The links are only the ones the writers actually put on a waste row
   * (`lib/waste-entry.js` newEntry/forOrder, `lib/qc-failure.js`, the Mac's
   * `newWasteEntry`, the void-and-log path in `renderer/invoicing.js`):
   *
   *   machine   `machineId` on the row; else the job's `machineId` — the
   *             desktop's job-waste form (`forOrder`) writes no printer
   *   material  `material` on the row (every writer sets it); else the
   *             material of the spool it came off (`spoolId`)
   *   customer  nothing on the row: through its job (`orderId`) to the job's
   *             `clientId` and that customer's record, else the name typed
   *             on the job (`client`, which storefront orders carry)
   *
   * A row whose link cannot be followed is counted in ONE "Unknown" group
   * (`key: null`, `unknown: true`) rather than dropped: the money was lost
   * either way, and groups that add up to less than the total leave the shop
   * wondering where the rest went. The caller words "Unknown" itself.
   *
   * @param {object[]} wasteLog
   * @param {object}   opts  `{ by, orders, machines, spools, clients }`;
   *   `by` is 'machine' | 'material' | 'customer' (anything else: no rows)
   * @returns {{key: string|null, label: string, full: number, material: number,
   *   machine: number, power: number, count: number, unknown: boolean}[]}
   *   biggest full cost first
   */
  function byGroup(wasteLog, opts) {
    const o = opts || {};
    const by = o.by || 'machine';
    if (by !== 'machine' && by !== 'material' && by !== 'customer') return [];
    const orders = indexById(o.orders);
    const machines = indexById(o.machines);
    const spools = indexById(o.spools);
    const clients = indexById(o.clients);

    /** `{ key, label }` for one row, or null when the link is missing. */
    function linkOf(w) {
      const job = orders.get(str(w.orderId)) || null;
      if (by === 'machine') {
        const id = str(w.machineId) || str(job && job.machineId);
        if (!id) return null;
        const m = machines.get(id);
        return { key: id, label: str(m && m.name) || id };
      }
      if (by === 'material') {
        const spool = spools.get(str(w.spoolId));
        const name = str(w.material) || str(spool && spool.material);
        return name ? { key: name, label: name } : null;
      }
      if (!job) return null;
      const cid = str(job.clientId);
      if (cid) {
        const c = clients.get(cid);
        return { key: cid, label: str(c && (c.name || c.company)) || str(job.client) || cid };
      }
      const typed = str(job.client);
      return typed ? { key: 'name:' + typed.toLowerCase(), label: typed } : null;
    }

    const groups = new Map();
    let unknown = null;
    for (const w of Array.isArray(wasteLog) ? wasteLog : []) {
      if (!w) continue;
      const link = linkOf(w);
      let g;
      if (link) {
        g = groups.get(link.key);
        if (!g) {
          g = { key: link.key, label: link.label, material: 0, machine: 0, power: 0, count: 0, unknown: false };
          groups.set(link.key, g);
        }
      } else {
        unknown = unknown || { key: null, label: 'Unknown', material: 0, machine: 0, power: 0, count: 0, unknown: true };
        g = unknown;
      }
      const p = partsOf(w);
      g.material += p.material;
      g.machine += p.machine;
      g.power += p.power;
      g.count += 1;
    }
    const all = Array.from(groups.values());
    if (unknown) all.push(unknown);
    const rows = all.map((g) => ({
      key: g.key, label: g.label,
      full: r2(g.material + g.machine + g.power),
      material: r2(g.material), machine: r2(g.machine), power: r2(g.power),
      count: g.count, unknown: g.unknown,
    }));
    rows.sort((a, b) => (b.full - a.full) || (b.count - a.count)
      || (Number(a.unknown) - Number(b.unknown)) || a.label.localeCompare(b.label));
    return rows;
  }

  const api = { hourlyRateOf, hoursFor, breakdown, attach, fullCostOf, partsOf, totals, byGroup };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytFailedPrintCost = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
