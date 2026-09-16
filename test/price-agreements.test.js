'use strict';
/**
 * A customer's agreed prices, applied to a cart — one rule for both apps.
 *
 * The matching was a loop inside the Electron client picker and nothing else;
 * the Mac app could store a price list and never used it. The matching is
 * kept exactly (first product the name contains decides, even at no price);
 * where the figure LANDS changed on 2026-09-16, deliberately: it is the price
 * of the part now, not its cost — see the module header and the last test.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
require('../lib/pricing.js');
const P = require('../lib/price-agreements.js');

/* ── The ORIGINAL matching, from renderer/wire-events.js, verbatim ────────── */
function originalMatch(c, part) {
  const pl = (c.priceList || []).find(p => p.product && part.name && part.name.toLowerCase().includes(p.product.toLowerCase()));
  return (pl && pl.price > 0) ? pl : null;
}

function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}
const WORDS = ['bracket', 'Bracket', 'keychain', 'key', 'box', '', 'BOX lid'];

test('the rule matches what the original loop matched, over generated carts', () => {
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
    const expected = cart.map(part => originalMatch({ priceList }, part));
    const n = P.apply(cart, priceList);
    cart.forEach((part, i) => {
      assert.equal(part.agreedPrice, expected[i] ? expected[i].price : undefined, `seed ${seed} part ${i}`);
      assert.equal(part.unitCost, 5, 'the cost is not touched');
      assert.equal(part.baseCost, 5);
    });
    assert.equal(n, expected.filter(Boolean).length, `seed ${seed}: the host would toast differently`);
    if (n) touched++;
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

test('the agreed figure is the PRICE of the part; the cost is what it cost', () => {
  const parts = [{ name: 'Wall bracket', qty: 4, unitCost: 3, baseCost: 12 }, { name: 'Lid', qty: 1, unitCost: 2, baseCost: 2, agreedPrice: 99 }];
  assert.equal(P.apply(parts, [{ product: 'bracket', price: 50 }]), 1);
  assert.equal(parts[0].agreedPrice, 50);
  assert.equal(parts[0].unitCost, 3, 'the cost is untouched, so the margin report is true');
  assert.equal(parts[0].baseCost, 12);
  assert.equal(parts[1].agreedPrice, undefined, 'an agreement a previous customer left is cleared');
  // What the customer pays: 4 × 50, the lid at cost plus margin, no markup on the bracket.
  const quote = globalThis.KhaytPricing.quoteTotal({ baseCost: 2, margin: 30, agreedAmount: 200 });
  assert.equal(quote.total, 202.6);
});
