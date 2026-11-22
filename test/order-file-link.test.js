/**
 * Joining an order to the model it printed and the settings it used.
 *
 * Three modules learned something useful and none could reach the others:
 * what a job actually cost, which settings worked, and which file this is. The
 * join makes the real question answerable — for THIS part with THESE settings,
 * how far out is my estimate?
 *
 * The care here is not in the join, it is in the arithmetic. A printer reports
 * ONE duration for a job that may contain four parts. Dividing that by the
 * parts' estimates is an apportionment, and a circular one: it uses the estimate
 * to split the very number meant to check the estimate. These tests mostly exist
 * to keep that apart from a real measurement.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  partEstimate, linkedParts, allocateActuals,
  setupPerformance, fileHistory, outcomesForOrder,
} = require('../lib/order-file-link.js');

const part = (o = {}) => Object.assign(
  { id: 'p1', printFileId: 'F1', setupId: 'S1', printTime: 3, printWeight: 40, qty: 1 }, o);
const measured = { time: 'moonraker', weight: 'moonraker' };

test('a part\'s estimate covers the whole line, not one unit', () => {
  assert.deepEqual(partEstimate(part({ qty: 3 })), { hours: 9, grams: 120 });
  // Support material is filament the shop paid for.
  assert.deepEqual(partEstimate(part({ supportWeight: 10 })), { hours: 3, grams: 50 });
  assert.deepEqual(partEstimate({}), { hours: 0, grams: 0 });
  assert.deepEqual(partEstimate(null), { hours: 0, grams: 0 });
  // A negative figure on a part is corrupt data, not a credit. Letting it
  // through would make one bad row cancel out other parts' real estimates and
  // silently shrink the total the actuals get divided against.
  assert.deepEqual(partEstimate({ printTime: -3, printWeight: 40 }), { hours: 0, grams: 40 });
  assert.deepEqual(partEstimate({ printTime: 3, printWeight: 40, supportWeight: -100 }), { hours: 3, grams: 40 });
  // A missing qty is one, not zero — otherwise the whole line vanishes.
  assert.deepEqual(partEstimate(part({ qty: 0 })), { hours: 3, grams: 40 });
});

test('a single-part order is EXACT — nothing was divided', () => {
  const order = { actualPrintTime: 3.5, actualWeight: 44, actualsSource: measured, parts: [part()] };
  const [a] = allocateActuals(order);
  assert.equal(a.exact, true);
  assert.equal(a.actHours, 3.5, 'the job\'s hours ARE this part\'s hours');
  assert.equal(a.actGrams, 44);
  assert.equal(a.measured, true);
});

test('a multi-part order is apportioned, and says so', () => {
  const order = {
    actualPrintTime: 6, actualWeight: 90, actualsSource: measured,
    parts: [part({ id: 'a', printTime: 2, printWeight: 30 }), part({ id: 'b', printTime: 4, printWeight: 60 })],
  };
  const [a, b] = allocateActuals(order);
  assert.equal(a.exact, false, 'this is an assumption wearing a measurement\'s clothes');
  assert.equal(b.exact, false);
  // Split by each part's share of the estimate: 2/6 and 4/6.
  assert.ok(Math.abs(a.actHours - 2) < 1e-9);
  assert.ok(Math.abs(b.actHours - 4) < 1e-9);
  assert.ok(Math.abs(a.actGrams - 30) < 1e-9);
  assert.ok(Math.abs(b.actGrams - 60) < 1e-9);
  // The split must conserve the measurement.
  assert.ok(Math.abs((a.actHours + b.actHours) - 6) < 1e-9);
  assert.ok(Math.abs((a.actGrams + b.actGrams) - 90) < 1e-9);
});

test('an order nobody measured contributes NOTHING, not zeros', () => {
  // Zeros would drag every average toward "the estimate was infinitely
  // optimistic", which is worse than having no data.
  assert.deepEqual(allocateActuals({ parts: [part()] }), []);
  assert.deepEqual(allocateActuals({ actualPrintTime: 0, actualWeight: 0, parts: [part()] }), []);
  assert.deepEqual(allocateActuals({ actualPrintTime: 3, parts: [] }), []);
  assert.deepEqual(allocateActuals(null), []);
});

test('a half-measured order still contributes the half it has', () => {
  // Time measured, weight never entered. The hours are real.
  const order = { actualPrintTime: 3.5, actualWeight: 0, actualsSource: measured, parts: [part()] };
  const [a] = allocateActuals(order);
  assert.equal(a.actHours, 3.5);
  assert.equal(a.actGrams, 0, 'and the weight stays absent rather than invented');
});

test('parts with no estimate split evenly rather than dividing by zero', () => {
  const order = {
    actualPrintTime: 4, actualWeight: 20, actualsSource: measured,
    parts: [part({ id: 'a', printTime: 0, printWeight: 0 }), part({ id: 'b', printTime: 0, printWeight: 0 })],
  };
  const [a, b] = allocateActuals(order);
  assert.equal(a.actHours, 2);
  assert.equal(b.actHours, 2);
  assert.ok(Number.isFinite(a.actGrams) && Number.isFinite(b.actGrams));
});

test('a typed actual is an actual, but is not a measurement', () => {
  // R3 records where the figures came from. Both count as jobs; only one counts
  // as measured, and a shop reading a variance deserves to know which.
  const typed = { actualPrintTime: 3.5, actualWeight: 44, parts: [part()],
    actualsSource: { time: 'manual', weight: 'manual' } };
  assert.equal(allocateActuals(typed)[0].measured, false);

  const half = { actualPrintTime: 3.5, actualWeight: 44, parts: [part()],
    actualsSource: { time: 'moonraker', weight: 'manual' } };
  assert.equal(allocateActuals(half)[0].measured, true, 'one measured axis is enough to count');

  const none = { actualPrintTime: 3.5, actualWeight: 44, parts: [part()] };
  assert.equal(allocateActuals(none)[0].measured, false, 'no provenance recorded — assume typed');
});

test('performance answers the question for one file and one setup', () => {
  const orders = [
    { actualPrintTime: 3.5, actualWeight: 44, actualsSource: measured, parts: [part()] },
    { actualPrintTime: 3.2, actualWeight: 41, actualsSource: measured, parts: [part({ id: 'p2' })] },
  ];
  const p = setupPerformance(orders, { printFileId: 'F1', setupId: 'S1' });
  assert.equal(p.jobs, 2);
  assert.equal(p.exactJobs, 2);
  assert.equal(p.measuredJobs, 2);
  assert.equal(p.estHours, 6);
  assert.equal(p.actHours, 6.7);
  assert.equal(p.hoursDeltaPct, 11.7, 'the estimate runs about 12% under');
});

test('exactOnly excludes the apportioned jobs it is meant to exclude', () => {
  // The whole point of tracking them apart. A four-part job divided by
  // assumption must not dilute eleven clean single-part measurements.
  const orders = [
    { actualPrintTime: 3.5, actualWeight: 44, actualsSource: measured, parts: [part()] },
    { actualPrintTime: 6, actualWeight: 90, actualsSource: measured,
      parts: [part({ id: 'a' }), part({ id: 'b', printFileId: 'F2', setupId: 'S9', printWeight: 50 })] },
  ];
  const all = setupPerformance(orders, { printFileId: 'F1' });
  const exact = setupPerformance(orders, { printFileId: 'F1', exactOnly: true });
  assert.equal(all.jobs, 2);
  assert.equal(all.exactJobs, 1);
  assert.equal(all.apportionedJobs, 1);
  assert.equal(exact.jobs, 1);
  assert.equal(exact.apportionedJobs, 0);
  assert.notEqual(all.hoursDeltaPct, exact.hoursDeltaPct,
    'the apportioned job really was pulling the number — that is why they are separate');
});

test('a file with no history reports nothing rather than a perfect estimate', () => {
  // 0% variance means "spot on". No data must not render as that.
  const p = setupPerformance([], { printFileId: 'F1' });
  assert.equal(p.jobs, 0);
  assert.equal(p.hoursDeltaPct, null);
  assert.equal(p.gramsDeltaPct, null);
  assert.equal(setupPerformance([{ parts: [part()] }], { printFileId: 'F1' }).jobs, 0);
});

test('performance without a file id answers nothing', () => {
  // Otherwise a missing id would silently aggregate the whole shop.
  for (const q of [null, {}, { setupId: 'S1' }]) {
    assert.equal(setupPerformance([{ actualPrintTime: 3, parts: [part()] }], q).jobs, 0, JSON.stringify(q));
  }
});

test('a setup filter does not leak other setups in', () => {
  const orders = [
    { actualPrintTime: 3.5, actualWeight: 44, parts: [part({ setupId: 'S1' })] },
    { actualPrintTime: 9, actualWeight: 99, parts: [part({ id: 'p2', setupId: 'S2' })] },
  ];
  assert.equal(setupPerformance(orders, { printFileId: 'F1', setupId: 'S1' }).jobs, 1);
  assert.equal(setupPerformance(orders, { printFileId: 'F1', setupId: 'S1' }).actHours, 3.5);
  assert.equal(setupPerformance(orders, { printFileId: 'F1' }).jobs, 2, 'unfiltered sees both');
});

test('fileHistory lists every setup the file has been printed with', () => {
  const orders = [
    { actualPrintTime: 3.5, actualWeight: 44, parts: [part({ setupId: 'S1' })] },
    { actualPrintTime: 2.9, actualWeight: 38, parts: [part({ id: 'p2', setupId: 'S2' })] },
    { actualPrintTime: 3.4, actualWeight: 43, parts: [part({ id: 'p3', setupId: 'S1' })] },
  ];
  const h = fileHistory(orders, 'F1');
  assert.equal(h.length, 2, 'two distinct setups');
  const s1 = h.find((x) => x.setupId === 'S1');
  assert.equal(s1.jobs, 2);
  assert.deepEqual(fileHistory(orders, 'nope'), []);
  assert.deepEqual(fileHistory(orders, null), []);
});

test('one job with one setup is ONE outcome, however many parts', () => {
  // Counting a four-part order four times would let a single job make a setup
  // look proven — which is precisely what lib/print-setups.js is built to
  // resist.
  const order = { parts: [
    part({ id: 'a' }), part({ id: 'b' }), part({ id: 'c' }), part({ id: 'd' }),
  ] };
  const out = outcomesForOrder(order, true);
  assert.equal(out.length, 1);
  assert.deepEqual(out[0], { printFileId: 'F1', setupId: 'S1', ok: true });
});

test('an order spanning two setups records against both', () => {
  const order = { parts: [part({ id: 'a' }), part({ id: 'b', printFileId: 'F2', setupId: 'S9' })] };
  const out = outcomesForOrder(order, false);
  assert.equal(out.length, 2);
  assert.ok(out.every((o) => o.ok === false));
});

test('parts with no setup record nothing', () => {
  // A part linked to a file but not to settings has nothing to teach.
  assert.deepEqual(outcomesForOrder({ parts: [part({ setupId: null })] }, true), []);
  assert.deepEqual(outcomesForOrder({ parts: [{ id: 'x' }] }, true), []);
  assert.deepEqual(outcomesForOrder(null, true), []);
});

test('linkedParts finds only the parts that name a file', () => {
  const order = { parts: [part(), { id: 'loose', printTime: 1 }, null] };
  assert.deepEqual(linkedParts(order).map((p) => p.id), ['p1']);
  assert.deepEqual(linkedParts(null), []);
  assert.deepEqual(linkedParts({ parts: 'nope' }), []);
});

test('junk orders never become numbers', () => {
  for (const bad of [null, undefined, 'x', 42, [], {}]) {
    assert.doesNotThrow(() => allocateActuals(bad), JSON.stringify(bad));
    assert.deepEqual(allocateActuals(bad), [], JSON.stringify(bad));
  }
  assert.equal(setupPerformance(null, { printFileId: 'F1' }).jobs, 0);
  assert.equal(setupPerformance([null, 5, 'x'], { printFileId: 'F1' }).jobs, 0);
  const negative = { actualPrintTime: -5, actualWeight: -5, parts: [part()] };
  assert.deepEqual(allocateActuals(negative), [], 'a negative actual is not an actual');

  // One bad axis and one good one: the good half must survive and the bad half
  // must land on zero, not carry a negative duration into the job's history.
  // With negatives on BOTH axes the early return hides this entirely.
  const halfNegative = { actualPrintTime: -5, actualWeight: 44, parts: [part()] };
  const [a] = allocateActuals(halfNegative);
  assert.equal(a.actGrams, 44, 'the usable figure is kept');
  assert.equal(a.actHours, 0, 'and the impossible one is dropped');
  assert.ok(a.actHours >= 0, 'never a negative duration');
});
