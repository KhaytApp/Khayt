/**
 * Pricing a model a stranger uploaded.
 *
 * This is the only place Khayt computes a price for someone who is not the shop,
 * so most of these tests are about REFUSING. A zero shown to a customer is a
 * promise of free work; a price built on a spool cost nobody configured is a
 * number the shop never agreed to. Both are worse than "we'll get back to you",
 * which the intake form already does on its own.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { publicQuote, DEFAULT_CONFIG } = require('../lib/public-quote.js');
const KhaytCost = require('../lib/calculator-cost.js');
const KhaytPricing = require('../lib/pricing.js');
const { estimateFromStl } = require('../lib/stl-estimate.js');

const deps = {
  computePartBaseCost: KhaytCost.computePartBaseCost,
  quoteTotal: KhaytPricing.quoteTotal,
  estimate: estimateFromStl,
};

const PRESET = {
  id: 'P1', name: 'A1', wearRate: 0.75, powerDraw: 150, elecRate: 0.18,
  laborRate: 90, failureRate: 10, prepTime: 0.25, postTime: 0.5,
};

const storeWith = (over = {}, quoteOver = {}) => JSON.parse(JSON.stringify({
  settings: {
    currency: 'SAR',
    lanApi: { intakeQuote: Object.assign({
      enabled: true, presetId: 'P1', spoolCost: 90, spoolWeight: 1000, marginPct: 40,
    }, quoteOver) },
  },
  printers: [PRESET],
  inventory: [],
  ...over,
}));

const SLICED = { exact: true, source: 'slicer', printTimeMins: 193, filamentGrams: 41.83, slicer: 'PrusaSlicer' };
const GEOM = { exact: false, source: 'geometry', geometry: { volumeMm3: 8000, bbox: { x: 20, y: 20, z: 20 } } };

const q = (intake, store = storeWith(), extra = {}) => publicQuote({ intake, store, deps, ...extra });

test('it is OFF until the shop turns it on', () => {
  // Nobody should drift into quoting strangers by upgrading.
  assert.equal(DEFAULT_CONFIG.enabled, false);
  const r = q(SLICED, storeWith({}, { enabled: false }));
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'off');
  assert.equal(r.price, null, 'and no number leaks out of a refusal');
});

test('a sliced file prices from the slicer\'s own figures', () => {
  const r = q(SLICED);
  assert.equal(r.ok, true);
  assert.equal(r.exact, true);
  assert.equal(r.slicer, 'PrusaSlicer');
  assert.equal(r.grams, 41.8);
  assert.equal(r.hours, 3.22);
  assert.ok(r.price > 0);
  assert.equal(r.currency, 'SAR');
});

test('an unsliced file prices, but is marked an estimate and names no slicer', () => {
  const r = q(GEOM);
  assert.equal(r.ok, true);
  assert.equal(r.exact, false, 'the customer must be told this is not measured');
  assert.equal(r.source, 'geometry');
  assert.equal(r.slicer, null, 'no slicer produced this — claiming one would be a lie');
  assert.ok(r.price > 0);
});

test('no result is ever binding', () => {
  // The shop confirms every price. This only starts the conversation.
  for (const i of [SLICED, GEOM]) assert.equal(q(i).binding, false);
});

test('an unconfigured shop gets a refusal, not a zero', () => {
  const noMaterial = q(SLICED, storeWith({}, { spoolCost: 0, spoolWeight: 0 }));
  assert.equal(noMaterial.ok, false);
  assert.equal(noMaterial.reason, 'not-configured');
  assert.equal(noMaterial.missing, 'material');

  const noPreset = q(SLICED, storeWith({}, { presetId: '' }));
  assert.equal(noPreset.ok, false);
  assert.equal(noPreset.missing, 'printer');

  for (const r of [noMaterial, noPreset]) assert.equal(r.price, null);
});

test('a configured printer that no longer exists refuses rather than guessing', () => {
  // Deleting the preset must break the quote loudly, not silently price at zero
  // machine cost.
  const r = q(SLICED, storeWith({ printers: [] }));
  assert.equal(r.ok, false);
  assert.equal(r.missing, 'printer');
});

test('a configured filament that no longer exists refuses too', () => {
  // And specifically does NOT fall back to a flat spoolCost the shop may have
  // set years ago and forgotten.
  const store = storeWith({ inventory: [] }, { filamentId: 'INV-gone', spoolCost: 90, spoolWeight: 1000 });
  const r = q(SLICED, store);
  assert.equal(r.ok, false);
  assert.equal(r.missing, 'material');
});

test('an inventory filament is preferred over the flat basis', () => {
  // It is the price the shop actually pays.
  const cheap = storeWith(
    { inventory: [{ id: 'F1', unitCost: 45, spoolWeight: 1000 }] },
    { filamentId: 'F1', spoolCost: 900, spoolWeight: 1000 });
  const dear = storeWith({}, { spoolCost: 900, spoolWeight: 1000 });
  assert.ok(q(SLICED, cheap).price < q(SLICED, dear).price,
    'the 45/kg inventory item, not the 900 flat figure');
});

test('a file we could not read yields no price', () => {
  for (const i of [
    { exact: false, source: null, warnings: ['unsupported'] },
    { exact: false, source: null, warnings: ['parse-failed'] },
    { exact: false, source: 'geometry', geometry: { volumeMm3: 0, bbox: {} } },
    null,
  ]) {
    const r = q(i);
    assert.equal(r.ok, false, JSON.stringify(i));
    assert.equal(r.reason, 'no-numbers');
  }
});

test('a half-answer from the slicer is not priced as a whole one', () => {
  // Time with no weight would price as though the part used no material.
  const r = q({ exact: true, source: 'slicer', printTimeMins: 120, filamentGrams: 0 });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'no-numbers');

  // And a file that CLAIMS exact but carries no figures must fall through to its
  // geometry rather than being refused — trusting the flag alone loses a quote
  // we could perfectly well have given.
  const claimsExact = q({
    exact: true, source: 'geometry', printTimeMins: 0, filamentGrams: 0,
    geometry: { volumeMm3: 8000, bbox: { x: 20, y: 20, z: 20 } },
  });
  assert.equal(claimsExact.ok, true, 'priced from geometry');
  assert.equal(claimsExact.exact, false, 'and not called exact');
});

test('an absurd cost never reaches a customer as a number', () => {
  // A misconfigured spool (weight 0 → division) can produce Infinity. Rounding
  // Infinity is still Infinity, and "Infinity SAR" is worse than no answer.
  const boom = { computePartBaseCost: () => Infinity, quoteTotal: deps.quoteTotal };
  const r1 = publicQuote({ intake: SLICED, store: storeWith(), deps: boom });
  assert.equal(r1.ok, false);
  assert.equal(r1.reason, 'no-price');

  for (const bad of [NaN, -5, -0.0001]) {
    const d = { computePartBaseCost: () => bad, quoteTotal: deps.quoteTotal };
    const r = publicQuote({ intake: SLICED, store: storeWith(), deps: d });
    assert.equal(r.ok, false, String(bad));
    assert.equal(r.price, null, String(bad));
  }
});

test('a stale slicer name is not attached to an estimate', () => {
  // Naming a slicer implies the figures came from one. On a geometric estimate
  // that is a claim the file does not support.
  const r = q({
    exact: false, source: 'geometry', slicer: 'PrusaSlicer',
    geometry: { volumeMm3: 8000, bbox: { x: 20, y: 20, z: 20 } },
  });
  assert.equal(r.ok, true);
  assert.equal(r.exact, false);
  assert.equal(r.slicer, null, 'the estimate must not borrow a slicer\'s authority');
});

test('waste is added to the customer\'s weight, and is capped', () => {
  const none = q(SLICED, storeWith({}, { wastePct: 0 }));
  const some = q(SLICED, storeWith({}, { wastePct: 0.1 }));
  assert.ok(some.grams > none.grams);
  assert.ok(Math.abs(some.grams - 41.83 * 1.1) < 0.2);
  // A typo of 500% must not multiply a customer's quote by six.
  const absurd = q(SLICED, storeWith({}, { wastePct: 5 }));
  assert.ok(absurd.grams <= 41.83 * 1.5 + 0.1, `capped, got ${absurd.grams}`);
});

test('a minimum price is a floor, never a ceiling', () => {
  const tiny = { exact: true, source: 'slicer', printTimeMins: 1, filamentGrams: 0.1 };
  const withFloor = q(tiny, storeWith({}, { minPrice: 250 }));
  assert.equal(withFloor.price, 250);
  // A big job is not dragged down to the floor.
  const big = q(SLICED, storeWith({}, { minPrice: 10 }));
  assert.ok(big.price > 10);
});

test('margin raises the price and is the shop\'s own number', () => {
  const none = q(SLICED, storeWith({}, { marginPct: 0 }));
  const fat = q(SLICED, storeWith({}, { marginPct: 100 }));
  assert.ok(fat.price > none.price);
  assert.ok(Math.abs(fat.price - none.price * 2) < 0.05, 'margin applies to the whole cost');
});

test('quantity is bounded so a request cannot ask for a million units', () => {
  assert.equal(q(SLICED, storeWith(), { qty: 5 }).qty, 5);
  assert.equal(q(SLICED, storeWith(), { qty: 0 }).qty, 1);
  assert.equal(q(SLICED, storeWith(), { qty: -3 }).qty, 1);
  assert.equal(q(SLICED, storeWith(), { qty: 999999 }).qty, 1000);
  assert.equal(q(SLICED, storeWith(), { qty: 'abc' }).qty, 1);
});

test('more units cost more', () => {
  assert.ok(q(SLICED, storeWith(), { qty: 4 }).price > q(SLICED, storeWith(), { qty: 1 }).price);
});

test('a broken cost engine refuses instead of throwing at a customer', () => {
  const boom = { computePartBaseCost: () => { throw new Error('x'); }, quoteTotal: deps.quoteTotal };
  assert.equal(publicQuote({ intake: SLICED, store: storeWith(), deps: boom }).reason, 'no-price');

  const boom2 = { computePartBaseCost: deps.computePartBaseCost, quoteTotal: () => { throw new Error('x'); } };
  assert.equal(publicQuote({ intake: SLICED, store: storeWith(), deps: boom2 }).reason, 'no-price');

  assert.equal(publicQuote({ intake: SLICED, store: storeWith(), deps: null }).reason, 'no-price');
  assert.doesNotThrow(() => publicQuote(null));
  assert.doesNotThrow(() => publicQuote({}));
});

test('a cost of zero is never turned into a price', () => {
  // Every cost input at zero means the shop has not really configured this.
  const free = storeWith({ printers: [{ id: 'P1', name: 'free' }] }, { spoolCost: 0.0000001, spoolWeight: 1e9 });
  const r = q(SLICED, free);
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'no-price');
  assert.equal(r.price, null);
});

test('the public price matches what the shop\'s own calculator would say', () => {
  // Two implementations of one price means two prices, and the customer sees
  // whichever one the shop is not looking at.
  const store = storeWith();
  const r = q(SLICED, store);
  const cfg = store.settings.lanApi.intakeQuote;
  const unitCost = KhaytCost.computePartBaseCost({
    qty: 1, printWeight: 41.83, printTime: 193 / 60,
    spoolCost: cfg.spoolCost, spoolWeight: cfg.spoolWeight,
    wearRate: PRESET.wearRate, powerDraw: PRESET.powerDraw, elecRate: PRESET.elecRate,
    laborRate: PRESET.laborRate, failureRate: PRESET.failureRate,
    prepTime: PRESET.prepTime, postTime: PRESET.postTime,
  }, { inventory: [], settings: store.settings });
  const expected = KhaytPricing.quoteTotal({
    baseCost: unitCost, qty: 1, margin: cfg.marginPct,
    discountPct: 0, rushEnabled: false, shippingCost: 0, extraLines: [],
  });
  assert.equal(r.price, Math.round(expected.total * 100) / 100);
});

test('a customer\'s estimate uses the SHOP\'s assumptions, not the module defaults', () => {
  // The two must not disagree about the same part. A shop that has told Khayt it
  // runs 60% infill should not have customers quoted at the built-in 20%.
  const store = storeWith();
  const dense = publicQuote({
    intake: GEOM, store,
    deps: { ...deps, estimatorOpts: { infillPct: 0.9, densityGPerCm3: 1.24, shellFactor: 0.35, throughputMm3PerS: 8, wastePct: 0 } },
  });
  const sparse = publicQuote({
    intake: GEOM, store,
    deps: { ...deps, estimatorOpts: { infillPct: 0.05, densityGPerCm3: 1.24, shellFactor: 0.35, throughputMm3PerS: 8, wastePct: 0 } },
  });
  assert.ok(dense.grams > sparse.grams, `${dense.grams} should exceed ${sparse.grams}`);
  assert.ok(dense.price > sparse.price, 'and the customer pays more for the denser part');
});

test('a calibrated throughput reaches the customer\'s quote', () => {
  // The point of lib/estimate-calibration.js: a rate learned from the shop's own
  // measured jobs must change what a customer is told, not just what the shop
  // sees on its own screen.
  const store = storeWith();
  const base = { infillPct: 0.2, densityGPerCm3: 1.24, shellFactor: 0.35, wastePct: 0 };
  const guessed = publicQuote({ intake: GEOM, store,
    deps: { ...deps, estimatorOpts: { ...base, throughputMm3PerS: 8 } } });
  const measuredRate = publicQuote({ intake: GEOM, store,
    deps: { ...deps, estimatorOpts: { ...base, throughputMm3PerS: 2.7 } } });
  assert.ok(measuredRate.hours > guessed.hours, 'a slower real machine means a longer job');
  assert.ok(measuredRate.price > guessed.price, 'and machine time is charged for');
  assert.equal(measuredRate.grams, guessed.grams, 'the weight is unaffected — only the time was guessed');
});

test('with no estimator options it still works, on the documented defaults', () => {
  const r = publicQuote({ intake: GEOM, store: storeWith(), deps });
  assert.equal(r.ok, true);
  assert.ok(r.price > 0);
});

/**
 * Whether the customer is told the number is shaky.
 *
 * lib/stl-estimate.js decides this; publicQuote's job is to carry it out to the
 * customer unchanged. Scored against a real slicer, geometry outside the
 * model's range lands between +58% and -66% — a figure this shop would not
 * stand behind must not arrive looking like one it would.
 */
test('a quote says whether its estimate can be trusted', () => {
  // A blocky part is squarely in range.
  const blocky = q({ exact: false, source: 'geometry',
    geometry: { volumeMm3: 64000, areaMm2: 9600, bbox: { x: 40, y: 40, z: 40 } } });
  assert.equal(blocky.ok, true, JSON.stringify(blocky));
  assert.equal(blocky.reliable, true);

  // A HueForge-style relief: enormous surface for its volume.
  const relief = q({ exact: false, source: 'geometry',
    geometry: { volumeMm3: 2419, areaMm2: 2419 * 5.656, bbox: { x: 100, y: 100, z: 2 } } });
  assert.equal(relief.ok, true, 'still quoted — the shop may want a rough figure');
  assert.equal(relief.reliable, false, 'but it must not be presented as dependable');
  assert.ok(relief.price > 0);
});

test('a sliced file is always reliable — the estimator never touched it', () => {
  const r = q(SLICED);
  assert.equal(r.ok, true, JSON.stringify(r));
  assert.equal(r.exact, true);
  assert.equal(r.reliable, true,
    'exact figures come off a slicer; only the geometric estimate can fall out of range');
});
