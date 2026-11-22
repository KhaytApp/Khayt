const { test } = require('node:test');
const assert = require('node:assert/strict');

const SP = require('../lib/supplier-prices.js');
const { computeUnitPrice } = require('../renderer/format.js');

/* ------------------------------------------------------------------
   The units a purchase can actually be recorded in.
   ------------------------------------------------------------------ */

/**
 * The seven the purchase form offers, taken from `renderer/inventory.js`.
 * If that list grows, this test is where an un-thought-about unit shows up:
 * every one of them must land in a family, and a new mass or volume unit must
 * be given a conversion rather than silently becoming its own island.
 */
const OFFERED = ['spool', 'kg', 'g', 'L', 'piece', 'roll', 'box'];

test('every offered unit normalises to itself', () => {
  for (const u of OFFERED) assert.equal(SP.normalizeUnit(u), u, u);
});

test('only the mass units share a family', () => {
  const families = OFFERED.map(u => SP.baseUnit(u));
  assert.deepEqual(families, ['spool', 'kg', 'kg', 'L', 'piece', 'roll', 'box']);
});

test('a missing or blank unit is a spool, not a family of its own', () => {
  assert.equal(SP.normalizeUnit(undefined), 'spool');
  assert.equal(SP.normalizeUnit(''), 'spool');
  assert.equal(SP.normalizeUnit('   '), 'spool');
  assert.equal(SP.normalizeUnit(null), 'spool');
});

test('spelling variants fold together', () => {
  assert.equal(SP.normalizeUnit('KG'), 'kg');
  assert.equal(SP.normalizeUnit(' Kilograms '), 'kg');
  assert.equal(SP.normalizeUnit('grams'), 'g');
  assert.equal(SP.normalizeUnit('litre'), 'L');
  assert.equal(SP.normalizeUnit('pcs'), 'piece');
});

test('an unrecognised unit keeps itself and mixes with nothing', () => {
  assert.equal(SP.normalizeUnit('cartridge'), 'cartridge');
  assert.equal(SP.baseUnit('cartridge'), 'cartridge');
  // Including another unrecognised one spelled differently.
  assert.notEqual(SP.baseUnit('cartridge'), SP.baseUnit('cartridges'));
});

/* ------------------------------------------------------------------
   Converting a price, which divides rather than multiplies.
   ------------------------------------------------------------------ */

test('a price per gram becomes a thousand times more per kilogram', () => {
  assert.equal(SP.toBasePrice(0.02, 'g'), 20);
  assert.equal(SP.toBasePrice(22, 'kg'), 22);
});

test('an unconvertible unit leaves its price alone', () => {
  assert.equal(SP.toBasePrice(75, 'spool'), 75);
  assert.equal(SP.toBasePrice(12, 'box'), 12);
  assert.equal(SP.toBasePrice(9, 'cartridge'), 9);
});

/* ------------------------------------------------------------------
   `unitPriceOf` must stay the renderer's rule.
   ------------------------------------------------------------------ */

test('unitPriceOf agrees with the renderer computeUnitPrice', () => {
  const cases = [
    { unitPrice: 5, amount: 100, quantity: 10 },
    { amount: 100, quantity: 4 },
    { amount: 50 },
    { unitPrice: 0, amount: 30, quantity: 3 },
    { unitPrice: null, amount: 30, quantity: 0 },
    {},
  ];
  for (const c of cases) {
    assert.equal(SP.unitPriceOf(c), computeUnitPrice(c), JSON.stringify(c));
  }
});

/* ------------------------------------------------------------------
   The bug this module exists to fix.
   ------------------------------------------------------------------ */

/**
 * One shop, one material, three purchases, three units — the shape the chart
 * got wrong. A spool for 75, then a kilogram for 22, then filament by the gram
 * at 0.02.
 */
const MIXED = [{
  name: 'Acme',
  purchases: [
    { materialType: 'PLA', unit: 'spool', unitPrice: 75, date: '2026-01-01' },
    { materialType: 'PLA', unit: 'kg', unitPrice: 22, date: '2026-02-01' },
    { materialType: 'PLA', unit: 'g', unitPrice: 0.02, date: '2026-03-01' },
  ],
}];

/**
 * What the chart used to do: bucket by material alone, plot every unitPrice on
 * one line, badge the last move, and rank best against worst. Kept here
 * verbatim in spirit so the assertions below say what changed rather than
 * merely what is.
 */
function theOldWay(suppliers) {
  const byMat = {};
  suppliers.forEach(sup => (sup.purchases || []).forEach(p => {
    const mt = (p.materialType || '').trim() || 'Untagged';
    (byMat[mt] = byMat[mt] || []).push({ date: p.date || '', unitPrice: computeUnitPrice(p), supplier: sup.name });
  }));
  return Object.keys(byMat).sort().map(mat => {
    const dated = byMat[mat].filter(e => e.date).sort((a, b) => a.date.localeCompare(b.date));
    const byPrice = byMat[mat].slice().sort((a, b) => a.unitPrice - b.unitPrice);
    const last = dated[dated.length - 1], prev = dated[dated.length - 2];
    return {
      material: mat,
      count: byMat[mat].length,
      pctChange: prev ? ((last.unitPrice - prev.unitPrice) / prev.unitPrice) * 100 : 0,
      best: byPrice[0].unitPrice,
      worst: byPrice[byPrice.length - 1].unitPrice,
    };
  });
}

