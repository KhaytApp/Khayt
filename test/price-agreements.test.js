'use strict';
/**
 * A customer's agreed prices, applied to a cart — one rule for both apps.
 *
 * The matching was a loop inside the Electron client picker and nothing else;
 * the Mac app could store a price list and never used it. The first test is
 * the original loop, copied out of `renderer/wire-events.js`, run beside the
 * rule over generated carts.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/pricing.js');
const P = require('../lib/price-agreements.js');

/* ── ORIGINAL: renderer/wire-events.js, the client picker's auto-fill, verbatim
   (`c.priceList` and `currentBuild` become arguments; `applied` is returned). */
function original(c, currentBuild) {
  let applied = false;
  if ((c.priceList || []).length > 0 && currentBuild.length > 0) {
    for (const part of currentBuild) {
      const pl = (c.priceList || []).find(p => p.product && part.name && part.name.toLowerCase().includes(p.product.toLowerCase()));
      if (pl && pl.price > 0) {
        part.unitCost = pl.price;
        part.baseCost = pl.price * (part.qty || 1);
        applied = true;
      }
    }
  }
  return applied;
}

function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}
const WORDS = ['bracket', 'Bracket', 'keychain', 'key', 'box', '', 'BOX lid'];

test('the rule applies what the original loop applied, over generated carts', () => {
  let touched = 0;
  for (let seed = 1; seed <= 500; seed++) {
    const r = rng(seed);
    const pick = (list) => list[Math.floor(r() * list.length)];
    const priceList = Array.from({ length: Math.floor(r() * 4) }, () => ({
      product: pick(WORDS), price: pick([0, 8, 12.5, 40]), note: '',
    }));
    const cart = Array.from({ length: Math.floor(r() * 4) }, () => ({
      name: pick(WORDS) + pick(['', ' small', ' x2']), qty: pick([undefined, 1, 3]), unitCost: 5, baseCost: 5,
    }));
    const a = JSON.parse(JSON.stringify(cart)), b = JSON.parse(JSON.stringify(cart));
    const was = original({ priceList }, a);
    const now = P.apply(b, priceList);
    assert.deepEqual(b, a, `seed ${seed}`);
    assert.equal(now > 0, was, `seed ${seed}: the host would toast differently`);
    if (now) touched++;
  }
  assert.ok(touched > 50, `only ${touched} carts touched — the generator is not reaching the rule`);
});

test('the first product the name contains decides, even at no price', () => {
  const list = [{ product: 'bracket', price: 0 }, { product: 'bracket', price: 9 }];
  assert.equal(P.find(list, 'Steel bracket'), null, 'a product written down with no price is not agreed');
  assert.equal(P.find([{ product: 'bracket', price: 9 }], 'Steel BRACKET').price, 9);
  assert.equal(P.find([{ product: '', price: 9 }], 'anything'), null);
  assert.equal(P.find([{ product: 'bracket', price: 9 }], ''), null);
  assert.equal(P.find(undefined, 'bracket'), null);
});

test('the agreed figure is the part\'s COST, and the margin goes on top — as the other app has always done', () => {
  // Documented, not endorsed: see the module header. If this ever changes it
  // changes in both apps, through the rule, with a migration for the jobs
  // already priced this way.
  const parts = [{ name: 'Wall bracket', qty: 4, unitCost: 3, baseCost: 12 }, { name: 'Lid', qty: 1, unitCost: 2, baseCost: 2 }];
  assert.equal(P.apply(parts, [{ product: 'bracket', price: 50 }]), 1);
  assert.equal(parts[0].unitCost, 50);
  assert.equal(parts[0].baseCost, 200);
  assert.equal(parts[1].unitCost, 2, 'an unmatched part keeps its cost');
  const quote = globalThis.KhaytPricing.quoteTotal({ baseCost: 200, margin: 30 });
  assert.equal(quote.total, 260, 'four parts agreed at 50 each bill 260 at 30% margin');
});
