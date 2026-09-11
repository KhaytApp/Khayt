'use strict';
const test = require('node:test');
const assert = require('node:assert');
const { machineReliability, FINISHED } = require('../lib/machine-reliability.js');

const machines = [{ id: 'm1', name: 'Old one' }, { id: 'm2', name: 'New one' }];
const job = (id, machineId, grams, status = 'completed', date = '2026-09-01', extra = {}) =>
  ({ id, machineId, status, date, parts: [{ printWeight: grams, qty: 1, printTime: 1 }], ...extra });
const scrap = (machineId, weight, failureType, date = '2026-09-01', cost = 0) =>
  ({ machineId, weight, failureType, date, cost });
function run(orders, waste, window = {}) {
  return machineReliability({ machines, orders, waste, unassigned: 'Unassigned', ...window }, {});
}
const of = (r, id) => r.rows.find((x) => x.machineId === id);

/**
 * THE REASON THIS EXISTS.
 *
 * Ranking by grams always names the busiest machine, which is the wrong
 * printer to sell. A machine that ran nine hundred hours and scrapped two kilos
 * is doing better than one that ran ninety and scrapped one.
 */
test('the worst machine is the worst RATE, not the one that scrapped the most', () => {
  const r = run([
    job('a', 'm1', 1000), job('b', 'm1', 1000),          // busy machine
    job('c', 'm2', 100), job('d', 'm2', 100),            // quiet machine
  ], [
    scrap('m1', 200, 'warping'),                          // ~9% of what it handled
    scrap('m2', 100, 'nozzle_jam'),                       // ~33% of what it handled
  ]);
  assert.equal(r.rows[0].machineId, 'm2');
  assert.ok(of(r, 'm2').scrapGrams < of(r, 'm1').scrapGrams,
    'the worst machine scrapped FEWER grams, which is the whole point');
  assert.equal(r.totals.worst.machineId, 'm2');
});

/// The denominator is everything the machine consumed, so a machine that
/// scrapped half its filament reads as 50% rather than 100%.
test('the rate is scrap against everything the machine handled', () => {
  const r = run([job('a', 'm1', 500)], [scrap('m1', 500, 'warping')]);
  assert.equal(of(r, 'm1').scrapRate, 0.5);
});

/// "Warping" sends somebody to the chamber temperature; a number does not.
test('each machine reports what it keeps doing wrong, by weight', () => {
  const r = run([job('a', 'm1', 1000)], [
    scrap('m1', 50, 'stringing'),
    scrap('m1', 300, 'warping'),
    scrap('m1', 20, 'warping'),
  ]);
  assert.equal(of(r, 'm1').worstFault.type, 'warping');
  assert.equal(of(r, 'm1').worstFault.grams, 320);
  assert.equal(of(r, 'm1').scraps, 3);
});

test('delivered work counts as output; unfinished and voided do not', () => {
  const r = run([
    job('a', 'm1', 100, 'delivered'),
    job('b', 'm1', 900, 'printing'),
    job('c', 'm1', 900, 'completed', '2026-09-01', { voidedAt: '2026-09-02' }),
  ], []);
  assert.equal(of(r, 'm1').jobs, 1);
  assert.equal(of(r, 'm1').grams, 100);
  assert.deepEqual(FINISHED, ['completed', 'delivered']);
});

/// A shop cannot act on it, but hiding it makes the shop's total look better
/// than it is.
test('scrap that names no machine is still in the shop total', () => {
  const r = run([job('a', 'm1', 1000)], [scrap(null, 500, 'warping')]);
  assert.equal(of(r, '__none__').scrapGrams, 500);
  assert.equal(r.totals.scrapGrams, 500);
  assert.equal(r.totals.scrapRate, 500 / 1500);
});

test('a machine that has done nothing is not a row', () => {
  const r = run([job('a', 'm1', 100)], []);
  assert.equal(of(r, 'm2'), undefined);
  assert.equal(r.rows.length, 1);
});

/// One scrapped print on a machine that has run twice is not evidence.
test('the machine to look at needs enough history to mean anything', () => {
  const barely = run([job('a', 'm1', 10)], [scrap('m1', 500, 'warping')]);
  assert.equal(barely.totals.worst, null, 'one job is not a rate');

  const enough = run([job('a', 'm1', 10), job('b', 'm1', 10)], [scrap('m1', 500, 'warping')]);
  assert.equal(enough.totals.worst.machineId, 'm1');
});

test('the window bounds both the output and the scrap', () => {
  const r = run([
    job('a', 'm1', 100, 'completed', '2026-08-01'),
    job('b', 'm1', 100, 'completed', '2026-09-15'),
  ], [
    scrap('m1', 50, 'warping', '2026-08-02'),
    scrap('m1', 10, 'warping', '2026-09-16'),
  ], { from: '2026-09-01' });
  assert.equal(of(r, 'm1').jobs, 1);
  assert.equal(of(r, 'm1').grams, 100);
  assert.equal(of(r, 'm1').scrapGrams, 10);
});

test('a machine with output and no scrap has a rate of zero, not nothing', () => {
  const r = run([job('a', 'm1', 100)], []);
  assert.equal(of(r, 'm1').scrapRate, 0);
  assert.equal(of(r, 'm1').worstFault, null);
});

test('grams and hours count every unit, not every line', () => {
  const r = machineReliability({
    machines, unassigned: 'Unassigned', waste: [],
    orders: [{ id: 'a', machineId: 'm1', status: 'completed', date: '2026-09-01',
               parts: [{ printWeight: 100, supportWeight: 20, printTime: 2, qty: 3 }] }],
  }, {});
  assert.equal(of(r, 'm1').grams, 360);
  assert.equal(of(r, 'm1').hours, 6);
});

test('nothing at all is an answer, not a throw', () => {
  const r = machineReliability(undefined, undefined);
  assert.deepEqual(r.rows, []);
  assert.equal(r.totals.scrapRate, null);
  assert.equal(r.totals.worst, null);
});
