'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildWebhookEvent, EVENTS } = require('../lib/webhooks.js');

test('builds a normalized event payload', () => {
  const e = buildWebhookEvent('created', { id: 'INV-1', project: 'Vase', status: 'pending', price: 100, paymentStatus: 'unpaid', dueDate: '2026-07-01' },
    { at: '2026-06-25T10:00:00.000Z', shopName: 'Acme', clientName: 'Layla', currency: 'SAR' });
  assert.equal(e.event, 'order.created');
  assert.equal(e.at, '2026-06-25T10:00:00.000Z');
  assert.equal(e.shop.name, 'Acme');
  assert.equal(e.order.id, 'INV-1');
  assert.equal(e.order.client, 'Layla');
  assert.equal(e.order.price, 100);
  assert.match(e.id, /^evt_INV-1_created_/);
});

test('unknown type → order.updated; missing fields safe', () => {
  const e = buildWebhookEvent('bogus', {}, {});
  assert.equal(e.event, 'order.updated');
  assert.equal(e.order.id, '');
  assert.equal(e.order.price, 0);
});

test('EVENTS catalog', () => {
  assert.deepEqual(EVENTS, ['created', 'status', 'paid']);
});
