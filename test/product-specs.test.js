/**
 * The three facts a storefront needs about a printed thing.
 *
 * Khayt has known all of them all along — print hours are what feed its own
 * availableFrom — and published none, so a shop typed each one again into its
 * storefront's admin. A hand-typed number that drifts from the shop's own record
 * is worse than no number, because both look authoritative.
 *
 * Dimensions are the fourth thing that was asked for and are NOT here: Khayt has
 * no dimension field on a product or a part, anywhere. Publishing an invented one
 * would be worse than publishing none.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/product-specs.js');

test('a single-part product reports its own numbers', () => {
  const p = { parts: [{ printTime: 5.25, printWeight: 140.91, material: 'PLA+ 2.0' }] };
  assert.deepEqual(S.productSpecs(p), { printHours: 5.25, weightGrams: 140.91, material: 'PLA+ 2.0' });
});

test('a multi-part product sums, multiplies by quantity, and lists each material once', () => {
  const p = { parts: [
    { printTime: 5.25, printWeight: 140.91, material: 'PLA+ 2.0', qty: 1 },
    { printTime: 1.5, printWeight: 40, supportWeight: 8, material: 'TPU', qty: 2 },
    { printTime: 0.25, printWeight: 5, material: 'PLA+ 2.0', qty: 1 },
  ] };
  const s = S.productSpecs(p);
  assert.equal(s.printHours, 5.25 + 1.5 * 2 + 0.25);
  assert.equal(s.weightGrams, 140.91 + (40 + 8) * 2 + 5);
  assert.equal(s.material, 'PLA+ 2.0, TPU', 'each material once, in the order the shop listed them');
});

test('supports are filament and are counted', () => {
  // partGramsConsumed() includes them because the completion deduction does. A
  // published weight that disagreed with the shop's own deduction would be a
  // second truth about the same gram.
  assert.equal(S.partGrams({ printWeight: 100, supportWeight: 25 }), 125);
  assert.equal(S.partGrams({ printWeight: 100, supportWeight: 25, qty: 3 }), 375);
});

test('print hours are MACHINE hours — prep and post are not added', () => {
  /* Finishing is published separately, inside the lead-time snapshot's
   * handlingDays. A consumer that added prep and post here and then added
   * handlingDays on top would count finishing twice, and quote later every
   * time — silently, in the direction that loses work. */
  const p = { parts: [{ printTime: 2, prepTime: 0.5, postTime: 1.5, printWeight: 10 }] };
  assert.equal(S.productSpecs(p).printHours, 2);
});

test('a product with no parts answers nothing, not zero', () => {
  // A consumer deciding whether it can quote a date has to tell "no parts" from
  // "prints instantly". Zero reads as an answer.
  assert.deepEqual(S.productSpecs({ parts: [] }), { printHours: null, weightGrams: null, material: '' });
  assert.deepEqual(S.productSpecs({}), { printHours: null, weightGrams: null, material: '' });
  assert.deepEqual(S.productSpecs(null), { printHours: null, weightGrams: null, material: '' });
});

test('a part with no numbers does not drag the product to zero', () => {
  const p = { parts: [{ printTime: 3, printWeight: 50, material: 'PETG' }, { name: 'hardware only' }] };
  const s = S.productSpecs(p);
  assert.equal(s.printHours, 3);
  assert.equal(s.weightGrams, 50);
  assert.equal(s.material, 'PETG');
});

test('nonsense is ignored rather than propagated', () => {
  const p = { parts: [{ printTime: -4, printWeight: 'heavy', material: '  ' }] };
  assert.deepEqual(S.productSpecs(p), { printHours: null, weightGrams: null, material: '' });
});

test('a short part keeps its hours', () => {
  // Four decimal places: twelve minutes is 0.2h and must not round to nothing.
  assert.equal(S.productSpecs({ parts: [{ printTime: 0.2, printWeight: 4 }] }).printHours, 0.2);
});

test('the publish sends them, and the module is loaded to compute them', () => {
  // The recurring failure here is a field computed and never published, or a
  // module called and never loaded.
  const fs = require('fs');
  const path = require('path');
  const root = path.join(__dirname, '..');
  const settings = fs.readFileSync(path.join(root, 'renderer', 'settings.js'), 'utf8');
  // The payload is built in lib/storefront-catalog.js (shared with the Mac).
  const build = fs.readFileSync(path.join(root, 'lib', 'storefront-catalog.js'), 'utf8');
  assert.match(build, /KhaytProductSpecs\.productSpecs\(p\)/);
  for (const f of ['printHours', 'weightGrams', 'material']) {
    assert.match(build, new RegExp(`it\\.${f} = spec\\.`), `the publish must send ${f}`);
  }
  for (const page of ['index.html', 'bedready.html']) {
    assert.match(fs.readFileSync(path.join(root, 'renderer', page), 'utf8'), /lib\/product-specs\.js/,
      `${page} must load the module it calls`);
  }
});
