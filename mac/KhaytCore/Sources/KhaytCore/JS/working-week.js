'use strict';
/**
 * How many hours a shop prints on each day of the week, by default.
 *
 * ── WHY THIS FILE EXISTS ────────────────────────────────────────────────────
 *
 * The default was written out as an object literal in four places —
 * renderer/app-state.js, twice in renderer/app-helpers.js, and
 * renderer/machines.js — and all four said:
 *
 *     { mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 0, sun: 0 }
 *
 * That is a FOUR-DAY WEEK, and it matches no working week anywhere. The Gulf
 * works Sunday to Thursday with a Friday–Saturday weekend; most of Europe and
 * the Americas work Monday to Friday. This is neither: it takes the Gulf's
 * weekend and then loses Sunday as well, which reads like a Western Sunday-off
 * left in place when Friday and Saturday were zeroed.
 *
 * It is not cosmetic. These hours feed avgDailyWorkingHours(), the due-date
 * suggestion on an order, the machine queue-clear date and the schedule
 * projection — so a shop that never opened Working Hours had every one of those
 * computed against four days instead of five, and quoted dates further out than
 * it needed to. Lead time errs late ON PURPOSE, through a safety margin the shop
 * can see and change; a missing working day is not that, it is arithmetic
 * quietly disagreeing with the calendar.
 *
 * Khayt's primary market is Saudi Arabia — ZATCA invoicing, Arabic-first, Salla
 * and Zid — and the existing Friday–Saturday weekend says the Gulf week was the
 * intent. So Sunday is restored and the default is Sunday to Thursday.
 *
 * A shop that has already set its own hours is untouched: this is only the
 * fallback for a `settings.workingHours` that was never written.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  /** Day keys, in the order the settings grid shows them. */
  const DAY_KEYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];

  /**
   * Sunday to Thursday, eight hours, with a Friday–Saturday weekend.
   *
   * Frozen because it is a shared default: one caller mutating it would change
   * the working week for every other caller in the session, and three of the
   * four sites that used to hold their own copy pass it straight into
   * arithmetic.
   */
  const DEFAULT_WORKING_HOURS = Object.freeze({
    sun: 8, mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 0,
  });

  /**
   * The shop's hours, or the default — never a partial object.
   *
   * A stored value missing a day is treated as that day being closed rather
   * than as the default's hours, because a shop that edited its week meant what
   * it left out.
   */
  function workingHours(settings) {
    const wh = settings && settings.workingHours;
    if (!wh || typeof wh !== 'object') return { ...DEFAULT_WORKING_HOURS };
    const out = {};
    for (const k of DAY_KEYS) {
      const n = Number(wh[k]);
      out[k] = Number.isFinite(n) && n > 0 ? Math.min(24, n) : 0;
    }
    return out;
  }

  /** Hours on one day, by JS `getDay()` index (0 = Sunday). */
  function hoursOnDay(settings, dayIndex) {
    const key = DAY_KEYS[((Number(dayIndex) % 7) + 7) % 7];
    return workingHours(settings)[key] || 0;
  }

  /** Days a week the shop actually works — what a lead-time promise counts in. */
  function workingDaysPerWeek(settings) {
    const wh = workingHours(settings);
    return DAY_KEYS.filter((k) => wh[k] > 0).length;
  }

  /**
   * The days the shop is closed, as `settings.holidays` holds them: local
   * calendar days, `YYYY-MM-DD`.
   *
   * Cleaned for reading: anything that is not such a day is dropped, a day
   * listed twice is listed once, and they come back in date order. The two
   * places that skip a holiday (the hours left before a due date, and the
   * date a machine's queue clears) look days up in a Set, so a malformed entry
   * never matched anything — it only cluttered the list the shop edits.
   */
  function holidays(settings) {
    const raw = settings && settings.holidays;
    if (!Array.isArray(raw)) return [];
    const seen = new Set();
    for (const d of raw) {
      if (typeof d !== 'string' || !/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/.test(d)) continue;
      seen.add(d);
    }
    return Array.from(seen).sort();
  }

  /** Whether a `YYYY-MM-DD` day is one of the shop's holidays. */
  function isHoliday(settings, day) {
    return holidays(settings).includes(String(day || ''));
  }

  const api = { DAY_KEYS, DEFAULT_WORKING_HOURS, workingHours, hoursOnDay, workingDaysPerWeek, holidays, isHoliday };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytWorkingWeek = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
