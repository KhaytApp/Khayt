'use strict';
// The VAT tax point of an accepted quote is the day it was accepted
// (lib/pnl-report.js taxPointDate). That day must be the shop's LOCAL day: a
// UTC day put an acceptance made just after midnight in Riyadh (UTC+3) on the
// first of a quarter into the quarter before.
process.env.TZ = 'Asia/Riyadh';
const test = require('node:test');
const assert = require('node:assert/strict');
const { applyQuoteApprovalToStore } = require('../lib/lan-quote-page.js');

test('a quote the customer approves after midnight is accepted that local day', () => {
  const store = { printLog: [{ id: 'QUO-1', status: 'quote', date: '2026-09-20' }] };
  // 00:30 on 1 October in Riyadh is 21:30 on 30 September UTC.
  const out = applyQuoteApprovalToStore(store, 'QUO-1', '2026-09-30T21:30:00.000Z');
  assert.equal(out.order.quoteAcceptedAt, '2026-10-01');
});
