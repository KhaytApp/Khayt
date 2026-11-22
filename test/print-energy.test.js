'use strict';
/**
 * What a print drew from the wall, added up from its smart plug's readings.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/smart-plug.js');
require('../lib/print-finish-photo.js');
const E = require('../lib/print-energy.js');

const T0 = Date.parse('2026-09-28T08:00:00Z');
const min = (n) => T0 + n * 60000;
const printing = (at, watts, filename = 'benchy.gcode') => ({ at, watts, state: 'printing', filename });

function run(samples, opts) {
  let memo = {};
  const dropped = [];
  for (const s of samples) {
    const r = E.tick(memo, 'M1', s, opts);
    memo = r.memo;
    if (r.dropped) dropped.push(r);
  }
  return { memo, dropped };
}

test('trapezoid between consecutive readings: a steady 120 W for an hour is 120 Wh', () => {
  const samples = [];
  for (let i = 0; i <= 60; i++) samples.push(printing(min(i), 120));
  const { memo } = run(samples);
  const r = E.take(memo, 'M1').reading;
  assert.equal(r.wh, 120);
  assert.equal(r.coveredS, 3600);
  assert.equal(r.coverage, 1);
  assert.equal(r.samples, 61);
});

test('a ramp is integrated as a ramp, not as either end', () => {
  // 0 W → 240 W over four minutes = 120 W mean × 1/15 h = 8 Wh.
  const { memo } = run([printing(min(0), 0), printing(min(4), 240)]);
  assert.equal(E.take(memo, 'M1').reading.wh, 8);
});

test('heat-up and pauses are part of the print; idle before and after is not', () => {
  const { memo } = run([
    { at: min(-5), watts: 8, state: 'standby' },        // idle: not metered
    printing(min(0), 300),                               // heat-up
    printing(min(1), 300),
    { at: min(2), watts: 60, state: 'paused', filename: 'benchy.gcode' },
    { at: min(3), watts: 60, state: 'paused', filename: 'benchy.gcode' },
  ]);
  const r = E.take(memo, 'M1').reading;
  // 300×1/60 + 180×1/60 + 60×1/60 = 5 + 3 + 1 = 9 Wh
  assert.equal(r.wh, 9);
});

test('not printing leaves the meter alone: the END is the finish edge\'s to call', () => {
  const { memo } = run([printing(min(0), 100), printing(min(1), 100),
    { at: min(2), watts: 5, state: 'complete', filename: 'benchy.gcode' }]);
  assert.ok(memo.M1, 'still there for take()');
  assert.equal(E.take(memo, 'M1').reading.wh, 1.7);
});

test('a gap longer than the cap is not bridged, and coverage says so', () => {
  const { memo } = run([
    printing(min(0), 100), printing(min(1), 100),
    printing(min(31), 100),                               // 30-minute gap: app was quit
    printing(min(32), 100),
  ]);
  const r = E.take(memo, 'M1').reading;
  assert.equal(r.gaps, 1);
  assert.equal(r.coveredS, 120);
  assert.equal(r.spanS, 32 * 60);
  assert.ok(r.coverage < E.MIN_COVERAGE);
  assert.equal(r.wh, 3.3);
});

test('a print spanning an app restart: the persisted meter resumes on the same file', () => {
  // First run of the app: 60 minutes metered, then the meter is saved (JSON).
  const first = run(Array.from({ length: 61 }, (_, i) => printing(min(i), 150)));
  const saved = JSON.parse(JSON.stringify(first.memo));
  // App reopened four minutes later — inside the gap cap, same file.
  let memo = saved;
  for (let i = 64; i <= 70; i++) memo = E.tick(memo, 'M1', printing(min(i), 150)).memo;
  const r = E.take(memo, 'M1').reading;
  assert.equal(r.gaps, 0);
  assert.equal(r.wh, 175);   // 70 minutes at 150 W
  // …and reopened after a long break: the gap is counted, not invented.
  let memo2 = saved;
  for (let i = 120; i <= 125; i++) memo2 = E.tick(memo2, 'M1', printing(min(i), 150)).memo;
  const r2 = E.take(memo2, 'M1').reading;
  assert.equal(r2.gaps, 1);
  assert.equal(r2.wh, 162.5);
});

test('a new file without an end in between drops the old meter rather than attribute it', () => {
  const { memo, dropped } = run([printing(min(0), 100), printing(min(1), 100),
    printing(min(2), 100, 'other.gcode'), printing(min(3), 100, 'other.gcode')]);
  assert.equal(dropped.length, 1);
  assert.equal(dropped[0].reason, 'new-file');
  assert.equal(memo.M1.filename, 'other.gcode');
  assert.equal(E.take(memo, 'M1').reading.wh, 1.7);
});

test('a stale meter is dropped', () => {
  const r = E.step({ filename: 'a.gcode', startedAt: min(0), lastAt: min(0), lastW: 100, wh: 5, coveredS: 60, samples: 2, gaps: 0 },
    { at: min(13 * 60), watts: 3, state: 'standby' });
  assert.equal(r.meter, null);
  assert.equal(r.reason, 'stale');
});

test('a plug that gives no watts meters nothing, and a reading with nothing in it is null', () => {
  const { memo } = run([printing(min(0), null), printing(min(1), null)]);
  assert.equal(E.take(memo, 'M1').reading, null);
  assert.equal(E.take({}, 'M1').reading, null);
});

test('a plug shared by two printers is never metered', () => {
  const machines = [
    { id: 'A', smartPlug: { type: 'shelly-rpc', host: '192.168.1.40' } },
    { id: 'B', smartPlug: { type: 'shelly-rpc', host: 'http://192.168.1.40/' } },
    { id: 'C', smartPlug: { type: 'shelly-rpc', host: '192.168.1.41' } },
    { id: 'D', smartPlug: { type: 'homeassistant', host: 'ha.local', entity: 'switch.one', token: 't' } },
    { id: 'E', smartPlug: { type: 'homeassistant', host: 'ha.local', entity: 'switch.two', token: 't' } },
  ];
  assert.deepEqual(E.sharedPlugIds(machines), ['A', 'B']);
  const r = E.step({ lastAt: min(0), wh: 3 }, printing(min(1), 100), { shared: true });
  assert.equal(r.meter, null);
  assert.equal(r.reason, 'shared');
});

test('the job is found by the print-finish photo\'s own rule', () => {
  const log = [
    { id: 'J1', machineId: 'M1', status: 'printing', parts: [{ fileRef: 'a.gcode' }] },
    { id: 'J2', machineId: 'M1', status: 'printing', parts: [{ fileRef: 'benchy.gcode' }] },
  ];
  const P = require('../lib/print-finish-photo.js');
  for (const f of ['benchy.gcode', 'a.gcode', 'nope.gcode']) {
    assert.equal(E.jobFor(log, 'M1', f), P.jobFor(log, 'M1', f));
  }
  assert.equal(E.jobFor(log, 'M1', 'benchy.gcode'), 'J2');
  assert.equal(E.jobFor(log, 'M1', 'nope.gcode'), null, 'two printing jobs and no file: no guess');
});

test('jobFields and energyWhOf: coverage decides whether the reading is used', () => {
  const f = E.jobFields({ wh: 180, coveredS: 3600, spanS: 3600, coverage: 1, samples: 61, gaps: 0 }, '2026-09-28T09:00:00Z');
  assert.equal(f.actualEnergyWh, 180);
  assert.equal(f.actualEnergy.source, 'plug');
  assert.equal(E.energyWhOf(f), 180);
  // 90% metered: scaled to the whole span at the print's own mean draw.
  assert.equal(E.energyWhOf({ actualEnergyWh: 90, actualEnergy: { coverage: 0.9 } }), 100);
  // 50% metered: not used.
  assert.equal(E.energyWhOf({ actualEnergyWh: 90, actualEnergy: { coverage: 0.5 } }), null);
  assert.equal(E.energyWhOf({}), null);
  assert.equal(E.jobFields(null), null);
});

test('actual power cost: measured when there is a reading, the old formula when not', () => {
  const rates = { powerDraw: 150, elecRate: 0.2, failureRate: 10 };
  const job = { printTime: 10, actualPrintTime: 12, parts: [{ printTime: 5, qty: 2, elecRate: 0.25, powerDraw: 150 }] };
  // No reading: actual hours × watts × the job's own tariff (from its parts).
  const none = E.actualPowerCost(job, rates);
  assert.equal(none.measured, false);
  assert.ok(Math.abs(none.cost - 12 * 0.15 * 0.25) < 1e-9);
  // Estimated: part hours × W × tariff × (1 + failure) × qty.
  assert.ok(Math.abs(none.estimated - 5 * 0.15 * 0.25 * 1.1 * 2) < 1e-9);
  const metered = E.actualPowerCost({ ...job, actualEnergyWh: 2400, actualEnergy: { coverage: 1 } }, rates);
  assert.equal(metered.measured, true);
  assert.ok(Math.abs(metered.cost - 2.4 * 0.25) < 1e-9);
  // A job with no parts' tariff falls back to the rate.
  assert.equal(E.tariffOf({ parts: [{}] }, rates), 0.2);
});

test('suggested wattage: Wh ÷ printer hours over recent metered prints, and not below three', () => {
  const job = (id, wh, h, at, extra) => ({ id, machineId: 'M1', status: 'completed', actualPrintTime: h,
    actualEnergyWh: wh, actualEnergy: { coverage: 1, at }, ...extra });
  const log = [
    job('a', 200, 2, '2026-09-01'),
    job('b', 300, 2, '2026-09-02'),
  ];
  assert.equal(E.suggestPowerDraw(log, 'M1'), null, 'two prints are not enough');
  log.push(job('c', 100, 1, '2026-09-03'));
  log.push(job('x', 999, 1, '2026-09-04', { machineId: 'M2' }));
  log.push(job('p', 500, 1, '2026-09-05', { actualEnergy: { coverage: 0.3, at: '2026-09-05' } }));
  const s = E.suggestPowerDraw(log, 'M1');
  assert.deepEqual(s, { watts: 120, basedOn: 3, hours: 5, wh: 600 });
  // Recent only.
  const s2 = E.suggestPowerDraw(log, 'M1', { limit: 2, minPrints: 2 });
  assert.equal(s2.basedOn, 2);
  assert.equal(s2.watts, Math.round(400 / 3));
});

test('electricity estimate against actual, per machine, metered finished jobs only', () => {
  const rates = { powerDraw: 100, elecRate: 0.2, failureRate: 0 };
  const orders = [
    { id: '1', machineId: 'M1', status: 'completed', parts: [{ printTime: 10, qty: 1 }],
      actualEnergyWh: 1500, actualEnergy: { coverage: 1 } },
    { id: '2', machineId: 'M1', status: 'printing', parts: [{ printTime: 10 }], actualEnergyWh: 999 },
    { id: '3', machineId: 'M2', status: 'completed', parts: [{ printTime: 10 }] },
  ];
  const rows = E.powerByMachine(orders, () => rates);
  assert.equal(rows.length, 1);
  assert.deepEqual(rows[0], { machineId: 'M1', sampled: 1, wh: 1500, estCost: 0.2, actCost: 0.3, deltaPct: 50 });
});
