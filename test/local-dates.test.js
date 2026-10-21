const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

require('../renderer/util.js');

const ROOT = path.join(__dirname, '..');

/**
 * `new Date().toISOString().slice(0, 10)` is not "today". toISOString() converts
 * to UTC, so the calendar date it yields is wrong for part of every day:
 *
 *   Riyadh (UTC+3)   — before 03:00 local it returns YESTERDAY
 *   New York (UTC-4) — after  20:00 local it returns TOMORROW
 *
 * 85 call sites across the renderer did this, on a product whose primary market
 * is the Gulf. Concretely: todayPlusDays(0) returned yesterday, the payments-due
 * window was 6 days instead of 7, and the "last quarter" analytics range both
 * dropped the last day of the quarter and pulled in the last day of the one
 * before it. renderer/util.js already had localDateStr() — a local-calendar
 * formatter — and app-helpers.js even carried a comment about avoiding exactly
 * this bug, but the call sites bypassed it.
 */

/** Every renderer source file, so the ban cannot be dodged by adding a new one. */
function rendererSources() {
  const out = [];
  const walk = (rel) => {
    for (const entry of fs.readdirSync(path.join(ROOT, rel))) {
      const r = path.join(rel, entry);
      const st = fs.statSync(path.join(ROOT, r));
      if (st.isDirectory()) walk(r);
      else if (entry.endsWith('.js') && !r.includes('locales')) out.push(r);
    }
  };
  walk('renderer');
  return out;
}

/**
 * A calendar unit derived from UTC, in any width.
 *
 * This started as a DAY check — slice(0, 10) and friends. That left a hole:
 * `toISOString().slice(0, 7)` is a UTC MONTH, and it walked straight past. The
 * expense budget check used it, so a shop in Riyadh logging a 200 expense at
 * 01:00 on the 1st was warned it had blown a 5,000 budget — the sum was still
 * counting the previous month. West of London the same line fails the other way
 * and never warns at all, on the last evening of a month.
 *
 * Years (slice(0, 4)) are included for the same reason: nothing about the bug
 * is specific to how many characters get taken off the front.
 */
const UTC_CALENDAR_UNIT = /toISOString\(\)\s*\.\s*(slice\(0,\s*(4|7|10)\)|split\('T'\)\[0\]|substring\(0,\s*(4|7|10)\))/;

test('no renderer file derives a calendar date from toISOString()', () => {
  // The whole point of the sweep: this must stay at zero, in every file.
  const bad = [];
  for (const rel of rendererSources()) {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    src.split('\n').forEach((line, i) => {
      if (UTC_CALENDAR_UNIT.test(line)) {
        bad.push(`${rel}:${i + 1}`);
      }
    });
  }
  assert.deepEqual(bad, [],
    `use localDateStr() / localMonthStr() instead of toISOString() for calendar units:\n  ${bad.join('\n  ')}`);
});

test('the ban recognises months and years, not only days', () => {
  // Pins the widening itself. Written because the day-only version reported a
  // clean sweep while a UTC month sat in the expense budget check.
  assert.ok(UTC_CALENDAR_UNIT.test("const d = new Date().toISOString().slice(0, 10);"), 'day');
  assert.ok(UTC_CALENDAR_UNIT.test("const m = new Date().toISOString().slice(0, 7);"), 'month');
  assert.ok(UTC_CALENDAR_UNIT.test("const y = new Date().toISOString().slice(0, 4);"), 'year');
  assert.ok(UTC_CALENDAR_UNIT.test("x.toISOString().split('T')[0]"), 'split form');
  assert.ok(UTC_CALENDAR_UNIT.test("x.toISOString().substring(0, 7)"), 'substring form');

  // A full timestamp is not a calendar unit — banning it would flag every
  // legitimate `updatedAt`, and a noisy guard gets deleted.
  assert.ok(!UTC_CALENDAR_UNIT.test('rec.updatedAt = new Date().toISOString();'), 'full ISO timestamp');
  assert.ok(!UTC_CALENDAR_UNIT.test('const s = other.toISOString();'), 'bare toISOString');
});

