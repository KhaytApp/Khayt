'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
// `tax` FIRST: ai-price reaches `KhaytTax` through the global, exactly as
// kpi-rows, top-lists and pnl-report do. Required here so the netting under
// test is the real rule rather than the gross fallback.
require('../lib/tax.js');
const { buildComparables, materialFamily, pickPrice } = require('../lib/ai-price.js');

const mk = (id, status, price, costBasis, material, date) =>
  ({ id, status, price, costBasis, date, parts: [{ material }] });

test('materialFamily extracts the family token', () => {
  assert.equal(materialFamily('PETG - Black (Brand)'), 'PETG');
  assert.equal(materialFamily('pla'), 'PLA');
  assert.equal(materialFamily(''), '');
});

test('buildComparables prefers same-material realized margins', () => {
  const log = [
    mk('A', 'completed', 100, 50, 'PLA Black', '2026-05-01'),  // 50%
    mk('B', 'delivered', 200, 120, 'PLA White', '2026-05-10'), // 40%
    mk('C', 'completed', 100, 70, 'PLA Grey', '2026-05-20'),   // 30%
    mk('D', 'completed', 100, 10, 'PETG', '2026-05-21'),       // 90% (other material)
    mk('E', 'quote', 100, 50, 'PLA', '2026-05-22'),            // ignored (not done)
  ];
  const c = buildComparables(log, { material: 'PLA' });
  assert.equal(c.basis, 'material');
  assert.equal(c.count, 3);
  assert.equal(c.medianMarginPct, 40);
  assert.equal(c.suggestedMargin, 40);
  assert.equal(c.minMarginPct, 30);
  assert.equal(c.maxMarginPct, 50);
  assert.ok(!c.examples.some((e) => e.project === 'D')); // PETG excluded
});

test('falls back to all priced jobs when a material has <3 comparables', () => {
  const log = [
    mk('A', 'completed', 100, 50, 'PLA', '2026-05-01'),
    mk('B', 'completed', 100, 60, 'PETG', '2026-05-02'),
    mk('C', 'completed', 100, 70, 'ABS', '2026-05-03'),
  ];
  const c = buildComparables(log, { material: 'TPU' }); // no TPU history
  assert.equal(c.basis, 'all');
  assert.equal(c.count, 3);
});

test('no priced history → basis none, count 0', () => {
  assert.deepEqual(buildComparables([], { material: 'PLA' }), { basis: 'none', material: 'PLA', count: 0 });
  const onlyQuotes = [{ id: 'Q', status: 'quote', price: 100, costBasis: 50, parts: [] }];
  assert.equal(buildComparables(onlyQuotes, { material: 'PLA' }).basis, 'none');
});

test('pickPrice validates the model output, falls back on garbage', () => {
  assert.equal(pickPrice({ foo: 1 }, null), null);
  const p = pickPrice({ suggestedMargin: 42.37, suggestedPrice: 71.555, rationale: ' good ' });
  assert.equal(p.suggestedMargin, 42.4);
  assert.equal(p.suggestedPrice, 71.56);
  assert.equal(p.rationale, 'good');
});


test('comparable margins are NET of tax for an inclusive-VAT shop', () => {
  // THE BUG THIS GUARDS. `price` is what the customer paid; for an inclusive
  // shop — Saudi, the Gulf, most of Europe — part of that is the tax
  // authority's and was never revenue. Margin against the gross overstates
  // every comparable in this file, and this module exists to RECOMMEND a
  // margin from them: the shop prices thin by exactly the overstatement.
  //
  // 115 charged at 15% inclusive is 100 kept. Against a 50 cost that is 50%,
  // not the 56.5% the gross gives.
  const log = [
    { status: 'completed', price: 115, costBasis: 50, date: '2026-09-01', parts: [{ material: 'PETG' }] },
    { status: 'completed', price: 230, costBasis: 100, date: '2026-09-02', parts: [{ material: 'PETG' }] },
    { status: 'completed', price: 57.5, costBasis: 25, date: '2026-09-03', parts: [{ material: 'PETG' }] },
  ];
  const saudi = { enableVat: true, vatRate: 15, vat: '310122393500003', country: 'SA' };
  assert.equal(buildComparables(log, { material: 'PETG', settings: saudi }).medianMarginPct, 50);

  // An UNREGISTERED shop keeps the whole price, so nothing is netted off it.
  assert.equal(buildComparables(log, { material: 'PETG', settings: {} }).medianMarginPct, 56.5);

  // And a caller that passes no settings gets the old answer rather than a
  // wrong one — the netting is opt-in by having a profile to net against.
  assert.equal(buildComparables(log, { material: 'PETG' }).medianMarginPct, 56.5);
});
