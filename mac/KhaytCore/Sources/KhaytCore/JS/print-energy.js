'use strict';
/**
 * What a print really drew from the wall, from the smart plug it sits on.
 *
 * ── WHY ────────────────────────────────────────────────────────────────────
 *
 * Electricity has always been costed as `hours × powerDraw ÷ 1000 × tariff`,
 * with `powerDraw` a single number the shop types per machine (150 W unless
 * somebody changed it). The HOURS have been corrected from the printer for a
 * while (`printer-actuals.js`); the WATTS never were, although a shop with a
 * metering plug (`smart-plug.js`) is handed a live reading every minute and
 * the app threw every one of them away. A bed at 110 °C for PETG and a PLA
 * print at 60 °C on the same machine are not the same 150 W.
 *
 * So this module does four things, all pure:
 *
 *   1. ADDS UP the plug's readings while the printer is printing — watt-hours
 *      by the trapezoid rule between consecutive readings (`step`).
 *   2. SAYS WHICH JOB the energy belongs to — the print-finish photo's rule
 *      (`lib/print-finish-photo.js` `jobFor`), deliberately not a second one:
 *      two rules for "which job was that print" would one day disagree, and a
 *      photo and a power bill would land on different jobs.
 *   3. READS IT BACK for costing (`energyWhOf`, `actualPowerCost`) — and only
 *      when enough of the print was actually metered.
 *   4. SUGGESTS a machine's wattage from its own history (`suggestPowerDraw`),
 *      which the machine sheet offers with "Use this" and never applies.
 *
 * ── WHAT "WHILE PRINTING" MEANS ───────────────────────────────────────────
 *
 * From the first reading at which the printer says it is in a job to the edge
 * out of it. That includes the bed and nozzle heating up and any pause —
 * Klipper reports `printing` from the moment the file starts, and its first
 * lines ARE the heat-up — because the shop pays for those watts on this job
 * and on no other. Idle time between jobs is not included: nobody is printing.
 *
 * ── GAPS ARE NOT BRIDGED ──────────────────────────────────────────────────
 *
 * Two readings further apart than `maxGapS` (five minutes by default) say
 * nothing about what happened between them: the Wi-Fi dropped, the Mac slept,
 * the app was quit and reopened. Integrating across that gap would invent
 * energy from two endpoints. So the gap is counted (`gaps`), the time is left
 * out of `coveredS`, and the reading carries its own COVERAGE — covered
 * seconds over the span it was watched for. `energyWhOf` refuses a reading
 * below `MIN_COVERAGE` and scales one above it up to the whole span, at the
 * print's own measured mean draw — the honest extrapolation, from THIS print.
 *
 * ── A PLUG ON SEVERAL PRINTERS ────────────────────────────────────────────
 *
 * A power strip behind one metering plug reads the sum of everything on it.
 * Two machines that name the same plug (`sharedPlugIds`) are never metered:
 * there is no way to split a sum between two printers from the sum alone, and
 * a bill charged to the wrong job is worse than the shop's typed wattage.
 *
 * Pure: no clock, no fetch, no store. The caller owns the plug, the poll and
 * the book, and hands the memory back each time.
 */
