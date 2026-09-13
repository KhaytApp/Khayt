/**
 * The price a shop charges, as opposed to the one arithmetic produced.
 *
 * The catalogue computed cost + margin and that was final — a number like 43.71,
 * which no shop puts on a shelf. Reported: "it does a good job of calculating
 * price but there should be a way to override the final price, basically I like
 * to round it up or down to multiples of fives."
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/product-price.js');

test('rounding to fives, in the direction the shop chose', () => {
  assert.equal(P.roundToStep(43.71, 5, 'nearest'), 45);
  assert.equal(P.roundToStep(43.71, 5, 'up'), 45);
  assert.equal(P.roundToStep(43.71, 5, 'down'), 40);
  // Direction is a pricing decision, not a numerical one: nearest gives away
  // two units of margin here and up does not. Both are legitimate.
  assert.equal(P.roundToStep(42, 5, 'nearest'), 40);
  assert.equal(P.roundToStep(42, 5, 'up'), 45);
});

test('a price already on a multiple is left alone', () => {
  /* 45 / 5 is 9.000000000000002 in floating point, so a naive Math.ceil pushes
   * an exact multiple up to the next one — 45 becomes 50, and again on every
   * save. This is the case that makes rounding-up unusable if it is wrong. */
  assert.equal(P.roundToStep(45, 5, 'up'), 45);
  assert.equal(P.roundToStep(40, 5, 'down'), 40);
  assert.equal(P.roundToStep(100, 25, 'up'), 100);
  assert.equal(P.roundToStep(0, 5, 'up'), 0);
});

test('rounding never produces a nonsense price', () => {
  // A convenience must not be the reason a product page shows NaN.
  assert.equal(P.roundToStep(43.71, 0, 'up'), 43.71, 'no step means no rounding');
  assert.equal(P.roundToStep(43.71, -5, 'up'), 43.71);
  assert.equal(P.roundToStep(43.71, 5, 'sideways'), 45, 'an unknown mode falls back to nearest');
  assert.equal(P.roundToStep('nope', 5, 'up'), null);
  assert.equal(P.roundToStep(12.1, 0.5, 'nearest'), 12, 'and no floating-point tail');
});

test('a typed price wins over the arithmetic and over the rounding', () => {
  const r = P.finalPrice({ priceOverride: 39.99, priceRound: { step: 5, mode: 'up' } }, 43.71);
  assert.equal(r.final, 39.99);
  assert.equal(r.source, 'override');
  assert.equal(r.base, 43.71, 'the calculated price stays visible — it is what shows the margin working');
});

test('zero is a price, not an absent one', () => {
  /* A giveaway, a sample, a part priced inside a bundle. Treating 0 as "no
   * override" would silently re-price free items at cost plus margin. */
  const r = P.finalPrice({ priceOverride: 0 }, 43.71);
  assert.equal(r.final, 0);
  assert.equal(r.source, 'override');
  // And an empty override is genuinely absent.
  assert.equal(P.finalPrice({ priceOverride: null }, 43.71).source, 'base');
  assert.equal(P.finalPrice({ priceOverride: '' }, 43.71).source, 'base');
});

test('a product with no rule prices exactly as it did before', () => {
  const r = P.finalPrice({}, 43.71);
  assert.equal(r.final, 43.71);
  assert.equal(r.source, 'base');
  assert.deepEqual(P.finalPrice(null, 43.71), { base: 43.71, final: 43.71, source: 'base' });
});

test('the shop is told which number it is looking at', () => {
  // A rounded price that does not admit it looks like the arithmetic produced it.
  assert.match(P.describe(P.finalPrice({ priceOverride: 40 }, 43.71)), /your own price/i);
  assert.match(P.describe(P.finalPrice({ priceRound: { step: 5, mode: 'up' } }, 43.71)), /rounded/i);
  // Rounding that changed nothing is not "rounded", it is the calculated price.
  assert.match(P.describe(P.finalPrice({ priceRound: { step: 5, mode: 'up' } }, 45)), /calculated/i);
});

test('the editor and the search agree on which price they show', () => {
  const fs = require('fs');
  const path = require('path');
  // The rule MOVED, and this guard follows it rather than being relaxed. It
  // lived in `renderer/inventory.js` while one app had a product editor; the
  // Mac grew one, so pricing a product is `lib/product-pricing.js` now and both
  // apps call it. What has to hold is unchanged: the editor applies the shop's
  // own rounding, so the editor and the search cannot show different prices.
  const rule = fs.readFileSync(path.join(__dirname, '..', 'lib', 'product-pricing.js'), 'utf8');
  assert.match(rule, /finalPrice\(d, basePrice\)/,
    'product pricing must apply the shop\'s own rounding rule');
  const inv = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'inventory.js'), 'utf8');
  assert.match(inv, /KhaytProductPricing\.priceProduct/,
    'the editor must price through the shared rule, not its own copy');
  assert.match(inv, /draft\.price = pricing\.price/, 'and the charged price has to be saved');
  const shell = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'shell.js'), 'utf8');
  assert.match(shell, /p\.price != null \? p\.price/,
    'search must show what the shop charges, not the pre-rounding figure');
});
