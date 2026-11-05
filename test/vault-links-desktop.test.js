'use strict';
/**
 * Khayt Vault share links on Windows/Linux (lib/main/vault-links.js): when it
 * offers them, what it refuses by name, and where the link secret lives.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { registerVaultLinks } = require('../lib/main/vault-links.js');

function setup({ book, dek = Buffer.alloc(32, 7), vaultOn = true, fetchImpl } = {}) {
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'vl-'));
  const handlers = {};
  const safeStorage = {
    isEncryptionAvailable: () => true,
    encryptString: (s) => Buffer.from('enc:' + s),
    decryptString: (b) => Buffer.from(b).toString().replace(/^enc:/, ''),
  };
  if (fetchImpl) globalThis.fetch = fetchImpl;
  registerVaultLinks({
    app: { getPath: () => userData }, ipcMain: { handle: (n, f) => { handlers[n] = f; } }, safeStorage,
    readBook: () => book, getDek: () => dek, cloudToken: (t) => t, isVaultOn: () => vaultOn, log: { warn() {} },
  });
  return { handlers, userData };
}
const signedIn = { settings: { cloud: { enabled: true, shopId: 'shop_1', url: 'https://cloud.example', token: 'tok' } } };

test('nothing is offered until the shop is signed in, on a vault library, and unlocked', async () => {
  assert.equal((await setup({ book: {} }).handlers['hub:vault-links-status']()).reason, 'signin');
  assert.equal((await setup({ book: signedIn, vaultOn: false }).handlers['hub:vault-links-status']()).reason, 'vault-off');
  assert.equal((await setup({ book: signedIn, dek: null }).handlers['hub:vault-links-status']()).reason, 'locked');
});

test('a model with no vault copy is refused by name, and no link is made', async () => {
  const calls = [];
  const book = { ...signedIn, printFiles: [{ id: 'R1', name: 'Dragon', vaultFileId: 'F1' }, { id: 'R2', name: 'Vase' }] };
  const { handlers } = setup({ book, fetchImpl: async (url, init) => {
    calls.push([init.method, new URL(url).pathname]);
    return new Response(JSON.stringify({ rev: 1, more: false, files: [] }), { status: 200, headers: { 'content-type': 'application/json' } });
  } });
  const r = await handlers['hub:vault-share'](null, { recordIds: ['R1', 'R2'], options: {} });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'not-in-vault');
  assert.deepEqual(r.names, ['Vase']);
  assert.ok(!calls.some(([m, p]) => m === 'POST' && /\/vault\/grants$/.test(p)), 'a link was created');
});

test('a link secret is kept sealed on this computer, read back for Copy Link, and forgotten on revoke', async () => {
  const seen = [];
  const fetchImpl = async (url, init) => {
    seen.push([init.method, new URL(url).pathname]);
    return new Response(JSON.stringify({ grantId: 'G1' }), { status: 200, headers: { 'content-type': 'application/json' } });
  };
  const { handlers, userData } = setup({ book: signedIn, fetchImpl });
  // put a secret where the share path would, via the same file the module reads
  const file = path.join(userData, 'vault-links.shop_1.json');
  fs.writeFileSync(file, JSON.stringify({ G1: { s: Buffer.from('enc:' + Buffer.alloc(32, 9).toString('base64')).toString('base64'), pendingSince: null } }));
  const u = await handlers['hub:vault-link-url'](null, { grantId: 'G1' });
  assert.equal(u.ok, true);
  assert.match(u.url, /^https:\/\/cloud\.example\/s\/G1#[A-Za-z0-9_-]{43}$/);
  assert.ok(!fs.readFileSync(file, 'utf8').includes(Buffer.alloc(32, 9).toString('base64')), 'the secret is not stored in the clear');
  const done = await handlers['hub:vault-link-change'](null, { grantId: 'G1', action: 'revoke' });
  assert.equal(done.ok, true);
  assert.deepEqual(seen.pop(), ['PATCH', '/v1/shops/shop_1/vault/grants/G1']);
  assert.equal((await handlers['hub:vault-link-url'](null, { grantId: 'G1' })).reason, 'not-kept');
});
