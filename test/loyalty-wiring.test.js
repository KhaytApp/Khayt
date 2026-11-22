/**
 * Loyalty display wiring: clientLoyaltyPoints sums earned points over a client's
 * completed orders via lib/loyalty (read-only; gated by settings.loyaltyEnabled).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

function setup(extra = {}) {
  require('../lib/loyalty.js');           // sets global.KhaytLoyalty
  require('../lib/order-status.js'); // globalThis.KhaytOrderStatus — 'delivered' is finished too
  require('../renderer/currency.js');     // orderRevenueBase etc. for getClientTier
  require('../lib/tax.js');          // sets globalThis.KhaytTax — money paths need it
  const clients = require('../renderer/clients.js');
  global.printLog = [
    { id: 'o1', clientId: 'c1', status: 'completed', price: 115 },  // ex-VAT 100 @15%
    { id: 'o2', clientId: 'c1', status: 'completed', price: 230 },  // ex-VAT 200
    { id: 'o3', clientId: 'c1', status: 'pending', price: 500 },    // excluded (not completed)
    { id: 'o4', clientId: 'c2', status: 'completed', price: 115 },
  ];
  global.settings = Object.assign({ loyaltyEnabled: true, enableVat: true, vatRate: 15, loyaltyPointsPerUnit: 1, loyaltyTiers: [] }, extra);
  return clients;
}

test('clientLoyaltyPoints sums ex-VAT points over completed orders only', () => {
  const clients = setup();
  // c1: floor(100*1) + floor(200*1) = 300 ; pending order excluded
  assert.equal(clients.clientLoyaltyPoints('c1'), 300);
  assert.equal(clients.clientLoyaltyPoints('c2'), 100);
});

test('clientLoyaltyPoints returns 0 when loyalty disabled (no behavior unless opted in)', () => {
  const clients = setup({ loyaltyEnabled: false });
  assert.equal(clients.clientLoyaltyPoints('c1'), 0);
});

test('VAT disabled → points earned on the full (tax-free) price', () => {
  const clients = setup({ enableVat: false });
  // c1: 115 + 230 = 345
  assert.equal(clients.clientLoyaltyPoints('c1'), 345);
});
