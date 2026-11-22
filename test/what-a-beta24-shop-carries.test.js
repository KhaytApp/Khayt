'use strict';
/**
 * Two things a shop upgrading from an earlier build meets in its OWN data.
 *
 * Both follow from money fixes in this release, and neither is created by the
 * new code — which is exactly why they were nearly missed. A fix is naturally
 * tested against the path it changes, and that path only ever produces the NEW
 * shape.
 *
 * 1. An instalment plan written before the deposit fix split the GROSS PRICE,
 *    so it asks for more than the order still owes. SAR 3,000 across three
 *    payments on a job with SAR 2,000 left.
 *
 * 2. Points used to be earned on cancelled, personal and fully refunded jobs.
 *    Correcting that lowers what a client has EARNED. The balance clamps at
 *    zero so nothing breaks — but a customer who was told they had points now
 *    has none, and the shop finds out when they ask.
 *
 * Both REPORT-ONLY, for different reasons. A schedule is an agreement the shop
 * may have put in writing; rewriting the amounts under it would be worse than
 * saying so. Re-inflating a points balance would perpetuate a liability the shop
 * does not owe. Contrast the deposit migration, which IS applied: there the
 * money was already recorded and only needed attributing to the right rows.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const P = require('../lib/payment-plan.js');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

/* ── 1. instalment plans written before the fix ────────────────────────── */

const legacyPlan = (over = {}) => ({
  id: 'O-1', project: 'Bracket', price: 3000, paidAmount: 1000,
  instalments: [{ amount: 1000 }, { amount: 1000 }, { amount: 1000 }], ...over,
});

test('a plan that ignores the deposit is found, with the overshoot named', () => {
  assert.deepEqual(P.overBilledPlans([legacyPlan()]),
    [{ id: 'O-1', project: 'Bracket', scheduled: 3000, owed: 2000, over: 1000 }]);
});

test('a plan made after the fix is not flagged', () => {
  const fixed = legacyPlan({ instalments: [{ amount: 666.67 }, { amount: 666.67 }, { amount: 666.66 }] });
  assert.deepEqual(P.overBilledPlans([fixed]), [], 'a correct plan was called an over-bill');
});

test('an order with no deposit cannot have double-counted one', () => {
  assert.deepEqual(P.overBilledPlans([legacyPlan({ paidAmount: 0 })]), []);
});

test('rows the customer has already paid are not counted against them', () => {
  // Only what is still to be ASKED FOR can be an over-bill.
  //
  // I got this fixture wrong twice: in both earlier versions, marking a row paid
  // made the remainder match the balance exactly, so the plan was correctly NOT
  // returned and the assertion read a field of `undefined`. The numbers have to
  // be chosen so the plan still overshoots WITH a row paid, or there is nothing
  // to compare. 4,000 scheduled against 2,000 owed leaves 3,000 after one row.
  const mk = (ins) => ({ id: 'O-1', project: 'B', price: 4000, paidAmount: 2000, instalments: ins });
  const four = [{ amount: 1000 }, { amount: 1000 }, { amount: 1000 }, { amount: 1000 }];

  const [all] = P.overBilledPlans([mk(four)]);
  assert.deepEqual({ scheduled: all.scheduled, owed: all.owed, over: all.over },
    { scheduled: 4000, owed: 2000, over: 2000 });

  const [one] = P.overBilledPlans([mk([{ ...four[0], paid: true }, ...four.slice(1)])]);
  assert.equal(one.scheduled, 3000, 'a paid row was counted as still to be billed');
  assert.equal(one.over, 1000);
});

test('a plan whose remaining rows match the balance is left alone', () => {
  // The case my bad assertion actually produced: 3000 scheduled, 1000 of it
  // already paid, 2000 owed. Nothing to say.
  const p = legacyPlan({ instalments: [{ amount: 1000, paid: true }, { amount: 1000 }, { amount: 1000 }] });
  assert.deepEqual(P.overBilledPlans([p]), []);
});

test('gift cards and credit notes count as paid down too', () => {
  assert.deepEqual(P.overBilledPlans([legacyPlan({ paidAmount: 0, giftCardDiscount: 1000 })])[0].over, 1000);
  assert.deepEqual(P.overBilledPlans([legacyPlan({ paidAmount: 0, creditNotes: [{ amount: 1000 }] })])[0].over, 1000);
});

