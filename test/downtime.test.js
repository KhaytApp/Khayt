const { test } = require('node:test');
const assert = require('node:assert/strict');

const D = require('../lib/downtime.js');

const at = iso => Date.parse(iso);
const JUNE = at('2026-06-01T00:00:00Z');
const JULY = at('2026-07-01T00:00:00Z');

/** Down for a belt change, then waiting for the part. Both true, and they overlap. */
const OVERLAPPING = {
  id: 'm1',
  downtimeBlocks: [
    { from: '2026-06-01T00:00:00Z', to: '2026-06-03T00:00:00Z', reason: 'belt change' },
    { from: '2026-06-02T00:00:00Z', to: '2026-06-04T00:00:00Z', reason: 'waiting for the part' },
  ],
};

/* ------------------------------------------------------------------
   The bug: elapsed time is a union, not a sum.
   ------------------------------------------------------------------ */

/** What the three readers did: clip each window, then add the lengths up. */
function theOldWay(machine, from, to) {
  let total = 0;
  for (const b of machine.downtimeBlocks || []) {
    const bFrom = new Date(b.from).getTime();
    const bTo = new Date(b.to).getTime();
    if (!Number.isFinite(bFrom) || !Number.isFinite(bTo) || bTo <= bFrom) continue;
    const start = Math.max(from, bFrom);
    const end = Math.min(to, bTo);
    if (end > start) total += (end - start) / 3600000;
  }
  return total;
}

test('adding the windows up counted the overlap twice', () => {
  // 1 June 00:00 to 4 June 00:00 is 72 hours of machine unavailable.
  assert.equal(theOldWay(OVERLAPPING, JUNE, JULY), 96);
});

test('the union is what actually elapsed', () => {
  assert.equal(D.hoursBetween(OVERLAPPING, JUNE, JULY), 72);
});

test('the error grows with every overlap a shop records', () => {
  const four = { downtimeBlocks: [
    { from: '2026-06-01T00:00:00Z', to: '2026-06-05T00:00:00Z' },
    { from: '2026-06-02T00:00:00Z', to: '2026-06-05T00:00:00Z' },
    { from: '2026-06-03T00:00:00Z', to: '2026-06-05T00:00:00Z' },
    { from: '2026-06-04T00:00:00Z', to: '2026-06-05T00:00:00Z' },
  ] };
  assert.equal(D.hoursBetween(four, JUNE, JULY), 96, 'four days');
  assert.equal(theOldWay(four, JUNE, JULY), 96 + 72 + 48 + 24);
});

test('a month can no longer report more downtime than it has hours', () => {
  const silly = { downtimeBlocks: Array.from({ length: 10 }, () => (
    { from: '2026-06-01T00:00:00Z', to: '2026-07-01T00:00:00Z' }
  )) };
  const hoursInJune = 30 * 24;
  assert.equal(D.hoursBetween(silly, JUNE, JULY), hoursInJune);
  assert.equal(theOldWay(silly, JUNE, JULY), hoursInJune * 10);
});

/* ------------------------------------------------------------------
   Merging.
   ------------------------------------------------------------------ */

test('windows that merely touch are one stretch', () => {
  const touching = { downtimeBlocks: [
    { from: '2026-06-01T00:00:00Z', to: '2026-06-02T00:00:00Z' },
    { from: '2026-06-02T00:00:00Z', to: '2026-06-03T00:00:00Z' },
  ] };
  assert.equal(D.mergedWindows(touching).length, 1);
  assert.equal(D.hoursBetween(touching, JUNE, JULY), 48);
});

test('windows with a gap between them stay apart', () => {
  const apart = { downtimeBlocks: [
    { from: '2026-06-01T00:00:00Z', to: '2026-06-02T00:00:00Z' },
    { from: '2026-06-05T00:00:00Z', to: '2026-06-06T00:00:00Z' },
  ] };
  assert.equal(D.mergedWindows(apart).length, 2);
  assert.equal(D.hoursBetween(apart, JUNE, JULY), 48);
});

test('a window wholly inside another disappears into it', () => {
  const nested = { downtimeBlocks: [
    { from: '2026-06-01T00:00:00Z', to: '2026-06-10T00:00:00Z' },
    { from: '2026-06-03T00:00:00Z', to: '2026-06-04T00:00:00Z' },
  ] };
  const merged = D.mergedWindows(nested);
  assert.equal(merged.length, 1);
  assert.equal((merged[0].endsAt - merged[0].startsAt) / 3600000, 216);
});

test('the reasons survive the merge', () => {
  const [w] = D.mergedWindows(OVERLAPPING);
  assert.equal(w.note, 'belt change · waiting for the part');
});

test('the same reason twice is not repeated', () => {
  const repeated = { downtimeBlocks: [
    { from: '2026-06-01T00:00:00Z', to: '2026-06-03T00:00:00Z', reason: 'belt change' },
    { from: '2026-06-02T00:00:00Z', to: '2026-06-04T00:00:00Z', reason: 'belt change' },
  ] };
  assert.equal(D.mergedWindows(repeated)[0].note, 'belt change');
});

