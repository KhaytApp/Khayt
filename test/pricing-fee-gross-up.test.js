/**
 * Marketplace fee lines are GROSSED UP (October 2026).
 *
 * A marketplace or card fee is taken from what the buyer pays, so a fee worked
 * out on the pre-fee price under-charges by the fee on the fee: 10% of 100
 * added 10, the platform took 10% of 110 = 11, and the shop kept 99. A FEE
 * line — a percentage line with a `platformId` (lib/platform-fees.js) or
 * `fee: true` — is now taken of the final price:
 *
 *   final = (subtotal + rush + shipping + surcharges + fixed) ÷ (1 − Σfee pct)
 *
 * Any other percentage line is the shop's OWN surcharge ("design 10%"): its
 * money, taken of subtotal + rush + shipping exactly as before, never grossed.
 *
 * The first test is the one that matters most: a quote with no FEE line —
 * fixed lines and surcharge percentages included — must come out of
 * lib/pricing.js byte-for-byte as it did before this change. The digest was
 * taken from the pre-change module (`git show ba5cf3ad:lib/pricing.js`) over
 * the same deterministic inputs; run the generator against that file to
 * inspect a mismatch.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');

const P = require('../lib/pricing.js');
const { quoteTotal, resolveExtraLines } = P;

/** Deterministic PRNG — a failing case must be reproducible. */
function makeRandom(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 0x100000000;
  };
}

/**
 * Quotes with no fee line, spanning every input pricing.js reads: tiers,
 * discounts over 100, rush, shipping, fixed lines (one carrying a platformId,
 * as Etsy's listing fee does), the shop's own percentage surcharges, lines
 * whose pct is 0 or negative, junk lines, agreed amounts, rounding, typed
 * prices, overhead, and the hobbyist build — which ignores every line, so a
 * fee line is allowed there.
 */
function noFeeCases() {
  const rnd = makeRandom(20261016);
  const pick = (xs) => xs[Math.floor(rnd() * xs.length)];
  const out = [];
  for (let i = 0; i < 4000; i++) {
    const business = rnd() < 0.85;
    const lines = Array.from({ length: Math.floor(rnd() * 5) }, () => pick([
      () => ({ label: 'Packaging', amount: Math.round(rnd() * 10000) / 100 }),
      () => ({ amount: rnd() * 40 }),
      () => ({ label: 'Etsy listing fee', amount: 0.2, platformId: 'etsy' }),
      () => ({ label: 'Design', pct: Math.round(rnd() * 3000) / 100 }),
      () => ({ label: 'Painting', pct: rnd() * 15 }),
      () => ({ label: 'Not a fee', pct: 5, fee: false }),
      () => ({ label: 'Zero pct', amount: Math.round(rnd() * 500) / 100, pct: 0 }),
      () => ({ amount: 3, pct: -2 }),
      () => ({ label: 'Zero fee', pct: 0, platformId: 'etsy', amount: 4 }),
      () => null,
      () => ({ amount: 'y' }),
      () => ({ pct: 'x' }),
    ])());
    if (!business && rnd() < 0.5) lines.push({ label: 'Etsy', pct: 6.5, platformId: 'etsy' });
    out.push({
      baseCost: Math.round(rnd() * 500000) / 100,
      qty: 1 + Math.floor(rnd() * 50),
      margin: Math.round(rnd() * 30000) / 100,
      priceTier: rnd() < 0.25 ? { pricePerUnit: Math.round(rnd() * 50000) / 100 } : null,
      discountPct: Math.round(rnd() * 12000) / 100,
      rushEnabled: rnd() < 0.4,
      rushPct: Math.round(rnd() * 5000) / 100,
      shippingCost: rnd() < 0.5 ? Math.round(rnd() * 20000) / 100 : 0,
      extraLines: lines,
      agreedAmount: rnd() < 0.2 ? rnd() * 300 : 0,
      priceRound: rnd() < 0.2 ? { step: pick([0.5, 1, 5, 10]), mode: pick(['nearest', 'up', 'down']) } : null,
      priceOverride: rnd() < 0.1 ? Math.round(rnd() * 100000) / 100 : (rnd() < 0.1 ? '' : null),
      overheadPerHour: rnd() < 0.3 ? rnd() * 10 : 0,
      printHours: rnd() * 40,
      business,
    });
  }
  return out;
}

