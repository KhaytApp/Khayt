'use strict';
/**
 * Every EXISTING job (no labourCost / packagingCost) costs exactly what each
 * reader summed before lib/order-money.js jobCost (Dev Hub, Nov 19): the
 * sample book, plus jobs that carry components and overhead (the sample book
 * has none, and a case the data cannot reach has never been tested). The
 * dashboard's cost of goods is compared against main's own kpi-rows.js.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
for (const f of ['tax', 'pricing', 'order-money', 'calculator-cost', 'print-rates', 'pnl-report']) require('../lib/' + f + '.js');
const M = globalThis.KhaytOrderMoney;
const { buildSampleData } = require('../lib/sample-data.js');

const book = buildSampleData({ today: '2026-11-19' });
const extra = [
  { id: 'X1', status: 'completed', price: 300, parts: [{ baseCost: 80, qty: 2, unitCost: 40 }, { baseCost: 12.5, qty: 1 }], componentsCost: 18.4 },
  { id: 'X2', status: 'pending', price: 150, parts: [{ baseCost: 60 }], overheadCost: 7.25 },
  { id: 'X3', status: 'completed', price: 500, parts: [{ baseCost: 100 }, { baseCost: 0 }], componentsCost: 30, overheadCost: 12 },
  { id: 'X4', status: 'quote', price: 0, parts: [] },
];
const jobs = (book.printLog || book.orders || []).concat(extra);
const sumParts = (o) => (o.parts || []).reduce((s, p) => s + (+p.baseCost || 0), 0);

test('the book has jobs to check, including components and overhead', () => {
  assert.ok(jobs.length >= extra.length + 1);
  assert.ok(jobs.every((o) => !(+o.labourCost > 0) && !(+o.packagingCost > 0)), 'existing jobs carry no labour/packaging');
});

test('job page (parts + components + overhead) == jobCost(o)', () => {
  for (const o of jobs) assert.equal(M.jobCost(o), sumParts(o) + Math.max(0, +o.componentsCost || 0) + Math.max(0, +o.overheadCost || 0), o.id);
});
test('Orders Log (parts + components, no overhead) == jobCost(o, { overhead: false })', () => {
  for (const o of jobs) assert.equal(M.jobCost(o, { overhead: false }), sumParts(o) + (+o.componentsCost || 0), o.id);
});
test('parts only (costBasis, still parts only) == jobCost with no fixed costs', () => {
  for (const o of jobs) assert.equal(M.jobCost(o, { components: false, overhead: false, labour: false, packaging: false }), sumParts(o), o.id);
});
test('product profit and the edit pricer: jobFixedCost == the fixed costs they summed', () => {
  for (const o of jobs) {
    assert.equal(M.jobFixedCost(o, { overhead: false }), Math.max(0, +o.componentsCost || 0), o.id);
    assert.equal(M.jobFixedCost(o), Math.max(0, +o.componentsCost || 0) + Math.max(0, +o.overheadCost || 0), o.id);
  }
});
test('dashboard cost of goods (kpi-rows orderCost) == before #2581, job for job', () => {
  // Frozen from main's kpi-rows.js before #2581: CI's shallow checkout has no
  // origin/main to read the old file from (it failed the "Syntax check" job).
  const before = require('./fixtures/kpi-ordercost-before-2581.json');
  const NEW = require('../lib/kpi-rows.js');
  const ctx = { inventory: book.inventory || [], settings: book.settings || {} };
  assert.equal(Object.keys(before.orderCost).length, jobs.length, 'the same jobs');
  for (const o of jobs) assert.equal(NEW.orderCost(o, ctx), before.orderCost[o.id], o.id);
});

test('a once-labour job (from a 15-part product with rates): jobCost == the catalogue, the dashboard counts labour once, a reprint keeps it', () => {
  for (const f of ['order-payment', 'part-ids', 'product-price', 'product-pricing', 'order-new', 'reprint']) require('../lib/' + f + '.js');
  const PP = globalThis.KhaytProductPricing; const N = globalThis.KhaytOrderNew; const K = require('../lib/kpi-rows.js'); const R = require('../lib/reprint.js');
  const rates = { laborRate: 90, prepTime: 0.25, postTime: 0.5, wearRate: 0.75, powerDraw: 150, elecRate: 0.18, failureRate: 10 };
  const part = { printWeight: 100, printTime: 2, spoolCost: 90, spoolWeight: 1000, qty: 1 };
  const product = { id: 'P', rates, parts: Array.from({ length: 15 }, (_, i) => Object.assign({ name: 'p' + i }, part)) };
  const settings = { defaultMargin: 30, defaultPackagingCost: 5 };
  const ctx = { inventory: [], settings };
  const cat = PP.priceProduct(product, ctx);
  const jp = PP.productJobParts(product, ctx);
  const job = N.newOrder({ parts: jp.parts, labourCost: jp.labourCost, packagingCost: jp.packagingCost, project: 'J', margin: 30 },
    { settings, orders: [], clients: [], now: new Date('2026-11-19T08:00:00Z'), tokens: { tracking: new Uint8Array(N.TOKEN_BYTES), quoteApproval: new Uint8Array(N.TOKEN_BYTES), id: new Uint8Array(4) } });
  assert.equal(Math.round(M.jobCost(job) * 100) / 100, cat.cost, 'the job costs what the catalogue says (253.89)');
  // Cost of goods counts only what is inventoried (2026-09-28): 15 × 9.00 of
  // material, plus the packaging once (5.50); never the labour. (Per part it
  // was 15 × (9 + 5) = 210: packaging counted fifteen times.)
  assert.equal(Math.round(K.orderCost(job, ctx) * 100) / 100, 140.5, 'the dashboard: material plus the packaging once, no labour');
  const rp = R.input(job, { settings, inventory: [] }, 'RP');
  {
    assert.equal(rp.labourCost, job.labourCost, 'a reprint keeps the labour at the order level');
    assert.ok(Math.abs(rp.parts.reduce((s, p) => s + p.baseCost, 0) - job.parts.reduce((s, p) => s + p.baseCost, 0)) < 0.01, 'and its parts without it');
  }
});
