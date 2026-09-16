/**
 * The extracted cost→price maths, and proof it is the SAME maths.
 *
 * This arithmetic decides what a customer is asked to pay, and it previously
 * lived inline in renderer/build.js between DOM reads and writes. Extracting it
 * is only safe if the numbers do not move: every quote a shop has already sent
 * was produced by the old expressions, and a refactor that shifts a total by a
 * rounding step reprices work silently.
 *
 * So the centrepiece here is an equivalence test. The ORIGINAL expressions are
 * reproduced verbatim below and compared against the extracted function across
 * thousands of randomised inputs. A characterisation test with three hand-picked
 * cases would pass just as happily on a subtly different formula.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const { quoteTotal, activePriceTier } = require('../lib/pricing.js');

/**
 * The pricing block exactly as it stood in renderer/build.js, with the DOM reads
 * replaced by arguments and nothing else changed. This is the oracle.
 */
function originalFormula({ totalBase, qty, margin, activeTier, discountPct, rushEnabled, rushPct, shippingCost, extraLines, biz }) {
  const m = biz ? Math.max(0, margin) : 0;
  const priceBeforeDiscount = activeTier
    ? activeTier.pricePerUnit * qty
    : totalBase * (1 + m / 100);
  const dPct = biz ? Math.min(100, Math.max(0, discountPct)) : 0;
  const discountAmt = priceBeforeDiscount * dPct / 100;
  const subAfterDiscount = priceBeforeDiscount - discountAmt;
  const rPct = biz && rushEnabled ? rushPct : 0;
  const rushFeeAmt = subAfterDiscount * rPct / 100;
  const shipping = biz ? Math.max(0, shippingCost) : 0;
  const extras = biz ? extraLines.reduce((s, l) => s + Math.max(0, +l.amount || 0), 0) : 0;
  return subAfterDiscount + rushFeeAmt + shipping + extras;
}

