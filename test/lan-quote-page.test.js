const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  applyQuoteApprovalToStore,
  isQuoteExpired,
  renderLanQuoteApprovalPage,
  ensureQuoteApprovalToken,
  ensureTrackingToken,
  verifyOrderAccessToken,
  verifyQuoteApprovalToken,
} = require('../lib/lan-quote-page');

test('applyQuoteApprovalToStore moves quote to pending', () => {
  const store = {
    printLog: [{ id: 'Q-1', status: 'quote', project: 'Widget', price: 100 }],
  };
  const result = applyQuoteApprovalToStore(store, 'Q-1');
  assert.equal(result.error, undefined);
  assert.equal(result.order.status, 'pending');
  assert.ok(result.order.clientApprovedAt);
  assert.ok(result.order.quoteAcceptedAt);
  assert.equal(store.printLog[0].status, 'pending');
});

test('applyQuoteApprovalToStore accepts on_hold with hasQuote', () => {
  const store = {
    printLog: [{ id: 'Q-2', status: 'on_hold', hasQuote: true, price: 50 }],
  };
  const result = applyQuoteApprovalToStore(store, 'Q-2');
  assert.equal(result.order.status, 'pending');
});

test('applyQuoteApprovalToStore rejects expired quotes', () => {
  // Yesterday on the SHOP's calendar, matching isQuoteExpired. Deriving it from
  // UTC produced a date that is still TODAY locally whenever UTC has rolled over
  // and the local zone has not — 22:38 in Los Angeles, say — so the quote was
  // not expired and the test failed against correct code.
  const localDay = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const yesterday = localDay(new Date(Date.now() - 86400000));
  const store = {
    printLog: [{ id: 'Q-4', status: 'quote', price: 50, quoteExpiresAt: yesterday }],
  };
  const result = applyQuoteApprovalToStore(store, 'Q-4');
  assert.equal(result.error, 'expired');
  assert.equal(store.printLog[0].status, 'quote');
});

test('applyQuoteApprovalToStore rejects non-quote status', () => {
  const store = {
    printLog: [{ id: 'Q-3', status: 'pending', price: 50 }],
  };
  const result = applyQuoteApprovalToStore(store, 'Q-3');
  assert.equal(result.error, 'cannot_approve');
});

test('applyQuoteApprovalToStore returns null for missing order', () => {
  const store = { printLog: [] };
  assert.equal(applyQuoteApprovalToStore(store, 'missing'), null);
});

test('isQuoteExpired compares quoteExpiresAt to today', () => {
  // The SHOP's day, matching isQuoteExpired. A UTC helper here quietly asserted
  // the bug: it agreed with the old implementation for most of the day and
  // disagreed for the hours when the two calendars differ, which is precisely
  // the window where an expired quote used to stay approvable.
  const localDay = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  const today = localDay(new Date());
  const yesterday = localDay(new Date(Date.now() - 86400000));
  assert.equal(isQuoteExpired({ quoteExpiresAt: yesterday }), true);
  assert.equal(isQuoteExpired({ quoteExpiresAt: today }), false);
  assert.equal(isQuoteExpired({}), false);
});

test('renderLanQuoteApprovalPage includes approve button when actionable', () => {
  const html = renderLanQuoteApprovalPage({
    order: { id: 'Q-9', project: 'Test', price: 10, parts: [] },
    shopName: 'Shop',
    approvePath: '/order/Q-9/approve',
  });
  assert.match(html, /Approve Quote/);
  assert.match(html, /Q-9/);
});

test('ensureTrackingToken and verifyOrderAccessToken', () => {
  const order = { id: 'O-1', status: 'printing' };
  const token = ensureTrackingToken(order);
  assert.equal(token.length, 32);
  assert.equal(verifyOrderAccessToken(order, token, 'trackingToken'), true);
  assert.equal(verifyOrderAccessToken(order, 'bad', 'trackingToken'), false);
});

test('ensureQuoteApprovalToken and verifyQuoteApprovalToken', () => {
  const order = { id: 'Q-11', status: 'quote' };
  const token = ensureQuoteApprovalToken(order);
  assert.equal(token.length, 32);
  assert.equal(verifyQuoteApprovalToken(order, token), true);
  assert.equal(verifyQuoteApprovalToken(order, 'wrong'), false);
});

test('renderLanQuoteApprovalPage shows expired message', () => {
  const html = renderLanQuoteApprovalPage({
    order: { id: 'Q-10', project: 'Test', price: 10 },
    shopName: 'Shop',
    approvePath: '/order/Q-10/approve',
    expired: true,
  });
  assert.match(html, /expired/i);
  assert.doesNotMatch(html, /id="approveBtn"/);
});
