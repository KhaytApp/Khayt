/**
 * Percentage fees, as wired through the app.
 *
 * lib/pricing.js is where the arithmetic is tested. What can only go wrong here
 * is that one of the OTHER places that price a job does not know about them —
 * and every one of those failures is a wrong number that still looks plausible:
 *
 *   1. The logged order. renderer/order-flows.js used to re-derive the price
 *      itself, summing `l.amount` — which a percentage line does not have. A
 *      quote shown as 132 was logged as 120, and nothing anywhere disagreed.
 *      That block was also the "second implementation" lib/pricing.js was
 *      extracted to prevent.
 *   2. The invoice. It renders `l.amount`, so a percentage line would print as
 *      0.00 on the document the customer actually receives.
 *   3. The order editor, which edits `amount` in place. Leaving a stale `pct`
 *      beside an edited amount means the invoice shows one number and any
 *      re-quote computes another.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const build = read('renderer/build.js');
const flows = read('renderer/order-flows.js');
const invoicing = read('renderer/invoicing.js');
const { quoteTotal, resolveExtraLines } = require('../lib/pricing.js');

test('the logged order is priced by lib/pricing.js, not a second formula', () => {
  // The record moved to lib/order-new.js so the Mac app could create a job at
  // all; the claim is the same one and this follows it there.
  const shared = read('lib/order-new.js');
  const at = shared.indexOf('const totalBaseCost');
  const body = shared.slice(at, shared.indexOf('const year =', at));
  assert.match(body, /P\.quoteTotal\(/, 'the new order re-derives the price itself');
  // The specific shapes that could not see a percentage.
  assert.doesNotMatch(body, /extraLines\.reduce/, 'the extras are still summed by hand');
  assert.doesNotMatch(body, /totalBaseCost \* \(1 \+ margin \/ 100\)/,
    'the price formula is duplicated here — two prices for one job');

  // And the renderer must not have grown one back.
  assert.doesNotMatch(flows, /KhaytPricing\.quoteTotal\(/,
    'order-flows.js is pricing a new order again');
});

test('the logged line freezes the money a percentage resolved to', () => {
  // An invoice reports what was charged. Recomputing a percentage months later,
  // against a base that has since changed, is a different number on a document
  // the customer already has.
  assert.match(read('lib/order-new.js'), /P\.resolveExtraLines\(extraLines, quote\.extrasBase, quote\.feeBase\)/,
    'the logged lines keep a percentage with no resolved amount');
});

test('the invoice shows the percentage and the frozen money', () => {
  // The document moved to lib/invoice-document.js so something other than the
  // Electron window could produce one; the claim is the same and follows it.
  const doc = read('lib/invoice-document.js');
  const at = doc.indexOf('const extraLinesHtml');
  const body = doc.slice(at, doc.indexOf('.join(\'\')', at));
  assert.match(body, /\+l\.pct > 0/, 'a percentage fee is indistinguishable from a fixed one');
  assert.match(body, /fmtMoney\(\+l\.amount \|\| 0\)/, 'the invoice does not print the money');

  // And the renderer has not grown its own copy back.
  assert.doesNotMatch(invoicing, /const extraLinesHtml/,
    'renderer/invoicing.js is building the line items again');
});

test('editing an amount drops the percentage it overrode', () => {
  assert.match(flows, /line\.amount = Math\.max\(0, \+inp\.value \|\| 0\);\s*\n[\s\S]{0,260}delete line\.pct;/,
    'an edited amount leaves a stale pct beside it, and the two disagree');
});

test('the calculator has no second extras total left in it', () => {
  // It had one, dead, that could not see a percentage — a trap for whoever read
  // it next and assumed it was the real figure.
  assert.doesNotMatch(build, /const extraLinesTotal = biz \?/,
    'the dead hand-rolled extras total is back');
});

test('the row editor writes exactly one of pct or amount', () => {
  const at = build.indexOf('function renderExtraLines(');
  const body = build.slice(at, build.indexOf('\n}', at));
  // Both handlers — typing a number, and switching the unit — must clear the
  // other field, or a row can hold both and a later flip resurrects a figure
  // nobody typed.
  assert.equal((body.match(/delete line\.amount;/g) || []).length, 2,
    'switching to % or typing into a % row leaves the old amount behind');
  assert.equal((body.match(/delete line\.pct;/g) || []).length, 2,
    'switching to a fixed amount leaves the old percentage behind');
  assert.match(body, /class="el-unit"/, 'there is no way to choose percentage in the UI');
});

test('the resolved money on screen comes from the same computation as the total', () => {
  const at = build.indexOf('function renderExtraLines(');
  const body = build.slice(at, build.indexOf('\n}', at));
  assert.match(body, /KhaytPricing\.resolveExtraLines\(currentExtraLines/,
    'the row works out its own money and can disagree with the total above it');
});

test('the % rows refresh without rebuilding the inputs', () => {
  // renderExtraLines() rebuilds the <input>s; calling it from updateGrandTotal
  // would steal focus on every keystroke.
  const at = build.indexOf('lastQuote = _q;');
  assert.ok(at > -1, 'the quote is never published for the rows to read');
  // Comments stripped first: this block's own comment explains why
  // renderExtraLines() is NOT called here, and matching that would pass or fail
  // on prose rather than on code.
  const body = build.slice(at, at + 700)
    .split('\n').filter((l) => !l.trim().startsWith('//')).join('\n');
  assert.match(body, /\.el-resolved/, 'the resolved figures are never refreshed');
  assert.doesNotMatch(body, /renderExtraLines\(\)/, 'the inputs are rebuilt mid-typing');
});

test('end to end: a quote with a marketplace fee logs the number it showed', () => {
  // The bug this whole file exists for, as arithmetic.
  const lines = [{ label: 'Etsy', pct: 6.5 }, { label: 'Packaging', amount: 2 }];
  const q = quoteTotal({ baseCost: 100, qty: 1, margin: 0, shippingCost: 20, extraLines: lines });
  const frozen = resolveExtraLines(lines, q.extrasBase)
    .map((r, i) => ({ ...lines[i], label: r.label, amount: r.amount }));
  // What the invoice will add up, from the frozen amounts alone.
  const invoiceExtras = frozen.reduce((s, l) => s + (+l.amount || 0), 0);
  assert.equal(+invoiceExtras.toFixed(2), +q.extras.toFixed(2),
    'the invoice total would differ from the quoted total');
  // And re-quoting the frozen lines cannot double-charge.
  assert.equal(quoteTotal({ baseCost: 100, qty: 1, margin: 0, shippingCost: 20, extraLines: frozen }).total,
    q.total, 'a stored line with both pct and amount was charged twice');
});

test('the fee-type label is translated everywhere', () => {
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    assert.ok(read(`renderer/locales/${code}.js`).includes('"calc.extra_unit":'), `${code} is missing calc.extra_unit`);
  }
});
