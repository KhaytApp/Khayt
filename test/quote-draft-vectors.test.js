'use strict';
/**
 * The shared vectors for lib/order-edit.js quoteIsDraft, run through partsLock
 * too (askPrice is the opposite of draft for a quote). The Mac and the iPhone
 * run the same file through their engine. Synthetic records only.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const E = require('../lib/order-edit.js');
const { cases } = require('./fixtures/quote-draft-vectors.json');

test('quote draft vectors: quoteIsDraft and partsLock agree with the file', () => {
  assert.ok(cases.length >= 12);
  for (const c of cases) {
    assert.equal(E.quoteIsDraft(c.order, c.ctx), c.draft, c.why);
    assert.equal(E.partsLock(c.order, c.ctx).askPrice, !c.draft, 'partsLock: ' + c.why);
  }
});

test('a markup change on a followed-up quote asks, through the rule\'s own ctx', () => {
  const part = { id: 'P1', name: 'a', baseCost: 100, unitCost: 100, qty: 1 };
  const order = { id: 'QF', status: 'quote', quoteShareStamped: true, price: 150, marginPct: 50, paidAmount: 0, parts: [part], followUpCount: 1 };
  const r = E.applyMarkup(JSON.parse(JSON.stringify(order)), 80, { now: 1 });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'ask_price');
  const msg = Object.assign({}, order, { followUpCount: 0, clientId: 'C1' });
  const clients = [{ id: 'C1', commLog: [{ id: 'm', at: '2026-11-15', orderId: 'QF' }] }];
  assert.equal(E.applyMarkup(JSON.parse(JSON.stringify(msg)), 80, { now: 1, clients }).reason, 'ask_price');
  // Without either, it is a draft: re-priced at once.
  const draft = Object.assign({}, order, { followUpCount: 0 });
  assert.equal(E.applyMarkup(JSON.parse(JSON.stringify(draft)), 80, { now: 1 }).ok, true);
});
