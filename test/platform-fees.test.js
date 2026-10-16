const { test } = require('node:test');
const assert = require('node:assert/strict');

const F = require('../lib/platform-fees.js');
const P = require('../lib/pricing.js');

/**
 * Issue #364, item 1 — asked for twice by the same shop, which is the strongest
 * signal in that thread:
 *
 *   "Etsy for instance charges two percentage based fees and a relisting fee of
 *    .20 for each item sold."
 *
 * The percentage/flat machinery already existed; what was missing is that the
 * shop had to remember three numbers and type them on every quote.
 */

test('Etsy is exactly what he described: two percentages and a flat fee', () => {
  const lines = F.feeLinesFor('etsy', {});
  assert.equal(lines.length, 3);
  assert.equal(lines.filter((l) => l.pct != null).length, 2, 'two percentage fees');
  assert.equal(lines.filter((l) => l.amount != null).length, 1, 'one flat fee');
  assert.equal(lines.find((l) => l.amount != null).amount, 0.20, 'the .20 listing fee');
});

test('the lines are the shape the calculator already appends', () => {
  // The whole point of this module is that nothing downstream changes: pricing,
  // the invoice and the totals treat these as the extra lines they already are.
  for (const l of F.feeLinesFor('etsy', {})) {
    assert.ok(l.label, 'every line has a label');
    assert.ok(l.pct != null || l.amount != null, 'and is either a percentage or an amount');
    assert.equal(P.isPercentLine(l), l.pct != null, 'lib/pricing agrees which kind it is');
  }
});

test('percentages are grossed up, so the shop keeps its subtotal after the platform', () => {
  // 100 subtotal: (100 + 0.20) ÷ (1 − 9.5%) = 110.72, of which 6.5% is 7.20 and
  // 3% is 3.32 — fees of 10.72, not the 9.70 a pre-fee percentage gave.
  const est = F.estimateFor('etsy', {}, 100);
  assert.equal(est.total, 10.72);
  const price = 100 + est.total;
  assert.ok(Math.abs(price - price * 0.095 - 0.20 - 100) < 0.01, 'Etsy takes its cut and 100 is left');
});

test('the estimate agrees with what lib/pricing will actually compute', () => {
  // The figure shown before adding must be the figure charged after adding,
  // otherwise the preview is a second implementation that can drift.
  const lines = F.feeLinesFor('etsy', {});
  const q = P.quoteTotal({ baseCost: 100, extraLines: lines });
  const viaPricing = P.resolveExtraLines(lines, q.extrasBase, q.feeBase).reduce((s, r) => s + r.amount, 0);
  assert.equal(Math.round(viaPricing * 100) / 100, F.estimateFor('etsy', {}, 100).total);
});

test('a zero subtotal charges the flat fees, and the percentages on those alone', () => {
  // 0.20 ÷ 0.905 = 0.22: the listing fee, plus 6.5% and 3% of what the buyer pays.
  assert.equal(F.estimateFor('etsy', {}, 0).total, 0.22);
  assert.equal(F.estimateFor('amazon', {}, 0).total, 0, 'no flat fee, nothing to charge');
});

/* ── the shop's own numbers win ─────────────────────────────────────────────── */

test("a shop's saved schedule REPLACES the preset rather than merging", () => {
  // Merging would resurrect a line the shop deliberately deleted on the next
  // update — an invisible charge on a customer's quote, which is the worst
  // failure this module could have.
  const settings = { platformFees: { etsy: { lines: [{ key: 'x', label: 'My Etsy rate', pct: 5 }] } } };
  const lines = F.feeLinesFor('etsy', settings);
  assert.equal(lines.length, 1);
  assert.equal(lines[0].pct, 5);
});

test('an unlisted platform yields nothing rather than guessing', () => {
  assert.deepEqual(F.feeLinesFor('nope', {}), []);
  assert.equal(F.platformFor('nope', {}), null);
});

test('unusable lines are dropped, not charged as zero', () => {
  const settings = { platformFees: { etsy: { lines: [
    { label: 'good', pct: 3 },
    { label: 'zero pct', pct: 0 },
    { label: 'negative', amount: -5 },
    { label: '' },
    null,
  ] } } };
  const lines = F.feeLinesFor('etsy', settings);
  assert.equal(lines.length, 1);
  assert.equal(lines[0].label, 'good');
});

/* ── adding twice ──────────────────────────────────────────────────────────── */

test('a platform can be detected on lines already added', () => {
  const lines = F.feeLinesFor('etsy', {});
  assert.equal(F.hasPlatform(lines, 'etsy'), true);
  assert.equal(F.hasPlatform(lines, 'shopify'), false);
  assert.equal(F.hasPlatform([], 'etsy'), false);
});

test("swapping platforms strips the old fees and keeps the shop's own lines", () => {
  // Clicking twice would otherwise stack a second copy, which a shop only
  // notices on the invoice.
  const own = { id: 'EL1', label: 'Rush', amount: 15 };
  const mixed = [own, ...F.feeLinesFor('etsy', {})];
  const cleaned = F.withoutPlatformFees(mixed);
  assert.deepEqual(cleaned, [own]);
});

test('every shipped preset is internally valid', () => {
  // A typo in the table would ship a fee that silently charges nothing.
  for (const id of F.platformIds()) {
    const p = F.platformFor(id, {});
    assert.ok(p.name, `${id} has a name`);
    assert.ok(p.lines.length > 0, `${id} has at least one fee`);
    for (const l of p.lines) {
      assert.ok(l.label, `${id}: every line is labelled`);
      assert.ok((l.pct > 0) !== (l.amount > 0), `${id}: a line is a percentage or an amount, not both`);
    }
  }
});

test('presets are copies — one shop editing cannot alter the table', () => {
  const a = F.platformFor('etsy', {});
  a.lines[0].pct = 99;
  assert.equal(F.platformFor('etsy', {}).lines[0].pct, 6.5);
});
