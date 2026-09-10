'use strict';
(function (global) {

/**
 * Turning a shop's live queue into the snapshot a storefront quotes from.
 *
 * Split out from main.js so the decisions below are testable without an Electron
 * app, a clock or a network — every one of them changes a date a customer will
 * be given, and "it looked right on my machine" is not a way to check that.
 *
 * Wrapped in the same IIFE every other shared module uses, so the Mac app can
 * evaluate it inside JavaScriptCore. There is no `require` there — modules are
 * run in order into one realm and find each other on the global — and the
 * publisher has to be the SAME code in both apps or the two will quote a
 * customer different dates from one book.
 */

// require() under Node and the test runner; the global under the renderer and
// inside JavaScriptCore. try/catch rather than a typeof check, because a host
// that DOES expose require would resolve './lead-time.js' against the wrong
// directory and throw — and falling back is right in both cases.
//
// ORDER MATTERS in the bundle: both of these must have run already. They are
// read once, here, so a missing one is a null at load rather than a promise
// built from half the rules.
let LeadTime, Attention;
try { LeadTime = require('./lead-time.js'); } catch (e) { LeadTime = null; }
if (!LeadTime) LeadTime = global.KhaytLeadTime;
try { Attention = require('./attention.js'); } catch (e) { Attention = null; }
if (!Attention) Attention = global.KhaytAttention;
let WorkingWeek;
try { WorkingWeek = require('./working-week.js'); } catch (e) { WorkingWeek = null; }
if (!WorkingWeek) WorkingWeek = global.KhaytWorkingWeek;

/** Statuses that still represent work to do. `completed` and `delivered` do not. */
const ACTIVE = new Set(['queued', 'pending', 'printing', 'post', 'qc', 'on_hold']);

/**
 * Which lanes may take a new order.
 *
 * lib/lead-time.js will put a job on any lane it is given and cannot know
 * better — so filtering here is not tidiness, it is the difference between a
 * promise and a promise made against a printer that was never going to print it.
 *
 * Offline machines are excluded, because a shop with one printer down is a shop
 * with less capacity and a customer should be told the true date rather than the
 * one that assumes a repair.
 *
 * Material is deliberately NOT filtered on. The basket is not known when the
 * snapshot is published — that is the whole point of publishing a snapshot
 * rather than answering a question — so this is the shop's general availability.
 * A shop whose printers take genuinely different materials will publish a date
 * that is right for its fastest lane; that is a known limit, written down here
 * rather than discovered later.
 */
function usableMachines(machines) {
  return (Array.isArray(machines) ? machines : [])
    .filter((m) => m && m.id && !m.isOffline && m.status !== 'offline' && m.status !== 'retired')
    .map((m) => String(m.id));
}

/**
 * Hours each lane is booked OUT of action, over the days a promise covers.
 *
 * `lib/lead-time.js` reads no clock and parses no dates — that is what makes a
 * promise reproducible — so the calendar work happens here, where the shop's
 * `nowIso` already is.
 *
 * `usableMachines` above already drops a printer that is OFFLINE, on the stated
 * principle that a shop with one printer down should tell a customer the true
 * date rather than the one that assumes a repair. A machine the shop has BOOKED
 * OUT for a belt change on Thursday is the same case, said in advance — and
 * until now it was the case nothing acted on.
 */
function downtimeByMachine(machines, nowIso, days) {
  const from = new Date(String(nowIso || '')).getTime();
  if (!Number.isFinite(from)) return {};
  const to = from + Math.max(1, days) * 86400000;
  const out = {};
  for (const m of Array.isArray(machines) ? machines : []) {
    if (!m || !m.id) continue;
    let hours = 0;
    for (const b of Array.isArray(m.downtimeBlocks) ? m.downtimeBlocks : []) {
      if (!b || !b.from || !b.to) continue;
      const bFrom = new Date(b.from).getTime();
      const bTo = new Date(b.to).getTime();
      if (!Number.isFinite(bFrom) || !Number.isFinite(bTo) || bTo <= bFrom) continue;
      const start = Math.max(from, bFrom);
      const end = Math.min(to, bTo);
      if (end > start) hours += (end - start) / 3600000;
    }
    if (hours > 0) out[String(m.id)] = hours;
  }
  return out;
}

/** Outstanding print hours per job, from the queue the shop actually has. */
function activeQueue(printLog) {
  const out = [];
  for (const o of Array.isArray(printLog) ? printLog : []) {
    if (!o || !ACTIVE.has(String(o.status || 'pending'))) continue;
    const hours = Number(o.printTime);
    // A job with no estimate is not a job with no work. Skipping it would
    // shorten every promise a shop makes while it has unestimated orders in the
    // queue — which is exactly when it is busiest.
    out.push({ hours: Number.isFinite(hours) && hours > 0 ? hours : 0, machineId: o.machineId || '' });
  }
  return out;
}

/**
 * Work the PRINTERS are doing that the order book knows nothing about.
 *
 * The queue above is built entirely from orders, so a machine running a job sent
 * to it straight from a slicer counted as free — and the shop quoted a customer
 * a turnaround as if a printer sitting five hours into a print were available.
 * Reported from the bench: a U1 mid-job, and Khayt calling it idle.
 *
 * This is the same lesson lib/moonraker-history.js already records for filament:
 * for "what is this machine actually doing", the printer is the ground truth and
 * the order log is a sample of it. It had never been applied to capacity.
 *
 * TWO CASES, AND ONLY ONE OF THEM IS A NUMBER.
 *
 *   Remaining time known → real queue load on that lane, in hours.
 *   Remaining time NOT known → the machine is occupied and nobody can say for
 *     how long. Klipper reports no usable estimate below about 1% of a job, so
 *     this is the normal state for the first minutes of every print. The lane is
 *     dropped from the usable set instead: "busy, duration unknown" is the truth,
 *     and inventing hours to stand in for it would put a guess into a date a
 *     customer holds the shop to.
 *
 * A machine that ALREADY has an active order against it is skipped: that order
 * is presumably the job on the bed, and counting both would inflate every
 * promise the shop makes while it is working normally.
 */
function printerInFlight(machines, statusCache, printLog) {
  const cache = statusCache || {};
  const ordered = new Set();
  for (const o of Array.isArray(printLog) ? printLog : []) {
    if (o && o.machineId && ACTIVE.has(String(o.status || 'pending'))) ordered.add(String(o.machineId));
  }
  const queue = [];
  const occupied = [];
  for (const m of Array.isArray(machines) ? machines : []) {
    if (!m || !m.id || ordered.has(String(m.id))) continue;
    if (Attention.machineState(m, cache[m.id]) !== 'printing') continue;
    const secs = Number(cache[m.id] && cache[m.id].timeRemaining);
    if (Number.isFinite(secs) && secs > 0) {
      queue.push({ hours: Math.round((secs / 3600) * 100) / 100, machineId: String(m.id) });
    } else {
      occupied.push(String(m.id));
    }
  }
  return { queue, occupied };
}

/**
 * Build the snapshot, or return null when the shop has not asked for this.
 *
 * @param {object} input
 * @param {object} input.settings   settings.leadTime
 * @param {object[]} input.printLog
 * @param {object[]} input.machines
 * @param {string} input.today      the shop's LOCAL day, 'YYYY-MM-DD'
 * @param {string} input.nowIso     injected clock
 */
/**
 * Working days a week, from the grid the shop actually fills in.
 *
 * Falls back to the stored `leadTime` figure only when there is no working
 * week to read — a book from before the grid existed, or a caller that passed
 * no settings at all. A grid with every day at zero is not an answer either;
 * a shop that is never open cannot be promised against, so the stored figure
 * stands rather than dividing by nothing.
 */
function workingDaysFrom(settings, lt) {
  const days = WorkingWeek && settings ? WorkingWeek.workingDaysPerWeek(settings) : 0;
  return days > 0 ? days : lt.workingDaysPerWeek;
}

/** Hours on an average working day, from the same grid — closed days excluded. */
function dailyHoursFrom(settings, lt) {
  if (!WorkingWeek || !settings) return lt.dailyHours;
  const wh = WorkingWeek.workingHours(settings) || {};
  const open = WorkingWeek.DAY_KEYS.map((k) => Number(wh[k]) || 0).filter((h) => h > 0);
  if (open.length === 0) return lt.dailyHours;
  // Two decimals. A mean over five days lands on a third of an hour often
  // enough that 7.666666666666667 would otherwise reach a published snapshot,
  // which is arithmetic showing through. NOT the quarter hour tried first:
  // that turns a real 8.4 into 8.5, which is a shop being promised against
  // six minutes a day it does not work.
  return Math.round((open.reduce((a, b) => a + b, 0) / open.length) * 100) / 100;
}

function buildSnapshot(input) {
  const i = input || {};
  const lt = (i.settings && i.settings.leadTime) || {};
  if (!lt.publishToCloud) return null;
  const inFlight = printerInFlight(i.machines, i.statusCache, i.printLog);
  return LeadTime.snapshot({
    computedAt: i.nowIso,
    today: i.today,
    queue: [...activeQueue(i.printLog), ...inFlight.queue],
    // A printer that is mid-job for an unknown remaining time is not a lane a
    // new order can be promised against.
    machineIds: usableMachines(i.machines).filter((id) => !inFlight.occupied.includes(id)),
    // A fortnight, which is longer than most promises and short enough that a
    // window booked for next quarter does not shorten today's answer.
    downtimeHours: downtimeByMachine(i.machines, i.nowIso, 14),
    // ── THE WEEK THE SHOP TYPED, NOT A SECOND ONE ────────────────────
    //
    // These two came from `settings.leadTime`, which is a separate pair of
    // numbers the shop fills in under "Delivery Estimates" — while the
    // Working Hours grid a few rows above, on the same settings pane, holds
    // the hours for each day of the week. Two models of one fact, both
    // editable, silently disagreeing: a shop that closed Friday and Saturday
    // in the grid still had its promises computed on whatever was left in
    // the other box, which defaults to five days at eight hours.
    //
    // `KhaytWorkingWeek.workingDaysPerWeek` was written for exactly this —
    // its own comment says it is "what a lead-time promise counts in" — and
    // had NO CALLERS. The rule was right and nothing asked it.
    //
    // A shop on the defaults sees no change: Sunday to Thursday is five days
    // at eight hours, which is what the other box already said. It moves only
    // for the shop that customised its week, which is the shop whose dates
    // were wrong.
    dailyHours: dailyHoursFrom(i.settings, lt),
    workingDaysPerWeek: workingDaysFrom(i.settings, lt),
    finishingDays: lt.finishingDays,
    dispatchDays: lt.dispatchDays,
    safetyDays: lt.safetyDays,
    staleAfterHours: lt.staleAfterHours,
  });
}

/**
 * Has anything changed enough to be worth publishing?
 *
 * `computedAt` moves every time this runs, so comparing whole snapshots would
 * publish on every tick and never say anything new. What a storefront reads is
 * the rest of it, so that is what is compared — and a republish that says
 * exactly what the last one said only costs the shop's cursor its freshness.
 *
 * The freshness IS the point though: an unchanged snapshot still needs
 * republishing before `staleAfterHours` runs out, or the storefront stops
 * quoting. So this answers "different", and the caller decides how often to
 * publish regardless.
 */
function differs(a, b) {
  if (!a || !b) return true;
  const strip = (s) => JSON.stringify({ ...s, computedAt: null });
  return strip(a) !== strip(b);
}

const api = {
  downtimeByMachine, buildSnapshot, usableMachines, activeQueue, printerInFlight, differs, ACTIVE };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytLeadTimePublish = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
