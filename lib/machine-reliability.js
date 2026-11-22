'use strict';
(function (global) {
/**
 * Which machine is costing the shop, and what it keeps doing wrong.
 *
 * Neither app has answered this. Waste is charted by failure type over time —
 * which says the shop has a warping problem — and never by MACHINE, which is
 * what says WHICH printer has it. "Replace the old one" is a decision worth
 * thousands, and until now there was nothing to make it on.
 *
 * ── AGAINST WHAT THE MACHINE PRINTED, NOT IN ISOLATION ────────────────────
 *
 * A printer that ran nine hundred hours and scrapped two kilos is doing better
 * than one that ran ninety and scrapped one — so the rate is scrap against what
 * that machine actually put out, and the raw grams are reported beside it
 * rather than instead of it. Ranking by grams alone would always name the
 * busiest machine, which is the wrong printer to sell.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function day(v) { return String(v == null ? '' : v).slice(0, 10); }

const FINISHED = ['completed', 'delivered'];

/**
 * @param {object} input
 *   machines  [{ id, name, color }]
 *   orders    every order; finished ones say what each machine put out
 *   waste     [{ machineId, date, weight, cost, failureType }]
 *   from, to  `YYYY-MM-DD` bounds, or '' for all time
 *   unassigned what to call scrap that names no machine
 * @param {object} deps
 *   gramsOf  (order) => grams that machine actually printed
 *   hoursOf  (order) => hours it ran
 * @returns {{rows: Array, totals: object}} worst rate first
 */
function machineReliability(input, deps) {
  const i = input || {};
  const d = deps || {};
  const gramsOf = typeof d.gramsOf === 'function'
    ? d.gramsOf
    : (o) => (o && Array.isArray(o.parts) ? o.parts : []).reduce(
        (s, p) => s + (num(p && p.printWeight) + num(p && p.supportWeight))
                      * Math.max(1, num(p && p.qty) || 1), 0);
  const hoursOf = typeof d.hoursOf === 'function'
    ? d.hoursOf
    : (o) => (o && Array.isArray(o.parts) ? o.parts : []).reduce(
        (s, p) => s + num(p && p.printTime) * Math.max(1, num(p && p.qty) || 1), 0);

  const from = day(i.from);
  const to = day(i.to);
  const inWindow = (at) => {
    const when = day(at);
    if (!when) return false;
    if (from && when < from) return false;
    if (to && when > to) return false;
    return true;
  };

  const NONE = '__none__';
  const byId = new Map();
  for (const m of (Array.isArray(i.machines) ? i.machines : [])) {
    if (!m || !m.id) continue;
    byId.set(String(m.id), {
      machineId: String(m.id), name: String(m.name || ''), color: m.color || '#888888',
      jobs: 0, grams: 0, hours: 0,
      scraps: 0, scrapGrams: 0, scrapCost: 0,
      scrapRate: null, worstFault: null, faults: {},
    });
  }
  // Scrap that names no machine is still scrap. A shop cannot act on it, but
  // hiding it makes the shop's total look better than it is.
  byId.set(NONE, {
    machineId: NONE, name: String(i.unassigned || ''), color: '#888888',
    jobs: 0, grams: 0, hours: 0,
    scraps: 0, scrapGrams: 0, scrapCost: 0,
    scrapRate: null, worstFault: null, faults: {},
  });

  for (const order of (Array.isArray(i.orders) ? i.orders : [])) {
    if (!order || order.voidedAt) continue;
    if (!FINISHED.includes(String(order.status || ''))) continue;
    if (!inWindow(order.date)) continue;
    const row = byId.get(String(order.machineId || '')) || byId.get(NONE);
    row.jobs += 1;
    row.grams += num(gramsOf(order));
    row.hours += num(hoursOf(order));
  }

  for (const entry of (Array.isArray(i.waste) ? i.waste : [])) {
    if (!entry || !inWindow(entry.date)) continue;
    const row = byId.get(String(entry.machineId || '')) || byId.get(NONE);
    row.scraps += 1;
    row.scrapGrams += num(entry.weight);
    row.scrapCost += num(entry.cost);
    const fault = String(entry.failureType || 'other');
    row.faults[fault] = num(row.faults[fault]) + num(entry.weight);
  }

  for (const row of byId.values()) {
    // Against what the machine PUT OUT, plus what it scrapped — the denominator
    // is everything it consumed, so a machine that scrapped half its filament
    // reads as 50% rather than 100%.
    const handled = row.grams + row.scrapGrams;
    row.scrapRate = handled > 0 ? row.scrapGrams / handled : null;
    // What it keeps doing wrong, which is the actionable half: "warping" sends
    // somebody to the chamber temperature, and a number does not.
    const faults = Object.entries(row.faults).sort((a, b) => b[1] - a[1]);
    row.worstFault = faults.length ? { type: faults[0][0], grams: faults[0][1] } : null;
  }

  const rows = [...byId.values()]
    .filter((r) => r.jobs > 0 || r.scraps > 0)
    // WORST RATE FIRST, not most grams — ranking by grams always names the
    // busiest machine, which is the wrong printer to sell.
    .sort((a, b) => (b.scrapRate ?? -1) - (a.scrapRate ?? -1)
                    || b.scrapGrams - a.scrapGrams);

  const grams = rows.reduce((s, r) => s + r.grams, 0);
  const scrapGrams = rows.reduce((s, r) => s + r.scrapGrams, 0);
  const handled = grams + scrapGrams;
  return {
    rows,
    totals: {
      jobs: rows.reduce((s, r) => s + r.jobs, 0),
      grams, scrapGrams,
      scraps: rows.reduce((s, r) => s + r.scraps, 0),
      scrapCost: rows.reduce((s, r) => s + r.scrapCost, 0),
      scrapRate: handled > 0 ? scrapGrams / handled : null,
      /// The machine to look at — worst rate, and only once it has printed
      /// enough for a rate to mean anything. One scrapped print on a machine
      /// that has run twice is not evidence of anything.
      worst: rows.find((r) => r.scrapRate != null && r.scraps > 0 && r.jobs >= 2) || null,
    },
  };
}

const api = { machineReliability, FINISHED };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMachineReliability = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
