'use strict';

/**
 * Where the quote pay link's secret may go: nowhere but this computer.
 *
 *   - sealed on disk and masked for the window (SECRET_PATHS), like every
 *     credential: test/every-secret-is-protected.test.js walks the list;
 *   - REMOVED, not masked, from what /api/store hands a phone and what goes
 *     to the cloud (PER_DEVICE_PATHS): the Mac's LanServer sends `forPhone`;
 *   - kept from this computer when a backup or a cloud copy comes in;
 *   - set and removed by main only: a save from the window can neither write
 *     it nor erase it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/store-secret-paths.js');
const { forCloud, forPhone } = require('../lib/cloud-outbox.js');
const { harness, MASK } = require('./helpers/store-io-harness.js');

const SECRET = 'test-secret-not-real-0123456789abcdef';
const book = () => ({
  settings: { shopName: 'Atelier', quotePayLink: { storeUrl: 'https://shop.example', secret: SECRET, secretSetAt: '2026-11-12T08:00:00.000Z' } },
  printLog: [], clients: [],
});

test('the path is on the secret list and the per-device list; when it was set is per device only', () => {
  assert.ok(P.SECRET_PATHS.includes('settings.quotePayLink.secret'));
  assert.ok(P.PER_DEVICE_PATHS.includes('settings.quotePayLink.secret'));
  assert.ok(P.PER_DEVICE_PATHS.includes('settings.quotePayLink.secretSetAt'));
  assert.ok(!P.SECRET_PATHS.includes('settings.quotePayLink.secretSetAt'), 'shown on this computer, so not masked');
});

const SET_AT = '2026-11-12T08:00:00.000Z';

test('"set {date}" goes nowhere the secret does not: not /api/store, the cloud or an export', () => {
  const { buildExportPayload } = require('../lib/store.js');
  for (const [name, out] of [['forPhone', forPhone(book()).settings], ['forCloud', forCloud(book()).settings],
    ['export', buildExportPayload(book(), { redactSecrets: true }).settings]]) {
    assert.equal('secretSetAt' in out.quotePayLink, false, `${name} carries secretSetAt`);
    assert.equal('secret' in out.quotePayLink, false, `${name} carries the secret`);
    assert.equal(JSON.stringify(out).includes(SET_AT), false, name);
    assert.equal(out.quotePayLink.storeUrl, 'https://shop.example', `${name} keeps the address`);
  }
});

test('"set {date}" is this computer\'s on restore, and absent when this computer has none', () => {
  const incoming = book();
  incoming.settings.quotePayLink.secretSetAt = '2025-01-01T00:00:00.000Z';
  P.keepMachineLocal(book(), incoming);
  assert.equal(incoming.settings.quotePayLink.secretSetAt, SET_AT);
  const bare = book();
  delete bare.settings.quotePayLink.secret; delete bare.settings.quotePayLink.secretSetAt;
  const again = book();
  P.keepMachineLocal(bare, again);
  assert.equal('secretSetAt' in again.settings.quotePayLink, false);
});

test('/api/store (forPhone) carries neither the secret nor a mask of it', () => {
  const out = forPhone(book());
  assert.equal(JSON.stringify(out).includes(SECRET), false);
  assert.equal('secret' in out.settings.quotePayLink, false, 'removed, not masked');
  assert.equal(out.settings.quotePayLink.storeUrl, 'https://shop.example', 'the address still goes');
});

test('the cloud push carries neither', () => {
  const out = forCloud(book());
  assert.equal(JSON.stringify(out).includes(SECRET), false);
  assert.equal('secret' in out.settings.quotePayLink, false);
});

test('the window gets the mask, never the secret', () => {
  const io = harness();
  const masked = io.maskStoreSecretsForRenderer(book());
  assert.equal(masked.settings.quotePayLink.secret, MASK);
  assert.equal(JSON.stringify(masked).includes(SECRET), false);
});

test('sealed on disk', () => {
  const io = harness();
  const sealed = io.encryptForDisk(book());
  assert.match(sealed.settings.quotePayLink.secret, /^__enc__/);
  assert.equal(JSON.stringify(sealed).includes(SECRET), false);
});

test('a save from the window keeps what is on disk, whatever it sent', () => {
  const io = harness();
  io.putOnDisk(book());
  for (const sent of [MASK, undefined, 'test-secret-not-real-written-by-the-window-xx']) {
    const win = book();
    if (sent === undefined) delete win.settings.quotePayLink.secret; else win.settings.quotePayLink.secret = sent;
    delete win.settings.quotePayLink.secretSetAt;
    const merged = io.mergeStoreSecretsFromDisk(win);
    assert.equal(merged.settings.quotePayLink.secret, SECRET, `window sent ${String(sent)}`);
    assert.equal(merged.settings.quotePayLink.secretSetAt, '2026-11-12T08:00:00.000Z');
  }
});

test('a save from the window cannot bring back a removed secret', () => {
  const io = harness();
  const none = book();
  delete none.settings.quotePayLink.secret; delete none.settings.quotePayLink.secretSetAt;
  io.putOnDisk(none);
  const merged = io.mergeStoreSecretsFromDisk(book());
  assert.equal('secret' in merged.settings.quotePayLink, false);
  assert.equal('secretSetAt' in merged.settings.quotePayLink, false);
});

test('a backup or a cloud copy coming in keeps this computer\'s secret, and brings none', () => {
  const incoming = book();
  incoming.settings.quotePayLink.secret = 'test-secret-not-real-from-another-computer';
  const local = book();
  P.keepMachineLocal(local, incoming);
  assert.equal(incoming.settings.quotePayLink.secret, SECRET);

  const bare = book();
  delete bare.settings.quotePayLink.secret;
  const again = book();
  P.keepMachineLocal(bare, again);
  assert.equal('secret' in again.settings.quotePayLink, false, 'none here: none taken from the backup');
});
