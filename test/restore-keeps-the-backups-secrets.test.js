'use strict';
/**
 * A restore puts the BACKUP's credentials on disk, and the window never sees them.
 *
 * hub:restore-backup and hub:read-restore-point handed the renderer the backup
 * fully decrypted — every API key, printer access code and cloud token in the
 * clear, in the one process hub:load-store is careful never to give them to.
 * Masking the reply is not enough by itself: the window saves what it restored,
 * and a save keeps the ON-DISK secret wherever it sends the mask. So a masked
 * restore would have kept TODAY's credentials under the backup's data, silently.
 *
 * lib/store-io.js restoreSnapshotToDisk writes the restored store in the main
 * process, then hands back the masked copy. These run the real functions against
 * a real file with a fake keychain (test/helpers/store-io-harness.js).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { harness, MASK } = require('./helpers/store-io-harness.js');

function today() {
  return {
    version: 1,
    settings: {
      cloud: { token: 'today-cloud-token' },
      ai: { apiKey: 'today-ai-key' },
      slicers: [{ id: 'local', path: '/Applications/OrcaSlicer.app' }],
      lanApi: { pin: 'today-pin' },
    },
    machines: [{ id: 'M1', name: 'Today', printerApi: { accessCode: 'today-code' } }],
    printLog: [{ id: 'O-today' }],
    printerCompletions: { M1: { grams: 12 } },
  };
}

function backup() {
  return {
    version: 1,
    settings: {
      cloud: { token: 'backup-cloud-token' },
      ai: { apiKey: 'backup-ai-key' },
      // A backup's slicer must never come back: it RUNS on this computer.
      slicers: [{ id: 'evil', path: '/tmp/evil', args: '--post-process rm' }],
      lanApi: { pin: 'backup-pin' },
    },
    machines: [{ id: 'M1', name: 'Backup', printerApi: { accessCode: 'backup-code' } }],
    printLog: [{ id: 'O-backup' }],
  };
}

const readDisk = (io) => io.readStoreDecryptedFromDisk();

test('a restored backup puts its own secrets on disk, sealed', async () => {
  const io = harness();
  io.putOnDisk(today());
  const r = await io.restoreSnapshotToDisk(io.encryptForDisk(backup()));
  assert.equal(r.ok, true);

  const disk = readDisk(io);
  assert.equal(disk.settings.cloud.token, 'backup-cloud-token');
  assert.equal(disk.settings.ai.apiKey, 'backup-ai-key');
  assert.equal(disk.settings.lanApi.pin, 'backup-pin');
  assert.equal(disk.machines[0].printerApi.accessCode, 'backup-code');
  assert.deepEqual(disk.printLog.map((o) => o.id), ['O-backup']);

  // Sealed at rest, as every save writes them.
  const raw = fs.readFileSync(path.join(io.userDataDir, 'khayt-store.json'), 'utf8');
  assert.ok(!raw.includes('backup-cloud-token'), 'a restored secret was written in the clear');
});

test('the window is handed the masked copy, never a secret', async () => {
  const io = harness();
  io.putOnDisk(today());
  const r = await io.restoreSnapshotToDisk(io.encryptForDisk(backup()));
  const json = JSON.stringify(r.masked);
  for (const s of ['backup-cloud-token', 'backup-ai-key', 'backup-pin', 'backup-code',
    'today-cloud-token', 'today-ai-key', 'today-pin', 'today-code']) {
    assert.ok(!json.includes(s), `${s} reached the renderer`);
  }
  assert.equal(r.masked.settings.cloud.token, MASK);
  assert.equal(r.masked.machines[0].printerApi.accessCode, MASK);
});

test("the window's follow-up save keeps the backup's secrets, not today's", async () => {
  // What renderer/settings.js does next: load the masked copy and save it.
  const io = harness();
  io.putOnDisk(today());
  const r = await io.restoreSnapshotToDisk(io.encryptForDisk(backup()));
  const saved = io.mergeStoreSecretsFromDisk(r.masked);
  assert.equal(saved.settings.cloud.token, 'backup-cloud-token');
  assert.equal(saved.machines[0].printerApi.accessCode, 'backup-code');
});

test("this computer's slicer and the main-owned keys survive a restore", async () => {
  const io = harness();
  io.putOnDisk(today());
  await io.restoreSnapshotToDisk(io.encryptForDisk(backup()));
  const disk = readDisk(io);
  assert.deepEqual(disk.settings.slicers, today().settings.slicers);
  assert.deepEqual(disk.printerCompletions, today().printerCompletions);
});

test('a restore point taken from the masked window copy keeps the current secret', async () => {
  // Restore points are built from the renderer's state, which only holds masks.
  const io = harness();
  io.putOnDisk(today());
  const rp = backup();
  rp.settings.cloud.token = MASK;
  await io.restoreSnapshotToDisk(io.encryptForDisk(rp));
  const disk = readDisk(io);
  assert.equal(disk.settings.cloud.token, 'today-cloud-token');
  assert.equal(disk.settings.ai.apiKey, 'backup-ai-key');
});

test('a file that is not a Khayt store is refused and nothing is written', async () => {
  const io = harness();
  io.putOnDisk(today());
  const before = fs.readFileSync(path.join(io.userDataDir, 'khayt-store.json'), 'utf8');
  for (const bad of [null, [], { name: 'package.json' }, { __corrupt: true }]) {
    const r = await io.restoreSnapshotToDisk(bad);
    assert.equal(r.ok, false);
  }
  assert.equal(fs.readFileSync(path.join(io.userDataDir, 'khayt-store.json'), 'utf8'), before);
});

test('migrateLanApiSecrets moves the legacy webhook secrets and drops the old keys', () => {
  const io = harness();
  const store = { settings: { sallaWebhookSecret: 'salla-old', zidWebhookSecret: 'zid-old' } };
  io.migrateLanApiSecrets(store);
  assert.equal(store.settings.lanApi.sallaWebhookSecret, 'salla-old');
  assert.equal(store.settings.lanApi.zidWebhookSecret, 'zid-old');
  assert.ok(!('sallaWebhookSecret' in store.settings), 'the plaintext legacy Salla secret stayed');
  assert.ok(!('zidWebhookSecret' in store.settings), 'the plaintext legacy Zid secret stayed');
});

test('migrateLanApiSecrets keeps the lanApi value already there and still drops the legacy one', () => {
  const io = harness();
  const store = { settings: { sallaWebhookSecret: 'salla-old', lanApi: { sallaWebhookSecret: 'salla-new' } } };
  io.migrateLanApiSecrets(store);
  assert.equal(store.settings.lanApi.sallaWebhookSecret, 'salla-new');
  assert.ok(!('sallaWebhookSecret' in store.settings));
});

test('migrateLanApiSecrets never drops a legacy key that was not copied', () => {
  // Nothing to copy (empty legacy value) leaves lanApi empty; the key is only
  // removed once lanApi holds a value.
  const io = harness();
  const store = { settings: { zidWebhookSecret: '' } };
  io.migrateLanApiSecrets(store);
  assert.ok('zidWebhookSecret' in store.settings);
});
