'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
test('signedOutAtStart: under the lock nobody stays signed in across a restart (#2608 security review)', () => {
  const { signedOutAtStart } = require('../lib/main/printer-permission.js');
  const ops = [{ id: 'o', roleKey: 'owner' }];
  const on = { settings: { operatorLockEnabled: true, activeOperatorId: 'o' }, operators: ops };
  const r = signedOutAtStart(on);
  assert.equal(r.changed, true);
  assert.equal(r.store.settings.activeOperatorId, null);
  assert.equal(on.settings.activeOperatorId, 'o', 'the input is not mutated');
  assert.equal(signedOutAtStart({ settings: { operatorLockEnabled: false, activeOperatorId: 'o' } }).changed, false);
  assert.equal(signedOutAtStart({ settings: { operatorLockEnabled: true, activeOperatorId: null } }).changed, false);
  assert.equal(signedOutAtStart(null).changed, false);
  // Turki, Nov 22: a PIN the pad cannot check is signed out too; the pad
  // tells them to ask the owner for a new one (op.pin_legacy).
  const legacy = { settings: { operatorLockEnabled: true, activeOperatorId: 'o' }, operators: [{ id: 'o', roleKey: 'owner', pinHash: 'bm90LWEtcGlu!' }] };
  assert.equal(signedOutAtStart(legacy).changed, true);
  assert.equal(signedOutAtStart(legacy).store.settings.activeOperatorId, null);
  const managed = { settings: { operatorLockEnabled: true, activeOperatorId: 'o' }, operators: [{ id: 'o', roleKey: 'owner', pinHash: require('../lib/pin-hash.js').hashPin('12345678') }] };
  assert.equal(signedOutAtStart(managed).changed, true);
  const noPin = { settings: { operatorLockEnabled: true, activeOperatorId: 'o' }, operators: [{ id: 'o', roleKey: 'owner' }] };
  assert.equal(signedOutAtStart(noPin).changed, true, 'no PIN: the pad signs them in with no PIN, so signing out costs nothing');
  const main = require('fs').readFileSync(require('path').join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /signedOut = await signOutAtStartOnDisk\(\)/);
});
