const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

/**
 * Six defects that made the app report the wrong NUMBER — the failure mode that
 * matters most in a shop manager, because nothing crashes and nobody notices.
 *
 * These are source-level guards rather than behavioural tests: the functions
 * involved live inside large renderer IIFEs that assume a DOM and the global
 * store, so requiring them in node is not possible without a fixture larger
 * than the thing under test. Each assertion therefore pins the specific
 * expression that was wrong, and each was mutation-checked by restoring the
 * original expression and confirming the test fails.
 */

test('a reorder unit price is per GRAM, not per spool', () => {
  // item.cost is the whole spool's cost. createPurchaseOrder multiplies
  // unitPrice by a qty measured in grams, so returning it undivided made every
  // auto-drafted PO ~1000x too expensive: 750 g of an 85/kg spool quoted at
  // 63,750 instead of 63.75.
  const src = read('renderer/inventory.js');
  const fn = src.slice(src.indexOf('function resolveReorderPrice'), src.indexOf('function maybeAutoDraftPurchaseOrders'));
  assert.match(fn, /perSpool\s*\/\s*Math\.max\(1,\s*\+item\.spoolWeight/,
    'the item.cost fallback must divide by spoolWeight to reach a per-gram rate');
  assert.equal(/const perG = \(\+item\.cost\) \|\|/.test(fn), false,
    'undivided item.cost is a per-spool figure and must not be returned as perG');
});

test('the per-gram arithmetic agrees with how stock is valued', () => {
  // The valuation at ~1572 is the reference: cost / spoolWeight * remaining.
  // If these two ever disagree again, one of them is wrong by ~1000x.
  const perGram = (item) => (+item.cost || 0) / Math.max(1, +item.spoolWeight || 1000);
  const item = { cost: 85, spoolWeight: 1000, weight: 400 };
  assert.equal(perGram(item), 0.085);
  assert.equal(Math.round(perGram(item) * item.weight * 100) / 100, 34, 'value of 400g of an 85/kg spool');
});

test('voided invoices are excluded everywhere revenue is totalled', () => {
  // Voiding deliberately KEEPS status 'completed' and only sets voidedAt, so a
  // status-only filter books a cancelled invoice as full revenue and full VAT.
  const src = read('renderer/analytics.js');
  const lines = src.split('\n');
  const bad = [];
  lines.forEach((l, i) => {
    // Any completed-status filter in a money aggregation must also test voidedAt.
    if (/o\.status === 'completed'/.test(l) && !/voidedAt/.test(l)) {
      // Only MONEY aggregations. Utilisation, on-time delivery and operator
      // stats also filter on completed, but whether a voided order counts as
      // work performed is a product judgment, not an arithmetic bug — excluded
      // deliberately rather than by oversight.
      const ctx = lines.slice(i, i + 4).join(' ');
      if (!/price|revenue|Revenue|orderRevenueBase|costBasis|profit/.test(ctx)) return;
      if (/machineId|clientId|operatorId|printingStartedAt|dueDate/.test(ctx)) return;
      bad.push(`analytics.js:${i + 1}`);
    }
    if (/if \(o\.status !== 'completed'\) continue;/.test(l)) bad.push(`analytics.js:${i + 1}`);
  });
  assert.deepEqual(bad, [], `revenue aggregations missing a !voidedAt guard:\n  ${bad.join('\n  ')}`);
});

test('saving instalments cannot destroy a recorded deposit', () => {
  // paidAmount is the authoritative cash figure and holds the deposit from
  // order creation. The plan generator builds a schedule with depositAmount:0
  // spanning the full price, so a freshly generated plan has instPaid = 0 —
  // assigning it over paidAmount erased a 500 deposit on save, silently.
  //
  // This pinned the exact expression `Math.max(+order.paidAmount || 0, instPaid)`
  // and so failed when the rule legitimately changed — the plan generator now
  // builds a schedule covering the BALANCE, so instalment payments have to be
  // ADDED to the deposit rather than compared against it, or an order paid in
  // full shows the deposit still outstanding forever.
  //
  // But the PROPERTY was right and catching something real: the first version of
  // that change dropped the Math.max, and `base + instPaid` is lower than
  // paidAmount whenever cash was taken at the counter and typed straight in — so
  // it destroyed exactly the money this test is named after. Assert the property.
  const src = read('renderer/order-flows.js');
  assert.equal(/^\s*order\.paidAmount = instPaid;\s*$/m.test(src), false,
    'the unconditional overwrite destroyed deposits');
  assert.match(src, /order\.paidAmount = Math\.max\(\+order\.paidAmount \|\| 0, fromPlan\);/,
    'paidAmount can move downward again — cash recorded outside the plan is destroyed');

  // Driven, not just read: the rule must never return less than it was given.
  const at = src.indexOf('const instBase = draft.instalmentBase;');
  assert.ok(at > 0, 'the paidAmount rule is gone');
  const body = src.slice(at, src.indexOf(';\n', src.indexOf('order.paidAmount =', at)) + 1);
  const rule = new Function('order', 'draft', 'instPaid', `${body}; return order.paidAmount;`);
  for (const [held, draft, instPaid] of [
    [1000, { instalmentBase: 1000 }, 0],        // plan made, nothing paid yet
    [1500, { instalmentBase: 1000 }, 0],        // 500 taken at the counter since
    [1500, { instalmentBase: 1000 }, 666.67],   // …and one row paid
    [1000, {}, 0],                              // a legacy plan, nothing paid
    [2500, {}, 100],                            // a legacy plan, cash beyond it
  ]) {
    assert.ok(rule({ paidAmount: held }, draft, instPaid) >= held,
      `paidAmount went DOWN from ${held} — recorded cash was destroyed`);
  }
  // And it does add, or the order never settles.
  assert.equal(rule({ paidAmount: 1000 }, { instalmentBase: 1000 }, 2000), 3000,
    'a plan covering the balance no longer settles the order');
});

test('"fully paid" is decided against the order price, not the instalment total', () => {
  // Instalment amounts are freely editable, so a partial plan (two 100 rows on
  // a 2,000 order) marked paid reported the whole order settled — and
  // paymentStatus is what the payment_received / paid webhooks carry.
  const src = read('renderer/order-flows.js');
  assert.equal(/instPaid >= totalInst \? 'paid'/.test(src), false,
    'comparing against the instalment total lets a partial plan report as settled');
  assert.match(src, /const owed = \+order\.price \|\| 0;/, 'the comparison must anchor on the order price');
});

test('the paid/partial decision behaves correctly at the boundary', () => {
  const decide = (paid, owed) => (paid <= 0 ? 'unpaid' : (owed > 0 && paid + 0.005 >= owed ? 'paid' : 'partial'));
  assert.equal(decide(0, 2000), 'unpaid');
  assert.equal(decide(200, 2000), 'partial', 'a partial plan marked paid is still partial');
  assert.equal(decide(2000, 2000), 'paid');
  // Float drift must not leave an order eternally one-hundredth short.
  assert.equal(decide(0.1 + 0.2, 0.3), 'paid', '0.1+0.2 !== 0.3 must still settle');
  assert.equal(decide(1999.999, 2000), 'paid', 'sub-cent drift settles');
  assert.equal(decide(1999, 2000), 'partial', 'a real shortfall does not');
});

test('archived orders release their stock reservation', () => {
  // renderPipelineDemand already excluded archived orders, so a reservation
  // surviving archiving contradicted the demand view sitting beside it: a
  // spool showed 600g reserved by a job nobody was going to print.
  const src = read('renderer/inventory.js');
  const lines = src.split('\n');
  const bad = [];
  lines.forEach((l, i) => {
    if (/o\.status !== 'completed' && o\.status !== 'quote'/.test(l) && !/archived/.test(l)) {
      bad.push(`inventory.js:${i + 1}`);
    }
  });
  assert.deepEqual(bad, [], `reservation filters that still count archived orders:\n  ${bad.join('\n  ')}`);
});

test('monthly margin is blended, not a mean of percentages', () => {
  const src = read('renderer/analytics.js');
  assert.equal(/marginByMonth\[m\]\.total \+= margin;/.test(src), false,
    'summing per-order percentages lets one tiny job dominate the month');
  // Pin the SHAPE (money accumulates into .revenue/.cost, the ratio is taken
  // once at the end) rather than the exact price expression — that expression
  // now nets credit notes, see the credit-note tests below.
  assert.match(src, /marginByMonth\[m\]\.revenue \+=/, 'accumulate money, divide once');
  assert.match(src, /marginByMonth\[m\]\.cost \+= \+o\.costBasis;/, 'cost accumulates alongside revenue');

  // The arithmetic, with the case that exposed it.
  const rows = [{ price: 100, cost: 20 }, { price: 10000, cost: 9000 }];
  const unweighted = rows.map((r) => (r.price - r.cost) / r.price * 100).reduce((a, b) => a + b) / rows.length;
  const rev = rows.reduce((s, r) => s + r.price, 0);
  const cost = rows.reduce((s, r) => s + r.cost, 0);
  const blended = (rev - cost) / rev * 100;
  assert.equal(Math.round(unweighted * 10) / 10, 45, 'the old figure');
  assert.equal(Math.round(blended * 10) / 10, 10.7, 'the true figure');
  // 45 crossed the green threshold (>= 40); 10.7 does not. The colour was lying too.
  assert.ok(unweighted >= 40 && blended < 40);
});

/* ============================================================
   Credit notes (refunds) must leave reported revenue
   ============================================================ */

require('../renderer/format.js');
const CUR = require('../renderer/currency.js');

/** Extract VAT out of a VAT-inclusive figure, the formula used app-wide. */
const vatOf = (revenue, rate) => (rate > 0 ? revenue * rate / (100 + rate) : 0);

test('a partial refund leaves no marker on the order at all', () => {
  // This is WHY the defect survived: generateCreditNote records the credit only
  // in creditNotes[] and sets creditedAt only on a FULL credit, so a partially
  // refunded order is indistinguishable from an unrefunded one to any filter
  // that looks at status / voidedAt / creditedAt.
  const o = { status: 'completed', price: 3000, paidAmount: 3000, creditNotes: [{ amount: 1200 }] };
  assert.equal(o.voidedAt, undefined);
  assert.equal(o.creditedAt, undefined);
  assert.equal(o.status, 'completed');
  const src = read('renderer/invoicing.js');
  assert.match(src, /if \(totalCredited >= \(\+order\.price \|\| 0\)\) \{/,
    'creditedAt is set only at FULL credit — a partial refund must be caught via creditNotes[]');
});

test('credit notes come out of revenue, and VAT follows revenue', () => {
  global.settings = { currency: 'SAR', vatRate: 15, exchangeRates: {} };
  global.clients = [];
  const o = { status: 'completed', price: 3000, paidAmount: 3000, creditNotes: [{ amount: 1200 }] };

  // The figures the app used to report.
  assert.equal(CUR.orderRevenueBase(o), 3000);
  assert.equal(vatOf(CUR.orderRevenueBase(o), 15).toFixed(2), '391.30');

  // The true figures.
  assert.equal(CUR.orderNetRevenueBase(o), 1800);
  assert.equal(vatOf(CUR.orderNetRevenueBase(o), 15).toFixed(2), '234.78');
});

test('netting converts the credit at the order rate, not the shop rate', () => {
  global.settings = { currency: 'SAR', vatRate: 15, exchangeRates: { USD: 3.75 } };
  global.clients = [{ id: 'c-us', currency: 'USD' }];
  const o = { status: 'completed', clientId: 'c-us', price: 1000, creditNotes: [{ amount: 400 }] };
  assert.equal(CUR.orderRevenueBase(o), 3750);
  assert.equal(CUR.orderNetRevenueBase(o), 2250, '600 USD earned, at 3.75');
  // Subtracting the raw 400 from the converted 3750 would give 3350 — the bug
  // this reuse of convertToBase exists to prevent.
  assert.notEqual(CUR.orderNetRevenueBase(o), 3350);
});

test('net revenue clamps at zero and ignores junk credit amounts', () => {
  global.settings = { currency: 'SAR', exchangeRates: {} };
  global.clients = [];
  assert.equal(CUR.orderNetRevenueBase({ price: 500 }), 500, 'no creditNotes → unchanged');
  assert.equal(CUR.orderNetRevenueBase({ price: 500, creditNotes: [] }), 500);
  assert.equal(CUR.orderNetRevenueBase({ price: 500, creditNotes: [{ amount: 900 }] }), 0,
    'an over-credit must not report negative revenue');
  assert.equal(CUR.orderNetRevenueBase({ price: 500, creditNotes: [{ amount: 'x' }, { amount: null }, { amount: 100 }] }), 400);
});

test('gift-card redemption is a tender, NOT a reduction of revenue', () => {
  // Deliberate asymmetry with orderOwedBase, which nets BOTH. Issuing a gift
  // card creates no order (giftCards[] is its own collection), so redemption is
  // the only point at which that money can be recognised as revenue — netting
  // it here would recognise it nowhere. Every other path agrees it is a tender.
  global.settings = { currency: 'SAR', exchangeRates: {} };
  global.clients = [];
  const o = { status: 'completed', price: 1000, giftCardDiscount: 400 };
  assert.equal(CUR.orderNetRevenueBase(o), 1000, 'a gift-card-settled sale is still a sale');

  // The rule moved to lib/order-payment.js — payStatus and the payment modal
  // both defer to it now, which is the point: they used to disagree, and one of
  // them WROTE the field the other read.
  const payment = read('lib/order-payment.js');
  assert.match(payment, /const paid = numberOf\(order\.paidAmount\) \+ numberOf\(order\.giftCardDiscount\);/,
    'a gift card is cash paid, not a discount');
  assert.match(payment, /const due = Math\.max\(0, price - credited\);/,
    'and a credit note reduces what is DUE — the two sides of the division');
  const P = require('../lib/order-payment.js');
  assert.equal(P.statusOf({ price: 1000, giftCardDiscount: 1000 }), 'paid',
    'a gift card settles the order');
  assert.equal(P.statusOf({ price: 1000, giftCardDiscount: 400 }), 'partial');
  const integrations = read('renderer/integrations.js');
  assert.match(integrations, /Gift Card Liability/,
    'the journal clears gift-card settlement against a liability, i.e. it is a tender');
});

test('orderOwedBase still nets credit notes after the refactor', () => {
  global.settings = { currency: 'SAR', exchangeRates: {} };
  global.clients = [];
  assert.equal(CUR.orderOwedBase({ price: 3000, paidAmount: 1000, creditNotes: [{ amount: 1200 }] }), 800);
  assert.equal(CUR.orderOwedBase({ price: 1000, paidAmount: 0, giftCardDiscount: 400, creditNotes: [{ amount: 200 }] }), 400);
});

test('no revenue aggregation still totals the GROSS price', () => {
  // The broad guard. Deliberately over-flags every orderRevenueBase call in the
  // renderer, then subtracts only the sites that are documented exclusions.
  // Anything new that answers "how much did the shop earn" trips this.
  const files = [
    'renderer/analytics.js', 'renderer/clients.js', 'renderer/expenses.js', 'renderer/kanban.js',
    'renderer/dashboard.js', 'renderer/inventory.js', 'renderer/operations-extras.js',
    'renderer/queue-list.js', 'renderer/waste.js', 'renderer/settings.js', 'renderer/logs.js',
    'renderer/themes/vivid/screens.js', 'renderer/themes/command/shell.js', 'renderer/themes/command/screens.js',
  ];
  const bad = [];
  for (const rel of files) {
    read(rel).split('\n').forEach((l, i) => {
      if (!/\borderRevenueBase\b/.test(l)) return;
      // EXCLUSION: the report builder emits per-order document columns ("price"
      // beside paidAmount/balance), reproducing the invoice rather than
      // reporting earnings.
      if (/price: Math\.round\(orderRevenueBase\(o\)\)/.test(l)) return;
      bad.push(`${rel}:${i + 1}  ${l.trim()}`);
    });
  }
  assert.deepEqual(bad, [], `revenue aggregations still using the gross price:\n  ${bad.join('\n  ')}`);
});

test('the client statement and the journal keep the GROSS figure on purpose', () => {
  // Both already account for credit notes as their own line. Netting here would
  // subtract the same credit twice — the mirror image of the defect above.
  const inv = read('renderer/invoicing.js');
  assert.match(inv, /const totalCharges = orders\.reduce\(\(s, o\) => s \+ orderRevenueBase\(o\), 0\);/,
    'the statement charges line is gross; totalCredit is shown beside it');
  assert.match(inv, /const totalCredit\s+= orders\.reduce/, 'and the credit line must still exist');

  const integrations = read('renderer/integrations.js');
  assert.match(integrations, /'Credit Note'.*'Revenue'/,
    'the journal reverses credit notes as their own double-entry rows');
});

test('every VAT figure is derived from the netted revenue', () => {
  // The property is WHICH REVENUE the tax is taken from — orderNetRevenueBase,
  // which subtracts credit notes — not the arithmetic used to take it. That
  // arithmetic moved into lib/tax.js when exclusive pricing arrived, and pinning
  // the old formula text would have failed a change that preserved the property
  // exactly. So assert the input, and assert the gross price is NOT the input.
  // The quarterly table's VAT moved into lib/pnl-report.js, so the property is
  // asserted THERE, by running it: a credit note must reduce the tax collected
  // exactly as it reduces the revenue. The remaining source pins cover the
  // exports that still take it themselves.
  require('../lib/business-scope.js');
  require('../lib/order-money.js');
  require('../lib/tax.js');
  const { pnlByPeriod } = require('../lib/pnl-report.js');
  const settings = { currency: 'SAR', enableVat: true, vatRate: 15 };
  const gross = pnlByPeriod([{ id: 'A', status: 'completed', date: '2026-08-10', price: 1000 }],
                            [], { settings, now: new Date(2026, 8, 4) })[0];
  const credited = pnlByPeriod([{ id: 'A', status: 'completed', date: '2026-08-10', price: 1000,
                                  creditNotes: [{ amount: 400 }] }],
                               [], { settings, now: new Date(2026, 8, 4) })[0];
  assert.equal(gross.vatCollected, 130.43);
  // 521.74, not 600: revenue is also net of the TAX now (see the test below).
  // What this one is about is the CREDIT NOTE, and the property it pins is that
  // the credit reduces the tax as well as the sale — 78.26 rather than 130.43.
  assert.equal(credited.revenue, 521.74, 'the credit note reduces the sale');
  assert.equal(Math.round((credited.revenue + credited.vatCollected) * 100) / 100, 600,
    'and the two together are what the customer was charged after the credit');
  assert.equal(credited.vatCollected, 78.26,
    'and the tax collected with it — VAT must follow the netted revenue, never the gross price');

  const checks = [
    ['renderer/expenses.js',  /vatCollected \+= KhaytTax\.computeTax\(\s*orderNetRevenueBase\(o\)/],
  ];
  for (const [rel] of checks) {
    assert.doesNotMatch(read(rel), /vatCollected \+= [^\n]*\bo\.price\b/,
      `${rel}: VAT collected must never be taken from the gross price`);
  }
  for (const [rel, re] of checks) {
    assert.match(read(rel), re, `${rel}: VAT collected must follow revenue, not the gross price`);
  }
  assert.doesNotMatch(read('renderer/analytics.js'), /vatCollected \+=/,
    'renderer/analytics.js must not total VAT itself any more — lib/pnl-report.js does');
  // The ZATCA/GAZT return's sales boxes must net credits too — and, since a
  // Saudi shop's prices INCLUDE the VAT, must have the VAT taken back out. This
  // pinned the exact old expression, which is the mistake the comment at the top
  // of this test warns against: it would have failed a change that preserved the
  // property. Assert the property. (The old expression was also wrong in the
  // other direction — it reported the gross as sales. See test/vat-return.test.js.)
  const vatReturn = (() => {
    const src = read('renderer/operations-extras.js')
      .replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
    const at = src.indexOf('function exportGaztVatReturn');
    assert.ok(at > 0, 'the VAT return is gone');
    return src.slice(at, at + 3000);
  })();
  assert.match(vatReturn, /const gross = orderNetRevenueBase\(o\);/,
    'the VAT return must take its sales from the netted revenue, not the gross price');
  assert.match(vatReturn, /KhaytTax\.computeTax\(gross, taxProfile\)/,
    'the VAT return must split net from VAT with the same module the invoices use');
  assert.ok(!/box1 \+= gross/.test(vatReturn),
    'box1 (standard-rated sales) must be NET of VAT — prices in Khayt include it');
});

test('margin figures net credit notes in the order\'s own currency', () => {
  // These three pair the price with costBasis / shippingCost, which are NOT
  // converted to base. Netting the credit in base here would divide a converted
  // numerator by an unconverted denominator, so they use orderCreditedRaw.
  // (The pre-existing currency mismatch between price and costBasis is a
  // separate defect and is deliberately left alone here.)
  assert.match(read('renderer/analytics.js'),
    /marginByMonth\[m\]\.revenue \+= Math\.max\(0, \(\+o\.price \|\| 0\) - orderCreditedRaw\(o\)\);/,
    'the monthly margin chart must net credit notes');
  assert.match(read('renderer/analytics.js'),
    /const rev = Math\.max\(0, \(\+o\.price \|\| 0\) - orderCreditedRaw\(o\)\);/,
    'the exported average margin must net credit notes');
  assert.match(read('renderer/logs.js'),
    /const gross = \(\+o\.price \|\| 0\) - \(\+o\.shippingCost \|\| 0\) - credited;/,
    'the orders-log margin column must net credit notes');
});

test('a refund moves the margin it should', () => {
  // 1,000 sale costing 600 is a 40% margin. Refund 400 and the shop earned 600
  // on a 600 cost — margin 0. Reading the gross price leaves it at 40%.
  const netRev = (o) => Math.max(0, (+o.price || 0) - (o.creditNotes || []).reduce((s, cn) => s + (+cn.amount || 0), 0));
  const o = { price: 1000, costBasis: 600, creditNotes: [{ amount: 400 }] };
  assert.equal((o.price - o.costBasis) / o.price * 100, 40, 'the figure the chart used to show');
  assert.equal((netRev(o) - o.costBasis) / netRev(o) * 100, 0, 'the true margin');
});

test('the income statement books revenue NET OF TAX, in either pricing mode', () => {
  // THE THIRD AXIS. This file already guards two questions about which figure
  // "revenue" means — the gross price versus the credit-netted one. This is the
  // one it did not ask: whether the tax is in it.
  //
  // ZATCA and IFRS 15 both treat tax collected on a sale as money held for the
  // government. It is a liability until it is remitted and it is never income,
  // so an income statement that counts it overstates profit by exactly the tax.
  // Khayt's own accountant export has always split it (`vatSplit` in
  // lib/accounting-export.js); the quarterly P&L did not, so the same book
  // answered one way to the shop and another to its accountant.
  //
  // AND THE MODE DECIDES, which is the easy way to break it in the other
  // direction: under `exclusive` the price a shop enters is ALREADY net and the
  // tax is added on top, so subtracting again would understate every such
  // shop's revenue.
  require('../lib/business-scope.js');
  require('../lib/order-money.js');
  require('../lib/tax.js');
  const { pnlByPeriod } = require('../lib/pnl-report.js');
  const when = { now: new Date(2026, 8, 4) };
  const order = [{ id: 'A', status: 'completed', date: '2026-08-10', price: 1150 }];
  const rated = (mode) => ({
    currency: 'SAR',
    tax: { name: 'VAT', mode, registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] },
  });

  const inclusive = pnlByPeriod(order, [], { settings: rated('inclusive'), ...when })[0];
  assert.equal(inclusive.revenue, 1000, 'the tax comes out of an inclusive price');
  assert.equal(inclusive.vatCollected, 150);
  assert.equal(inclusive.net, 1000, 'and the net is the revenue, not the takings');

  const exclusive = pnlByPeriod(order, [], { settings: rated('exclusive'), ...when })[0];
  assert.equal(exclusive.revenue, 1150, 'an exclusive price IS the revenue — nothing to remove');
  assert.equal(exclusive.vatCollected, 172.5, 'the tax is charged on top of it');
  assert.equal(exclusive.net, 1150);

  // A shop that is not registered has no tax to take out of anything.
  const none = pnlByPeriod(order, [], { settings: { currency: 'SAR' }, ...when })[0];
  assert.equal(none.revenue, 1150);
  assert.equal(none.vatCollected, 0);

  // And the figure the shop actually banked is still recoverable: revenue plus
  // the tax it collected is what the customer was charged.
  assert.equal(Math.round((inclusive.revenue + inclusive.vatCollected) * 100) / 100, 1150);
});

test('the P&L, the dashboard and the best lists report the SAME revenue', () => {
  // Three surfaces answer "what did the shop earn", and until now two of them
  // answered with the tax included. The figures a shop compares across screens
  // have to be the same figure, so this asserts they agree rather than
  // asserting each one separately against a number typed here.
  require('../lib/business-scope.js');
  require('../lib/order-money.js');
  require('../lib/tax.js');
  const { pnlByPeriod } = require('../lib/pnl-report.js');
  const KpiRows = require('../lib/kpi-rows.js');
  const Kpi = require('../lib/kpi.js');
  const TopLists = require('../lib/top-lists.js');

  const settings = {
    currency: 'SAR',
    tax: { name: 'VAT', mode: 'inclusive', registration: 'VAT No.', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] },
  };
  const orders = [
    { id: 'A', status: 'completed', date: '2026-08-10', price: 1150, clientId: 'C1' },
    { id: 'B', status: 'completed', date: '2026-08-20', price: 2300, clientId: 'C1' },
  ];
  const clients = [{ id: 'C1', name: 'One Customer' }];
  const CHARGED = 3450;
  const NET = 3000;          // 3,450 inclusive of 15% is 3,000 plus 450 tax

  const pnl = pnlByPeriod(orders, [], { settings, clients, now: new Date(2026, 8, 4) })[0];
  assert.equal(pnl.revenue, NET, 'the P&L');
  assert.equal(pnl.vatCollected, 450);

  const rows = KpiRows.kpiRows({
    orders, from: '2026-08-01', to: '2026-08-31', settings,
    money: (o) => ({ revenue: +o.price || 0, cost: 0, outstanding: 0 }),
  });
  assert.equal(Kpi.computeKpis(rows).revenue, NET, 'the dashboard');

  const top = TopLists.topClients(orders, { settings, clients });
  assert.equal(Math.round(top[0].revenue * 100) / 100, NET, 'the best-customers list');

  // And none of them is quietly reporting what the customer was charged.
  assert.notEqual(pnl.revenue, CHARGED);
  assert.equal(Math.round((pnl.revenue + pnl.vatCollected) * 100) / 100, CHARGED,
    'which is still recoverable, as revenue plus the tax collected');
});
