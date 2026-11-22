const { test } = require('node:test');
const assert = require('node:assert/strict');

test('BNPL_CATALOG includes Tabby and Stripe entries', () => {
  require('../renderer/integrations.js');
  assert.ok(Array.isArray(global.BNPL_CATALOG));
  assert.ok(global.BNPL_CATALOG.some((s) => s.id === 'tabby'));
  assert.ok(global.BNPL_CATALOG.some((s) => s.id === 'stripe'));
});

test('getCarrierTrackingUrl builds Aramex link', () => {
  const { getCarrierTrackingUrl } = require('../renderer/integrations.js');
  const url = getCarrierTrackingUrl('aramex', '12345');
  assert.match(url, /aramex\.com/i);
  assert.match(url, /12345/);
});

test('KhaytIntegrations exports email and LAN helpers', () => {
  const integrations = require('../renderer/integrations.js');
  assert.equal(typeof integrations.fireWebhook, 'function');
  assert.equal(typeof integrations.startLanServer, 'function');
  assert.equal(typeof integrations.sendTelegramForOrder, 'function');
});
