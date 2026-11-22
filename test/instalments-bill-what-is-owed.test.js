'use strict';
/**
 * Generating a payment plan billed the deposit a second time.
 *
 * The "generate instalments" button passed the order's GROSS PRICE:
 *
 *     const total = +order.price || 0;
 *     KhaytPaymentPlan.buildSchedule({ total, depositAmount: 0, installments: 3, ... })
 *
 * So a SAR 3,000 job with a SAR 1,000 deposit already taken produced three
 * payments of SAR 1,000 — SAR 3,000 in total, against SAR 2,000 outstanding.
 * The customer was asked for money they had already handed over, and the shop
 * had no figure anywhere telling it otherwise.
 *
 * `orderOwedRaw` is the order-currency counterpart of `orderOwedBase`: the same
 * rules (cash, gift-card redemption and credit notes all pay an order down)
 * without converting to base, because the caller writes amounts BACK onto the
 * order. An instalment plan denominated in the shop's base currency on an order
 * priced in another would be a second bug.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const P = require('../lib/payment-plan.js');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

/** orderOwedRaw, loaded out of renderer/currency.js rather than re-implemented. */
function loadOwedRaw() {
  const sandbox = { globalThis: null, window: {}, module: { exports: {} }, console };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  // business-scope FIRST: orderOwedRaw gates on KhaytBusinessScope, and a
  // sandbox without it silently skips both gates — the test would then pass
  // while the shipped code, which does have it, behaved differently.
  vm.runInContext(read('lib/business-scope.js'), sandbox, { filename: 'business-scope.js' });
  sandbox.module = { exports: {} };
  // order-money.js first: currency.js's rules moved there so the Mac app
  // could share them, and it delegates through the global. In a sandbox
  // there is no require, so the dependency has to be run in here too.
  vm.runInContext(read('lib/order-money.js'), sandbox, { filename: 'order-money.js' });
  vm.runInContext(read('renderer/currency.js'), sandbox, { filename: 'currency.js' });
  const api = sandbox.module.exports;
  assert.equal(typeof api.orderOwedRaw, 'function', 'orderOwedRaw is not exported');
  return api.orderOwedRaw;
}

const owedRaw = loadOwedRaw();
const TODAY = new Date().toISOString().slice(0, 10);
const plan = (total) => P.buildSchedule({ total, depositAmount: 0, installments: 3, firstDueDate: TODAY, intervalDays: 30 });
const sum = (s) => Math.round(s.reduce((a, x) => a + x.amount, 0) * 100) / 100;

test('a deposit already taken is not billed again', () => {
  const order = { id: 'O-1', price: 3000, paidAmount: 1000 };
  assert.equal(owedRaw(order), 2000, 'the outstanding figure is wrong before any schedule is built');
  assert.equal(sum(plan(owedRaw(order))), 2000,
    'the schedule bills more than the customer still owes');
  // The bug, for contrast: the gross price billed the deposit twice.
  assert.equal(sum(plan(order.price)), 3000);
});

test('gift-card redemption and credit notes pay the order down too', () => {
  assert.equal(owedRaw({ price: 1000, giftCardDiscount: 250 }), 750);
  assert.equal(owedRaw({ price: 1000, creditNotes: [{ amount: 400 }] }), 600);
  assert.equal(owedRaw({ price: 1000, paidAmount: 200, giftCardDiscount: 100, creditNotes: [{ amount: 300 }] }), 400);
});

test('a fully paid order has nothing to schedule', () => {
  assert.equal(owedRaw({ price: 1000, paidAmount: 1000 }), 0);
  assert.equal(owedRaw({ price: 1000, paidAmount: 1500 }), 0, 'an overpayment must not go negative');
  assert.deepEqual(plan(0), [], 'a schedule was built for an order that owes nothing');
});

test('a personal print and a superseded parent owe nothing', () => {
  // Same two gates as orderOwedBase — a split parent's children carry the debt.
  assert.equal(owedRaw({ price: 1000, nonBusiness: true }), 0);
  assert.equal(owedRaw({ price: 1000, status: 'split', splitInto: ['a'] }), 0);
});

test('the amounts stay in the ORDER\'s currency, not the shop\'s base', () => {
  // orderOwedBase converts; this one must not, because these numbers are written
  // back onto the order as instalment rows.
  const order = { price: 1000, paidAmount: 250, currency: 'EUR' };
  assert.equal(owedRaw(order), 750, 'the outstanding figure was converted to base currency');
});

