/**
 * `lib/quote-sheet.js` — the shop's pricing inputs, published for a storefront
 * to quote uploads with Khayt's own calculator.
 *
 * THE TEST THAT MATTERS is the first one: for a spread of parts, a price
 * reached from the shop's real book and a price reached from
 * `toStore(build(book))` must be the SAME number. That is the promise made to
 * the shop — "Khayt's calculator, not a second one" — and it is only kept if
 * the sheet carries everything the price depends on and nothing drifts in the
 * round trip.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/tax.js');
require('../lib/spool-edit.js');
const PQ = require('../lib/public-quote.js');
const QS = require('../lib/quote-sheet.js');
const { computePartBaseCost } = require('../lib/calculator-cost.js');
const { quoteTotal } = require('../lib/pricing.js');
const Stl = require('../lib/stl-estimate.js');

const book = ({ settings, ...over } = {}) => ({
  settings: {
    // A VAT-registered Saudi shop, which reclaims the tax on what it buys.
    currency: 'SAR', defaultPackagingCost: 4.5, country: 'SA', enableVat: true, vatRate: 15,
    lanApi: { intakeQuote: { enabled: true, presetId: 'P1', filamentId: 'INV-1', marginPct: 40,
                             minPrice: 25, wastePct: 0.08 } },
    ...settings,
  },
  printers: [{ id: 'P1', name: 'U1', wearRate: 0.6, powerDraw: 350, elecRate: 0.18, laborRate: 40,
               failureRate: 5, prepTime: 0.1, postTime: 0.25 }],
  inventory: [{ id: 'INV-1', material: 'Sunlu PETG', materialType: 'fdm', cost: 85, vatAmount: 11.09,
                weight: 700, spoolWeight: 1000 }],
  printLog: [],
  ...over,
});

const estimatorOpts = { densityGPerCm3: 1.27, infillPct: 0.2, wallThicknessMm: 1.2, wastePct: 0.05 };
const deps = (opts) => ({ computePartBaseCost, quoteTotal, estimate: Stl.estimateFromStl, estimatorOpts: opts });

const intakes = [
  { exact: true, printTimeMins: 95, filamentGrams: 41.2, slicer: 'OrcaSlicer' },
  { exact: true, printTimeMins: 7, filamentGrams: 3.1 },           // below the minimum price
  { exact: true, printTimeMins: 1440, filamentGrams: 820 },         // a day-long plate
  { source: 'geometry', geometry: { volumeMm3: 42000, surfaceAreaMm2: 9800, bboxMm: [60, 40, 30] } },
  { source: 'geometry', geometry: { volumeMm3: 350000, surfaceAreaMm2: 41000, bboxMm: [120, 90, 80] } },
];

test('a price from the sheet is the price from the book, for every part and quantity', () => {
  let priced = 0;
  for (const variant of [{}, { settings: { enableVat: false } }]) {
    const store = book(variant);
    const sheet = QS.build(store, { now: new Date('2026-09-23T10:00:00Z'), staleAfterHours: 168, estimatorOpts });
    assert.ok(sheet, 'a configured shop published nothing');
    const rebuilt = QS.toStore(JSON.parse(JSON.stringify(sheet)));   // across the wire
    for (const intake of intakes) {
      for (const qty of [1, 3, 25]) {
        const fromBook = PQ.publicQuote({ intake, store, qty, deps: deps(estimatorOpts) });
        const fromSheet = PQ.publicQuote({ intake, store: rebuilt, qty, deps: deps(sheet.estimator) });
        assert.deepEqual(fromSheet, fromBook,
          `${JSON.stringify(intake).slice(0, 60)} ×${qty}: the web would quote differently from the shop`);
        if (fromBook.ok) priced += 1;
      }
    }
  }
  // Two refusals are equal too. Most of these must be real prices, or the
  // comparison above proves nothing.
  assert.ok(priced >= 24, `only ${priced} of 30 quotes were prices`);
});

test('the material is published net of the tax a registered shop reclaims', () => {
  const sheet = QS.build(book(), { estimatorOpts });
  assert.ok(sheet.material.spoolCost < 85, 'a Saudi shop reclaims VAT, so the spool costs a print less than 85');
  const us = QS.build(book({ settings: { enableVat: false } }), { estimatorOpts });
  assert.equal(us.material.spoolCost, 85, 'a shop that reclaims nothing pays what it paid');
  assert.equal(sheet.material.name, 'Sunlu PETG');
});

test('nothing is published when public pricing is off or unconfigured — null withdraws it', () => {
  const off = book(); off.settings.lanApi.intakeQuote.enabled = false;
  assert.equal(QS.build(off, { estimatorOpts }), null);
  const noPrinter = book(); noPrinter.printers = [];
  assert.equal(QS.build(noPrinter, { estimatorOpts }), null);
  const noMaterial = book(); noMaterial.inventory = [];
  assert.equal(QS.build(noMaterial, { estimatorOpts }), null, 'a configured filament that is gone is not a flat price');
});

test('the sheet carries no inventory, queue or customer — only what the price is made of', () => {
  const sheet = QS.build(book({ clients: [{ name: 'Nora' }] }), { estimatorOpts: { ...estimatorOpts, note: 'x' } });
  assert.deepEqual(Object.keys(sheet).sort(), ['computedAt', 'currency', 'estimator', 'marginPct', 'material',
    'minPrice', 'packagingCost', 'printer', 'staleAfterHours', 'v', 'wastePct']);
  assert.deepEqual(Object.keys(sheet.printer).sort(), [...QS.PRINTER_FIELDS].sort());
  assert.equal('note' in sheet.estimator, false, 'only numbers go to the estimator');
  assert.ok(!JSON.stringify(sheet).includes('Nora'));
});

test('a sheet past its staleAfterHours is stale', () => {
  const sheet = QS.build(book(), { now: new Date('2026-09-01T00:00:00Z'), staleAfterHours: 24, estimatorOpts });
  assert.equal(QS.stale(sheet, new Date('2026-09-01T23:00:00Z')), false);
  assert.equal(QS.stale(sheet, new Date('2026-09-02T01:00:00Z')), true);
  assert.equal(QS.stale({}, new Date()), true);
});

test('it loads without require, as JavaScriptCore loads it', () => {
  const fs = require('node:fs');
  const path = require('node:path');
  const vm = require('node:vm');
  const c = {};
  vm.createContext(c);
  for (const m of ['tax', 'spool-edit', 'public-quote', 'quote-sheet']) {
    vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', `${m}.js`), 'utf8'), c);
  }
  const sheet = vm.runInContext(`KhaytQuoteSheet.build(${JSON.stringify(book())}, { estimatorOpts: {} })`, c);
  assert.ok(sheet && sheet.material.spoolCost > 0);
});
