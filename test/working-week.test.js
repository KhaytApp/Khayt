/**
 * The default working week, and why it was wrong.
 *
 * `{ mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 0, sun: 0 }` was written out in
 * FIVE places — app-state, twice in app-helpers, machines and settings. It is a
 * four-day week and matches no working week anywhere: the Gulf works Sunday to
 * Thursday with a Friday–Saturday weekend, and most of Europe and the Americas
 * work Monday to Friday. This is neither — it takes the Gulf's weekend and loses
 * Sunday as well, which reads like a Western Sunday-off left in place when
 * Friday and Saturday were zeroed.
 *
 * Not cosmetic: these hours feed avgDailyWorkingHours(), the due-date suggestion
 * on an order, the machine queue-clear date and the schedule projection. A shop
 * that never opened Working Hours had all four computed against four days
 * instead of five, and quoted dates further out than it needed to. Lead time
 * errs late on purpose through a visible safety margin; a missing working day is
 * not that.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/working-week.js');
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');

test('the default is a five-day Sunday-to-Thursday week', () => {
  assert.deepEqual({ ...W.DEFAULT_WORKING_HOURS },
    { sun: 8, mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 0 });
  assert.equal(W.workingDaysPerWeek(null), 5, 'four working days matches no calendar');
  assert.equal(W.hoursOnDay(null, 0), 8, 'Sunday is a working day in the Gulf');
  assert.equal(W.hoursOnDay(null, 5), 0, 'Friday is not');
  assert.equal(W.hoursOnDay(null, 6), 0, 'nor Saturday');
});

test('a shop that set its own week keeps it exactly', () => {
  const own = { workingHours: { sun: 0, mon: 6, tue: 6, wed: 6, thu: 6, fri: 6, sat: 0 } };
  assert.deepEqual(W.workingHours(own), { sun: 0, mon: 6, tue: 6, wed: 6, thu: 6, fri: 6, sat: 0 });
  assert.equal(W.workingDaysPerWeek(own), 5);
});

test('a day a shop left out is closed, not defaulted', () => {
  // It edited its week; the omission is the answer. Filling the gap from the
  // default would hand a shop hours it deliberately removed.
  assert.deepEqual(W.workingHours({ workingHours: { mon: 8 } }),
    { sun: 0, mon: 8, tue: 0, wed: 0, thu: 0, fri: 0, sat: 0 });
});

test('nonsense is closed rather than NaN', () => {
  // These numbers are multiplied into a promised date; NaN there is a blank
  // where a customer expects a day.
  const junk = { workingHours: { sun: 'x', mon: -4, tue: null, wed: 99, thu: 8 } };
  const wh = W.workingHours(junk);
  assert.equal(wh.sun, 0);
  assert.equal(wh.mon, 0, 'negative hours are closed, not negative capacity');
  assert.equal(wh.wed, 24, 'and a day is capped at twenty-four hours');
  assert.equal(Object.values(wh).every(Number.isFinite), true);
});

test('the shared default cannot be mutated by one caller', () => {
  // Three of the sites that held their own copy pass it straight into
  // arithmetic; a shared, unfrozen object would let one of them change the
  // working week for every other caller in the session.
  assert.equal(Object.isFrozen(W.DEFAULT_WORKING_HOURS), true);
  assert.notEqual(W.workingHours(null), W.workingHours(null), 'each caller gets its own copy');
});

test('no file writes the literal out any more', () => {
  // The bug was five copies drifting from the calendar together.
  for (const f of ['app-state.js', 'app-helpers.js', 'machines.js', 'settings.js']) {
    const src = fs.readFileSync(path.join(ROOT, 'renderer', f), 'utf8');
    assert.doesNotMatch(src, /mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 0, sun: 0/,
      `${f} must take the working week from lib/working-week.js`);
  }
});

test('the settings form offers Sunday as a working day too', () => {
  const html = fs.readFileSync(path.join(ROOT, 'renderer', 'index.html'), 'utf8');
  assert.match(html, /id="wh_sun"[^>]*value="8"/, 'a fresh profile must show the same week as the default');
  // And the day names are translated — they read as English in an Arabic shop.
  for (const d of ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun']) {
    assert.match(html, new RegExp(`data-i18n="day\\.${d}"`), `${d} must be translatable`);
  }
});

test('the module loads before the file that reads it at eval time', () => {
  /* app-state.js spreads DEFAULT_WORKING_HOURS while it evaluates, so the order
   * of these two script tags is a hard dependency rather than a preference.
   *
   * Loaded after, the constant is undefined and — in the sandboxed renderer,
   * where `require` does not exist either — the accessor falls to null and the
   * app fails to boot. The full unit suite passed anyway, because under Node the
   * `require` branch works; only launching the app showed it. This is the cheap
   * guard for a constraint nothing else expresses. */
  for (const page of ['index.html', 'bedready.html']) {
    const html = fs.readFileSync(path.join(ROOT, 'renderer', page), 'utf8');
    const lib = html.indexOf('lib/working-week.js');
    const state = html.indexOf('src="app-state.js"');
    assert.ok(lib > -1, `${page} must load the working week`);
    assert.ok(state > -1, `${page} must load app-state`);
    assert.ok(lib < state, `${page}: working-week.js has to load before app-state.js`);
  }
});

test('holidays: real days, once each, in date order', () => {
  assert.deepEqual(W.holidays({ holidays: ['2026-12-02', '2026-09-23', 'soon', '2026-13-01', 42, '2026-09-23', '2026-2-1'] }),
    ['2026-09-23', '2026-12-02']);
  assert.deepEqual(W.holidays({}), []);
  assert.deepEqual(W.holidays({ holidays: 'x' }), []);
  assert.equal(W.isHoliday({ holidays: ['2026-09-23'] }, '2026-09-23'), true);
  assert.equal(W.isHoliday({ holidays: ['2026-09-23'] }, '2026-09-24'), false);
});