/** Deterministic PRNG — a failing case must be reproducible, not a coin toss. */
function makeRandom(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

test('EQUIVALENCE: the extracted maths matches the original over random inputs', () => {
  const rnd = makeRandom(20260728);
  let checked = 0;

  for (let i = 0; i < 4000; i++) {
    const useTier = rnd() < 0.3;
    const c = {
      totalBase: Math.round(rnd() * 500000) / 100,
      qty: 1 + Math.floor(rnd() * 50),
      margin: Math.round(rnd() * 30000) / 100,
      activeTier: useTier ? { pricePerUnit: Math.round(rnd() * 50000) / 100 } : null,
      discountPct: Math.round(rnd() * 12000) / 100,   // deliberately exceeds 100 sometimes
      rushEnabled: rnd() < 0.4,
      rushPct: Math.round(rnd() * 5000) / 100,
      shippingCost: Math.round(rnd() * 20000) / 100,
      extraLines: Array.from({ length: Math.floor(rnd() * 4) }, () => ({ amount: Math.round(rnd() * 10000) / 100 })),
      biz: rnd() < 0.85,
    };

    const expected = originalFormula(c);
    const got = quoteTotal({
      baseCost: c.totalBase, qty: c.qty, margin: c.margin, priceTier: c.activeTier,
      discountPct: c.discountPct, rushEnabled: c.rushEnabled, rushPct: c.rushPct,
      shippingCost: c.shippingCost, extraLines: c.extraLines, business: c.biz,
    }).total;

    assert.ok(Math.abs(got - expected) < 1e-9,
      `case ${i} differs: extracted ${got}, original ${expected}\n${JSON.stringify(c)}`);
    checked++;
  }
  assert.equal(checked, 4000);
});

test('the parts sum to the total — the UI can show a breakdown that adds up', () => {
  const r = quoteTotal({
    baseCost: 100, qty: 1, margin: 50, discountPct: 10,
    rushEnabled: true, rushPct: 25, shippingCost: 15,
    extraLines: [{ amount: 5 }, { amount: 2.5 }],
  });
  assert.equal(r.priceBeforeDiscount, 150);
  assert.equal(r.discountAmount, 15);
  assert.equal(r.subtotal, 135);
  assert.equal(r.rushFee, 33.75, 'rush is charged on the DISCOUNTED subtotal');
  assert.equal(r.extras, 7.5);
  assert.equal(r.total, 135 + 33.75 + 15 + 7.5);
});

test('rush is charged after the discount, not before', () => {
  // Order of operations is a business decision already baked into sent quotes.
  // Charging rush first would raise every rushed, discounted job.
  const after = quoteTotal({ baseCost: 100, discountPct: 50, rushEnabled: true, rushPct: 100 });
  assert.equal(after.total, 100, '100 → 50 after discount → +50 rush');
  assert.notEqual(after.total, 150, 'rushing before the discount would give this');
});

test('shipping and extras are neither discounted nor rushed', () => {
  const r = quoteTotal({
    baseCost: 100, discountPct: 100, rushEnabled: true, rushPct: 100,
    shippingCost: 20, extraLines: [{ amount: 5 }],
  });
  assert.equal(r.subtotal, 0, 'a 100% discount clears the goods');
  assert.equal(r.total, 25, 'but shipping and extras are still owed in full');
});

test('a price tier replaces cost-plus-margin entirely', () => {
  const withTier = quoteTotal({ baseCost: 1000, qty: 10, margin: 500, priceTier: { pricePerUnit: 25 } });
  assert.equal(withTier.priceBeforeDiscount, 250, 'tier price x qty, margin ignored');
});

test('the hobbyist experience prices nothing — the total is pure cost', () => {
  const r = quoteTotal({
    baseCost: 100, margin: 80, discountPct: 20, rushEnabled: true, rushPct: 25,
    shippingCost: 30, extraLines: [{ amount: 10 }], business: false,
  });
  assert.equal(r.total, 100, 'no margin, discount, fee, shipping or extras');
  assert.equal(r.priceBeforeDiscount, 100);
});

test('junk inputs cannot produce a NaN price', () => {
  // These reach the function from text inputs and from JSON over the LAN API.
  const r = quoteTotal({
    baseCost: 'abc', qty: null, margin: undefined, discountPct: NaN,
    rushEnabled: true, rushPct: 'x', shippingCost: {}, extraLines: [null, { amount: 'y' }, undefined],
  });
  for (const [k, v] of Object.entries(r)) {
    // `priceSource` is a word, not money; everything else must be a number.
    if (k === 'priceSource') { assert.equal(v, 'base'); continue; }
    assert.ok(Number.isFinite(v), `${k} is ${v}`);
  }
  assert.equal(r.total, 0);
});

test('negative inputs cannot pay the customer', () => {
  const r = quoteTotal({ baseCost: -500, margin: -50, shippingCost: -20, extraLines: [{ amount: -10 }] });
  assert.equal(r.total, 0, 'a negative cost or fee is clamped, never credited');
});

test('a discount above 100% does not invert into a charge', () => {
  const r = quoteTotal({ baseCost: 100, discountPct: 250 });
  assert.equal(r.subtotal, 0, 'clamped at free, not negative');
});

// MARK: - tier selection

test('the highest tier the quantity reaches is the one that applies', () => {
  const tiers = [{ minQty: 5, pricePerUnit: 40 }, { minQty: 10, pricePerUnit: 30 }, { minQty: 50, pricePerUnit: 20 }];
  assert.equal(activePriceTier(tiers, 4), null, 'below every tier');
  assert.equal(activePriceTier(tiers, 5).pricePerUnit, 40);
  assert.equal(activePriceTier(tiers, 49).pricePerUnit, 30, 'the highest REACHED, not the cheapest listed');
  assert.equal(activePriceTier(tiers, 500).pricePerUnit, 20);
});

test('a half-filled tier row is ignored, not priced at zero', () => {
  // The UI lets a shop start typing a tier. An incomplete row must never become
  // "this job is free".
  assert.equal(activePriceTier([{ minQty: 10, pricePerUnit: 0 }], 100), null);
  assert.equal(activePriceTier([{ minQty: 0, pricePerUnit: 25 }], 100), null);
  assert.equal(activePriceTier([{}, null, undefined], 100), null);
  assert.equal(activePriceTier(null, 100), null);
});

// ─── percentage extra lines ────────────────────────────────────────────────
// A marketplace fee is a percentage, not a number the shop can know before the
// price exists. Etsy and Shopify charge on what the BUYER pays, shipping
// included, which is why the base is not the subtotal.

const { resolveExtraLines, isPercentLine } = require('../lib/pricing.js');

test('a percentage line is charged on what the buyer pays, shipping included', () => {
  // subtotal 100, no rush, shipping 20 -> base 120, so 10% is 12 and not 10.
  const q = quoteTotal({ baseCost: 100, qty: 1, margin: 0, shippingCost: 20,
    extraLines: [{ pct: 10 }] });
  assert.equal(q.extrasBase, 120);
  assert.equal(q.extrasPercent, 12);
  assert.equal(q.total, 132);
});

test('the base includes the rush fee too', () => {
  // subtotal 100 + 25% rush = 125; 10% of that is 12.5.
  const q = quoteTotal({ baseCost: 100, qty: 1, margin: 0, rushEnabled: true, rushPct: 25,
    extraLines: [{ pct: 10 }] });
  assert.equal(q.extrasBase, 125);
  assert.equal(q.extrasPercent, 12.5);
});

test('percentages do not compound, and the order of the lines cannot change the total', () => {
  // The property that matters: a quote whose total depends on which row was
  // typed first is indefensible when a customer asks why.
  const lines = [{ pct: 5 }, { amount: 10 }, { pct: 5 }, { amount: 3 }];
  const base = { baseCost: 200, qty: 1, margin: 0, shippingCost: 15 };
  const first = quoteTotal({ ...base, extraLines: lines }).total;
  // Every permutation of four lines.
  const perms = (xs) => xs.length <= 1 ? [xs]
    : xs.flatMap((x, i) => perms([...xs.slice(0, i), ...xs.slice(i + 1)]).map((r) => [x, ...r]));
  for (const order of perms(lines)) {
    assert.equal(quoteTotal({ ...base, extraLines: order }).total, first,
      `reordering changed the total: ${JSON.stringify(order)}`);
  }
  // And two 5% lines are 10% of the base, not 10.25%.
  assert.equal(quoteTotal({ ...base, extraLines: [{ pct: 5 }, { pct: 5 }] }).extrasPercent,
    quoteTotal({ ...base, extraLines: [{ pct: 10 }] }).extrasPercent);
});

test('a fixed line is not part of the base a percentage is taken from', () => {
  // Otherwise a percentage would depend on how many fixed lines sat above it,
  // which is the compounding problem wearing a different hat.
  const withFixed = quoteTotal({ baseCost: 100, qty: 1, margin: 0,
    extraLines: [{ amount: 50 }, { pct: 10 }] });
  const withoutFixed = quoteTotal({ baseCost: 100, qty: 1, margin: 0, extraLines: [{ pct: 10 }] });
  assert.equal(withFixed.extrasPercent, withoutFixed.extrasPercent);
  assert.equal(withFixed.extras, 60);            // 50 fixed + 10 percent
});

test('a line with no pct is fixed, exactly as every existing quote is', () => {
  // Absence is what all shipped data has, so absence must keep meaning "fixed".
  assert.equal(isPercentLine({ amount: 5 }), false);
  assert.equal(isPercentLine({ amount: 5, pct: 0 }), false);
  assert.equal(isPercentLine({ amount: 5, pct: -2 }), false);
  assert.equal(isPercentLine({ pct: 6.5 }), true);
  // pct: 0 must not swallow the amount that was meant to apply.
  assert.equal(quoteTotal({ baseCost: 100, qty: 1, margin: 0,
    extraLines: [{ amount: 7, pct: 0 }] }).extras, 7);
});

test('a line is charged once — a leftover amount on a percentage line is ignored', () => {
  // The realistic shape: a row was a fixed 3, the shop switched it to 6.5%, and
  // the old amount is still sitting in the object. Charging both is silent
  // double-billing, and the total still looks plausible.
  const q = quoteTotal({ baseCost: 100, qty: 1, margin: 0,
    extraLines: [{ label: 'Etsy', pct: 10, amount: 3 }] });
  assert.equal(q.extrasFixed, 0, 'the stale amount was charged as well as the percentage');
  assert.equal(q.extrasPercent, 10);
  assert.equal(q.extras, 10);
  assert.equal(q.total, 110);
  // And the rendered row shows the percentage, not the leftover.
  const [row] = resolveExtraLines([{ pct: 10, amount: 3 }], q.extrasBase);
  assert.equal(row.amount, 10);
  assert.equal(row.pct, 10);
});

test('the breakdown adds up to the total', () => {
  const q = quoteTotal({ baseCost: 100, qty: 2, margin: 50, discountPct: 10,
    rushEnabled: true, rushPct: 20, shippingCost: 30,
    extraLines: [{ amount: 5 }, { pct: 7.5 }] });
  assert.equal(q.extras, q.extrasFixed + q.extrasPercent);
  assert.equal(q.total, q.subtotal + q.rushFee + q.shipping + q.extras);
  assert.equal(q.extrasBase, q.subtotal + q.rushFee + q.shipping);
});

test('resolveExtraLines returns the same numbers the total was built from', () => {
  // A second computation in the view is how a breakdown ends up disagreeing
  // with the total printed above it.
  const lines = [{ label: 'Etsy', pct: 6.5 }, { label: 'Packaging', amount: 4 }];
  const q = quoteTotal({ baseCost: 250, qty: 1, margin: 20, shippingCost: 10, extraLines: lines });
  const rows = resolveExtraLines(lines, q.extrasBase);
  assert.equal(rows.reduce((s, r) => s + r.amount, 0), q.extras);
  assert.equal(rows[0].pct, 6.5);
  assert.equal(rows[1].pct, null, 'a fixed line must not claim a percentage');
  assert.equal(rows[0].label, 'Etsy');
});

test('the commerce-free experience still charges nothing, percentage or not', () => {
  const q = quoteTotal({ baseCost: 100, qty: 1, margin: 50, shippingCost: 20,
    extraLines: [{ pct: 50 }, { amount: 9 }], business: false });
  assert.equal(q.extras, 0);
  assert.equal(q.extrasPercent, 0);
  assert.equal(q.total, 100);
});

test('junk lines are ignored rather than poisoning the total', () => {
  for (const bad of [null, undefined, {}, { pct: 'x' }, { amount: 'y' }, { pct: NaN }]) {
    const q = quoteTotal({ baseCost: 100, qty: 1, margin: 0, extraLines: [bad] });
    assert.equal(q.total, 100, JSON.stringify(bad));
  }
});

/* ── The last word on the total: agreed parts, rounding, a typed figure ─────
   Added 2026-09-16. Each is inert when absent — the equivalence tests above
   are the proof, since none of them passes the new inputs. */
const { roundToStep } = require('../lib/pricing.js');

test('an agreed amount is added after the discount and never marked up', () => {
  const q = quoteTotal({ baseCost: 100, margin: 30, agreedAmount: 200, discountPct: 10 });
  assert.equal(q.priceBeforeDiscount, 130, 'the marked-up half');
  assert.equal(q.discountAmount, 13, 'the discount is on the marked-up half only');
  assert.equal(q.agreedAmount, 200);
  assert.equal(q.subtotal, 317);
  assert.equal(q.total, 317);
  // Rush, shipping and extras still apply to it.
  const rushed = quoteTotal({ baseCost: 0, agreedAmount: 200, rushEnabled: true, rushPct: 25, shippingCost: 10 });
  assert.equal(rushed.rushFee, 50);
  assert.equal(rushed.total, 260);
  // The hobbyist build prices nothing, agreed or not.
  assert.equal(quoteTotal({ baseCost: 100, agreedAmount: 200, business: false }).total, 100);
});

test('rounding to a step: nearest, up, down — and a total already on a multiple stays', () => {
  const at = (mode) => quoteTotal({ baseCost: 1421.05, margin: 30, priceRound: { step: 5, mode } });
  assert.equal(+at('nearest').computedTotal.toFixed(2), 1847.37);
  assert.equal(at('nearest').total, 1845);
  assert.equal(at('up').total, 1850);
  assert.equal(at('down').total, 1845);
  assert.equal(at('up').priceSource, 'rounded');
  assert.equal(quoteTotal({ baseCost: 100, margin: 30, priceRound: { step: 5, mode: 'up' } }).total, 130, '130 is already a multiple of 5');
  assert.equal(quoteTotal({ baseCost: 100, margin: 30, priceRound: { step: 1, mode: 'nearest' } }).total, 130);
  assert.equal(quoteTotal({ baseCost: 100.4, margin: 0, priceRound: { step: 1, mode: 'nearest' } }).total, 100);
  // No step, a zero step, or the hobbyist build: the arithmetic stands.
  assert.equal(quoteTotal({ baseCost: 100.4, margin: 0, priceRound: { step: 0 } }).priceSource, 'base');
  assert.equal(quoteTotal({ baseCost: 100.4, margin: 0, priceRound: null }).total, 100.4);
  assert.equal(quoteTotal({ baseCost: 100.4, margin: 0, priceRound: { step: 5 }, business: false }).total, 100.4);
});

test('a typed price is the price, and a cleared box is not a free job', () => {
  const q = quoteTotal({ baseCost: 100, margin: 30, priceRound: { step: 5, mode: 'up' }, priceOverride: 120 });
  assert.equal(q.total, 120, 'typed wins over rounding');
  assert.equal(q.priceSource, 'override');
  assert.equal(q.computedTotal, 130, 'and the arithmetic is still there to show');
  assert.equal(quoteTotal({ baseCost: 100, margin: 30, priceOverride: 0 }).total, 0, 'zero is a price');
  for (const absent of [null, undefined, '']) {
    assert.equal(quoteTotal({ baseCost: 100, margin: 30, priceOverride: absent }).total, 130, `${JSON.stringify(absent)} is absent`);
  }
  assert.equal(quoteTotal({ baseCost: 100, margin: 30, priceOverride: 'x' }).total, 130, 'garbage is absent');
  assert.equal(quoteTotal({ baseCost: 100, margin: 30, priceOverride: -5 }).total, 130, 'a negative price is not a price');
  assert.equal(quoteTotal({ baseCost: 100, margin: 30, priceOverride: 12.345 }).total, 12.35, 'money has two decimals');
});

test('the rounding here is the product rule\'s rounding, with or without that module loaded', () => {
  // Without: the local copy.
  const cases = [[1847.37, 5, 'nearest'], [1847.37, 5, 'up'], [1847.37, 5, 'down'], [45, 5, 'up'], [12.1, 0.5, 'nearest'], [1847.37, 1, 'up'], [1847.37, 10, 'nearest']];
  const local = cases.map(([v, s, m]) => roundToStep(v, s, m));
  // With: the same answers.
  const P = require('../lib/product-price.js');
  assert.ok(globalThis.KhaytProductPrice === P, 'the product rule registered itself');
  const theirs = cases.map(([v, s, m]) => P.roundToStep(v, s, m));
  assert.deepEqual(local, theirs);
  assert.deepEqual(cases.map(([v, s, m]) => roundToStep(v, s, m)), theirs, 'and delegating gives the same');
  assert.deepEqual(theirs, [1845, 1850, 1845, 45, 12, 1848, 1850]);
});
