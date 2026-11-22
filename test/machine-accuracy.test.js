const { test } = require('node:test');
const assert = require('node:assert/strict');

const A = require('../lib/machine-accuracy.js');
const Actuals = require('../lib/printer-actuals.js');
const V = require('../lib/estimate-variance.js');

const deps = {
  compare: Actuals.compareToEstimate,
  median: V.median,
  confidence: V.confidenceFor,
};

/** One finished print, with a duration a printer reported. */
const job = (over = {}) => ({
  status: 'completed',
  machineId: over.machineId === undefined ? 'MACH-1' : over.machineId,
  printTime: over.estH,
  actualPrintTime: over.actH,
  completedAt: over.at || '2026-08-01T00:00:00Z',
  actualsSource: over.typed
    ? { time: 'manual', weight: 'manual' }
    : (over.noSource ? undefined : { time: 'moonraker', weight: 'moonraker' }),
  ...(over.extra || {}),
});

test('the book this was found against: nineteen measured prints, and the panel was blank', () => {
  // Every one of these carries a Moonraker duration and NONE carries
  // printingStartedAt, because the jobs were logged from the printer's own
  // history rather than dragged through the printing stage by hand. Both old
  // panels filtered on that field and rendered an empty string.
  const orders = Array.from({ length: 19 }, (_, i) =>
    job({ estH: 5.69, actH: 5.54, at: `2026-08-${String(i + 1).padStart(2, '0')}T00:00:00Z` }));
  for (const o of orders) assert.equal(o.printingStartedAt, undefined);

  const [row] = A.accuracyByMachine(orders, deps);
  assert.equal(row.sampled, 19);
  assert.equal(row.machineId, 'MACH-1');
  // Finishing EARLY, which is what the real machine does.
  assert.ok(row.hoursDeltaPct < 0, 'the machine beats its estimate');
  assert.equal(row.confidence, 'good');
});

test('a typed actual is not evidence, however confidently it was typed', () => {
  // The dialog pre-fills the estimate, so a shop that hits confirm records the
  // estimate under a second name. Counting those compares an estimate to itself
  // and reports a machine as perfectly calibrated.
  const orders = [
    job({ estH: 4, actH: 4, typed: true }),
    job({ estH: 4, actH: 4, typed: true }),
  ];
  assert.deepEqual(A.accuracyByMachine(orders, deps), []);
  assert.equal(A.accuracyOverall(orders, deps), null);
});

test('an order with no actualsSource at all is not assumed measured', () => {
  assert.deepEqual(A.accuracyByMachine([job({ estH: 4, actH: 5, noSource: true })], deps), []);
});

test('measured on weight and typed on time does not count as a time reading', () => {
  // PrusaLink reports a duration and no filament; a shop can fill in either by
  // hand. "This order was measured" is not one fact.
  const o = job({ estH: 4, actH: 5 });
  o.actualsSource = { time: 'manual', weight: 'moonraker' };
  assert.deepEqual(A.accuracyByMachine([o], deps), []);
});

test('nothing measured reads as nothing, not as bang on', () => {
  // Null and not zero. A headline of +0% for a shop no printer has ever
  // reported to is the failure this exists to end, one level up.
  assert.equal(A.accuracyOverall([job({ estH: 4, actH: 4, typed: true })], deps), null);
  assert.equal(A.accuracyOverall([], deps), null);
});

test('one long print does not outvote a dozen short ones', () => {
  // Both old panels summed the hours and divided, so a single forty-hour job
  // decided the verdict. Twelve prints bang on the estimate, and one that ran
  // four times as long as quoted.
  const orders = [
    ...Array.from({ length: 12 }, (_, i) =>
      job({ estH: 3, actH: 3, at: `2026-08-${String(i + 1).padStart(2, '0')}T00:00:00Z` })),
    job({ estH: 10, actH: 40, at: '2026-08-20T00:00:00Z' }),
  ];
  const [row] = A.accuracyByMachine(orders, deps);
  assert.equal(row.sampled, 13);
  assert.equal(row.hoursDeltaPct, 0, 'the median is the twelve, not the one');

  // Σactual / Σestimate — what the old panels computed — says something else
  // entirely, and it is the outlier talking.
  const sumEst = orders.reduce((t, o) => t + o.printTime, 0);
  const sumAct = orders.reduce((t, o) => t + o.actualPrintTime, 0);
  assert.ok(Math.round((sumAct - sumEst) / sumEst * 100) >= 50);
});

test('each machine is judged on its own prints', () => {
  const orders = [
    job({ machineId: 'slow', estH: 4, actH: 6 }),
    job({ machineId: 'slow', estH: 4, actH: 6 }),
    job({ machineId: 'quick', estH: 4, actH: 3 }),
    job({ machineId: 'quick', estH: 4, actH: 3 }),
  ];
  const rows = A.accuracyByMachine(orders, deps);
  assert.equal(rows.length, 2);
  // Furthest OVER first: a machine finishing early is not a problem to look at.
  assert.equal(rows[0].machineId, 'slow');
  assert.equal(rows[0].hoursDeltaPct, 50);
  assert.equal(rows[1].machineId, 'quick');
  assert.equal(rows[1].hoursDeltaPct, -25);
});

