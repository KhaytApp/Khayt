'use strict';
/**
 * WhatsApp delivery reports onto the commLog: matched by message id, and a
 * status only ever moves forward (khayt-cloud "WhatsApp delivery reports").
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const WS = require('../lib/whatsapp-status.js');

const clients = () => [
  { id: 'c1', commLog: [
    { id: 'm1', type: 'whatsapp', note: 'Your order shipped', at: '2026-10-18T08:00:00Z', messageId: 'wamid.A', status: 'sent' },
    { id: 'm2', type: 'call', note: 'Called', at: '2026-10-18T09:00:00Z' },
  ] },
  { id: 'c2', commLog: [
    { id: 'm3', type: 'whatsapp', note: 'Ready', at: '2026-10-18T08:30:00Z', messageId: 'wamid.B', status: 'read' },
  ] },
  { id: 'c3' },
];

test('a report moves the line it names forward and stamps when', () => {
  const r = WS.apply(clients(), [{ messageId: 'wamid.A', status: 'delivered', at: '2026-10-18T08:01:00Z', seq: 1 }]);
  assert.equal(r.changed, 1);
  assert.equal(r.clients[0].commLog[0].status, 'delivered');
  assert.equal(r.clients[0].commLog[0].statusAt, '2026-10-18T08:01:00Z');
  assert.equal(r.clients[0].commLog[1].status, undefined, 'a call is not a message');
});

test('never backwards: a late delivered after read changes nothing', () => {
  const input = clients();
  const r = WS.apply(input, [{ messageId: 'wamid.B', status: 'delivered', at: '2026-10-18T08:40:00Z' }]);
  assert.equal(r.changed, 0);
  assert.equal(r.clients[1], input[1], 'an untouched client is the same object');
});

test('of several reports for one message, the furthest wins, whatever their order', () => {
  const r = WS.apply(clients(), [
    { messageId: 'wamid.A', status: 'read', at: '2026-10-18T08:05:00Z' },
    { messageId: 'wamid.A', status: 'delivered', at: '2026-10-18T08:01:00Z' },
  ]);
  assert.equal(r.clients[0].commLog[0].status, 'read');
  assert.equal(r.changed, 1);
});

test('failed keeps Meta\'s reason', () => {
  const r = WS.apply(clients(), [{ messageId: 'wamid.B', status: 'failed', at: '2026-10-18T09:00:00Z',
    errorCode: 131026, errorTitle: 'Message undeliverable' }]);
  const line = r.clients[1].commLog[0];
  assert.equal(line.status, 'failed');
  assert.equal(line.errorCode, 131026);
  assert.equal(line.errorTitle, 'Message undeliverable');
});

test('reports for messages this book does not hold are counted, not invented', () => {
  const r = WS.apply(clients(), [{ messageId: 'wamid.Z', status: 'read' }, { messageId: '', status: 'read' },
    { messageId: 'wamid.A', status: 'bogus' }]);
  assert.equal(r.changed, 0);
  assert.equal(r.unmatched, 1);
});

test('only a real instant, a numeric code and a short title reach the book', () => {
  const r = WS.apply(clients(), [{ messageId: 'wamid.A', status: 'failed', at: 'x'.repeat(5000),
    errorCode: { nested: 'x'.repeat(5000) }, errorTitle: 't'.repeat(5000) }]);
  const line = r.clients[0].commLog[0];
  assert.equal(line.status, 'failed');
  assert.equal(line.statusAt, undefined);
  assert.equal(line.errorCode, undefined);
  assert.equal(line.errorTitle.length, 200);
});