test('note is accepted where reason is absent', () => {
  const noted = { downtimeBlocks: [{ from: '2026-06-01T00:00:00Z', to: '2026-06-02T00:00:00Z', note: 'moved rooms' }] };
  assert.equal(D.mergedWindows(noted)[0].note, 'moved rooms');
});

/* ------------------------------------------------------------------
   What is skipped rather than guessed at.
   ------------------------------------------------------------------ */

test('a window missing an end, backwards, or unparseable is skipped', () => {
  const junk = { downtimeBlocks: [
    { from: '2026-06-01T00:00:00Z' },
    { to: '2026-06-02T00:00:00Z' },
    { from: '2026-06-05T00:00:00Z', to: '2026-06-01T00:00:00Z' },
    { from: '2026-06-01T00:00:00Z', to: '2026-06-01T00:00:00Z' },
    { from: 'not a date', to: '2026-06-02T00:00:00Z' },
    null,
  ] };
  assert.deepEqual(D.windows(junk), []);
  assert.equal(D.hoursBetween(junk, JUNE, JULY), 0);
});

test('a machine with no windows, or none at all, is never down', () => {
  assert.equal(D.hoursBetween({ downtimeBlocks: [] }, JUNE, JULY), 0);
  assert.equal(D.hoursBetween({}, JUNE, JULY), 0);
  assert.equal(D.hoursBetween(null, JUNE, JULY), 0);
  assert.deepEqual(D.windows(undefined), []);
});

test('a period that is empty or backwards is no hours', () => {
  assert.equal(D.hoursBetween(OVERLAPPING, JULY, JUNE), 0);
  assert.equal(D.hoursBetween(OVERLAPPING, JUNE, JUNE), 0);
  assert.equal(D.hoursBetween(OVERLAPPING, NaN, JULY), 0);
});

/* ------------------------------------------------------------------
   Clipping, and the order it happens in.
   ------------------------------------------------------------------ */

test('a window is clipped to the period asked about', () => {
  const long = { downtimeBlocks: [{ from: '2026-05-20T00:00:00Z', to: '2026-06-05T00:00:00Z' }] };
  assert.equal(D.hoursBetween(long, JUNE, JULY), 4 * 24, 'only the June part');
});

test('merging happens before clipping, which is the order that matters', () => {
  // Each window clipped to June is 48h and 48h; clipped-then-added gives 96.
  // Merged first, the union clipped to June is 72.
  const spanning = { downtimeBlocks: [
    { from: '2026-05-30T00:00:00Z', to: '2026-06-03T00:00:00Z' },
    { from: '2026-06-02T00:00:00Z', to: '2026-06-04T00:00:00Z' },
  ] };
  assert.equal(D.hoursBetween(spanning, JUNE, JULY), 72);
  assert.equal(theOldWay(spanning, JUNE, JULY), 48 + 48);
});

/* ------------------------------------------------------------------
   Several periods at once, which is what a chart draws.
   ------------------------------------------------------------------ */

test('hoursByPeriod answers in the order it was asked', () => {
  const across = { downtimeBlocks: [
    { from: '2026-05-30T00:00:00Z', to: '2026-06-02T00:00:00Z' },
    { from: '2026-06-01T00:00:00Z', to: '2026-06-03T00:00:00Z' },
  ] };
  const periods = [
    { from: at('2026-05-01T00:00:00Z'), to: JUNE },
    { from: JUNE, to: JULY },
    { from: JULY, to: at('2026-08-01T00:00:00Z') },
  ];
  assert.deepEqual(D.hoursByPeriod(across, periods), [48, 48, 0]);
});

test('hoursByPeriod agrees with hoursBetween for each period', () => {
  const periods = [{ from: JUNE, to: JULY }];
  assert.deepEqual(
    D.hoursByPeriod(OVERLAPPING, periods),
    [D.hoursBetween(OVERLAPPING, JUNE, JULY)],
  );
});

test('no periods, or a nonsense one, yields no hours', () => {
  assert.deepEqual(D.hoursByPeriod(OVERLAPPING, []), []);
  assert.deepEqual(D.hoursByPeriod(OVERLAPPING, undefined), []);
  assert.deepEqual(D.hoursByPeriod(OVERLAPPING, [{ from: JULY, to: JUNE }, {}]), [0, 0]);
});

/* ------------------------------------------------------------------
   The stored records are not touched.
   ------------------------------------------------------------------ */

test('counting hours never rewrites what the shop recorded', () => {
  const before = JSON.parse(JSON.stringify(OVERLAPPING));
  D.hoursBetween(OVERLAPPING, JUNE, JULY);
  D.mergedWindows(OVERLAPPING);
  D.hoursByPeriod(OVERLAPPING, [{ from: JUNE, to: JULY }]);
  assert.deepEqual(OVERLAPPING, before,
    'the shop\'s own windows, with its own reasons on them, stay as written');
});
