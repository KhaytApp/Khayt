'use strict';
(function (global) {
/**
 * Can the shop take this job, and when would it start?
 *
 * Work that has been agreed and not yet finished, against the hours each
 * machine is actually run for. The answer a shop needs is not a percentage —
 * it is a DATE, and the percentage is how it gets there.
 *
 * ── WHAT THE VERSION THIS REPLACES COULD NOT SAY ──────────────────────────
 *
 * `pct` was `Math.min(100, …)`. A machine booked three weeks over therefore
 * read as exactly full — identical to one with nothing left and nothing
 * waiting. That is the single most important signal on the screen and it was
 * clamped away: "full" means take no more today, "300%" means the shop is
 * three weeks behind and somebody has to be told.
 *
 * It also counted voided orders — a cancelled job kept booking the machine —
 * and dropped every machine with no target set, so a shop that had not filled
 * that field in saw an empty panel while its queue grew.
 *
 * Pure: no DOM, no fs, no Electron.
 */

function num(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/** Agreed and not finished. A quote is not booked — nobody has said yes. */
const BOOKED = ['pending', 'printing', 'post', 'qc', 'on_hold'];

/**
 * @param {object} input
 *   machines  [{ id, name, color, targetHoursPerDay }]
 *   orders    every order; which ones are booked is part of the answer
 *   days      the window to measure against, in days (default 7)
 *   unassigned what to call work that names no machine
 * @param {object} deps
 *   hoursOf   (order) => estimated print hours; defaults to `printTime`
 * @returns {{rows: Array, totals: object}}
 */
function capacity(input, deps) {
  const i = input || {};
  const d = deps || {};
  const hoursOf = typeof d.hoursOf === 'function' ? d.hoursOf : (o) => num(o && o.printTime);
  const days = Math.max(1, num(i.days) || 7);

  const NONE = '__none__';
  const byId = new Map();
  for (const m of (Array.isArray(i.machines) ? i.machines : [])) {
    if (!m || !m.id) continue;
    byId.set(String(m.id), {
      machineId: String(m.id), name: String(m.name || ''), color: m.color || '#888888',
      hoursPerDay: num(m.targetHoursPerDay),
      bookedHours: 0, jobs: 0,
      availableHours: 0, loadPct: null, daysToClear: null, overbooked: false,
    });
  }
  // Work that names no machine is still work. Dropping it is how a queue grows
  // behind a panel reading 40%.
  byId.set(NONE, {
    machineId: NONE, name: String(i.unassigned || ''), color: '#888888',
    hoursPerDay: 0, bookedHours: 0, jobs: 0,
    availableHours: 0, loadPct: null, daysToClear: null, overbooked: false,
  });

  for (const order of (Array.isArray(i.orders) ? i.orders : [])) {
    if (!order || order.voidedAt) continue;
    if (!BOOKED.includes(String(order.status || ''))) continue;
    const row = byId.get(String(order.machineId || '')) || byId.get(NONE);
    row.bookedHours += num(hoursOf(order));
    row.jobs += 1;
  }

  for (const row of byId.values()) {
    if (row.hoursPerDay > 0) {
      row.availableHours = row.hoursPerDay * days;
      // NOT CLAMPED. 300% is the answer, and it is a different answer from 100%.
      row.loadPct = (row.bookedHours / row.availableHours) * 100;
      row.overbooked = row.bookedHours > row.availableHours;
      // The figure a shop actually acts on: when does the queue clear.
      row.daysToClear = row.bookedHours / row.hoursPerDay;
    }
  }

  const rows = [...byId.values()]
    // A machine with nothing booked and no target has nothing to say. One with
    // a target is worth a row even when idle — that IS the answer to "can you
    // take this job".
    .filter((r) => r.bookedHours > 0 || r.hoursPerDay > 0)
    .sort((a, b) => (b.loadPct == null ? -1 : b.loadPct) - (a.loadPct == null ? -1 : a.loadPct)
                    || b.bookedHours - a.bookedHours);

  const withTarget = rows.filter((r) => r.hoursPerDay > 0);
  const bookedHours = rows.reduce((s, r) => s + r.bookedHours, 0);
  const availableHours = withTarget.reduce((s, r) => s + r.availableHours, 0);
  const hoursPerDay = withTarget.reduce((s, r) => s + r.hoursPerDay, 0);
  // Hours on machines nobody has given a target, or on no machine at all. Held
  // apart because they cannot be turned into a percentage of anything — and
  // saying nothing about them is how they stay invisible.
  const untargeted = rows.filter((r) => r.hoursPerDay <= 0)
    .reduce((s, r) => s + r.bookedHours, 0);

  return {
    rows,
    totals: {
      bookedHours, availableHours, untargeted,
      jobs: rows.reduce((s, r) => s + r.jobs, 0),
      loadPct: availableHours > 0
        ? ((bookedHours - untargeted) / availableHours) * 100 : null,
      daysToClear: hoursPerDay > 0 ? (bookedHours - untargeted) / hoursPerDay : null,
      overbooked: availableHours > 0 && (bookedHours - untargeted) > availableHours,
      /// No machine has a target, so no percentage can be worked out at all —
      /// which is a thing to say, not an empty panel.
      noTargets: withTarget.length === 0,
    },
  };
}

const api = { capacity, BOOKED };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytCapacity = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
