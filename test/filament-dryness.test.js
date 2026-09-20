'use strict';
const { test } = require('node:test');
const assert = require('node:assert');
const D = require('../lib/filament-dryness');

const DAY = 86400000;
const now = 1_700_000_000_000; // fixed epoch for determinism

test('materialKey normalises common variants', () => {
  assert.equal(D.materialKey('PLA Matte'), 'PLA');
  assert.equal(D.materialKey('pla+'), 'PLA');
  assert.equal(D.materialKey('PETG'), 'PETG');
  assert.equal(D.materialKey('Nylon'), 'PA');
  assert.equal(D.materialKey('PA6-CF'), 'PA');
  assert.equal(D.materialKey('PA-CF'), 'PA');
  assert.equal(D.materialKey('mystery goo'), null);
});

test('materialSpec falls back to DEFAULT for unknown material', () => {
  assert.deepEqual(D.materialSpec('unobtanium'), D.DEFAULT);
  assert.equal(D.materialSpec('PETG').dryTempC, 65);
});

test('PETG detected before PLA (substring order does not misclassify)', () => {
  // "PETG" contains no "PLA", but guard against a naive scan that hits something else first.
  assert.equal(D.materialKey('Prusament PETG'), 'PETG');
});

test('isSealed treats drybox and sealed as dry storage', () => {
  assert.equal(D.isSealed('drybox'), true);
  assert.equal(D.isSealed('sealed'), true);
  assert.equal(D.isSealed('open'), false);
  assert.equal(D.isSealed(undefined), false);
});

test('dryStatus: never dried → unknown', () => {
  const s = D.dryStatus({ material: 'PLA', storage: 'open' }, now);
  assert.equal(s.state, 'unknown');
  assert.equal(s.daysSince, null);
});

test('dryStatus: fresh PLA in open air is good', () => {
  const s = D.dryStatus({ material: 'PLA', storage: 'open', driedAt: now - 2 * DAY }, now);
  assert.equal(s.state, 'good');
  assert.equal(s.intervalDays, 14);
  assert.ok(s.daysSince >= 1.9 && s.daysSince <= 2.1);
});

test('dryStatus: PLA open at 12 days is due (>=75% of 14)', () => {
  const s = D.dryStatus({ material: 'PLA', storage: 'open', driedAt: now - 12 * DAY }, now);
  assert.equal(s.state, 'due');
});

test('dryStatus: PLA open past 14 days is overdue', () => {
  const s = D.dryStatus({ material: 'PLA', storage: 'open', driedAt: now - 20 * DAY }, now);
  assert.equal(s.state, 'overdue');
  assert.ok(s.pct > 1);
});

test('dryStatus: same spool in a drybox uses the long interval', () => {
  const rec = { material: 'PLA', storage: 'drybox', driedAt: now - 20 * DAY };
  const s = D.dryStatus(rec, now);
  assert.equal(s.intervalDays, 90);
  assert.equal(s.state, 'good');
});

test('dryStatus: Nylon in open air degrades within a day', () => {
  const s = D.dryStatus({ material: 'Nylon', storage: 'open', driedAt: now - 2 * DAY }, now);
  assert.equal(s.intervalDays, 1);
  assert.equal(s.state, 'overdue');
});

test('dryStatus: future driedAt clamps daysSince to 0 (good)', () => {
  const s = D.dryStatus({ material: 'PLA', storage: 'open', driedAt: now + 5 * DAY }, now);
  assert.equal(s.daysSince, 0);
  assert.equal(s.state, 'good');
});

test('recording a drying sets driedAt as well as the log', () => {
  // `dryStatus` reads `driedAt` and NOTHING else. The drying log wrote only
  // `dryingLog`, so a shop that recorded a drying was still told the spool was
  // overdue — by the same app, on the same screen.
  const D = require('../lib/filament-dryness.js');
  let spool = { material: 'PETG' };
  spool = Object.assign(spool, D.recordDrying(spool, { date: '2026-09-01', tempC: 65 }));
  assert.strictEqual(spool.driedAt, '2026-09-01');
  assert.strictEqual(spool.dryingLog.length, 1);
  assert.strictEqual(D.dryStatus(spool, new Date('2026-09-02').getTime()).state, 'good');
});

test('the newest drying wins, so correcting an old one cannot move it backwards', () => {
  const D = require('../lib/filament-dryness.js');
  let spool = { material: 'PETG' };
  spool = Object.assign(spool, D.recordDrying(spool, { date: '2026-09-20' }));
  spool = Object.assign(spool, D.recordDrying(spool, { date: '2026-06-01' }));
  assert.strictEqual(spool.driedAt, '2026-09-20',
    'writing down a drying somebody forgot made the spool older');
  assert.strictEqual(spool.dryingLog.length, 2, 'the forgotten drying was not kept');
});

test('an entry with no date is kept out of the log rather than dated today', () => {
  const D = require('../lib/filament-dryness.js');
  const out = D.recordDrying({ material: 'PLA', driedAt: '2026-05-05' }, {});
  assert.strictEqual(out.dryingLog.length, 0);
  assert.strictEqual(out.driedAt, '2026-05-05', 'an empty entry cleared the date');
});

test('the drying log in the main app goes through this rule', () => {
  // `renderer/inventory.js` used to push onto `dryingLog` directly — and the
  // main app did not even LOAD this module, so it could not have asked.
  const fs = require('fs');
  const inv = fs.readFileSync(require('path').join(__dirname, '..', 'renderer/inventory.js'), 'utf8');
  assert.match(inv, /KhaytFilamentDryness\.recordDrying\(/,
    'the drying log writes the log and not the date the verdict reads');
  const index = fs.readFileSync(require('path').join(__dirname, '..', 'renderer/index.html'), 'utf8');
  assert.match(index, /lib\/filament-dryness\.js/,
    'the main app calls a module it does not load');
});
