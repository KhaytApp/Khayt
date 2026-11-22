const { test } = require('node:test');
const assert = require('node:assert/strict');

const V = require('../lib/estimate-variance.js');
const Link = require('../lib/order-file-link.js');
const Actuals = require('../lib/printer-actuals.js');

const deps = { allocate: (o) => Link.allocateActuals(o), compare: Actuals.compareToEstimate };

/** One finished job of one model, with figures a printer reported. */
const job = (over = {}) => ({
  date: over.date || '2026-08-01',
  project: over.project || 'Bracket',
  status: 'completed',
  actualPrintTime: over.actH,
  actualWeight: over.actG,
  actualsSource: over.typed ? undefined : { time: 'moonraker', weight: 'moonraker' },
  parts: [{
    id: 'p1', printFileId: over.file || 'f-bracket', qty: 1,
    printTime: over.estH, printWeight: over.estG,
  }],
});

test('it uses the tested comparison rather than a second copy of it', () => {
  // compareToEstimate had seven tests and zero callers while analytics computed
  // its own average inline. Two implementations of one calculation is the shape
  // that let three storefronts drift; this closes it by consuming the tested one.
  const src = require('fs').readFileSync(require('path').join(__dirname, '..', 'lib', 'estimate-variance.js'), 'utf8');
  assert.ok(/compare\(\{ printTime/.test(src), 'the injected comparison is called per job');
  assert.ok(!/actualHours\s*-\s*est/.test(src), 'and no variance arithmetic is re-derived here');
});

test('a model that costs more than it was quoted says so, and by how much', () => {
  // The sentence the whole feature exists for.
  const orders = [
    job({ estG: 41, estH: 3.2, actG: 48, actH: 3.3 }),
    job({ estG: 41, estH: 3.2, actG: 49, actH: 3.3, date: '2026-08-02' }),
    job({ estG: 41, estH: 3.2, actG: 48, actH: 3.3, date: '2026-08-03' }),
  ];
  const [row] = V.varianceByModel(orders, deps);
  assert.equal(row.printFileId, 'f-bracket');
  assert.equal(row.sampled, 3);
  assert.equal(row.confidence, 'fair');
  assert.equal(row.estGrams, 41);
  assert.equal(row.actGrams, 48);
  assert.ok(row.gramsDeltaPct > 16 && row.gramsDeltaPct < 20, `got ${row.gramsDeltaPct}`);

  const a = V.advice(row);
  assert.ok(a, 'this one earns a sentence');
  assert.equal(a.axis, 'filament');
  assert.equal(a.pct, 17, '48 g against a 41 g quote is +17%, not a rounder number');
  assert.equal(a.sampled, 3);
});

test('a typed actual is not a measurement and never counts', () => {
  // A typed actual is usually the estimate confirmed. Including them would mean
  // comparing an estimate to itself and reporting a variance near zero — the
  // exact failure printer-actuals.js exists to end, recreated one level up.
  const typed = [job({ estG: 41, estH: 3.2, actG: 60, actH: 5, typed: true })];
  assert.deepEqual(V.varianceByModel(typed, deps), []);

  // The same figures, measured, do count.
  assert.equal(V.varianceByModel([job({ estG: 41, estH: 3.2, actG: 60, actH: 5 })], deps).length, 1);
});

test('a divided job is not a measurement of any one part', () => {
  // A multi-part job's per-part figures are a proportional share of one total.
  // That is a fair way to split a bill and not a reading of anything.
  const multi = {
    date: '2026-08-01', status: 'completed', actualPrintTime: 6, actualWeight: 100,
    actualsSource: { time: 'moonraker', weight: 'moonraker' },
    parts: [
      { id: 'a', printFileId: 'f-a', qty: 1, printTime: 3, printWeight: 40 },
      { id: 'b', printFileId: 'f-b', qty: 1, printTime: 3, printWeight: 40 },
    ],
  };
  assert.deepEqual(V.varianceByModel([multi], deps), [], 'nothing exact, nothing reported');
});

test('one print is reported as one print, not as a percentage to trust', () => {
  const [row] = V.varianceByModel([job({ estG: 41, estH: 3.2, actG: 60, actH: 5 })], deps);
  assert.equal(row.sampled, 1);
  assert.equal(row.confidence, 'thin');
  // …and a single sample earns no advice however far out it is.
  assert.equal(V.advice(row), null, 'one print is an anecdote');

  const five = Array.from({ length: 5 }, (_, i) => job({ estG: 41, estH: 3.2, actG: 60, actH: 5, date: `2026-08-0${i + 1}` }));
  assert.equal(V.varianceByModel(five, deps)[0].confidence, 'good');
});

test('the median ignores the one job that went wrong', () => {
  // Mean would let a single failed print rewrite a model's price.
  const orders = [
    job({ estG: 40, estH: 4, actG: 41, actH: 4.1 }),
    job({ estG: 40, estH: 4, actG: 42, actH: 4.2, date: '2026-08-02' }),
    job({ estG: 40, estH: 4, actG: 400, actH: 40, date: '2026-08-03' }),  // jammed, rescued, restarted
  ];
  const [row] = V.varianceByModel(orders, deps);
  assert.equal(row.actGrams, 42, 'the middle print, not the average');
  assert.ok(row.gramsDeltaPct < 10, `a rescue must not become a price change, got ${row.gramsDeltaPct}`);
});

test('worst first, on whichever axis is further out', () => {
  // Two prints each: advice() refuses a single sample, so one job per model
  // would test the sort and prove nothing about the sentence.
  const twice = (o) => [job(o), job({ ...o, date: '2026-08-02' })];
  const rows = V.varianceByModel([
    ...twice({ file: 'f-slow', project: 'Slow', estG: 40, estH: 4, actG: 40, actH: 6 }),  // +50% time
    ...twice({ file: 'f-fat', project: 'Fat', estG: 40, estH: 4, actG: 52, actH: 4 }),    // +30% filament
    ...twice({ file: 'f-ok', project: 'Fine', estG: 40, estH: 4, actG: 40, actH: 4 }),    // spot on
  ], deps);
  assert.deepEqual(rows.map((r) => r.printFileId), ['f-slow', 'f-fat', 'f-ok']);
  // Sorting on filament alone would have buried the model that takes half as
  // long again as quoted.
  assert.equal(V.advice(rows[0]).axis, 'time');
  assert.equal(V.advice(rows[1]).axis, 'filament');
  assert.equal(V.advice(rows[2]), null);
});

test('over-quoting is not reported as a problem', () => {
  // A shop charging too much hears about it from its customers. Reporting every
  // wobble as news is how a panel stops being read.
  const [row] = V.varianceByModel([
    job({ estG: 60, estH: 6, actG: 40, actH: 4 }),
    job({ estG: 60, estH: 6, actG: 40, actH: 4, date: '2026-08-02' }),
  ], deps);
  assert.ok(row.gramsDeltaPct < 0, 'the number is still shown');
  assert.equal(V.advice(row), null, 'it just does not get a sentence');
});

test('percentages are rounded to something the data supports', () => {
  // Averaging two numbers hands back -1.9499999999999997, which is float noise
  // wearing the clothes of precision.
  const [row] = V.varianceByModel([
    job({ estG: 100, estH: 10, actG: 101, actH: 9.8 }),
    job({ estG: 100, estH: 10, actG: 102, actH: 9.81, date: '2026-08-02' }),
  ], deps);
  const places = (v) => (String(v).split('.')[1] || '').length;
  for (const v of [row.gramsDeltaPct, row.hoursDeltaPct, row.estGrams, row.actGrams, row.estHours, row.actHours]) {
    assert.ok(places(v) <= 2, `${v} has ${places(v)} decimal places`);
  }
  // And the specific noise this rounding exists for.
  assert.ok(!String(row.hoursDeltaPct).includes('999'), `float noise survived: ${row.hoursDeltaPct}`);
});

test('junk in never becomes a price recommendation', () => {
  for (const bad of [null, undefined, 'nope', [], [null], [{}], [{ parts: 'x' }]]) {
    assert.deepEqual(V.varianceByModel(bad, deps), [], JSON.stringify(bad));
  }
  // Missing dependencies are refused rather than half-run.
  assert.deepEqual(V.varianceByModel([job({ estG: 1, estH: 1, actG: 2, actH: 2 })], {}), []);
  assert.deepEqual(V.varianceByModel([job({ estG: 1, estH: 1, actG: 2, actH: 2 })], { allocate: deps.allocate }), []);
  for (const bad of [null, undefined, {}, { sampled: 0 }]) assert.equal(V.advice(bad), null);
});

test('a part with no print file has nothing to attribute a cost to', () => {
  const orphan = job({ estG: 40, estH: 4, actG: 50, actH: 5 });
  orphan.parts[0].printFileId = null;
  assert.deepEqual(V.varianceByModel([orphan], deps), []);
});