/** The quote AND its resolved rows — what a screen and an invoice print. */
function digest(pricing) {
  const h = crypto.createHash('sha256');
  for (const input of noFeeCases()) {
    const q = pricing.quoteTotal(input);
    h.update(JSON.stringify(q) + '\n');
    // The rows only where they are printed: the hobbyist build prices no line,
    // and the fee line it was handed is a fee line, not a no-fee quote.
    if (input.business) {
      h.update(JSON.stringify(pricing.resolveExtraLines(input.extraLines, q.extrasBase, q.feeBase)) + '\n');
    }
  }
  return h.digest('hex');
}

const NO_FEE_DIGEST = 'b2ce3b9302f91f69f30cc2bfee9806dc4b6c398c38c752bfefe1a39db9c8f479';

test('a quote with no fee line — surcharges and fixed lines included — is byte-identical to before', () => {
  assert.equal(digest(P), NO_FEE_DIGEST,
    'a quote with no marketplace fee line changed — every such quote a shop sends would move');
});

// ─── the arithmetic ──────────────────────────────────────────────────────────

/** What the shop is left with after the platform takes its fees of a total. */
const shopKeeps = (total, pcts, fixedFees = 0) =>
  total - pcts.reduce((s, p) => s + total * p / 100, 0) - fixedFees;

const fee = (pct, extra = {}) => ({ label: 'Fee', pct, platformId: 'etsy', ...extra });

test('a fee line is one with a platformId or fee: true — nothing else', () => {
  assert.equal(P.isFeeLine({ pct: 3, platformId: 'shopify' }), true);
  assert.equal(P.isFeeLine({ pct: 3, fee: true }), true);
  assert.equal(P.isFeeLine({ pct: 3 }), false, 'a bare % line is the shop’s surcharge');
  assert.equal(P.isFeeLine({ pct: 3, fee: false }), false);
  assert.equal(P.isFeeLine({ pct: 3, fee: 'yes' }), false, 'only an explicit true');
  assert.equal(P.isFeeLine({ amount: 0.2, platformId: 'etsy' }), false, 'a fixed fee is not a percentage');
  assert.equal(P.isFeeLine(null), false);
});

test('one fee line: the shop keeps its price after the platform takes its cut', () => {
  for (const line of [fee(10), { label: 'Card', pct: 10, fee: true }]) {
    const q = quoteTotal({ baseCost: 100, extraLines: [line] });
    // 100 ÷ 0.9 = 111.11…; the fee line is 10% of that, to the cent.
    assert.equal(q.extrasPercent, 11.11);
    assert.equal(q.total, 111.11);
    assert.equal(q.extrasBase, 100, 'the surcharge base is unchanged');
    assert.equal(q.feeBase, 100 / 0.9, 'a fee is taken of the final price');
    assert.equal(q.feePct, 10);
    assert.equal(q.feeWarning, null);
    assert.ok(Math.abs(shopKeeps(q.total, [10]) - 100) < 0.01);
  }
});

test('a % line with no platformId is the shop’s surcharge and is NOT grossed up', () => {
  const q = quoteTotal({ baseCost: 100, extraLines: [{ label: 'Design', pct: 10 }] });
  assert.equal(q.total, 110);
  assert.equal(q.extrasPercent, 10);
  assert.equal(q.feePct, undefined, 'a surcharge is not a fee');
  assert.equal(q.feeBase, undefined);
});

