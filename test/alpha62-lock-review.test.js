'use strict';

/**
 * alpha.62 security review, the shared-module half: an export carries no PIN
 * hash, and a deposit is a number the shop meant.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/store.js');
const P = require('../lib/portal-owner.js');

const HASH = 'p2$200000$' + 'ab'.repeat(16) + '$' + 'cd'.repeat(32);

test('a redacted export masks every staff PIN hash and the recovery-code hash', () => {
  const out = S.buildExportPayload({
    settings: { recoveryCodeHash: HASH, shopName: 'Atelier' },
    operators: [{ id: 'OP-1', name: 'Noura', pinHash: HASH }, { id: 'OP-2', name: 'Faisal' }],
    printLog: [], machines: [],
  }, { redactSecrets: true });
  assert.ok(!JSON.stringify(out).includes(HASH), 'a hash left the shop in its "redacted" copy');
  assert.equal(out.operators[0].pinHash, S.SECRET_MASK, 'masked, not deleted: no hash is a free sign-in');
  assert.equal('pinHash' in out.operators[1], false, 'nobody gains a PIN');
  assert.equal(out.settings.recoveryCodeHash, S.SECRET_MASK);
  assert.equal(out.settings.shopName, 'Atelier');
});

test('an unredacted export (the backup) keeps them, and a book with no staff stays without', () => {
  const book = { settings: { recoveryCodeHash: HASH }, operators: [{ id: 'OP-1', pinHash: HASH }] };
  const out = S.buildExportPayload(book);
  assert.equal(out.operators[0].pinHash, HASH);
  assert.equal(out.settings.recoveryCodeHash, HASH);
  assert.equal('operators' in S.buildExportPayload({ settings: {} }, { redactSecrets: true }), false);
});

test('a deposit is a plain or properly grouped number — a decimal comma is refused, not multiplied', () => {
  const dep = (t) => P.depositForm(t, '');
  for (const bad of ['12,50', '1,5', '1,25,0', '0x10', '1e3', '-5', 'abc', '0.001', '١٢']) {
    assert.equal(dep(bad).ok, false, bad);
  }
  assert.equal(dep('1,250.50').cloudDeposit, 1250.5);
  assert.equal(dep('1250').cloudDeposit, 1250);
  assert.equal(dep('12.5').cloudDeposit, 12.5);
  assert.equal(dep('').cloudDeposit, null);
  assert.equal(dep('0').cloudDeposit, null);
});
