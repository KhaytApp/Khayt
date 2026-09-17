/**
 * Loyalty redemption: available = earned − redeemed; redeeming issues a store-
 * credit gift card + a ledger entry, and points can't be double-spent.
 * Uses the jsdom harness so renderClients() (a UI side-effect) has a real DOM.
 */
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { setupDom } = require('./helpers/dom.js');

let dom, clients;
beforeEach(() => {
  dom = setupDom();
  dom.loadI18n();
  require('../lib/loyalty.js');
  require('../renderer/format.js');
  require('../renderer/currency.js');
  require('../lib/tax.js');          // sets globalThis.KhaytTax — money paths need it
  require('../lib/order-status.js'); // globalThis.KhaytOrderStatus — both spellings of finished
  require('../renderer/app-helpers.js'); // payStatus, orderOwedBase, etc. (renderClients deps)
  clients = require('../renderer/clients.js');
  global.localName = (c) => (c && (c.nameEn || c.nameAr || c.name)) || '';
  global.toast = () => {};
  global.saveAll = () => {};
  dom.seedState({
    settings: { loyaltyEnabled: true, enableVat: false, loyaltyPointsPerUnit: 1, loyaltyRedeemRate: 0.01, loyaltyTiers: [] },
    clients: [{ id: 'c1', nameEn: 'Acme' }],
    printLog: [{ id: 'o1', clientId: 'c1', status: 'completed', price: 1000, project: 'x', date: '2026-01-01' }],
    giftCards: [],
    loyaltyLedger: [],
  });
});
afterEach(() => dom.teardown());

test('clientLoyaltyAvailable = earned − redeemed (clamped ≥ 0)', () => {
  assert.equal(clients.clientLoyaltyAvailable('c1'), 1000);
  loyaltyLedger.push({ clientId: 'c1', type: 'redeem', points: 400 });
  assert.equal(clients.clientLoyaltyRedeemed('c1'), 400);
  assert.equal(clients.clientLoyaltyAvailable('c1'), 600);
  loyaltyLedger.push({ clientId: 'c1', type: 'redeem', points: 999999 });
  assert.equal(clients.clientLoyaltyAvailable('c1'), 0, 'never negative');
});

test('redeemLoyaltyPoints issues store credit + ledger entry; no double-spend', () => {
  clients.redeemLoyaltyPoints('c1');
  assert.equal(giftCards.length, 1, 'a store-credit gift card is issued');
  assert.equal(giftCards[0].balance, 10, '1000 pts × 0.01 = 10 credit');
  assert.equal(giftCards[0].source, 'loyalty');
  assert.equal(loyaltyLedger.length, 1);
  assert.equal(loyaltyLedger[0].points, 1000);
  assert.equal(clients.clientLoyaltyAvailable('c1'), 0, 'points consumed');
  clients.redeemLoyaltyPoints('c1'); // nothing left
  assert.equal(giftCards.length, 1, 'no double-spend');
});
