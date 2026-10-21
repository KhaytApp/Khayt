/**
 * The printer's own job history, and why the nozzle counter needed it.
 *
 * Khayt's print log is a BUSINESS record — orders, with a client and a price. A
 * printer runs far more than orders: test prints, reprints, calibration, and
 * everything nobody paid for. All of it is real filament through the same
 * nozzle.
 *
 * Measured on a real machine: the order log accounted for 2,461 g since the
 * nozzle went in, and the printer's own history said 4,980 g — against a 2,000 g
 * threshold. The warning was firing late, which ruins parts rather than wasting
 * nozzles.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const MH = require('../lib/moonraker-history.js');
const NW = require('../lib/nozzle-wear.js');

// Timestamps written as dates rather than epoch seconds, because the first
// version of this fixture used 2025 values against a 2026 nozzle-install date
// and every assertion failed for a reason that had nothing to do with the code.
const at = (iso) => Date.parse(iso) / 1000;

const raw = {
  jobs: [
    { job_id: '1', filename: 'a_PLA.gcode', status: 'completed',
      start_time: at('2026-08-15T09:00:00Z'), end_time: at('2026-08-15T12:00:00Z'),
      print_duration: 10800, filament_used: 12000,
      metadata: { filament_weight_total: 120, filament_name: 'Generic PLA";"Generic PLA', layer_height: 0.2, nozzle_diameter: 0.4 } },
    { job_id: '2', filename: 'b_CF.gcode', status: 'completed',
      start_time: at('2026-08-20T09:00:00Z'), end_time: at('2026-08-20T11:00:00Z'), print_duration: 7200,
      metadata: { filament_weight_total: 100, filament_name: 'PLA-CF' } },
    { job_id: '3', filename: 'c.gcode', status: 'cancelled',
      start_time: at('2026-08-22T09:00:00Z'), print_duration: 60,
      metadata: { filament_weight_total: 0 } },
    { job_id: '4', filename: 'old.gcode', status: 'completed',
      start_time: at('2026-06-15T09:00:00Z'), print_duration: 3600,
      metadata: { filament_weight_total: 900, filament_name: 'PLA' } },
  ],
};

test('the per-tool material list is unquoted and deduped', () => {
  // A four-toolhead machine reports one entry per tool whether or not it was
  // used, and the slicer writes the list ALREADY QUOTED — so a plain split
  // leaves a stray quote glued to every entry. That reached the abrasiveness
  // patterns as `Generic PLA" + "Generic PLA`, matching nothing it should.
  assert.equal(MH.materialOf({ filament_name: 'Generic PLA";"Generic PLA";"Generic PLA' }), 'Generic PLA');
  assert.equal(MH.materialOf({ filament_name: 'Generic PLA";"Generic PLA Silk' }), 'Generic PLA + Generic PLA Silk');
  assert.equal(MH.materialOf({ filament_type: 'PETG;PETG;PETG;PETG' }), 'PETG');
  assert.equal(MH.materialOf({}), '');
});

test('a job maps into the units the store keeps', () => {
  const [j] = MH.mapJobs(raw);
  assert.equal(j.jobId, '1');
  assert.equal(j.grams, 120, 'weight comes from filament_weight_total, not the LENGTH in filament_used');
  assert.equal(j.hours, 3, '10800 seconds is three hours');
  assert.equal(j.startedAt, '2026-08-15T09:00:00.000Z', 'unix seconds become ISO, like every other date in the store');
  assert.equal(j.material, 'Generic PLA');
  // Thumbnails are deliberately dropped: the store is pushed to the cloud
  // encrypted on every sync and a hundred base64 previews would multiply it.
  assert.equal(j.thumbnails, undefined);
});

test('only completed jobs count, and only since the nozzle went in', () => {
  const jobs = MH.mapJobs(raw);
  assert.equal(MH.completed(jobs).length, 3, 'the cancelled one is not completed');
  const since = MH.totalsSince(jobs, '2026-08-01');
  assert.equal(since.grams, 220, 'the June job belongs to whatever nozzle was fitted then');
  assert.equal(since.jobs, 2);
  const all = MH.totalsSince(jobs, '');
  assert.equal(all.grams, 1120);
});

test('re-importing does not double anything', () => {
  const jobs = MH.mapJobs(raw);
  assert.equal(MH.merge(jobs, jobs).length, jobs.length, 'keyed on the printer\'s own job id');
  const extra = MH.mapJobs({ jobs: [{ job_id: '9', filename: 'new.gcode', status: 'completed', start_time: at('2026-08-28T09:00:00Z'), metadata: { filament_weight_total: 5 } }] });
  assert.equal(MH.merge(jobs, extra).length, jobs.length + 1);
  // Newest first, so a card can show the last thing it printed.
  assert.equal(MH.merge(jobs, extra)[0].filename, 'new.gcode');
});

test('the wear model prefers the printer over the order log', () => {
  const jobs = MH.mapJobs(raw);
  const machine = {
    id: 'M1',
    nozzle: { material: 'stainless', installedAt: '2026-08-01', gramsThreshold: 2000 },
    printerHistory: { jobs },
  };
  // An order log that knows about ONE of those jobs would say 120 g.
  const orderLog = [{ machineId: 'M1', status: 'completed', date: '2026-09-01',
    parts: [{ printWeight: 120, qty: 1, material: 'PLA' }] }];
  const r = NW.nozzleWear(orderLog, machine);
  assert.equal(r.source, 'printer', 'the machine itself is the ground truth for what went through it');
  assert.equal(r.grams, 220, 'not the 120 g the order log knows about');
  // The carbon-fibre job costs ten times its weight.
  assert.equal(r.wear, 120 + 100 * 10);
  assert.equal(r.worst.material, 'PLA-CF');
});

test('a machine with no imported history still uses the order log', () => {
  // The import is opt-in per machine and most shops will not have run it.
  const orderLog = [{ machineId: 'M1', status: 'completed', date: '2026-09-01',
    parts: [{ printWeight: 120, qty: 1, material: 'PLA' }] }];
  const r = NW.nozzleWear(orderLog, { id: 'M1', nozzle: { installedAt: '2026-08-01' } });
  assert.equal(r.grams, 120);
  assert.notEqual(r.source, 'printer');
});

test('an empty or malformed history falls back rather than reporting zero wear', () => {
  const orderLog = [{ machineId: 'M1', status: 'completed', date: '2026-09-01',
    parts: [{ printWeight: 500, qty: 1 }] }];
  for (const history of [{ jobs: [] }, { jobs: null }, {}]) {
    const r = NW.nozzleWear(orderLog, { id: 'M1', nozzle: { installedAt: '2026-08-01' }, printerHistory: history });
    assert.equal(r.grams, 500, 'an empty import must not silently zero the counter');
  }
});

test('reading the history is a GET and nothing else', () => {
  // It is meant to be safe to run mid-print, which is when a shop reaches for
  // it. Anything that could pause, cancel or queue does not belong on this path.
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const fn = src.slice(src.indexOf('async function fetchPrinterHistory'), src.indexOf('async function sendPrinterCommand'));
  assert.ok(fn.length > 200, 'fetchPrinterHistory has moved — update this test');
  assert.doesNotMatch(fn, /method:\s*['"](POST|PUT|DELETE|PATCH)/i, 'the history read must never write to the printer');
  assert.match(fn, /resolvePrinterTarget\(host\)/, 'and stays behind the same resolved-and-pinned LAN host guard as every other printer call');
  assert.match(fn, /server\/history\/list/);
});

test('a malformed answer from the printer does not take the import down', () => {
  /* `j && j.metadata` was guarded and `j.job_id` was read straight off the same
   * object — half a guard, which is not a guard. A null entry in the array threw
   * and the whole history import died with it.
   *
   * A printer answering oddly on the LAN must not be able to do that, and this
   * is not a hypothetical shape: the array comes off the network.
   */
  assert.doesNotThrow(() => MH.mapJobs({ jobs: [null, undefined, {}, 42, 'x'] }));
  assert.deepEqual(MH.mapJobs({ jobs: [null, {}, { filename: 'a.gcode', job_id: '1' }] })
    .map((j) => j.filename), ['a.gcode'], 'the readable entries still come through');
  assert.doesNotThrow(() => MH.mapJobs(null));
  assert.doesNotThrow(() => MH.mapJobs({ jobs: 'not an array' }));
  assert.doesNotThrow(() => MH.mapJobs({ jobs: [{ filename: 'a', metadata: null }] }));
});