test('a surcharge and a platform fee together: surcharge first, then the fee grosses up the whole', () => {
  const lines = [{ label: 'Design', pct: 10 }, { label: 'Packaging', amount: 5 },
    { label: 'Etsy transaction fee', pct: 6.5, platformId: 'etsy' }];
  const q = quoteTotal({ baseCost: 100, shippingCost: 20, extraLines: lines });
  // 1. surcharge on 100 + 20 = 12.  2. + 5 fixed → 137.  3. 137 ÷ 0.935.
  const final = 137 / 0.935;
  assert.equal(q.extrasBase, 120);
  assert.equal(q.feeBase, final);
  assert.equal(q.feePct, 6.5, 'the surcharge is not counted as a fee');
  const rows = resolveExtraLines(lines, q.extrasBase, q.feeBase);
  assert.equal(rows[0].amount, 12, 'the surcharge is exactly what it always was');
  assert.equal(rows[1].amount, 5);
  assert.equal(rows[2].amount, Math.round(final * 6.5) / 100);
  assert.equal(q.total, 146.52);
  assert.ok(Math.abs(rows.reduce((s, r) => s + r.amount, 0) - q.extras) < 1e-9);
  // The platform takes 6.5% of what the buyer pays; the shop keeps 137,
  // its 12 surcharge included.
  assert.ok(Math.abs(shopKeeps(q.total, [6.5]) - 137) < 0.01, `kept ${shopKeeps(q.total, [6.5])}`);
});

test('fee lines and a fixed fee: both are grossed up (Etsy on 100)', () => {
  const P2 = require('../lib/platform-fees.js');
  const lines = P2.feeLinesFor('etsy', {});
  const q = quoteTotal({ baseCost: 100, extraLines: lines });
  const G = 100.2 / (1 - 0.095);
  assert.equal(q.feeBase, G);
  assert.equal(q.extrasFixed, 0.2);
  assert.equal(q.extrasPercent, Math.round(G * 6.5) / 100 + Math.round(G * 3) / 100);
  assert.equal(q.total, 110.72);
  assert.ok(Math.abs(shopKeeps(q.total, [6.5, 3], 0.2) - 100) < 0.01);
});

test('several fee lines gross up together, not one on top of another', () => {
  const two = quoteTotal({ baseCost: 200, shippingCost: 15, extraLines: [fee(5), fee(5)] });
  const one = quoteTotal({ baseCost: 200, shippingCost: 15, extraLines: [fee(10)] });
  assert.equal(two.feeBase, one.feeBase);
  assert.ok(Math.abs(two.total - one.total) <= 0.01 + 1e-9, 'the same price, give or take a cent per line');
  assert.ok(Math.abs(shopKeeps(two.total, [5, 5]) - 215) < 0.01);
  // Reordering the lines — fees, surcharges and fixed — cannot change the total.
  const lines = [fee(2.9), { amount: 0.3 }, fee(6.5, { fee: true }), { pct: 4 }, { amount: 4 }];
  const first = quoteTotal({ baseCost: 87.3, extraLines: lines }).total;
  const perms = (xs) => xs.length <= 1 ? [xs]
    : xs.flatMap((x, i) => perms([...xs.slice(0, i), ...xs.slice(i + 1)]).map((r) => [x, ...r]));
  for (const order of perms(lines)) {
    assert.equal(quoteTotal({ baseCost: 87.3, extraLines: order }).total, first, JSON.stringify(order));
  }
});

test('fees of 95% or more are not grossed up — no runaway price, no Infinity, and a warning', () => {
  for (const pcts of [[95], [60, 40], [100], [150], [50, 50, 50]]) {
    const q = quoteTotal({ baseCost: 100, shippingCost: 10, extraLines: pcts.map((p) => fee(p)) });
    assert.equal(q.feeWarning, 'fees-too-high', JSON.stringify(pcts));
    assert.equal(q.feePct, pcts.reduce((s, p) => s + p, 0));
    assert.equal(q.feeBase, 110, 'falls back to the old arithmetic: each fee on the pre-fee price');
    for (const v of Object.values(q)) if (typeof v === 'number') assert.ok(Number.isFinite(v));
    assert.ok(Math.abs(q.total - (110 + 110 * q.feePct / 100)) < 0.01);
  }
  // Only FEE lines count toward the cap: a big surcharge beside a small fee
  // still grosses the fee up.
  const mixed = quoteTotal({ baseCost: 100, extraLines: [{ pct: 90 }, fee(10)] });
  assert.equal(mixed.feeWarning, null);
  assert.equal(mixed.feePct, 10);
  assert.ok(Math.abs(shopKeeps(mixed.total, [10]) - 190) < 0.01);
  // Just under the guard still grosses up.
  const q = quoteTotal({ baseCost: 100, extraLines: [fee(94.9)] });
  assert.equal(q.feeWarning, null);
  assert.ok(Math.abs(shopKeeps(q.total, [94.9]) - 100) < 0.01);
  assert.equal(P.FEE_PCT_CAP, 95);
});

