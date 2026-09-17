/**
 * lib/expense-categories.js is `renderExpenseCategoryChart`'s arithmetic,
 * lifted out of renderer/analytics.js.
 *
 * THE PROOF METHOD: the original loop is copied below VERBATIM and compared
 * against the module over generated books. It matches exactly wherever no tax
 * is reclaimable, which is every shop that is not registered and every
 * expense recorded without a `vatAmount`.
 *
 * THE ONE DELIBERATE CHANGE is outside that comparison and has its own tests:
 * the tax on a purchase is not a cost for a registered shop, because it is
 * reclaimed. `lib/pnl-report.js` has always charged `paid - claimable`; this
 * chart summed the gross, so the two disagreed by the whole of the reclaimable
 * tax — 15% of every category with a receipt, at the Saudi rate — and a shop
 * reading one and then the other saw two totals for the same money.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { byCategory } = require('../lib/expense-categories.js');

/** The chart's own loop, as it stood. */
function original(filtered) {
  const totals = {};
  for (const e of filtered) {
    const cat = e.category || 'other';
    totals[cat] = (totals[cat] || 0) + (+e.amount || 0);
  }
  const sorted = Object.entries(totals).sort((a, b) => b[1] - a[1]);
  const grand = sorted.reduce((s, [, v]) => s + v, 0) || 1;
  const maxV = sorted[0]?.[1] || 1;
  return { sorted, grand, maxV };
}

function rng(seed) { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); }
const pick = (r, list) => list[Math.floor(r() * list.length)];
const CATS = ['filament', 'rent', 'power', 'tools', 'other', '', undefined, 'packaging'];

function genBook(r) {
  const n = Math.floor(r() * 12);
  const out = [];
  for (let i = 0; i < n; i++) {
    const e = { category: pick(r, CATS) };
    if (r() < 0.9) e.amount = Math.round(r() * 100000) / 100;
    if (r() < 0.2) e.amount = pick(r, [0, -5, 'abc', null]);
    out.push(e);
  }
  if (r() < 0.1) out.push(null);
  return out;
}

test('with nothing reclaimable it is the chart\'s own arithmetic, exactly', () => {
  const r = rng(20260916);
  let nonEmpty = 0;
  for (let i = 0; i < 500; i++) {
    const book = genBook(r);
    const was = original(book.filter(Boolean));
    const now = byCategory(book, { reclaimsTax: false });

    assert.deepEqual(now.rows.map((x) => [x.category, x.amount]), was.sorted,
      `book ${i}: ${JSON.stringify(book)}`);
    // `grand` used `|| 1` only to avoid dividing by zero; the real total is
    // what the categories came to.
    assert.equal(now.total, was.sorted.reduce((s, [, v]) => s + v, 0));
    // `maxV` carried the chart's own `|| 1`, which exists to stop a bar
    // dividing by zero and is not a total. The real biggest is what the top
    // category came to, which may legitimately be nought.
    assert.equal(now.biggest, was.sorted[0]?.[1] ?? 0);
    // And the share is the same percentage the chart printed.
    for (const row of now.rows) {
      // `+ 0` normalises a negative zero: a category whose expenses sum to a
      // small negative rounds to -0, and -0 is not 0 under strict equality
      // though every screen prints them the same.
      assert.equal(Math.round(row.share * 100) + 0, Math.round(row.amount / was.grand * 100) + 0);
    }
    if (now.rows.length) nonEmpty++;
  }
  assert.ok(nonEmpty > 400, `only ${nonEmpty} books had any rows`);
});

test('a registered shop does not count the tax it reclaims as a cost', () => {
  const book = [
    { category: 'filament', amount: 115, vatAmount: 15 },
    { category: 'filament', amount: 100 },            // no field: reclaims nothing
    { category: 'rent', amount: 50, vatAmount: 0 },
  ];
  const registered = byCategory(book, { reclaimsTax: true });
  assert.equal(registered.total, 250);
  assert.equal(registered.reclaimed, 15);
  assert.deepEqual(registered.rows.map((r) => [r.category, r.amount]), [['filament', 200], ['rent', 50]]);

  // The same book for a shop that is not registered: every riyal is a cost.
  const not = byCategory(book, { reclaimsTax: false });
  assert.equal(not.total, 265);
  assert.equal(not.reclaimed, 0);

  // Which is exactly what the P&L does with the same numbers.
  const asPnl = book.reduce((s, e) => s + (+e.amount || 0) - Math.min(+e.amount || 0, Math.max(0, +e.vatAmount || 0)), 0);
  assert.equal(registered.total, asPnl, 'the chart and the P&L disagree again');
});

test('a receipt claiming more tax than it paid cannot make a category negative', () => {
  const odd = byCategory([{ category: 'x', amount: 50, vatAmount: 900 }], { reclaimsTax: true });
  assert.equal(odd.rows[0].amount, 0);
  assert.equal(odd.reclaimed, 50);
  // A negative vatAmount reclaims nothing rather than adding to the cost.
  const neg = byCategory([{ category: 'x', amount: 50, vatAmount: -20 }], { reclaimsTax: true });
  assert.equal(neg.rows[0].amount, 50);
});

test('an entirely reclaimable book shares out as nought, not NaN', () => {
  const all = byCategory([{ category: 'x', amount: 15, vatAmount: 15 }], { reclaimsTax: true });
  assert.equal(all.total, 0);
  assert.equal(all.rows[0].share, 0);
  assert.equal(byCategory([], {}).total, 0);
  assert.deepEqual(byCategory(null, {}).rows, []);
});