test('the old grouping produced the three wrong answers', () => {
  const [pla] = theOldWay(MIXED);
  assert.equal(pla.count, 3, 'all three in one bucket');
  // A move from 22 per kilo to 0.02 per gram is no change at all — the same
  // 20-odd per kilo — but it was shown as the price collapsing.
  assert.ok(pla.pctChange < -99, `was ${pla.pctChange}`);
  // And the gram price wins "best price" purely by being a smaller unit.
  assert.equal(pla.best, 0.02);
  assert.equal(pla.worst, 75);
});

test('grouping by unit family splits the mixed material honestly', () => {
  const groups = SP.groups(MIXED, { untagged: 'Untagged' });
  assert.equal(groups.length, 2);

  const mass = groups.find(g => g.unit === 'kg');
  const spool = groups.find(g => g.unit === 'spool');
  assert.ok(mass && spool);

  // The two mass purchases, both now per kilogram: 22 then 20.
  assert.equal(mass.count, 2);
  assert.deepEqual(mass.entries.map(e => e.price), [22, 20]);
  assert.ok(Math.abs(mass.pctChange - (-100 * 2 / 22)) < 1e-9, `was ${mass.pctChange}`);
  assert.equal(mass.best.price, 20);
  assert.equal(mass.worst.price, 22);
  assert.equal(mass.converted, true);

  // The spool stands alone and is not compared with either of them.
  assert.equal(spool.count, 1);
  assert.equal(spool.best.price, 75);
  assert.equal(spool.worst.price, 75);
  assert.equal(spool.converted, false);
});

test('a material bought in one unit is unchanged by the split', () => {
  const one = [{ name: 'Acme', purchases: [
    { materialType: 'PETG', unit: 'spool', unitPrice: 30, date: '2026-01-01' },
    { materialType: 'PETG', unit: 'spool', unitPrice: 36, date: '2026-02-01' },
  ] }];
  const [g] = SP.groups(one, { untagged: 'Untagged' });
  const [old] = theOldWay(one);
  assert.equal(g.material, old.material);
  assert.equal(g.count, old.count);
  assert.equal(g.best.price, old.best);
  assert.equal(g.worst.price, old.worst);
  assert.ok(Math.abs(g.pctChange - old.pctChange) < 1e-9);
});

/* ------------------------------------------------------------------
   Everything else the chart reads off a group.
   ------------------------------------------------------------------ */

test('undated purchases count and rank but are not plotted', () => {
  const s = [{ name: 'Acme', purchases: [
    { materialType: 'PLA', unit: 'kg', unitPrice: 25, date: '' },
    { materialType: 'PLA', unit: 'kg', unitPrice: 22, date: '2026-02-01' },
  ] }];
  const [g] = SP.groups(s, { untagged: 'Untagged' });
  assert.equal(g.count, 2);
  assert.equal(g.entries.length, 1, 'only the dated one can be placed on a line');
  assert.equal(g.worst.price, 25, 'but the undated one still ranks');
  assert.equal(g.previous, null);
  assert.equal(g.pctChange, 0, 'one point is not a trend');
});

test('untagged purchases take the label the caller supplies', () => {
  const s = [{ name: 'Acme', purchases: [{ unit: 'kg', unitPrice: 20, date: '2026-01-01' }] }];
  assert.equal(SP.groups(s, { untagged: 'No type' })[0].material, 'No type');
  assert.equal(SP.groups(s, {})[0].material, 'Untagged');
});

test('a price falls back to the amount spread over the quantity', () => {
  const s = [{ name: 'Acme', purchases: [
    { materialType: 'PLA', unit: 'kg', amount: 88, quantity: 4, date: '2026-01-01' },
  ] }];
  assert.equal(SP.groups(s, {})[0].entries[0].price, 22);
});

test('purchases from several suppliers land in one comparable group', () => {
  const s = [
    { name: 'Acme', purchases: [{ materialType: 'PLA', unit: 'kg', unitPrice: 22, date: '2026-01-01' }] },
    { name: 'Bolt', purchases: [{ materialType: 'PLA', unit: 'g', unitPrice: 0.019, date: '2026-02-01' }] },
  ];
  const [g] = SP.groups(s, {});
  assert.equal(g.count, 2);
  assert.equal(g.best.supplier, 'Bolt', 'cheaper once both are per kilogram');
  assert.equal(g.worst.supplier, 'Acme');
});

test('groups come back in a stable order', () => {
  const s = [{ name: 'Acme', purchases: [
    { materialType: 'PETG', unit: 'spool', unitPrice: 30, date: '2026-01-01' },
    { materialType: 'PLA', unit: 'spool', unitPrice: 20, date: '2026-01-01' },
    { materialType: 'PLA', unit: 'kg', unitPrice: 22, date: '2026-01-01' },
  ] }];
  assert.deepEqual(
    SP.groups(s, {}).map(g => `${g.material}/${g.unit}`),
    ['PETG/spool', 'PLA/kg', 'PLA/spool'],
  );
});

test('a book with no suppliers or no purchases yields nothing', () => {
  assert.deepEqual(SP.groups([], {}), []);
  assert.deepEqual(SP.groups(undefined, {}), []);
  assert.deepEqual(SP.groups([{ name: 'Acme' }], {}), []);
});

test('grouping does not reorder the caller\'s own arrays', () => {
  const purchases = [
    { materialType: 'PLA', unit: 'kg', unitPrice: 30, date: '2026-03-01' },
    { materialType: 'PLA', unit: 'kg', unitPrice: 20, date: '2026-01-01' },
  ];
  const s = [{ name: 'Acme', purchases }];
  SP.groups(s, {});
  assert.deepEqual(purchases.map(p => p.unitPrice), [30, 20]);
});