test('rounding: each fee line is to the cent and the parts add up to the total', () => {
  const rnd = makeRandom(7);
  for (let i = 0; i < 2000; i++) {
    const lines = [];
    const n = 1 + Math.floor(rnd() * 3);
    for (let k = 0; k < n; k++) lines.push(fee(Math.round(rnd() * 1500) / 100 + 0.01, { label: `F${k}` }));
    if (rnd() < 0.5) lines.push({ label: 'Flat', amount: Math.round(rnd() * 500) / 100 });
    if (rnd() < 0.5) lines.push({ label: 'Design', pct: Math.round(rnd() * 2000) / 100 });
    const input = {
      baseCost: Math.round(rnd() * 100000) / 100, margin: Math.round(rnd() * 100),
      discountPct: rnd() < 0.3 ? 10 : 0, rushEnabled: rnd() < 0.3, rushPct: 25,
      shippingCost: rnd() < 0.5 ? Math.round(rnd() * 3000) / 100 : 0, extraLines: lines,
    };
    const q = quoteTotal(input);
    const rows = resolveExtraLines(lines, q.extrasBase, q.feeBase);
    const feeRows = rows.filter((r, k) => P.isFeeLine(lines[k]));
    for (const r of feeRows) assert.equal(Math.round(r.amount * 100) / 100, r.amount, 'a fee line is not to the cent');
    // The rows ARE the lines the total was built from.
    assert.ok(Math.abs(rows.reduce((s, r) => s + r.amount, 0) - q.extras) < 1e-9);
    assert.ok(Math.abs(q.subtotal + q.rushFee + q.shipping + q.extras - q.total) < 1e-9);
    // Each fee line is the platform's actual fee on the price charged, to the cent.
    for (const r of feeRows) {
      assert.ok(Math.abs(r.amount - q.total * r.pct / 100) <= 0.01 + 1e-9, `${r.pct}% line ${r.amount}`);
    }
    // After every fee the shop keeps all the rest, within a cent per fee line.
    const feeSum = feeRows.reduce((s, r) => s + r.amount, 0);
    const pre = q.total - feeSum;
    const pcts = feeRows.map((r) => r.pct);
    assert.ok(Math.abs(shopKeeps(q.total, pcts) - pre) <= 0.01 * pcts.length + 1e-9,
      `case ${i}: kept ${shopKeeps(q.total, pcts)} of ${pre}`);
  }
});

test('rounding the total or typing a price is still the last word', () => {
  const q = quoteTotal({ baseCost: 100, extraLines: [fee(10)], priceRound: { step: 5, mode: 'up' } });
  assert.equal(q.computedTotal, 111.11);
  assert.equal(q.total, 115);
  const typed = quoteTotal({ baseCost: 100, extraLines: [fee(10)], priceOverride: 105 });
  assert.equal(typed.total, 105);
  assert.equal(typed.priceSource, 'override');
});

test('a saved job freezes the fee it was quoted with, from the fee base', () => {
  // The job freezes each line's money (lib/order-new.js) and the invoice prints
  // that frozen `amount` — nothing re-runs the arithmetic over an old record.
  const fs = require('fs');
  const path = require('path');
  const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');
  assert.match(read('lib/order-new.js'), /resolveExtraLines\(extraLines, quote\.extrasBase, quote\.feeBase\)/);
  assert.match(read('lib/invoice-document.js'), /fmtMoney\(\+l\.amount \|\| 0\)/);
  // And every screen that resolves rows hands over both bases.
  const build = read('renderer/build.js');
  const calls = build.match(/resolveExtraLines\([^)]*\)/g) || [];
  assert.ok(calls.length >= 2);
  for (const c of calls) assert.match(c, /feeBase/, `a screen resolves rows without the fee base: ${c}`);
});
