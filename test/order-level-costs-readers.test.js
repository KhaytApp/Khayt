'use strict';
/**
 * A product's labour and packaging carried ONCE on the order stay out of its
 * parts wherever a part is costed again (money review of #2581). The parts
 * productJobParts returns carry `orderLevelCosts: true`, and
 * lib/calculator-cost.js leaves both out of such a part unless the caller
 * asks otherwise. Before, every re-costing caller counted them per part
 * again. The reviewer's fixture: 4 parts, defaultPackagingCost 5 → part
 * 11.61, labour 74.25, packaging 5.50, price 164.04, cost 126.19.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const vm = require('vm');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'print-rates', 'calculator-cost', 'product-price', 'product-pricing', 'order-new', 'order-edit', 'product-profit', 'break-even']) require('../lib/' + f + '.js');
const N = globalThis.KhaytOrderNew, PP = globalThis.KhaytProductPricing, CC = globalThis.KhaytCalculatorCost;
const E = globalThis.KhaytOrderEdit, PRt = globalThis.KhaytPrintRates, Mo = globalThis.KhaytOrderMoney;
const clone = (o) => JSON.parse(JSON.stringify(o));
const rates = { laborRate: 90, prepTime: 0.25, postTime: 0.5, wearRate: 0.75, powerDraw: 150, elecRate: 0.18, failureRate: 10 };
const part = { printWeight: 100, printTime: 2, spoolCost: 90, spoolWeight: 1000, qty: 1 };
const settings = { defaultMargin: 30, currency: 'SAR', defaultPackagingCost: 5 };
const product = { id: 'P', parts: Array.from({ length: 4 }, (_, i) => Object.assign({ name: 'p' + i }, part)), rates };
const ctx = { inventory: [], settings };
const jp = PP.productJobParts(product, ctx);
const make = (parts) => N.newOrder({ parts: clone(parts), labourCost: jp.labourCost, packagingCost: jp.packagingCost, project: 'J', margin: 30, productId: 'P', asQuote: true },
  { settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'), tokens: { tracking: new Uint8Array(16), quoteApproval: new Uint8Array(16), id: new Uint8Array(4) } });

test('the job matches the catalogue, and its parts are marked', () => {
  assert.equal(PP.priceProduct(product, ctx).cost, 126.19);
  const job = make(jp.parts);
  assert.equal(job.price, 164.04);
  assert.ok(job.parts.every((p) => p.orderLevelCosts === true));
  assert.ok(Math.abs(Mo.jobCost(job, { overhead: false }) - 126.19) < 0.005);
});

test('a marked part re-costed with NO options leaves out labour and packaging (11.61, not 77.16)', () => {
  for (const p of jp.parts) assert.ok(Math.abs(CC.partTotalCost(p, ctx) - 11.6094) < 0.0001);
  assert.ok(CC.partTotalCost(Object.assign({}, jp.parts[0], { orderLevelCosts: undefined }), ctx) > 70, 'an unmarked part keeps per-part labour');
  assert.ok(CC.partTotalCost(jp.parts[0], ctx, { labour: true, packaging: true }) > 70, 'an explicit option still wins');
});

test('HIGH 1: the job sheet re-costing one part (qty 1→2) prices as newOrder (≈179.14), not 379.33', () => {
  const job = make(jp.parts);
  const next = clone(job.parts);
  const rated = PRt.withRates(Object.assign({}, next[0], { qty: 2 }), { settings });   // renderer/job-sheet.js costed()
  const unit = CC.computePartBaseCost(rated, ctx);
  rated.unitCost = +unit.toFixed(4); rated.baseCost = +(unit * 2).toFixed(2); next[0] = rated;
  const r = E.applyJobEdit(job, { parts: next }, { now: 1, id: 'e', priceId: 'e2', ids: ['N1'], settings, clients: [], priceSeenOk: true, keepPrice: false });
  assert.equal(r.ok, true, r.reason);
  assert.equal(job.parts[0].baseCost, 23.22);
  const fresh = clone(jp.parts); fresh[0].qty = 2; fresh[0].baseCost = 2 * 11.6094;
  assert.ok(Math.abs(job.price - make(fresh).price) <= 0.0100001, `${job.price} vs ${make(fresh).price}`);
});

test('HIGH 2: product profit costs the job 126.19 (parts + once), not 445.19', () => {
  const job = Object.assign(make(jp.parts), { status: 'completed' });
  const prof = globalThis.KhaytProductProfit.productProfit({ orders: [job], products: [product] },
    { revenueOf: (o) => o.price, partCostOf: (p) => CC.partTotalCost(p, ctx), nameOf: (p) => p.id, countsForBusiness: () => true });
  assert.ok(Math.abs(prof.rows[0].cost - 126.19) < 0.005, String(prof.rows[0].cost));
});

test('break-even counts the job at 126.19: its parts plus the once labour and packaging (365.44 before)', () => {
  const job = Object.assign(make(jp.parts), { status: 'completed', date: '2026-11-10' });
  const r = globalThis.KhaytBreakEven.breakEven({ fixedCosts: [{ name: 'Rent', amount: 100 }], completed: [job], since: '2026-11-01', month: '2026-11' },
    { revenueOf: (o) => o.price, partCostOf: (p) => CC.partTotalCost(p, ctx) });
  assert.ok(Math.abs(r.marginPct - (164.04 - 126.1876) / 164.04) < 0.0001, String(r.marginPct));
});

test('HIGH 3: the calculator drops a product\'s once-costs when its last part leaves the cart', () => {
  const src = fs.readFileSync(require('path').join(__dirname, '..', 'renderer', 'build.js'), 'utf8');
  const at = src.indexOf('function syncFixedCosts()');
  const end = src.indexOf('\n}\n', at) + 3;
  const box = { currentBuild: [], currentFixedCosts: null };
  vm.runInNewContext(src.slice(at, end) + '\nthis.sync = syncFixedCosts;', box);
  const sync = () => { vm.runInNewContext('sync()', box); return box.currentFixedCosts; };
  // Two products and a manual part.
  box.currentBuild = [{ onceGroup: 'A', orderLevelCosts: true }, { onceGroup: 'A', orderLevelCosts: true }, { onceGroup: 'B', orderLevelCosts: true }, { name: 'manual' }];
  box.currentFixedCosts = { labourCost: 100, packagingCost: 10, groups: { A: { labourCost: 74.25, packagingCost: 5.5 }, B: { labourCost: 25.75, packagingCost: 4.5 } } };
  box.currentBuild.splice(2, 1);                         // product B's only part removed
  let f = sync();
  assert.equal(f.labourCost, 74.25); assert.equal(f.packagingCost, 5.5);
  box.currentBuild.splice(0, 2);                         // product A's parts removed: a manual part only
  f = sync();
  assert.equal(f.labourCost, 0); assert.equal(f.packagingCost, 0);
  // A once-job copied in (no groups): cleared when no marked part is left.
  box.currentBuild = [{ name: 'manual' }];
  box.currentFixedCosts = { labourCost: 74.25, packagingCost: 5.5 };
  f = sync();
  assert.equal(f.labourCost + f.packagingCost, 0);
});

test('costedShare: no parts prices all of it (1); a 0-cost costed part beside agreed ones counts by number', () => {
  assert.equal(N.costedShare([]), 1);
  assert.equal(N.costedShare([{ baseCost: 0 }, { baseCost: 10, agreedPrice: 20 }]), 0.5);
  assert.equal(N.costedShare([{ baseCost: 10, agreedPrice: 20 }]), 0);
  assert.equal(N.costedShare([{ baseCost: 30 }, { baseCost: 10, agreedPrice: 20 }]), 0.75);
  assert.equal(N.costedShare([{ kind: 'components', baseCost: 50 }, { baseCost: 10 }]), 1);
});

// ── The job sheet: a part added BY HAND to a once-job (Dev Hub, Nov 19,
// Turki): unmarked, its own labour; the order's once-costs unchanged. A
// product part edited there keeps the mark. One rule decides:
// KhaytOrderMoney.addedPartMark.
function sheetCosted() {
  const src = fs.readFileSync(require('path').join(__dirname, '..', 'renderer', 'job-sheet.js'), 'utf8');
  const at = src.indexOf('  function costed(part, order) {');
  const body = src.slice(at, src.indexOf('\n  }\n', at) + 5);
  const box = { global: globalThis, settings, list: () => [], PR: () => PRt, CC: () => CC, Math };
  vm.runInNewContext(body + '\nthis.costed = costed;', box);
  return box.costed;
}

test('the rule lives in one place: a hand part on a once-job is not marked (Turki, Nov 19)', () => {
  assert.equal(Mo.HAND_PARTS_SHARE_ONCE, false);
  assert.equal(Mo.addedPartMark({ labourCost: 74.25 }), false);
});

test('the sheet: a manual part added to a once-job gets its own labour; the once-costs are unchanged', () => {
  const costed = sheetCosted();
  const job = make(jp.parts);
  const manual = costed({ name: 'hand', qty: 1, printWeight: 100, printTime: 2, spoolCost: 90, spoolWeight: 1000, laborRate: 90, prepTime: 0.25, postTime: 0.5, failureRate: 10 }, job);
  assert.equal(manual.orderLevelCosts, undefined, 'a hand part is not marked');
  assert.ok(manual.baseCost > 70, 'it carries its own labour: ' + manual.baseCost);
  const r = E.applyJobEdit(job, { parts: clone(job.parts).concat([manual]) }, { now: 1, id: 'e', priceId: 'e2', ids: ['N1'], settings, clients: [], priceSeenOk: true, keepPrice: false });
  assert.equal(r.ok, true, r.reason);
  assert.equal(job.labourCost, jp.labourCost); assert.equal(job.packagingCost, jp.packagingCost);
  const fresh = clone(jp.parts).concat([Object.assign({}, manual)]);
  assert.ok(Math.abs(job.price - make(fresh).price) <= 0.0100001, `${job.price} vs ${make(fresh).price}`);
});

test('the sheet: a product part edited there keeps the mark (no labour of its own)', () => {
  const costed = sheetCosted();
  const job = make(jp.parts);
  const edited = costed(Object.assign({}, job.parts[0], { qty: 2 }), job);
  assert.equal(edited.orderLevelCosts, true);
  assert.equal(edited.baseCost, 23.22);
});

/* ── Release money review (Nov 19): a hand part on a once-job ─────────────── */

