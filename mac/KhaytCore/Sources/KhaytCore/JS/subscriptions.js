'use strict';
(function () {

/**
 * Subscriptions / recurring-orders recurrence engine — pure selector + date math.
 *
 * See docs/KHAYT-3.0-SUBSCRIPTIONS-SPEC.md. This module is the side-effect-free
 * core of the standing-order feature: it decides which subscriptions are *due*
 * for materialization right now, how many cycles elapsed while the app was
 * closed (catch-up), and how to advance a subscription's schedule cursor. It
 * deliberately does NOT create orders — that is the renderer's job (logPrint).
 *
 * Mirrors the shape of lib/quote-followup.js: pure functions that return what is
 * due plus an immutable patch the caller assigns onto the record and persists.
 * No fs / renderer imports; `now` is injected (epoch ms, ISO string, or Date) so
 * the logic is fully deterministic and unit-testable.
 *
 * Schedule dates are stored as local 'YYYY-MM-DD' day strings (same convention
 * as quote-followup.js). `nextRunAt` is the engine's cursor; `lastRunAt` is a
 * full ISO timestamp of the last successful generation.
 *
 * Intervals: 'daily' | 'weekly' | 'biweekly' | 'monthly' | 'quarterly' | 'yearly'.
 * Calendar intervals (monthly/quarterly/yearly) keep the same day-of-month,
 * clamping to the target month's length (Jan 31 + monthly → Feb 28/29).
 */

const DAY_MS = 86400000;

/** Fixed-length intervals expressed in whole days. */
const DAY_INTERVALS = {
  daily: 1,
  weekly: 7,
  biweekly: 14,
};

/** Calendar intervals expressed in whole months. */
const MONTH_INTERVALS = {
  monthly: 1,
  quarterly: 3,
  yearly: 12,
};

/** All recognised interval keys. */
const INTERVALS = Object.freeze([
  ...Object.keys(DAY_INTERVALS),
  ...Object.keys(MONTH_INTERVALS),
]);

/* ───────────────────────── date helpers ───────────────────────── */

/** Zero-pad a number to two digits. */
function pad2(n) {
  return String(n).padStart(2, '0');
}

/** Format a Date as a local 'YYYY-MM-DD' day string. */
function toYmd(d) {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

/** Local-midnight Date for a 'YYYY-MM-DD' day string, or null when unusable. */
function dayStartFromYmd(ymd) {
  if (!ymd || typeof ymd !== 'string') return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(ymd.trim());
  if (!m) return null;
  const d = new Date(+m[1], +m[2] - 1, +m[3]);
  return Number.isNaN(d.getTime()) ? null : d;
}

/**
 * Local-midnight 'YYYY-MM-DD' for an injected `now` (epoch ms, ISO string, or
 * Date). Time-of-day is discarded — schedule math happens at day granularity.
 */
function todayYmd(now) {
  const d = now instanceof Date ? new Date(now.getTime()) : new Date(now);
  if (Number.isNaN(d.getTime())) throw new Error('subscriptions: invalid `now`');
  return toYmd(d);
}

/** Last day-of-month (1–31) for a given full year + 0-based month. */
function daysInMonth(year, monthIdx) {
  return new Date(year, monthIdx + 1, 0).getDate();
}

/**
 * Advance a 'YYYY-MM-DD' date by one calendar interval (months), preserving the
 * day-of-month and clamping to the target month length.
 */
function addMonths(ymd, months) {
  const d = dayStartFromYmd(ymd);
  const day = d.getDate();
  const total = d.getMonth() + months;
  const year = d.getFullYear() + Math.floor(total / 12);
  const monthIdx = ((total % 12) + 12) % 12;
  const clampedDay = Math.min(day, daysInMonth(year, monthIdx));
  return toYmd(new Date(year, monthIdx, clampedDay));
}

/** Advance a 'YYYY-MM-DD' date by a fixed number of whole days. */
function addDays(ymd, days) {
  const d = dayStartFromYmd(ymd);
  d.setDate(d.getDate() + days);
  return toYmd(d);
}

/* ───────────────────────── public API ───────────────────────── */

/**
 * Next scheduled date after `fromIso` for the given interval.
 * @param {string} fromIso  a 'YYYY-MM-DD' (or ISO) day string
 * @param {string} interval one of INTERVALS
 * @returns {string} next 'YYYY-MM-DD'
 */
function nextRunDate(fromIso, interval) {
  if (!INTERVALS.includes(interval)) {
    throw new Error(`subscriptions: unknown interval '${interval}'`);
  }
  const from = dayStartFromYmd(fromIso);
  if (!from) throw new Error(`subscriptions: invalid date '${fromIso}'`);
  const base = toYmd(from);
  if (interval in DAY_INTERVALS) return addDays(base, DAY_INTERVALS[interval]);
  return addMonths(base, MONTH_INTERVALS[interval]);
}

/**
 * How many whole interval boundaries have been crossed between `nextRunAt` and
 * `now` (inclusive of the boundary landing exactly on `now`). Used for catch-up
 * when the app was closed across multiple periods.
 *
 * A subscription whose `nextRunAt` is in the future yields 0. A `nextRunAt`
 * exactly equal to today yields 1 (one cycle is due now). Walking the calendar
 * (rather than dividing by an average period) keeps month-length clamping exact.
 *
 * @param {object} sub  subscription with { interval, nextRunAt }
 * @param {string|number|Date} now
 * @returns {number} count of cycles due (>= 0)
 */
function cyclesDue(sub, now) {
  if (!sub || !INTERVALS.includes(sub.interval)) return 0;
  const start = dayStartFromYmd(sub.nextRunAt);
  if (!start) return 0;
  const today = todayYmd(now);
  let cursor = toYmd(start);
  let count = 0;
  // Cap the walk defensively so a corrupt far-past cursor can't loop forever.
  // 10000 cycles covers >27 years of daily generation.
  while (cursor <= today && count < 10000) {
    count += 1;
    cursor = nextRunDate(cursor, sub.interval);
  }
  return count;
}

/**
 * Is a single subscription due for materialization right now?
 * Active, with a `nextRunAt` on or before today, and not past its `endAt`.
 * @param {object} sub
 * @param {string|number|Date} now
 */
function isDueForCycle(sub, now) {
  if (!sub || sub.status !== 'active') return false;
  const next = dayStartFromYmd(sub.nextRunAt);
  if (!next) return false;
  const today = todayYmd(now);
  if (toYmd(next) > today) return false;
  if (sub.endAt) {
    const end = dayStartFromYmd(sub.endAt);
    if (end && toYmd(end) < today) return false;
  }
  return true;
}

/**
 * Select all active subscriptions that are due, each annotated with `cyclesDue`
 * (how many cycles elapsed). Sorted by soonest `nextRunAt` first. Pure — does
 * not mutate the inputs; the `cyclesDue` field lives on a shallow copy.
 *
 * @param {object[]} subs
 * @param {string|number|Date} [now]
 * @returns {object[]} due subscriptions, each spread + { cyclesDue }
 */
function selectDueSubscriptions(subs, now = Date.now()) {
  const list = Array.isArray(subs) ? subs : [];
  return list
    .filter((s) => isDueForCycle(s, now))
    .map((s) => ({ ...s, cyclesDue: cyclesDue(s, now) }))
    .sort((a, b) =>
      String(a.nextRunAt || '').localeCompare(String(b.nextRunAt || '')));
}

/**
 * Patch advancing a subscription's schedule cursor strictly past `now`
 * (catch-up: skip every missed boundary up to and including today, landing on
 * the next *future* occurrence). `cyclesDue` is reported separately by the
 * selector so the caller decides whether to generate 1 or N orders.
 *
 * @param {object} sub  { interval, nextRunAt }
 * @param {string|number|Date} [now]
 * @returns {{ nextRunAt: string, lastRunAt: string }}
 */
function advanceSchedule(sub, now = Date.now()) {
  const today = todayYmd(now);
  let cursor = dayStartFromYmd(sub && sub.nextRunAt) ? toYmd(dayStartFromYmd(sub.nextRunAt)) : today;
  let guard = 0;
  // Walk forward until strictly after today (a cursor == today is still "due").
  while (cursor <= today && guard < 10000) {
    cursor = nextRunDate(cursor, sub.interval);
    guard += 1;
  }
  return {
    nextRunAt: cursor,
    lastRunAt: new Date(now).toISOString(),
  };
}

/**
 * Patch to apply after generating ONE cycle's order: stamp the run timestamp and
 * advance `nextRunAt` by exactly one interval from the previous cursor. Used by
 * the catch-up loop that materializes one order per missed cycle.
 *
 * @param {object} sub  { interval, nextRunAt }
 * @param {string|number|Date} [runIso] timestamp for lastRunAt
 * @returns {{ lastRunAt: string, nextRunAt: string }}
 */
function markCyclePatch(sub, runIso = Date.now()) {
  const prev = dayStartFromYmd(sub && sub.nextRunAt);
  if (!prev) throw new Error('subscriptions: markCyclePatch needs a valid nextRunAt');
  return {
    lastRunAt: new Date(runIso).toISOString(),
    nextRunAt: nextRunDate(toYmd(prev), sub.interval),
  };
}

/** Normalize an interval's recurring amount to a per-month figure. */
function monthlyFactor(interval) {
  if (interval in DAY_INTERVALS) return (365 / 12) / DAY_INTERVALS[interval]; // avg cycles/month
  if (interval in MONTH_INTERVALS) return 1 / MONTH_INTERVALS[interval];
  return 0;
}

/** Monthly recurring revenue across the ACTIVE subscriptions (rounded to 2dp). */
function monthlyRecurringRevenue(subs) {
  let mrr = 0;
  for (const s of (subs || [])) {
    if (!s || s.status !== 'active') continue;
    mrr += (Math.max(0, +s.amount || 0)) * monthlyFactor(s.interval);
  }
  return Math.round(mrr * 100) / 100;
}

const api = {
  INTERVALS,
  monthlyFactor,
  monthlyRecurringRevenue,
  nextRunDate,
  cyclesDue,
  isDueForCycle,
  selectDueSubscriptions,
  advanceSchedule,
  markCyclePatch,
  // low-level (exposed for tests / reuse)
  toYmd,
  todayYmd,
  daysInMonth,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') {
  globalThis.KhaytSubscriptions = api;
}

})();