test('the generator asks for what is owed, and says so when nothing is', () => {
  const src = code('renderer/order-flows.js');
  // The HANDLER, not the button markup — the id appears in both.
  const at = src.indexOf("#oeGenInstalments')?.addEventListener");
  assert.ok(at > 0, 'the generate-instalments handler is gone');
  const body = src.slice(at, at + 1600);
  assert.match(body, /const total = orderOwedRaw\(order\)/,
    'the plan is generated from the gross price again — the deposit gets billed twice');
  assert.ok(!/const total = \+order\.price/.test(body));
  assert.match(body, /inst\.nothing_owed/,
    'a fully paid order is told to "set a price" instead of that it owes nothing');
});

test('the new string exists in every locale', () => {
  const dir = path.join(ROOT, 'renderer', 'locales');
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) {
    assert.ok(read(path.join('renderer', 'locales', f)).includes('"inst.nothing_owed"'), `${f} is missing it`);
  }
});

/* ------------------------------------------------------------------
 * The other half: a plan that covers the BALANCE must still settle the order.
 *
 * The save path recorded `paidAmount = Math.max(paidAmount, instPaid)`. That was
 * right ONLY BECAUSE the generator used to span the gross price: a SAR 3,000 job
 * with a SAR 1,000 deposit got a SAR 3,000 plan, so max(1000, 3000) = 3000 and
 * the order settled. It also billed the customer SAR 4,000 for a SAR 3,000 job,
 * which is what the generator fix above stopped.
 *
 * Fixing one without the other leaves the worse of both:
 *
 *   BEFORE  plan 3000  customer paid 4000  recorded 3000  still owes    0.00
 *   AFTER   plan 2000  customer paid 3000  recorded 2000  still owes 1000.00
 *
 * The customer has paid in full and is chased forever. That is a regression the
 * generator fix introduced, found by asking what the REST of the app does with
 * the value it now produces.
 * ------------------------------------------------------------------ */

/**
 * The save path's rule.
 *
 * This used to slice the expression out of `renderer/order-flows.js` and run it
 * through `new Function`, because the rule lived in a window this process
 * cannot open. It is `collectionTotals` in `lib/payment-plan.js` now — shared
 * with the macOS app, which collects instalments of its own — so the four
 * properties below are checked against the rule itself.
 *
 * `price` is irrelevant to the figure being asserted here (it decides
 * paid/partial, not the amount), so it is passed as 0 and left out of the way.
 */
function paidAmountRule(order, draft, instPaid) {
  const { collectionTotals } = require('../lib/payment-plan.js');
  return collectionTotals({
    price: 0,
    paidAmount: order.paidAmount,
    instalments: [{ amount: instPaid, paid: true }],
    instalmentBase: draft.instalmentBase,
  }).paidAmount;
}

test('a plan covering the balance settles the order', () => {
  // deposit 1000 already in paidAmount; plan of 2000 fully paid → 3000.
  const got = paidAmountRule({ paidAmount: 1000 }, { instalmentBase: 1000 }, 2000);
  assert.equal(got, 3000, `the order records ${got}, so it shows ${3000 - got} owed on a job paid in full`);
});

test('a legacy plan keeps the old rule, which was right for it', () => {
  // No instalmentBase: the schedule spans the gross price, so taking the larger
  // is correct and adding would double the deposit.
  const got = paidAmountRule({ paidAmount: 1000 }, {}, 3000);
  assert.equal(got, 3000, 'a plan written before the fix was double-counted');
});

test('a part-paid plan adds only what has been paid', () => {
  assert.equal(paidAmountRule({ paidAmount: 1000 }, { instalmentBase: 1000 }, 666.67), 1666.67);
});

test('an order with no deposit behaves the same either way', () => {
  assert.equal(paidAmountRule({ paidAmount: 0 }, { instalmentBase: 0 }, 2000), 2000);
  assert.equal(paidAmountRule({ paidAmount: 0 }, {}, 2000), 2000);
});

test('the base is recorded when a plan is generated, and travels with it', () => {
  // Written by the generator, carried onto the draft when the editor opens, and
  // written back on save. Missing any one of the three and the additive rule
  // silently never applies — the failure this whole section is about.
  const src = code('renderer/order-flows.js');
  assert.match(src, /draft\.instalmentBase = \+order\.paidAmount \|\| 0;/,
    'the generator no longer records the cash the order already held');
  assert.match(src, /^\s*instalmentBase: order\.instalmentBase,$/m,
    'the editor draft does not carry it, so save writes undefined back');
  assert.match(src, /order\.instalmentBase = draft\.instalments\.length > 0 \? draft\.instalmentBase : undefined;/,
    'it is not written back to the order, or not cleared with the schedule');
});
