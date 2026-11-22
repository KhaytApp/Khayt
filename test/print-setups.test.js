/**
 * Remembering which settings actually worked.
 *
 * A print file already counted prints and failures but not WITH WHAT, so a shop
 * reprinting a bracket six months later knew it had worked once and nothing
 * about the machine, material or layer height — which is the same as not
 * knowing. These tests are mostly about the two judgement calls: what counts as
 * a setup you can trust, and which one to reach for.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  STATUS, GOOD_RATE, deriveStatus, statusOf, successRate,
  recordOutcome, recommendSetup, describeSetup, summarize,
} = require('../lib/print-setups.js');

const mk = (o = {}) => Object.assign(
  { id: 's', ok: 0, failed: 0, createdAt: '2026-01-01T00:00:00Z' }, o);

test('a setup nobody has run is untested, not failed', () => {
  // Telling a shop a setup "failed" when they have never tried it is telling
  // them something untrue.
  const fresh = mk();
  assert.equal(deriveStatus(fresh), STATUS.NEEDS_TEST);
  assert.equal(successRate(fresh), null, 'and it has no rate at all');
});

test('one clean print is evidence enough to call it good', () => {
  assert.equal(deriveStatus(mk({ ok: 1 })), STATUS.KNOWN_GOOD);
  assert.equal(successRate(mk({ ok: 1 })), 1);
});

test('one bad print does not condemn a setup that usually works', () => {
  // Filament runs out, a spool tangles, somebody knocks the machine. Nine good
  // prints and one bad one is a good setup, not a suspect one.
  assert.equal(deriveStatus(mk({ ok: 9, failed: 1 })), STATUS.KNOWN_GOOD);
  assert.equal(deriveStatus(mk({ ok: 3, failed: 1 })), STATUS.KNOWN_GOOD, 'exactly at the threshold');
  assert.equal(GOOD_RATE, 0.75);
});

test('a setup that fails a third of the time is not one to reach for', () => {
  assert.equal(deriveStatus(mk({ ok: 2, failed: 1 })), STATUS.NEEDS_TEST);
  assert.equal(deriveStatus(mk({ ok: 1, failed: 3 })), STATUS.NEEDS_TEST,
    'it has worked once, so it is not hopeless — but it is not trusted');
});

test('a setup that has only ever failed is failed', () => {
  assert.equal(deriveStatus(mk({ failed: 1 })), STATUS.FAILED);
  assert.equal(deriveStatus(mk({ failed: 5 })), STATUS.FAILED);
});

test('the shop can overrule the tally', () => {
  // "It printed, but I did not like the finish" is a judgement no counter
  // reaches. The override wins in both directions.
  assert.equal(statusOf(mk({ ok: 9, status: STATUS.FAILED })), STATUS.FAILED);
  assert.equal(statusOf(mk({ failed: 9, status: STATUS.KNOWN_GOOD })), STATUS.KNOWN_GOOD);
  // Junk in the override field falls back to the record rather than being obeyed.
  assert.equal(statusOf(mk({ ok: 5, status: 'excellent' })), STATUS.KNOWN_GOOD);
  assert.equal(statusOf(mk({ ok: 5, status: null })), STATUS.KNOWN_GOOD);
});

test('recording an outcome does not mutate the caller\'s setup', () => {
  // The renderer holds these in a store it saves wholesale; a silent in-place
  // edit is how a half-written record reaches disk.
  const before = mk({ ok: 1 });
  const after = recordOutcome(before, true, '2026-06-01T10:00:00Z');
  assert.equal(before.ok, 1, 'the original is untouched');
  assert.equal(after.ok, 2);
  assert.equal(after.lastOkAt, '2026-06-01T10:00:00Z');
});

test('a failure is recorded separately from a success', () => {
  const s = recordOutcome(mk({ ok: 3, lastOkAt: '2026-01-01T00:00:00Z' }), false, '2026-06-01T10:00:00Z');
  assert.equal(s.ok, 3, 'the success count is not touched');
  assert.equal(s.failed, 1);
  assert.equal(s.lastFailedAt, '2026-06-01T10:00:00Z');
  assert.equal(s.lastOkAt, '2026-01-01T00:00:00Z', 'and the last good print is remembered');
});

test('outcomes accumulate from nothing', () => {
  let s = {};
  for (let i = 0; i < 3; i++) s = recordOutcome(s, true, '2026-06-01T00:00:00Z');
  s = recordOutcome(s, false, '2026-06-02T00:00:00Z');
  assert.equal(s.ok, 3);
  assert.equal(s.failed, 1);
  assert.equal(statusOf(s), STATUS.KNOWN_GOOD);
});

test('the recommendation is the setup with the best record', () => {
  const setups = [
    mk({ id: 'a', ok: 1, lastOkAt: '2026-01-05T00:00:00Z' }),
    mk({ id: 'b', ok: 5, lastOkAt: '2026-01-04T00:00:00Z' }),
    mk({ id: 'c', failed: 4 }),
    mk({ id: 'd' }),
  ];
  assert.equal(recommendSetup(setups).id, 'b', 'five successes beats one');
});

test('a known-good setup beats an untested one however new', () => {
  const setups = [
    mk({ id: 'untested', createdAt: '2026-12-31T00:00:00Z' }),
    mk({ id: 'proven', ok: 2, lastOkAt: '2026-01-01T00:00:00Z' }),
  ];
  assert.equal(recommendSetup(setups).id, 'proven');
});

test('a reliable setup beats a flaky one that has simply been run more', () => {
  // The case that matters most in a real shop. A setup that works half the time
  // will accumulate successes just by being used, and raw success count alone
  // would keep recommending it over one that works every time.
  const setups = [
    mk({ id: 'flaky', ok: 5, failed: 5, lastOkAt: '2026-06-01T00:00:00Z' }),
    mk({ id: 'reliable', ok: 2, lastOkAt: '2026-01-01T00:00:00Z' }),
  ];
  assert.equal(statusOf(setups[0]), STATUS.NEEDS_TEST);
  assert.equal(statusOf(setups[1]), STATUS.KNOWN_GOOD);
  assert.equal(recommendSetup(setups).id, 'reliable',
    'five successes out of ten is not better than two out of two');
});

test('a setup the shop has vouched for beats an untried one', () => {
  // Neither has a print against it, so every count-based tiebreak is level. The
  // shop's own verdict is the only thing separating them, and it should win.
  const setups = [
    mk({ id: 'untried', createdAt: '2026-01-01T00:00:00Z' }),
    mk({ id: 'vouched', status: STATUS.KNOWN_GOOD, createdAt: '2026-06-01T00:00:00Z' }),
  ];
  assert.equal(recommendSetup(setups).id, 'vouched');
});

test('a failing setup is NEVER recommended, even as the only option', () => {
  // The answer a shop needs is "change something", not "try the least broken one
  // again" — that costs a spool and a night.
  assert.equal(recommendSetup([mk({ id: 'bad', failed: 3 })]), null);
  assert.equal(recommendSetup([mk({ id: 'a', failed: 1 }), mk({ id: 'b', failed: 9 })]), null);
  // An explicit "failed" override is honoured here too.
  assert.equal(recommendSetup([mk({ id: 'x', ok: 10, status: STATUS.FAILED })]), null);
});

test('an untested setup is offered when nothing better exists', () => {
  // It has not failed. Somebody has to try it.
  const r = recommendSetup([mk({ id: 'new' }), mk({ id: 'bad', failed: 2 })]);
  assert.equal(r.id, 'new');
});

test('the recommendation does not flip between equally good setups', () => {
  // An answer that changes on every render reads as a bug, and a shop cannot
  // build a habit around it.
  const setups = [
    mk({ id: 'z', ok: 3, lastOkAt: '2026-01-05T00:00:00Z', createdAt: '2026-01-02T00:00:00Z' }),
    mk({ id: 'a', ok: 3, lastOkAt: '2026-01-05T00:00:00Z', createdAt: '2026-01-01T00:00:00Z' }),
  ];
  const first = recommendSetup(setups).id;
  assert.equal(first, 'a', 'the older definition wins the tie');
  for (let i = 0; i < 5; i++) assert.equal(recommendSetup(setups).id, first);
  // …and the input order must not decide it.
  assert.equal(recommendSetup(setups.slice().reverse()).id, first);
});

test('the more recent success wins when counts are level', () => {
  const setups = [
    mk({ id: 'old', ok: 2, lastOkAt: '2026-01-01T00:00:00Z' }),
    mk({ id: 'new', ok: 2, lastOkAt: '2026-06-01T00:00:00Z' }),
  ];
  assert.equal(recommendSetup(setups).id, 'new');
});

test('recommending from nothing returns nothing', () => {
  for (const bad of [[], null, undefined, 'nope', [null, undefined, 42, 'x']]) {
    assert.equal(recommendSetup(bad), null, JSON.stringify(bad));
  }
});

test('a setup describes itself the way a shop would say it', () => {
  assert.equal(
    describeSetup({ layerHeightMm: 0.2, nozzleMm: 0.4, material: 'PLA', colour: 'black' }, 'Prusa MK4'),
    '0.2mm layers · 0.4mm nozzle · PLA black on Prusa MK4');
  // Partial information still reads as a sentence rather than stray separators.
  assert.equal(describeSetup({ material: 'PETG' }), 'PETG');
  assert.equal(describeSetup({ layerHeightMm: 0.3 }, 'Bambu'), '0.3mm layers on Bambu');
  assert.equal(describeSetup({}, 'Bambu'), 'Bambu');
  assert.equal(describeSetup({}), '');
  assert.equal(describeSetup(null), '');
});

test('the summary counts every setup exactly once', () => {
  const setups = [
    mk({ id: 'a', ok: 5 }), mk({ id: 'b', ok: 1 }),
    mk({ id: 'c', failed: 4 }), mk({ id: 'd' }),
  ];
  const s = summarize(setups);
  assert.equal(s.total, 4);
  assert.equal(s.knownGood + s.needsTest + s.failed, s.total, 'no setup is double-counted or lost');
  assert.equal(s.knownGood, 2);
  assert.equal(s.needsTest, 1);
  assert.equal(s.failed, 1);
  assert.equal(s.prints, 6);
  assert.equal(s.failures, 4);
});

test('junk counts never become numbers', () => {
  // These come off a store that has been through several schema versions.
  for (const bad of [null, undefined, -3, NaN, 'seven', {}]) {
    const s = mk({ ok: bad, failed: bad });
    assert.equal(deriveStatus(s), STATUS.NEEDS_TEST, JSON.stringify(bad));
    assert.equal(successRate(s), null, JSON.stringify(bad));
  }
  assert.doesNotThrow(() => deriveStatus(null));
  assert.doesNotThrow(() => statusOf(undefined));
  assert.doesNotThrow(() => summarize(null));
  assert.equal(summarize(null).total, 0);
  assert.equal(summarize([null, 5, 'x']).total, 0, 'non-objects are not setups');
});

test('a fractional count is not a count', () => {
  assert.equal(deriveStatus(mk({ ok: 2.7 })), STATUS.KNOWN_GOOD, 'truncated to 2');
  assert.equal(deriveStatus(mk({ ok: 0.4 })), STATUS.NEEDS_TEST, 'truncates to 0 — untried');
});