test('a cent of rounding is not an over-bill', () => {
  const p = legacyPlan({ price: 1000, paidAmount: 0.01, instalments: [{ amount: 1000 }] });
  assert.deepEqual(P.overBilledPlans([p]), [], 'a rounding cent was reported to the shop as a billing error');
});

test('orders with no plan at all are ignored', () => {
  assert.deepEqual(P.overBilledPlans([{ id: 'x', price: 100, paidAmount: 50 }]), []);
  assert.deepEqual(P.overBilledPlans([{ id: 'y', price: 100, paidAmount: 50, instalments: [] }]), []);
  assert.deepEqual(P.overBilledPlans(null), []);
});

/* ── 2. clients who redeemed against the inflated total ────────────────── */

test('clientsOverRedeemed exists and is exported to the app', () => {
  const src = code('renderer/clients.js');
  assert.match(src, /function clientsOverRedeemed\(\)/, 'the detector is gone');
  assert.match(src, /^\s*clientsOverRedeemed,$/m, 'it is not exported, so nothing can call it');
});

test('it needs no stored history — redeemed > earned is the whole condition', () => {
  // The detector moved into `lib/loyalty.js` with the sum it compares against,
  // so the macOS app can answer the same question. This used to read the
  // renderer's source for two expressions; it drives the rule instead, which
  // is what those two expressions were standing in for.
  require('../lib/order-money.js');
  require('../lib/order-status.js');
  require('../lib/tax.js');
  const { overRedeemed } = require('../lib/loyalty.js');
  const settings = { loyaltyEnabled: true, loyaltyPointsPerUnit: 1 };
  const orders = [{ id: 'a', clientId: 'c1', status: 'completed', price: 100, date: '2026-01-01' }];
  const clients = [{ id: 'c1', name: 'Acme' }, { id: 'c2', name: 'Beta' }];

  // Nothing redeemed: not walked, not reported — no stored history required.
  assert.deepEqual(overRedeemed({ orders, ledger: [], clients, settings }), []);

  // Redeemed beyond what is now earned: reported, with the shortfall.
  const ledger = [{ clientId: 'c1', type: 'redeem', points: 250 }];
  const out = overRedeemed({ orders, ledger, clients, settings });
  assert.equal(out.length, 1, 'the over-redeemed client is not reported');
  assert.equal(out[0].id, 'c1');
  assert.equal(out[0].over, 150);

  // And a client who spent less than they earned is not an accusation.
  const fine = [{ clientId: 'c1', type: 'redeem', points: 50 }];
  assert.deepEqual(overRedeemed({ orders, ledger: fine, clients, settings }), []);
});

/* ── the report is wired, and says rather than does ────────────────────── */

test('both are reported on load, and neither rewrites anything', () => {
  const st = code('renderer/settings.js');
  const at = st.indexOf('function reportLegacyMoneyState()');
  assert.ok(at > 0, 'the reporter is gone');
  const body = st.slice(at, at + 2600);
  assert.match(body, /KhaytPaymentPlan\.overBilledPlans\(/);
  assert.match(body, /clientsOverRedeemed\(\)/);
  // Report-only: it must not touch a schedule or a balance.
  assert.ok(!/\.instalments\s*=/.test(body), 'the reporter rewrites an instalment schedule');
  assert.ok(!/loyaltyLedger\.push|\.points\s*=/.test(body), 'the reporter changes a points balance');
  assert.match(body, /console\.warn/, 'nothing durable is left for support to read');

  const app = code('renderer/app-state.js');
  assert.match(app, /reportLegacyMoneyState\(\)/,
    'nothing calls the reporter — the shop meets both surprises with no warning');
});

test('it announces on change, not on every launch', () => {
  const st = code('renderer/settings.js');
  const at = st.indexOf('function reportLegacyMoneyState()');
  const body = st.slice(at, at + 2600);
  assert.match(body, /localStorage\.getItem\(KEY\)/, 'the report nags on every launch');
  assert.match(body, /if \(signature === lastSeen\) return;/, 'the same set is announced twice');
});

test('all four strings exist in every locale', () => {
  const dir = path.join(ROOT, 'renderer', 'locales');
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));
  assert.equal(files.length, 9);
  for (const f of files) {
    const src = read(path.join('renderer', 'locales', f));
    for (const k of ['money.plan_over_one', 'money.plan_over_many', 'money.points_over_one', 'money.points_over_many']) {
      assert.ok(src.includes(`"${k}"`), `${f} is missing ${k}`);
    }
  }
});
