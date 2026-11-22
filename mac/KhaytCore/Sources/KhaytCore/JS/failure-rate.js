'use strict';
/**
 * A failure allowance learned from what actually failed.
 *
 * ── WHY ─────────────────────────────────────────────────────────────────────
 *
 * Every price carries a failure allowance: `failureRate`% on top of the whole
 * base cost (lib/calculator-cost.js), 10 unless the shop says otherwise. The
 * shop also RECORDS its failures — a QC fail (lib/qc-failure.js) and a waste
 * entry for a print that failed off the bench (lib/waste-entry.js) — and the
 * two never met: a shop failing one print in twenty was still quoted as if it
 * failed one in ten, and one failing one in five was undercharging every job.
 *
 * ── WHAT IS COUNTED ─────────────────────────────────────────────────────────
 *
 *   failed attempts ÷ total attempts, over a recent window (90 days)
 *
 *   A SUCCESS    a finished job (completed or delivered, not voided) whose QC
 *                did not end in a fail, dated by when it finished.
 *   A FAILURE    one failed attempt at a job. Each QC fail writes BOTH a defect
 *                on the job and a waste row carrying its `orderId`, so they are
 *                not added together: a job's failures are the larger of its
 *                waste rows and its defects in the window — and at least one
 *                if the job's QC stands at `fail`.
 *
 * Waste rows that name no job are left out: nothing says which job, machine or
 * material they were an attempt at, and there is no success to set them
 * against either.
 *
 * ── MOST SPECIFIC FIRST, BUT ONLY ON ENOUGH EVIDENCE ────────────────────────
 *
 * The question is asked of this machine AND this material, then of the
 * machine, then of the material, then of the whole shop, and the first with at
 * least `minSample` attempts (20) answers. Five prints on a new printer are not
 * a failure rate; they are an anecdote. Below the minimum anywhere, the answer
 * says so (`enough: false`) and carries the count, so a screen can say "based
 * on N prints" rather than suggest a figure from nothing.
 *
 * The suggestion is ONLY a suggestion. This module never writes a rate; the
 * screen offers it beside the field and the shop decides.
 *
 * PURE: no DOM, no clock — `today` is passed in.
 */
(function (global) {

  const FINISHED = new Set(['completed', 'delivered']);
  const DEFAULT_DAYS = 90;
  const DEFAULT_MIN = 20;

  const trim = (v) => String(v == null ? '' : v).trim();
  const same = (a, b) => trim(a).toLowerCase() === trim(b).toLowerCase();

  function dayNumber(s) {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(trim(s));
    if (!m) return null;
    const t = Date.UTC(+m[1], +m[2] - 1, +m[3]);
    return Number.isFinite(t) ? Math.round(t / 86400000) : null;
  }

  function qcFailed(o) {
    if (o.qcStatus) return o.qcStatus === 'fail';
    return !!o.qcFailedAt && !o.qcPassedAt;
  }

  /**
   * Every attempt in the window, as `{ machineId, material, failed }` rows.
   *
   * `history`: `{ orders, wasteLog }`. `opts`: `{ today, days }`.
   */
  function attempts(history, opts) {
    const h = history || {};
    const o = opts || {};
    const today = dayNumber(o.today);
    if (today === null) return [];
    const days = Math.max(1, Math.round(+o.days || DEFAULT_DAYS));
    const from = today - days + 1;
    const inWindow = (s) => { const d = dayNumber(s); return d !== null && d >= from && d <= today; };

    const orders = (Array.isArray(h.orders) ? h.orders : []).filter((x) => x && x.id);
    const byId = new Map(orders.map((x) => [String(x.id), x]));

    const wasteFor = new Map();
    for (const w of Array.isArray(h.wasteLog) ? h.wasteLog : []) {
      if (!w || !w.orderId || !inWindow(w.date)) continue;
      const id = String(w.orderId);
      if (!wasteFor.has(id)) wasteFor.set(id, []);
      wasteFor.get(id).push(w);
    }

    const rows = [];
    const seen = new Set();
    const failuresOf = (order, id) => {
      const waste = wasteFor.get(id) || [];
      const defects = (order && Array.isArray(order.defects) ? order.defects : [])
        .filter((d) => d && inWindow(d.at)).length;
      let n = Math.max(waste.length, defects);
      if (n === 0 && order && qcFailed(order) && inWindow(order.qcFailedAt || order.qcAt)) n = 1;
      return { n, waste };
    };

    for (const order of orders) {
      const id = String(order.id);
      seen.add(id);
      const machineId = order.machineId || null;
      const material = order.material || '';
      const { n } = failuresOf(order, id);
      for (let k = 0; k < n; k++) rows.push({ machineId, material, failed: true });
      const finished = FINISHED.has(order.status) && !order.voidedAt;
      if (finished && !qcFailed(order) && inWindow(order.completedAt || order.date)) {
        rows.push({ machineId, material, failed: false });
      }
    }
    // Waste against a job this book no longer holds is still a failed attempt
    // at SOMETHING the shop took on; it is counted by what the row itself says.
    for (const [id, waste] of wasteFor) {
      if (byId.has(id)) continue;
      for (const w of waste) rows.push({ machineId: w.machineId || null, material: w.material || '', failed: true });
    }
    return rows;
  }

  function tally(rows) {
    const failures = rows.filter((r) => r.failed).length;
    return { failures, attempts: rows.length };
  }

  /**
   * The suggested failure allowance for a machine and a material.
   *
   * `history`: `{ orders, wasteLog }`.
   * `opts`: `{ today, machineId?, material?, days = 90, minSample = 20 }`.
   *
   * Returns `{ pct, failures, attempts, scope, enough, days, minSample }` —
   * `scope` is which question answered: `machine_material`, `machine`,
   * `material` or `shop`. `pct` is rounded to one decimal, and null when there
   * is not enough to go on.
   */
  function suggest(history, opts) {
    const o = opts || {};
    const days = Math.max(1, Math.round(+o.days || DEFAULT_DAYS));
    const minSample = Math.max(1, Math.round(+o.minSample || DEFAULT_MIN));
    const rows = attempts(history, { today: o.today, days });
    const machineId = trim(o.machineId);
    const material = trim(o.material);

    const scopes = [];
    if (machineId && material) {
      scopes.push(['machine_material', (r) => same(r.machineId, machineId) && same(r.material, material)]);
    }
    if (machineId) scopes.push(['machine', (r) => same(r.machineId, machineId)]);
    if (material) scopes.push(['material', (r) => same(r.material, material)]);
    scopes.push(['shop', () => true]);

    for (const [scope, keep] of scopes) {
      const t = tally(rows.filter(keep));
      if (t.attempts >= minSample) {
        return {
          pct: Math.round((t.failures / t.attempts) * 1000) / 10,
          failures: t.failures, attempts: t.attempts, scope, enough: true, days, minSample,
        };
      }
    }
    // Not enough anywhere: say how much there is, from the widest question.
    const all = tally(rows);
    return { pct: null, failures: all.failures, attempts: all.attempts, scope: 'shop', enough: false, days, minSample };
  }

  const api = { suggest, attempts, DEFAULT_DAYS, DEFAULT_MIN };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytFailureRate = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
