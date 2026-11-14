'use strict';
/**
 * Pay link v2: this computer's signing key (`settings.quoteLinkKey`) goes
 * nowhere but this computer. No private key ever syncs (decided 14 Nov 2026):
 *
 *   - the seed is sealed on disk and masked for the window (SECRET_PATHS);
 *   - the whole record is REMOVED from /api/store, the cloud push and exports
 *     (PER_DEVICE_PATHS), and kept from this computer when a backup comes in;
 *   - only main writes it: a save from the window can neither replace nor erase it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/store-secret-paths.js');
const { forCloud, forPhone } = require('../lib/cloud-outbox.js');
const { harness, MASK } = require('./helpers/store-io-harness.js');

// Test value only: not a real key.
const SEED = 'test-seed-not-real-000000000000000000000AA';
const RECORD = { seed: SEED, kid: 'test-kid-not-real-0000000000000000000000000', x: 'test-x', createdAt: '2026-11-14T08:00:00.000Z', status: 'current' };
const book = () => ({ settings: { shopName: 'Atelier', quoteLinkKey: { ...RECORD } }, printLog: [], clients: [] });

test('the seed is a secret path, and the whole record is per device', () => {
  assert.ok(P.SECRET_PATHS.includes('settings.quoteLinkKey.seed'));
  assert.ok(P.PER_DEVICE_PATHS.includes('settings.quoteLinkKey'));
});

test('/api/store, the cloud push and an export carry no part of the key', () => {
  const { buildExportPayload } = require('../lib/store.js');
  for (const [name, out] of [['forPhone', forPhone(book())], ['forCloud', forCloud(book())],
    ['export', buildExportPayload(book(), { redactSecrets: true })]]) {
    assert.equal('quoteLinkKey' in out.settings, false, `${name} carries the key record`);
    assert.equal(JSON.stringify(out).includes(SEED), false, name);
    assert.equal(out.settings.shopName, 'Atelier', `${name} keeps the rest`);
  }
});

test('sealed on disk; the window gets the mask, never the seed', () => {
  const io = harness();
  const sealed = io.encryptForDisk(book());
  assert.match(sealed.settings.quoteLinkKey.seed, /^__enc__/);
  assert.equal(JSON.stringify(sealed).includes(SEED), false);
  const masked = io.maskStoreSecretsForRenderer(book());
  assert.equal(masked.settings.quoteLinkKey.seed, MASK);
  assert.equal(JSON.stringify(masked).includes(SEED), false);
});

test('a save from the window keeps the record on disk, whatever it sent', () => {
  const io = harness();
  io.putOnDisk(book());
  for (const sent of [undefined, { seed: MASK }, { ...RECORD, seed: 'test-seed-not-real-written-by-the-windowAA', status: 'revoked' }]) {
    const win = book();
    if (sent === undefined) delete win.settings.quoteLinkKey; else win.settings.quoteLinkKey = sent;
    const merged = io.mergeStoreSecretsFromDisk(win);
    assert.equal(merged.settings.quoteLinkKey.seed, SEED, `window sent ${JSON.stringify(sent)}`);
    assert.equal(merged.settings.quoteLinkKey.status, 'current');
  }
});

test('a save from the window cannot bring a key back once main removed it', () => {
  const io = harness();
  const none = book();
  delete none.settings.quoteLinkKey;
  io.putOnDisk(none);
  const merged = io.mergeStoreSecretsFromDisk(book());
  assert.equal('quoteLinkKey' in merged.settings, false);
});

test('a backup coming in keeps this computer\'s key, and brings none of its own', () => {
  const incoming = book();
  incoming.settings.quoteLinkKey = { ...RECORD, seed: 'test-seed-not-real-from-another-computerAA', kid: 'other' };
  P.keepMachineLocal(book(), incoming);
  assert.equal(incoming.settings.quoteLinkKey.seed, SEED);
  assert.equal(incoming.settings.quoteLinkKey.kid, RECORD.kid);

  const bare = book();
  delete bare.settings.quoteLinkKey;
  const again = book();
  P.keepMachineLocal(bare, again);
  assert.equal('quoteLinkKey' in again.settings, false, 'none here: none taken from the backup');
});
