'use strict';

/**
 * A phone on the LAN is never handed a PIN hash (maintainer's decision,
 * 2026-10-07). `/api/store` sends `forPhone`; the cloud push keeps sending
 * `forCloud`, because the shop's other computers need an operator's PIN to
 * work there too. lib/store-secret-paths.js PHONE_PRIVATE has the reasoning.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/store-secret-paths.js');
const { forCloud, forPhone } = require('../lib/cloud-outbox.js');
const MASK = require('../lib/store.js').SECRET_MASK;

const HASH = 'p2$210000$00112233445566778899aabbccddeeff$' + 'ab'.repeat(32);
const book = () => ({
  settings: { recoveryCodeHash: HASH, shopName: 'Atelier', ntfy: { topic: 'secret-topic' } },
  operators: [
    { id: 'OP-1', name: 'Noura', roleKey: 'manager', pinHash: HASH },
    { id: 'OP-2', name: 'Faisal', roleKey: 'operator' },
  ],
  printLog: [{ id: 'J1', operatorId: 'OP-1' }],
});

test('a phone gets no PIN hash and no recovery hash', () => {
  const out = forPhone(book());
  assert.equal(out.operators[0].pinHash, MASK);
  assert.equal(out.settings.recoveryCodeHash, MASK);
  assert.ok(!JSON.stringify(out).includes(HASH), 'the hash appears nowhere in what is sent');
});

test('masked, not deleted: the operator keeps its shape for a phone that sends it back', () => {
  const out = forPhone(book());
  assert.ok('pinHash' in out.operators[0]);
  assert.equal('pinHash' in out.operators[1], false, 'an operator with no PIN does not gain one');
  assert.equal(out.operators[0].name, 'Noura');
  assert.equal(out.operators[0].roleKey, 'manager');
});

test('everything the cloud hides, the phone does not get either', () => {
  const out = forPhone(book());
  assert.equal(out.settings.ntfy.topic, MASK);
  assert.equal(out.settings.shopName, 'Atelier');
});

test('the cloud still carries the PIN, so a PIN set on one computer works on the next', () => {
  const out = forCloud(book());
  assert.equal(out.operators[0].pinHash, HASH);
  assert.equal(out.settings.recoveryCodeHash, HASH);
});

test('the book handed in is not changed', () => {
  const b = book();
  forPhone(b);
  assert.equal(b.operators[0].pinHash, HASH);
  assert.equal(b.settings.recoveryCodeHash, HASH);
});

test('the list says what it masks', () => {
  assert.deepEqual([...P.PHONE_PRIVATE_PATHS].sort(), ['operators[].pinHash', 'settings.recoveryCodeHash']);
  const seen = [];
  P.forEachPhonePrivate(book(), (v) => seen.push(v));
  assert.equal(seen.length, 2);
  P.forEachPhonePrivate(null, () => assert.fail('nothing to visit'));
});

test('a phone that edits an operator and sends it home does not wipe the PIN', () => {
  const sync = require('../lib/sync.js');
  const home = book();
  home.operators[0].rev = 1;
  home.operators[0].updatedAt = '2026-10-01T00:00:00.000Z';
  // The phone renames Noura from what it was handed.
  const fromPhone = { ...forPhone(home).operators[0], name: 'Noura A.', rev: 2,
    updatedAt: '2026-10-07T09:00:00.000Z' };
  sync.applyDeltas(home, { deltas: [{ collection: 'operators', record: fromPhone }], tombstones: [] },
    { appendOnly: [] });
  const op = home.operators.find(o => o.id === 'OP-1');
  assert.equal(op.name, 'Noura A.', 'the edit arrived');
  assert.equal(op.pinHash, HASH, 'the mask did not replace the real hash');
});