test('a job on no machine is dropped from the breakdown and kept in the headline', () => {
  // Which MACHINE to trust cannot be answered by a bucket holding all of them;
  // "how good are our estimates" does not need to know which machine ran it.
  const orders = [
    job({ machineId: 'm1', estH: 4, actH: 4 }),
    job({ machineId: '', estH: 4, actH: 8 }),
  ];
  const rows = A.accuracyByMachine(orders, deps);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].sampled, 1);
  assert.equal(A.accuracyOverall(orders, deps).sampled, 2);
});

test('an unfinished print is not a measurement of anything', () => {
  const o = job({ estH: 4, actH: 1.2 });
  o.status = 'printing';
  assert.deepEqual(A.accuracyByMachine([o], deps), []);
});

test('a missing side is dropped rather than counted as zero', () => {
  assert.deepEqual(A.accuracyByMachine([job({ estH: 0, actH: 4 })], deps), []);
  assert.deepEqual(A.accuracyByMachine([job({ estH: 4, actH: 0 })], deps), []);
});

test('minSamples keeps a single print from reading as a verdict', () => {
  const orders = [job({ machineId: 'm1', estH: 4, actH: 6 })];
  assert.deepEqual(A.accuracyByMachine(orders, deps, { minSamples: 2 }), []);
  assert.equal(A.accuracyByMachine(orders, deps, { minSamples: 1 }).length, 1);
});

test('the breakdown and the headline come off the same readings', () => {
  // Before, one averaged across every job and the other averaged per machine
  // without ever rolling up, so nothing made the two agree. With one machine
  // they are now the same arithmetic and must land on the same figure.
  const orders = Array.from({ length: 5 }, (_, i) =>
    job({ estH: 4, actH: 4.4 + i * 0.1, at: `2026-08-0${i + 1}T00:00:00Z` }));
  const [row] = A.accuracyByMachine(orders, deps);
  const all = A.accuracyOverall(orders, deps);
  assert.equal(row.hoursDeltaPct, all.hoursDeltaPct);
  assert.equal(row.estHours, all.estHours);
  assert.equal(row.actHours, all.actHours);
  assert.equal(row.lastAt, all.lastAt);
});

