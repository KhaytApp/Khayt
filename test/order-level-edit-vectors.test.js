'use strict';
/**
 * A job carrying a product's labour and packaging at the ORDER level, edited:
 * every edit prices it exactly as a fresh lib/order-new.js newOrder of the
 * edited job does, the labour and packaging in the costed share only
 * (KhaytOrderNew.costedShare), never on top of agreed prices (money review of
 * #2581). The four edits the review found drifting, each against newOrder.
 *
 * Within a halala: an edit works the markup factor back from the job's
 * ROUNDED price (pricedFrom, every job, before this change), so a fresh total
 * sitting on a half-halala (318.03498) can round the other way. The drift the
 * review found was 4 to 48.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
for (const f of ['tax', 'pricing', 'order-money', 'order-payment', 'part-ids', 'calculator-cost', 'order-new', 'order-edit']) require('../lib/' + f + '.js');
const N = globalThis.KhaytOrderNew;
const E = globalThis.KhaytOrderEdit;
const clone = (o) => JSON.parse(JSON.stringify(o));
const settings = { currency: 'SAR', defaultMargin: 30 };
const L = 74.25, PK = 5.5;
const part = (i, agreed) => Object.assign({ id: 'P' + i, name: 'p' + i, qty: 1, baseCost: 11.6094, unitCost: 11.6094, printTime: 2, printWeight: 100 }, agreed ? { agreedPrice: 20 } : {});
const make = (parts, margin) => N.newOrder({ parts: clone(parts), labourCost: L, packagingCost: PK, project: 'J', margin: margin || 30, asQuote: true },
  { settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'), tokens: { tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) } });
const near = (a, b, why) => assert.ok(Math.abs(a - b) <= 0.0100001, `${why}: ${a} vs newOrder ${b}`);
const edit = (job, next, extra) => {
  const r = E.applyJobEdit(job, next, Object.assign({ now: 1, id: 'e', priceId: 'e2', ids: ['N1', 'N2'], settings, clients: [], priceSeenOk: true, keepPrice: false }, extra || {}));
  assert.equal(r.ok, true, r.reason);
  return job;
};
const parts = (agreedIdx) => Array.from({ length: 15 }, (_, i) => part(i, agreedIdx(i)));

test('a 6th part agreed (5 → 6 of 15) prices as newOrder of the edited job', () => {
  const job = make(parts((i) => i < 5));
  const next = clone(job.parts); next[5].agreedPrice = 20;
  edit(job, { parts: next });
  near(job.price, make(parts((i) => i < 6)).price, '6th agreed');
});

test('one agreement removed (all 15 → 14 agreed) prices as newOrder, at the markup the sheet passes', () => {
  // An all-agreed job carries no markup of its own (newOrder stores none),
  // so the sheet passes its markup field as ctx.marginPct (applyParts).
  const job = make(parts(() => true));
  const next = clone(job.parts); next[0].agreedPrice = null;  // how a caller clears one (a missing key merges the old back)
  edit(job, { parts: next }, { marginPct: 30 });
  near(job.price, make(parts((i) => i > 0)).price, 'agreement removed');
});

test('a part\'s quantity doubled prices as newOrder', () => {
  const job = make(parts((i) => i < 5));
  const next = clone(job.parts); next[10].qty = 2; next[10].baseCost = 2 * 11.6094;
  edit(job, { parts: next });
  const fresh = parts((i) => i < 5); fresh[10].qty = 2; fresh[10].baseCost = 2 * 11.6094;
  near(job.price, make(fresh).price, 'qty doubled');
});

test('the markup moved to 80% prices as newOrder at 80%', () => {
  const job = make(parts((i) => i < 5));
  edit(job, { marginPct: 80 });
  near(job.price, make(parts((i) => i < 5), 80).price, 'markup 80');
});

test('the labour and packaging stay whole as COST through every edit', () => {
  const job = make(parts((i) => i < 5));
  edit(job, { marginPct: 80 });
  assert.equal(job.labourCost, L); assert.equal(job.packagingCost, PK);
  assert.ok(Math.abs(globalThis.KhaytOrderMoney.jobCost(job) - (15 * 11.6094 + L + PK)) < 0.0001);
});