/**
 * The ban above covers renderer/ only, where 85 call sites were fixed. lib/ was
 * never in scope — and isQuoteExpired() in lib/lan-quote-page.js was deciding
 * whether a CUSTOMER's quote had expired from the UTC day. In Riyadh that left
 * an expired quote approvable from local midnight to 03:00; in New York it
 * marked a live quote expired after 20:00.
 *
 * lib is not renderer, though: some files there do UTC arithmetic on purpose,
 * anchoring to T00:00:00Z and reading back in UTC, which never drifts because
 * both ends agree. Those are listed with the reason rather than reformatted —
 * changing correct code to satisfy a pattern match would be the worse trade.
 */
const LIB_UTC_IS_DELIBERATE = {
  'lib/schedule.js': 'setUTCDate then read UTC — day arithmetic, both ends UTC, cannot drift',
  'lib/lead-time.js': 'same shape as schedule.js: anchors to T00:00:00Z and reads UTC back, so the '
    + 'arithmetic cannot drift. The LOCAL day enters as the caller-supplied `today`, which is where '
    + 'the timezone decision belongs — this module never asks a clock.',
  'lib/sample-data.js': 'anchors to T00:00:00Z and does UTC arithmetic; demo data besides',
  'lib/payment-plan.js': 'addDays anchors to T00:00:00.000Z; the no-argument branch is unreachable',
  'lib/telemetry-scrub.js': 'telemetry is aggregated in UTC by design, not shown as a local day',
  'lib/active-count.js': 'the cloud contract defines the day, ISO week and month in UTC so every '
    + 'install counts against the same calendar; never shown to anyone as a local day',
};

test('no lib file derives a LOCAL calendar date from toISOString()', () => {
  const offenders = [];
  const walk = (rel) => {
    for (const entry of fs.readdirSync(path.join(ROOT, rel))) {
      const r = path.join(rel, entry);
      if (fs.statSync(path.join(ROOT, r)).isDirectory()) { walk(r); continue; }
      if (!entry.endsWith('.js')) continue;
      if (LIB_UTC_IS_DELIBERATE[r]) continue;
      const src = fs.readFileSync(path.join(ROOT, r), 'utf8');
      src.split('\n').forEach((line, i) => {
        // A comment explaining the banned pattern is not an instance of it.
        const code = line.trim();
        if (code.startsWith('*') || code.startsWith('//')) return;
        // Same widened pattern as the renderer ban above: a UTC month or year is
        // the same bug as a UTC day, and lib/ has no reason to be checked less.
        if (UTC_CALENDAR_UNIT.test(line)) {
          offenders.push(`${r}:${i + 1}`);
        }
      });
    }
  };
  walk('lib');
  assert.deepEqual(offenders, [],
    'these read a calendar day from UTC — use the local calendar, or add the file to '
    + `LIB_UTC_IS_DELIBERATE with the reason:\n  ${offenders.join('\n  ')}`);
});

test('an expired quote is expired in the shop timezone, not UTC', () => {
  const { isQuoteExpired } = require('../lib/lan-quote-page.js');
  const RealDate = Date;
  // 22:30Z on the 27th = 01:30 local on the 28th in Riyadh (UTC+3).
  const fixed = new RealDate('2026-07-27T22:30:00Z');
  global.Date = class extends RealDate {
    constructor(...a) { return a.length ? new RealDate(...a) : new RealDate(fixed); }
    static now() { return fixed.getTime(); }
  };
  try {
    const localDay = new RealDate(fixed).toLocaleDateString('en-CA');
    if (localDay !== '2026-07-28') return;   // only meaningful east of UTC
    assert.equal(isQuoteExpired({ quoteExpiresAt: '2026-07-27' }), true,
      'a quote that expired yesterday must not stay approvable after local midnight');
    assert.equal(isQuoteExpired({ quoteExpiresAt: '2026-07-28' }), false,
      'a quote expiring today is still valid today');
  } finally { global.Date = RealDate; }
});