(function (global) {

  /** Readings further apart than this are a gap, not a slope. */
  const MAX_GAP_S = 300;
  /** Below this share of the print metered, the reading is not used for cost. */
  const MIN_COVERAGE = 0.8;
  /** A reading nobody has added to for this long belongs to a print long gone. */
  const STALE_S = 12 * 3600;
  /** Recent prints the wattage suggestion is drawn from, and the fewest it needs. */
  const SUGGEST_LIMIT = 10;
  const SUGGEST_MIN = 3;

  // The vocabulary `print-finish-photo` uses for mid-job, so the meter runs
  // exactly while the finish rule thinks a print is on.
  const IN_JOB = /^(printing|busy|running|working|paus)/i;

  const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : null; };
  const pos = (v) => { const n = num(v); return n !== null && n > 0 ? n : null; };
  const round = (v, dp) => { const f = Math.pow(10, dp); return Math.round(v * f) / f; };
  const fileKey = (name) => String(name || '').trim().toLowerCase().split(/[\\/]/).pop() || '';

  function inJob(state) { return IN_JOB.test(String(state || '')); }

  /**
   * Machines whose plug is shared with another machine, by id.
   *
   * Same plug = same base address and, for Home Assistant, the same entity.
   * Read through `KhaytSmartPlug.config` when it is loaded, so "same plug"
   * means what the plug module means by an address.
   */
  function sharedPlugIds(machines) {
    const SP = global.KhaytSmartPlug;
    const byPlug = new Map();
    for (const m of Array.isArray(machines) ? machines : []) {
      if (!m || !m.id) continue;
      let key = null;
      if (SP && typeof SP.config === 'function') {
        const c = SP.config(m);
        if (c) key = c.base.toLowerCase() + '|' + String(c.entity || '').toLowerCase();
      } else if (m.smartPlug && m.smartPlug.host) {
        key = String(m.smartPlug.host).toLowerCase() + '|' + String(m.smartPlug.entity || '').toLowerCase();
      }
      if (!key) continue;
      if (!byPlug.has(key)) byPlug.set(key, []);
      byPlug.get(key).push(String(m.id));
    }
    const out = [];
    for (const ids of byPlug.values()) if (ids.length > 1) out.push(...ids);
    return out.sort();
  }

  /** A plug's watts, or null when it gave none (or nonsense). */
  const wattsOf = (v) => { const w = num(v); return w !== null && w >= 0 ? w : null; };

  function fresh(sample) {
    const w = wattsOf(sample.watts);
    return {
      filename: String(sample.filename || ''),
      startedAt: sample.at,
      lastAt: sample.at,
      lastW: w,
      wh: 0,
      coveredS: 0,
      samples: w === null ? 0 : 1,
      gaps: 0,
    };
  }

  /**
   * Fold one plug reading into one machine's meter.
   *
   * @param {object|null} meter  what the last call returned as `meter`, or null
   * @param {object} sample  `{ at (ms), watts (number|null), state, filename }`
   *   — the plug's watts and the PRINTER's state and file at that moment
   * @param {object} [opts]  `{ maxGapS, shared }` — `shared: true` for a plug
   *   that feeds more than one machine, which is never metered
   * @returns {{ meter: object|null, dropped: object|null, reason: string|null }}
   *   `dropped` is a meter abandoned because the printer moved on to another
   *   file without an end ever being seen, or it went stale; it is never
   *   attributed to a job.
   */
  function step(meter, sample, opts) {
    const o = opts || {};
    const s = sample || {};
    const maxGap = pos(o.maxGapS) || MAX_GAP_S;
    const at = num(s.at);
    if (o.shared) return { meter: null, dropped: meter || null, reason: meter ? 'shared' : null };
    if (at === null) return { meter: meter || null, dropped: null, reason: null };
    // Not printing: the meter is left exactly as it is. The END is the finish
    // rule's to call (`take`), not a second edge detector's — and the finish
    // edge usually arrives from the printer poll before the plug is next read.
    if (!inJob(s.state)) {
      if (meter && at - meter.lastAt > STALE_S * 1000) return { meter: null, dropped: meter, reason: 'stale' };
      return { meter: meter || null, dropped: null, reason: null };
    }
    if (!meter) return { meter: fresh(s), dropped: null, reason: null };

    // A different file with no end in between: the app missed the edge (it
    // was closed, or the Mac slept through it). That energy belongs to a print
    // nobody can name any more, so it is dropped rather than guessed at.
    const file = String(s.filename || '');
    if (file && meter.filename && fileKey(file) !== fileKey(meter.filename)) {
      return { meter: fresh(s), dropped: meter, reason: 'new-file' };
    }
    if (at - meter.lastAt > STALE_S * 1000) {
      return { meter: fresh(s), dropped: meter, reason: 'stale' };
    }

    const next = Object.assign({}, meter);
    if (!next.filename && file) next.filename = file;
    const dt = (at - meter.lastAt) / 1000;
    if (dt <= 0) return { meter, dropped: null, reason: null };
    const watts = wattsOf(s.watts);
    if (watts !== null) next.samples = (next.samples || 0) + 1;
    if (dt > maxGap) {
      next.gaps = (next.gaps || 0) + 1;
    } else if (watts !== null && next.lastW !== null && next.lastW !== undefined) {
      next.wh += ((next.lastW + watts) / 2) * (dt / 3600);
      next.coveredS += dt;
    }
    next.lastAt = at;
    next.lastW = watts;
    return { meter: next, dropped: null, reason: null };
  }

  /**
   * One machine's meter, folded through `step`, inside the whole memory
   * `{ [machineId]: meter }` — the shape a host keeps and persists.
   */
  function tick(memo, machineId, sample, opts) {
    const all = memo && typeof memo === 'object' ? Object.assign({}, memo) : {};
    const id = String(machineId || '');
    if (!id) return { memo: all, dropped: null, reason: null };
    const r = step(all[id] || null, sample, opts);
    if (r.meter) all[id] = r.meter; else delete all[id];
    return { memo: all, dropped: r.dropped, reason: r.reason };
  }

  /**
   * What a finished meter says, in the shape a job or a waste row stores.
   * Null when nothing was measured: two readings are the least a slope needs.
   */
  function reading(meter) {
    if (!meter || !(meter.wh > 0) || !(meter.coveredS > 0)) return null;
    const spanS = Math.max(meter.coveredS, (num(meter.lastAt) - num(meter.startedAt)) / 1000 || 0);
    return {
      wh: round(meter.wh, 1),
      coveredS: Math.round(meter.coveredS),
      spanS: Math.round(spanS),
      coverage: spanS > 0 ? round(Math.min(1, meter.coveredS / spanS), 3) : 0,
      samples: meter.samples || 0,
      gaps: meter.gaps || 0,
    };
  }

  /**
   * Take a machine's meter out of the memory at the end of a print.
   * @returns {{ memo, reading: object|null }}
   */
  function take(memo, machineId) {
    const all = memo && typeof memo === 'object' ? Object.assign({}, memo) : {};
    const id = String(machineId || '');
    const meter = all[id] || null;
    delete all[id];
    return { memo: all, reading: reading(meter) };
  }

  /**
   * The job a metered print belongs to: the print-finish photo's rule,
   * word for word. Null when the book cannot say without guessing.
   */
  function jobFor(printLog, machineId, filename) {
    const P = global.KhaytPrintFinishPhoto
      || (typeof require === 'function' ? (() => { try { return require('./print-finish-photo.js'); } catch (e) { return null; } })() : null);
    return P ? P.jobFor(printLog, machineId, filename) : null;
  }

  /**
   * The fields a finished, metered print writes onto its job.
   *
   * `actualEnergyWh` beside `actualPrintTime`, and `actualEnergy` with what
   * it rests on — so a reader can tell a whole print metered from a print
   * the app was closed for half of.
   */
  function jobFields(r, atIso) {
    if (!r || !(r.wh > 0)) return null;
    return {
      actualEnergyWh: r.wh,
      actualEnergy: {
        source: 'plug', coveredS: r.coveredS, spanS: r.spanS, coverage: r.coverage,
        samples: r.samples, gaps: r.gaps, at: atIso || null,
      },
    };
  }

  /**
   * The energy a record (a job, or a waste row) measured, in Wh — or null.
   *
   * Null when none was measured, and null when too little of the print was:
   * a reading covering half a print is half a bill. Above `MIN_COVERAGE` it is
   * scaled to the whole span at the print's own mean draw.
   */
  function energyWhOf(record, opts) {
    const r = record || {};
    const wh = pos(r.actualEnergyWh !== undefined ? r.actualEnergyWh : r.energyWh);
    if (wh === null) return null;
    const meta = r.actualEnergy || r.energy || {};
    const minCov = pos((opts || {}).minCoverage) || MIN_COVERAGE;
    const cov = num(meta.coverage);
    // A reading that carries no coverage was written by something that
    // measured it whole (or by hand) — taken as it stands.
    if (cov === null) return wh;
    if (cov < minCov) return null;
    return round(wh / Math.min(1, cov), 1);
  }

  /** The tariff a job was costed at: its parts' own, else the resolved rate. */
  function tariffOf(order, rates) {
    for (const p of Array.isArray(order && order.parts) ? order.parts : []) {
      const r = num(p && p.elecRate);
      if (r !== null && r >= 0 && p.elecRate !== '' && p.elecRate !== null) return r;
    }
    const r = num(rates && rates.elecRate);
    return r !== null && r >= 0 ? r : 0;
  }

  /**
   * What electricity the job's own parts were COSTED at — the estimate inside
   * `computePartBaseCost`, failure allowance included, times each part's qty.
   * The figure `actualPowerCost` replaces when there is a measurement.
   */
  function estimatedPowerCost(order, rates) {
    const rt = rates || {};
    let total = 0;
    for (const p of Array.isArray(order && order.parts) ? order.parts : []) {
      if (!p) continue;
      const pick = (k) => { const v = num(p[k]); return v !== null && p[k] !== '' && p[k] !== null ? v : (num(rt[k]) || 0); };
      const hours = Math.max(0, num(p.printTime) || 0);
      const watts = Math.max(0, pick('powerDraw'));
      const tariff = Math.max(0, pick('elecRate'));
      const fr = Math.max(0, pick('failureRate'));
      const qty = Math.max(1, num(p.qty) || 1);
      total += hours * (watts / 1000) * tariff * (1 + fr / 100) * qty;
    }
    return total;
  }

  /**
   * What a finished job's electricity ACTUALLY cost.
   *
   * Measured energy × the job's tariff when a plug metered enough of it;
   * otherwise the job's actual hours (or its estimate) × the machine's
   * wattage × the tariff — which is what every job without a plug has always
   * been costed at.
   *
   * @param {object} order
   * @param {object} rates  resolved rates (`KhaytPrintRates.ratesFor`)
   * @returns {{ cost: number, measured: boolean, wh: number|null, estimated: number }}
   */
  function actualPowerCost(order, rates) {
    const rt = rates || {};
    const tariff = tariffOf(order, rt);
    const estimated = estimatedPowerCost(order, rt);
    const wh = energyWhOf(order);
    if (wh !== null) return { cost: (wh / 1000) * tariff, measured: true, wh, estimated };
    const hours = pos(order && order.actualPrintTime) || pos(order && order.printTime) || 0;
    const watts = Math.max(0, num(rt.powerDraw) || 0);
    return { cost: hours * (watts / 1000) * tariff, measured: false, wh: null, estimated };
  }

  /**
   * A machine's wattage, from what its plug measured.
   *
   * Measured Wh ÷ measured print hours, over the machine's most recent
   * metered prints — the RATIO OF THE SUMS, so a forty-hour print counts forty
   * times an hour-long one, which is what a bill does.
   *
   * The hours are the printer's `actualPrintTime` (which excludes pauses and,
   * on most firmware, the heat-up), while the energy includes both. That is
   * deliberate: a quote multiplies SLICER hours, which leave out the heat-up
   * too, by this wattage — so folding the heat-up into the watts is how a
   * quote comes to charge for it.
   *
   * @returns {{ watts: number, basedOn: number, hours: number, wh: number }|null}
   *   null below `minPrints` metered prints.
   */
  function suggestPowerDraw(printLog, machineId, opts) {
    const o = opts || {};
    const limit = pos(o.limit) || SUGGEST_LIMIT;
    const min = pos(o.minPrints) || SUGGEST_MIN;
    const id = String(machineId || '');
    if (!id) return null;
    const rows = (Array.isArray(printLog) ? printLog : [])
      .filter((j) => j && String(j.machineId || '') === id)
      .map((j) => ({ j, wh: energyWhOf(j), h: pos(j.actualPrintTime) }))
      .filter((r) => r.wh !== null && r.h !== null)
      .sort((a, b) => String(stampOf(b.j)).localeCompare(String(stampOf(a.j))))
      .slice(0, limit);
    if (rows.length < min) return null;
    const wh = rows.reduce((s, r) => s + r.wh, 0);
    const hours = rows.reduce((s, r) => s + r.h, 0);
    if (!(hours > 0)) return null;
    return { watts: Math.round(wh / hours), basedOn: rows.length, hours: round(hours, 2), wh: round(wh, 1) };
  }

  /**
   * Estimate against actual, for ELECTRICITY, one row per machine.
   *
   * For the actuals screens (how each machine runs against its quote) — not
   * the P&L, which carries the shop's real electricity bill as an expense.
   * Only finished jobs a plug metered enough of; everything else has no
   * actual to compare. The delta is on the TOTALS, like the bill it predicts.
   *
   * @param {Array} orders
   * @param {function} ratesOf  (machineId) => resolved rates for that machine
   * @returns {Array<{machineId, sampled, wh, estCost, actCost, deltaPct}>}
   *   the machine running furthest over its estimate first
   */
  function powerByMachine(orders, ratesOf) {
    const rOf = typeof ratesOf === 'function' ? ratesOf : () => ({});
    const groups = new Map();
    for (const o of Array.isArray(orders) ? orders : []) {
      if (!o || !o.machineId) continue;
      if (o.status !== 'completed' && o.status !== 'delivered') continue;
      if (energyWhOf(o) === null) continue;
      const id = String(o.machineId);
      const a = actualPowerCost(o, rOf(id) || {});
      if (!groups.has(id)) groups.set(id, { machineId: id, sampled: 0, wh: 0, estCost: 0, actCost: 0 });
      const g = groups.get(id);
      g.sampled += 1; g.wh += a.wh; g.estCost += a.estimated; g.actCost += a.cost;
    }
    const rows = [...groups.values()].map((g) => ({
      machineId: g.machineId, sampled: g.sampled, wh: round(g.wh, 1),
      estCost: round(g.estCost, 2), actCost: round(g.actCost, 2),
      deltaPct: g.estCost > 0 ? round(((g.actCost - g.estCost) / g.estCost) * 100, 1) : null,
    }));
    rows.sort((a, b) => (b.deltaPct || 0) - (a.deltaPct || 0));
    return rows;
  }

  function stampOf(job) {
    return (job.actualEnergy && job.actualEnergy.at) || job.completedAt || job.date || '';
  }

  const api = {
    MAX_GAP_S, MIN_COVERAGE, STALE_S, SUGGEST_LIMIT, SUGGEST_MIN,
    inJob, sharedPlugIds, step, tick, take, reading, jobFor, jobFields,
    energyWhOf, tariffOf, estimatedPowerCost, actualPowerCost, suggestPowerDraw, powerByMachine,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrintEnergy = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
