'use strict';
(function (global) {

/**
 * The next N hours on the machines, as blocks on a band.
 *
 * A shop's first question in the morning is "when is that machine free", and
 * every screen Khayt had answered it with a number. A number has to be read and
 * compared; a gap on a band is seen. This module works out what goes on that
 * band.
 *
 * ── WHAT IS KNOWN, WHAT IS PROJECTED, AND WHAT IS NEITHER ──────────────────
 *
 * These are three different things and the band must not blur them.
 *
 * KNOWN — a running job's end. The printer says how long it has left
 * (`timeRemaining`, seconds) or how far through it is (`progress`, 0–100)
 * against the job's own estimate. Either gives an end.
 *
 * PROJECTED — everything queued behind it. Nothing schedules those; they are
 * laid end to end in the order the board would run them, and every one of them
 * carries `projected: true` so a screen can draw them differently. A shop that
 * reads a projection as a promise will plan a delivery around it.
 *
 * NEITHER — a machine Khayt cannot ask. A printer with no connection, or one
 * whose poll is failing, is printing something that ends at a time nobody
 * knows. The temptation is to fall back on the job's estimate from its start
 * date, and that is wrong twice over: the start date is the day the job was
 * TAKEN, not the hour it went on the plate.
 *
 * So such a machine gets `known: false`, no blocks, and — this is the part that
 * matters — **it is left out of the capacity totals entirely**. Counting it as
 * forty-eight free hours would overstate the shop's capacity by a whole machine
 * on exactly the day its printer went offline. The totals say how many machines
 * they are over, so a shop can see the difference.
 *
 * ── NO CLOCK IN HERE ──────────────────────────────────────────────────────
 *
 * `now` is injected, like `lib/scheduling.js`. Same inputs, same band, always.
 *
 * Depends on `lib/scheduling.js` for the queue order and
 * `lib/order-deduction.js` for what a job takes off the shelf — reused rather
 * than re-derived, so the band, the board and the shelf cannot disagree about
 * which job runs next or what it needs.
 */

const MINUTE = 60000;
const HOUR = 3600000;
const DEFAULT_HOURS = 48;
/** What counts as waiting for a machine. Mirrors `lib/scheduling.js`. */
const QUEUED_STATUSES = new Set(['pending', 'queued']);

function arrayOf(x) { return Array.isArray(x) ? x.filter(Boolean) : []; }
/**
 * A number, or null — and ABSENT IS NULL, not zero.
 *
 * `+null` is 0 and `Number.isFinite(0)` is true, so the obvious one-liner made
 * a machine Khayt cannot poll look like a machine whose print has exactly zero
 * seconds left. Every unaskable printer came back "free in a moment", which is
 * the precise lie this module exists to avoid.
 */
function num(x) {
  if (x === null || x === undefined || x === '') return null;
  const n = +x;
  return Number.isFinite(n) ? n : null;
}

/** Hours a job is estimated to take. Zero for a job nobody estimated. */
function hoursOf(order) {
  const n = num(order && order.printTime);
  return n !== null && n > 0 ? n : 0;
}

/**
 * When the job on this machine finishes, in epoch ms — or null.
 *
 * `timeRemaining` first because it is the printer's own answer and it accounts
 * for what the print is actually doing. `progress` against the job's estimate
 * second. Neither, and the answer is null: see the header.
 */
function endOfRunning(order, reading, now) {
  const left = num(reading && reading.timeRemaining);
  if (left !== null && left >= 0) return now + left * 1000;
  const pct = num(reading && reading.progress);
  const hours = hoursOf(order);
  // A progress of 0 says the print has not started laying anything, which is
  // not the same as "nothing is known" — but it makes the estimate the whole
  // job, which is the honest reading of it.
  if (pct !== null && pct >= 0 && pct < 100 && hours > 0) {
    return now + hours * HOUR * (1 - pct / 100);
  }
  return null;
}

/**
 * Grams this job still needs, by material, against what is on the shelf.
 *
 * `claimsFor` maps a job's parts to the spools they were assigned, which is the
 * same mapping that will draw them down when the job completes. A job wanting
 * more than its spool holds is not stuck if another spool of the same material
 * is on the shelf — `deductForOrder` falls back to one — so the comparison is
 * per MATERIAL, not per spool.
 */
function shortfallOf(order, inventory) {
  const D = global.KhaytOrderDeduction;
  if (!D || typeof D.claimsFor !== 'function') return null;
  const shelf = arrayOf(inventory);
  const need = new Map();
  for (const claim of D.claimsFor(order, shelf)) {
    const material = String((claim.spool && claim.spool.material) || '');
    if (!material) continue;
    need.set(material, (need.get(material) || 0) + (+claim.grams || 0));
  }
  let worst = null;
  for (const [material, grams] of need) {
    let have = 0;
    for (const s of shelf) if (String(s.material || '') === material) have += Math.max(0, +s.weight || 0);
    const short = grams - have;
    if (short > 0 && (worst === null || short > worst.short)) {
      worst = { material, needs: grams, has: have, short };
    }
  }
  return worst;
}

/** The jobs waiting on this machine, in the order the board would run them. */
function queueFor(machine, orders, now) {
  const S = global.KhaytScheduling;
  const mine = orders.filter(o =>
    String(o.machineId || '') === String(machine.id)
    && QUEUED_STATUSES.has(String(o.status || '')));
  // The board's own urgency, so the band and the board name the same next job.
  // Without `scheduling` loaded the input order stands, which is what the
  // renderer has always treated as queue order.
  if (!S || typeof S.urgencyScore !== 'function') return mine;
  return mine
    .map((o, i) => ({ o, i, u: S.urgencyScore(o, now) }))
    .sort((a, b) => (a.u - b.u) || (a.i - b.i))
    .map(x => x.o);
}

/**
 * Clip a block to the window and record which end was cut.
 *
 * A block that starts before the window or runs past it is the normal case, not
 * an edge case: a 42-hour print does not fit in anybody's idea of a day. The
 * clipping is reported rather than silently applied, because a bar drawn to the
 * edge of a chart and a bar that ENDS there look identical.
 */
function clip(startsAt, endsAt, from, to) {
  const startMinute = Math.max(0, (startsAt - from) / MINUTE);
  const endMinute = Math.min((to - from) / MINUTE, (endsAt - from) / MINUTE);
  return {
    startMinute, endMinute,
    minutes: Math.max(0, endMinute - startMinute),
    clippedStart: startsAt < from,
    clippedEnd: endsAt > to,
    beforeMinutes: startsAt < from ? (from - startsAt) / MINUTE : 0,
    afterMinutes: endsAt > to ? (endsAt - to) / MINUTE : 0,
  };
}

/** The free stretches between what is booked, inside the window. */
function gapsBetween(blocks, minutes) {
  const out = [];
  let cursor = 0;
  for (const b of blocks) {
    if (b.startMinute > cursor) out.push({ startMinute: cursor, minutes: b.startMinute - cursor });
    cursor = Math.max(cursor, b.endMinute);
  }
  if (cursor < minutes) out.push({ startMinute: cursor, minutes: minutes - cursor });
  return out.filter(g => g.minutes > 0);
}

/**
 * The band.
 *
 * @param {object} input
 *   machines   [{ id, name }]
 *   orders     [{ id, status, machineId, printTime, project, ... }]
 *   inventory  [{ id, material, weight }]
 *   live       { [machineId]: { progress, timeRemaining } } — a machine absent
 *              here is one Khayt cannot ask; see the header.
 *   now        epoch ms
 *   hours      window length, default 48
 */
function band(input) {
  const inp = input || {};
  const now = num(inp.now) || 0;
  const hours = num(inp.hours) || DEFAULT_HOURS;
  const from = now, to = now + hours * HOUR, minutes = hours * 60;
  const machines = arrayOf(inp.machines);
  const orders = arrayOf(inp.orders);
  const inventory = arrayOf(inp.inventory);
  const live = (inp.live && typeof inp.live === 'object') ? inp.live : {};

  const rows = machines.map(m => {
    const id = String(m.id);
    const running = orders.find(o =>
      String(o.machineId || '') === id && String(o.status || '') === 'printing') || null;
    const reading = live[id] || live[m.id] || null;

    // A machine that is printing something Khayt cannot time is not a machine
    // with 48 free hours. It is a machine whose next free hour is unknown.
    if (running && endOfRunning(running, reading, now) === null) {
      return {
        machineId: id, name: String(m.name || ''), state: 'printing',
        known: false, blocks: [], gaps: [],
        bookedMinutes: 0, freeMinutes: 0, overrunMinutes: 0,
        runningOrderId: String(running.id),
      };
    }

    const blocks = [];
    let cursor = now;
    if (running) {
      const endsAt = endOfRunning(running, reading, now);
      const startsAt = endsAt - hoursOf(running) * HOUR;
      // Every block carries the same fields, including the two that can only
      // be false here: a running job is neither beyond the window nor waiting
      // on stock. A shape that varies by kind is one a typed caller has to
      // decode as optional, and then "absent" and "false" stop being different.
      blocks.push(Object.assign({
        orderId: String(running.id), kind: 'printing', projected: false,
        title: String(running.project || ''), startsAt, endsAt,
        shortfall: null, beyond: false,
      }, clip(startsAt, endsAt, from, to)));
      cursor = endsAt;
    }

    for (const o of queueFor(m, orders, now)) {
      const startsAt = cursor;
      const endsAt = startsAt + hoursOf(o) * HOUR;
      // Past the window and it cannot be drawn, but the FIRST one past it is
      // still worth naming — a shop wants to know what it just missed.
      if (startsAt >= to) {
        blocks.push(Object.assign({
          orderId: String(o.id), kind: 'queued', projected: true,
          title: String(o.project || ''), startsAt, endsAt,
          shortfall: shortfallOf(o, inventory), beyond: true,
        }, clip(startsAt, endsAt, from, to)));
        break;
      }
      const shortfall = shortfallOf(o, inventory);
      blocks.push(Object.assign({
        orderId: String(o.id), kind: shortfall ? 'blocked' : 'queued', projected: true,
        title: String(o.project || ''), startsAt, endsAt, shortfall, beyond: false,
      }, clip(startsAt, endsAt, from, to)));
      cursor = endsAt;
    }

    const drawn = blocks.filter(b => !b.beyond && b.minutes > 0);
    const booked = drawn.reduce((s, b) => s + b.minutes, 0);
    return {
      machineId: id, name: String(m.name || ''),
      state: running ? 'printing' : (drawn.length ? 'queued' : 'free'),
      known: true, blocks, gaps: gapsBetween(drawn, minutes),
      bookedMinutes: booked, freeMinutes: minutes - booked,
      overrunMinutes: drawn.reduce((s, b) => s + b.afterMinutes, 0),
      runningOrderId: running ? String(running.id) : null,
    };
  });

  // Only over the machines whose hours are actually knowable. A shop reading
  // "46% utilised" while a printer is offline is reading a number about two
  // machines that claims to be about three.
  const counted = rows.filter(r => r.known);
  const capacityMinutes = counted.length * minutes;
  const bookedMinutes = counted.reduce((s, r) => s + r.bookedMinutes, 0);
  return {
    from, to, minutes, hours,
    rows,
    countedMachines: counted.length,
    unknownMachines: rows.length - counted.length,
    capacityMinutes, bookedMinutes,
    freeMinutes: capacityMinutes - bookedMinutes,
    utilised: capacityMinutes > 0 ? bookedMinutes / capacityMinutes : 0,
  };
}

const api = { band, endOfRunning, shortfallOf, queueFor, gapsBetween, clip, DEFAULT_HOURS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMachineBand = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