test('it uses the tested comparison rather than a second copy of it', () => {
  const src = require('fs').readFileSync(
    require('path').join(__dirname, '..', 'lib', 'machine-accuracy.js'), 'utf8');
  assert.ok(/compare\(\{ printTime/.test(src), 'the injected comparison is called per job');
  assert.ok(!/actHours\s*-\s*estHours/.test(src), 'and no variance arithmetic is re-derived here');
});

test('it refuses to answer without the shared rules rather than inventing them', () => {
  // A default median or a default idea of "enough evidence" would be a second
  // definition, quietly disagreeing with the model panel.
  const orders = [job({ estH: 4, actH: 5 })];
  assert.deepEqual(A.accuracyByMachine(orders, {}), []);
  assert.deepEqual(A.accuracyByMachine(orders, { compare: deps.compare }), []);
  assert.equal(A.accuracyOverall(orders, { compare: deps.compare, median: deps.median }), null);
});

test('the wall clock is never consulted, even when both timestamps are there', () => {
  // completedAt - printingStartedAt counts the hours a finished print sat on the
  // bed waiting to be noticed. It can only ever make a machine look slow.
  const o = job({ estH: 4, actH: 4 });
  o.printingStartedAt = '2026-08-01T00:00:00Z';
  o.completedAt = '2026-08-01T20:00:00Z';   // twenty hours, sixteen of them overnight
  const [row] = A.accuracyByMachine([o], deps);
  assert.equal(row.hoursDeltaPct, 0, 'the measured four hours, not the twenty on the clock');
});

test('a delivered print is a finished print', () => {
  // Both spellings exist in real stores. `order-status.js` derives the delivered
  // STAGE from completed + deliveredAt, so a handed-over job keeps the status
  // `completed` — but the bundled sample, and books written by older versions,
  // store the literal string `delivered`.
  //
  // Testing only for `completed` passed every unit test written against a fresh
  // order and dropped five of the sample's six measured prints. The one it kept
  // was the one job nobody had got round to delivering.
  const o = job({ estH: 4, actH: 5 });
  o.status = 'delivered';
  const [row] = A.accuracyByMachine([o], deps);
  assert.equal(row.sampled, 1);
  assert.equal(row.hoursDeltaPct, 25);
  assert.ok(A.isFinished({ status: 'completed' }));
  assert.ok(A.isFinished({ status: 'delivered' }));
  assert.ok(!A.isFinished({ status: 'printing' }));
});

test('the sample shop spans the cases this panel can draw', () => {
  // A branch the sample cannot reach has never been drawn, let alone reviewed.
  // This panel has three colour bands and three confidence words, and the
  // screenshot that gets looked at is taken against the sample — so the sample
  // has to contain a machine in each band.
  //
  // It did not. Two sample orders carried time actuals 12x and 22x their
  // estimate while their WEIGHT actuals sat at 0.91x and 0.99x, which is noise
  // in one field rather than a shop that had a bad month; one of them put a
  // machine at +561% and made the whole panel unreadable.
  const fs = require('fs');
  const path = require('path');
  const sample = JSON.parse(fs.readFileSync(path.join(
    __dirname, '..', 'mac', 'KhaytCore', 'Sources', 'KhaytApp', 'Resources', 'sample-shop.json'), 'utf8'));

  const rows = A.accuracyByMachine(sample.printLog, deps);
  assert.ok(rows.length >= 3, `wanted three machines to compare, got ${rows.length}`);

  const band = (p) => (p >= 25 ? 'over' : p >= 10 ? 'watch' : 'fine');
  const bands = new Set(rows.map((r) => band(r.hoursDeltaPct)));
  assert.deepEqual([...bands].sort(), ['fine', 'over', 'watch'],
    'every colour band must have a machine in it');

  const confidences = new Set(rows.map((r) => r.confidence));
  assert.ok(confidences.size >= 2, 'more than one confidence word must be reachable');

  // And no reading may be absurd again. Every measured sample print sits in the
  // band a real printer produces; the two that did not are what this guards.
  for (const o of sample.printLog) {
    if (!A.timeWasMeasured(o) || !(o.printTime > 0) || !(o.actualPrintTime > 0)) continue;
    const ratio = o.actualPrintTime / o.printTime;
    assert.ok(ratio > 0.5 && ratio < 2,
      `${o.id} claims a print took ${ratio.toFixed(1)}x its estimate`);
  }

  // Worst first, so the machine a shop should look at is the one it reads first.
  const pcts = rows.map((r) => r.hoursDeltaPct);
  assert.deepEqual(pcts, [...pcts].sort((a, b) => b - a));
});

test('the rule is what the Electron screen actually calls', () => {
  // The recurring bug in this codebase is a correct, tested module with no
  // caller — `compareToEstimate` had seven tests and zero callers while
  // analytics computed its own average inline, and this panel was a second
  // instance of exactly that. A guard on the call site, because the arithmetic
  // being right is not the same as it being the arithmetic that runs.
  const fs = require('fs');
  const path = require('path');
  const root = path.join(__dirname, '..');
  const js = fs.readFileSync(path.join(root, 'renderer', 'analytics.js'), 'utf8');
  const html = fs.readFileSync(path.join(root, 'renderer', 'index.html'), 'utf8');

  assert.match(js, /KhaytMachineAccuracy\.accuracyByMachine\(/);
  assert.match(js, /KhaytMachineAccuracy\.accuracyOverall\(/);
  assert.match(html, /<script src="\.\.\/lib\/machine-accuracy\.js"><\/script>/);

  // And the wall-clock version is gone rather than merely bypassed. Two panels
  // answering one question, one of them structurally blank, is what this
  // replaced; leaving the old one behind would restore the disagreement.
  assert.ok(!js.includes('timestampAccuracySection'),
    'the duplicate headline panel is still referenced');
  assert.ok(!html.includes('timestampAccuracySection'),
    'the duplicate headline panel still has a node to draw into');
  assert.ok(!/renderMachineAccuracy[\s\S]{0,3000}printingStartedAt/.test(js),
    'the machine panel still reaches for the wall clock');
});

test('the Mac app draws it from the same module', () => {
  // The bundled copy is the same bytes (mac-core-is-not-a-fork.test.js proves
  // that); this proves the copy is REACHED. A module listed and synced but
  // never called would pass every drift guard and draw nothing.
  const fs = require('fs');
  const path = require('path');
  const mac = path.join(__dirname, '..', 'mac', 'KhaytCore', 'Sources');
  const engine = fs.readFileSync(path.join(mac, 'KhaytCore', 'KhaytEngine.swift'), 'utf8');
  const screen = fs.readFileSync(path.join(mac, 'KhaytApp', 'MachineProfit.swift'), 'utf8');
  const reports = fs.readFileSync(path.join(mac, 'KhaytApp', 'Reports.swift'), 'utf8');

  assert.match(engine, /"machine-accuracy",/, 'the module is bundled');
  assert.match(engine, /KhaytMachineAccuracy\.accuracyByMachine/);
  assert.match(engine, /KhaytMachineAccuracy\.accuracyOverall/);
  assert.match(reports, /engine\.machineAccuracy\(/, 'and something asks for it');
  assert.match(reports, /engine\.shopAccuracy\(/);
  assert.match(screen, /Accuracy\(shop: shop, rows: accuracy, all: shopAccuracy\)/,
    'and a view draws the answer');
});
