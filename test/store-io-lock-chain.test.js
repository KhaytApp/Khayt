'use strict';
/**
 * Re-review of #2608/#2609: main's own load-time lock-field changes (the
 * owner migration, hashing old PINs, and with #2608 the sign-out at start) run INSIDE the write
 * chain, so a write queued ahead of them is kept, not overwritten with a
 * stale copy (lib/store-io.js updateStoreOnDiskAllowingLock).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createStoreIo } = require('../lib/store-io.js');
const { safeJsonParse } = require('../lib/safe-json.js');
const PP = require('../lib/main/printer-permission.js');

async function fresh(book) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-lockchain-'));
  let held = {};
  const io = createStoreIo({
    app: { getPath: () => dir }, fs, safeStorage: { isEncryptionAvailable: () => false },
    safeJsonParse, crypto: require('node:crypto'),
    onStoreUpdated: (d) => { held = d; }, getStore: () => held,
  });
  await io.persistLanStoreUpdate(book);
  return { io, dir, disk: () => io.recoverStoreRaw().data };
}
const book = () => ({
  settings: { operatorLockEnabled: true, activeOperatorId: 'o' },
  operators: [{ id: 'o', name: 'Owner', roleKey: 'owner' }],
  printLog: [], inventory: [], clients: [], machines: [], expenses: [],
});

test('a write queued first is kept when the sign-out at start runs after it', async () => {
  const { io, dir, disk } = await fresh(book());
  const order = io.updateStoreOnDisk((cur) => ({ ...cur, printLog: [...cur.printLog, { id: 'a1', project: 'LAN order' }] }));
  const out = io.updateStoreOnDiskAllowingLock((cur) => { const r = PP.signedOutAtStart(cur); return r.changed ? r.store : cur; }, ['settings.activeOperatorId']);
  await Promise.all([order, out]);
  const d = disk();
  assert.equal(d.printLog.length, 1, 'the queued order survived');
  assert.equal(d.settings.activeOperatorId, null, 'and nobody is signed in');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a write queued first is kept when the PIN upgrade at load runs after it', async () => {
  const b = book();
  b.operators[0].pinHash = Buffer.from('1234').toString('base64');
  const { io, dir, disk } = await fresh(b);
  const PinHash = require('../lib/pin-hash.js');
  const order = io.updateStoreOnDisk((cur) => ({ ...cur, printLog: [...cur.printLog, { id: 'a1', project: 'LAN order' }] }));
  const up = io.updateStoreOnDiskAllowingLock((cur) => { const r = PP.upgradeLegacyPins(cur, PinHash.hashPin); return r.changed ? r.store : cur; }, ['operators']);
  await Promise.all([order, up]);
  const d = disk();
  assert.equal(d.printLog.length, 1, 'the queued order survived');
  assert.ok(PinHash.isPbkdf2Hash(d.operators[0].pinHash), 'and the PIN is hashed');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('only the named lock fields may change; the ordinary writer still may change none', async () => {
  const { io, dir, disk } = await fresh(book());
  await assert.rejects(io.updateStoreOnDiskAllowingLock((cur) => ({ ...cur, settings: { ...cur.settings, operatorLockEnabled: false } }), ['settings.activeOperatorId']), /operatorLockEnabled/);
  await assert.rejects(io.updateStoreOnDisk((cur) => ({ ...cur, settings: { ...cur.settings, activeOperatorId: null } })), /activeOperatorId/);
  await assert.rejects(io.updateStoreOnDiskAllowingLock((cur) => cur, []), /needs the lock fields/);
  assert.equal(disk().settings.activeOperatorId, 'o');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('a mutator with nothing to change writes nothing', async () => {
  const { io, dir } = await fresh(book());
  const file = path.join(dir, 'khayt-store.json');
  const before = fs.statSync(file).mtimeMs;
  await new Promise((r) => setTimeout(r, 20));
  await io.updateStoreOnDiskAllowingLock((cur) => cur, ['operators']);
  assert.equal(fs.statSync(file).mtimeMs, before);
  fs.rmSync(dir, { recursive: true, force: true });
});
