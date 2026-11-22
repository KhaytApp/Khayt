/**
 * lib/date-range.js is the renderer's `inRange`, lifted.
 *
 * THE PROOF: the original is copied below VERBATIM from renderer/app-helpers.js
 * as of the lift — the page globals it read and `new Date()` it called are the
 * only things supplied from outside — and both are run over thousands of
 * generated dates, ranges and clocks and compared answer for answer.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { inRange, RANGES, localDay, localMonth } = require('../lib/date-range.js');

const ORIGINAL = `
function inRange(dateStr, range, ctx) {
  if (!range || range === 'all') return true;
  if (!dateStr) return false;
  // Validate the date string is parseable
  if (isNaN(new Date(dateStr))) return false;
  if (range === 'custom') {
    const from = ctx ? customRangeFrom[ctx] : '';
    const to   = ctx ? customRangeTo[ctx]   : '';
    if (!from && !to) return true;
    const ds = dateStr.slice(0, 10);
    if (from && ds < from) return false;
    if (to   && ds > to)   return false;
    return true;
  }
  // Use string slicing for all range checks to avoid UTC/local timezone boundary issues
  const now = new Date();
  const nowY = now.getFullYear();
  const nowM = now.getMonth(); // 0-based
  const ds = dateStr.slice(0, 10); // YYYY-MM-DD
  if (range === 'month') {
    const nowStr = \`\${nowY}-\${String(nowM + 1).padStart(2, '0')}\`;
    return ds.slice(0, 7) === nowStr;
  }
  if (range === 'last_month') {
    const lm = new Date(nowY, nowM - 1, 1);
    const lmStr = \`\${lm.getFullYear()}-\${String(lm.getMonth() + 1).padStart(2, '0')}\`;
    return ds.slice(0, 7) === lmStr;
  }
  if (range === 'quarter') {
    const nowQ = Math.floor(nowM / 3);
    const dsMonth = parseInt(ds.slice(5, 7), 10) - 1; // 0-based
    const dsYear  = parseInt(ds.slice(0, 4), 10);
    return dsYear === nowY && Math.floor(dsMonth / 3) === nowQ;
  }
  if (range === 'last_quarter') {
    const lastQEnd   = new Date(nowY, nowM - (nowM % 3), 0); // last day of prev quarter
    const lastQStart = new Date(lastQEnd.getFullYear(), Math.floor(lastQEnd.getMonth() / 3) * 3, 1);
    const fromStr = localDateStr(lastQStart);
    const toStr   = localDateStr(lastQEnd);
    return ds >= fromStr && ds <= toStr;
  }
  if (range === 'year') {
    return ds.slice(0, 4) === String(nowY);
  }
  return true;
}
return inRange;`;

/** The original with its clock frozen at `now` and its custom span supplied. */
function original(now, from, to) {
  const RealDate = Date;
  // A Date whose no-argument constructor is the frozen clock; every other
  // form passes through, so the original's own arithmetic is untouched.
  class FrozenDate extends RealDate {
    constructor(...args) { super(...(args.length ? args : [now.getTime()])); }
  }
  const localDateStr = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const fn = new Function('Date', 'customRangeFrom', 'customRangeTo', 'localDateStr', ORIGINAL);
  return fn(FrozenDate, { x: from }, { x: to }, localDateStr);
}

function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];
const day = (r) => {
  const y = 2024 + Math.floor(r() * 4), m = 1 + Math.floor(r() * 12), d = 1 + Math.floor(r() * 28);
  return `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
};

test('the module and the original agree over 6000 generated dates, ranges and clocks', () => {
  const r = rng(20260905);
  for (let i = 0; i < 6000; i++) {
    const now = new Date(2024 + Math.floor(r() * 4), Math.floor(r() * 12), 1 + Math.floor(r() * 28), 13);
    // Well-formed dates and the shapes that are plainly not dates. A PARTIAL
    // date — "2026", "2026-09" — is the one deliberate change and is tested
    // on its own below, so it is not generated here.
    const dateStr = pick(r, [day(r), day(r) + 'T09:15:00.000Z', '', null, 'not a date']);
    const range = pick(r, [...RANGES, undefined, 'nonsense']);
    const from = pick(r, ['', day(r)]);
    const to = pick(r, ['', day(r)]);
    const theirs = original(now, from, to)(dateStr, range, 'x');
    const ours = inRange(dateStr, range, { now, from, to });
    assert.equal(ours, theirs, `date=${dateStr} range=${range} now=${localDay(now)} from=${from} to=${to}`);
  }
});

test('a partial date is in no period, where the original filed it under the year', () => {
  // The deliberate change. `"2026".slice(0, 4)` is the year, so the original
  // put a record dated "2026" in "this year" and in nothing else; every other
  // branch sliced ten characters out of four and matched nothing.
  const now = new Date(2026, 8, 4);
  for (const partial of ['2026', '2026-09', '2026-9-4']) {
    for (const range of RANGES) {
      assert.equal(inRange(partial, range, { now }), range === 'all',
        `${partial} in ${range}`);
    }
  }
  // And a real date is unaffected, in either shape it is written.
  assert.equal(inRange('2026-09-04', 'month', { now }), true);
  assert.equal(inRange('2026-09-04T22:00:00.000Z', 'month', { now }), true);
});

test('the custom span with no page context behaves as the original did', () => {
  // The original read `ctx ? customRangeFrom[ctx] : ''` — no context, no span.
  assert.equal(inRange('2026-05-15', 'custom'), true);
  assert.equal(inRange('2026-05-15', 'custom', { from: '2026-06-01' }), false);
});

test('local day and month are the shop\'s calendar, not UTC\'s', () => {
  const d = new Date(2026, 8, 4, 23, 30);
  assert.equal(localDay(d), '2026-09-04');
  assert.equal(localMonth(d), '2026-09');
});