test('localDateStr returns the LOCAL calendar date, not the UTC one', () => {
  // A moment that is a different calendar day in UTC than in a UTC+ zone.
  const d = new Date(2026, 6, 25, 1, 30); // 01:30 local on Jul 25
  assert.equal(localDateStr(d), '2026-07-25');
  // Pin the actual defect: in any UTC+ zone the ISO form disagrees.
  const offsetMin = -d.getTimezoneOffset();
  if (offsetMin > 90) {
    assert.notEqual(d.toISOString().slice(0, 10), '2026-07-25',
      'this test only proves something in a UTC+ zone; it is a no-op elsewhere');
  }
});

test('localMonthStr returns the LOCAL calendar month, not the UTC one', () => {
  // The expense budget check now depends on this. The failing moment is the
  // first hours of the 1st in a UTC+ zone: local says the new month, UTC still
  // says the old one, and the budget sum counts the wrong month's spending.
  const d = new Date(2026, 7, 1, 1, 30); // 01:30 local on Aug 1
  assert.equal(localMonthStr(d), '2026-08');
  const offsetMin = -d.getTimezoneOffset();
  if (offsetMin > 90) {
    assert.notEqual(d.toISOString().slice(0, 7), '2026-08',
      'this test only proves something in a UTC+ zone; it is a no-op elsewhere');
  }
});

test('localMonthStr pads the month', () => {
  assert.equal(localMonthStr(new Date(2026, 0, 5)), '2026-01');
  assert.equal(localMonthStr(new Date(2026, 11, 31)), '2026-12');
});

test('localDateStr pads month and day', () => {
  assert.equal(localDateStr(new Date(2026, 0, 5)), '2026-01-05');
  assert.equal(localDateStr(new Date(2026, 11, 31)), '2026-12-31');
});

test('todayPlusDays(0) is today, not yesterday', () => {
  // The regression this replaced: inventory.js:1365 normalised to local midnight
  // and then serialised via UTC, so n=0 returned yesterday east of Greenwich and
  // the dashboard "payments due" card ran a 6-day window instead of 7.
  const todayPlusDays = (n) => {
    const d = new Date(); d.setHours(0, 0, 0, 0); d.setDate(d.getDate() + n);
    return localDateStr(d);
  };
  assert.equal(todayPlusDays(0), localDateStr(new Date()));

  const seven = new Date(); seven.setHours(0, 0, 0, 0); seven.setDate(seven.getDate() + 7);
  assert.equal(todayPlusDays(7), localDateStr(seven));
});

test('the last-quarter range covers the whole quarter', () => {
  // From 2026-07-25, "last quarter" is Q2: 2026-04-01 .. 2026-06-30 inclusive.
  const now = new Date(2026, 6, 25);
  const lastQEnd = new Date(now.getFullYear(), now.getMonth() - (now.getMonth() % 3), 0);
  const lastQStart = new Date(lastQEnd.getFullYear(), Math.floor(lastQEnd.getMonth() / 3) * 3, 1);
  assert.equal(localDateStr(lastQStart), '2026-04-01');
  assert.equal(localDateStr(lastQEnd), '2026-06-30', 'the last day of the quarter must be inside the range');
});

test('an instalment plan generated on the 31st does not skip a month', () => {
  // new Date(2026, 1, 31) rolls over into March, so a plan generated on Jan 31
  // put its first instalment in March and February vanished.
  const firstDue = (today) => {
    const y = today.getFullYear(), m = today.getMonth() + 1;
    const lastDay = new Date(y, m + 1, 0).getDate();
    return localDateStr(new Date(y, m, Math.min(today.getDate(), lastDay)));
  };
  assert.equal(firstDue(new Date(2026, 0, 31)), '2026-02-28');
  assert.equal(firstDue(new Date(2024, 0, 31)), '2024-02-29', 'leap year');
  assert.equal(firstDue(new Date(2026, 6, 25)), '2026-08-25', 'a normal day is unchanged');
});