{
  for (const f of ['pnl-report', 'kpi-rows', 'reprint']) require('../lib/' + f + '.js');
  const P = globalThis.KhaytPnl, K = require('../lib/kpi-rows.js'), R = globalThis.KhaytReprint;
  // Two product parts with rates (11.61 each, labour 74.25 and packaging 5.50
  // once) plus a part added BY HAND, qty 3, its own labour (addedPartMark false).
  const two = PP.productJobParts({ id: 'P2', parts: [0, 1].map((i) => Object.assign({ name: 'q' + i }, part)), rates }, ctx);
  const hand = PRt.withRates(Object.assign({ name: 'hand', labourPerLine: true }, part, { qty: 3, prepTime: 0.5, postTime: 0.25, laborRate: 90, failureRate: 10 }), { settings });
  const hu = CC.computePartBaseCost(hand, ctx);
  hand.unitCost = +hu.toFixed(4); hand.baseCost = +(hu * 3).toFixed(4);
  const tok = { tracking: new Uint8Array(16), quoteApproval: new Uint8Array(16), id: new Uint8Array(4) };
  const job = N.newOrder({ parts: clone(two.parts).concat([hand]), labourCost: two.labourCost, packagingCost: two.packagingCost, project: 'J', margin: 30, productId: 'P2' },
    { settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'), tokens: tok });
  job.status = 'completed'; job.costBasis = job.parts.reduce((s, p) => s + p.baseCost, 0);

  test('H1: the hand part keeps its own labour in the P&L stock share and the dashboard cost of goods (55.50, not 150.70 / 50.50)', () => {
    assert.equal(hand.baseCost, 164.0782);
    assert.equal(job.price, 347.16);
    const share = P.stockShare(job, ctx);
    assert.ok(Math.abs(share - 0.26696) < 0.0001, 'stock share ' + share + ' (0.775 when the hand part was split without its labour)');
    const cogs = job.costBasis * share + Mo.jobFixedCost(job, { components: false, overhead: false, labour: false });
    assert.equal(+cogs.toFixed(2), 55.5, 'P&L cost of goods');
    assert.equal(K.orderCost(job, ctx), 55.5, 'dashboard cost of goods');
  });

  test('M1: a reprint of the job keeps the hand part\'s labour, and the product\'s at the order level', () => {
    const rp = R.input(job, { settings, inventory: [] }, 'RP');
    assert.deepEqual(rp.parts.map((p) => +p.baseCost.toFixed(4)), [11.6094, 11.6094, 164.0782]);
    assert.equal(rp.labourCost, 74.25);
    assert.equal(rp.packagingCost, 5.5);
  });
}

test('M2: Recalculate and a new markup on a FINISHED job ask first, as on a job whose price the customer has seen', () => {
  const tok = { tracking: new Uint8Array(16), quoteApproval: new Uint8Array(16), id: new Uint8Array(4) };
  const base = N.newOrder({ parts: clone(jp.parts), labourCost: jp.labourCost, packagingCost: jp.packagingCost, project: 'J', margin: 30, productId: 'P' },
    { settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'), tokens: tok });
  const done = Object.assign(clone(base), { status: 'completed', materialDeducted: true, price: 500, priceSource: 'override', priceOverride: 500 });
  const c = { settings, now: new Date('2026-11-19T09:00:00Z') };
  const asked = E.applyJobEdit(clone(done), { reprice: {} }, c);
  assert.equal(asked.ok, false); assert.equal(asked.reason, 'ask_price', 'Recalculate on a finished job: asked, never silent');
  const target = clone(done);
  const yes = E.applyJobEdit(target, { reprice: {} }, Object.assign({ priceSeenOk: true }, c));
  assert.equal(yes.ok, true, 'once the shop said yes');
  assert.notEqual(target.price, 500, 'repriced in place');
  // Before the fix a finished job did not ask at all: the lock was 'deducted' with askPrice false.
  assert.equal(E.partsLock(clone(done), c).code, 'deducted');
  const mk = E.applyJobEdit(clone(Object.assign({}, done, { priceSource: undefined, priceOverride: undefined })), { marginPct: 10 }, c);
  assert.equal(mk.reason === 'ask_price' || mk.reason === 'deducted' || mk.reason === 'price_fixed', true, 'a markup on a finished job is never applied silently: ' + mk.reason);
});
