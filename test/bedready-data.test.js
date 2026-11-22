'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { migrateAndResolveUserData, BR_DIRNAME, LEGACY_DIRNAME } = require('../lib/bedready-data');

function tmpAppData() {
  const d = path.join(os.tmpdir(), 'brdata-test-' + process.pid + '-' + Math.floor(process.hrtime()[1]));
  fs.mkdirSync(d, { recursive: true });
  return d;
}
const write = (p, s) => { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, s); };

test('fresh install: creates and returns the Bed Ready dir, no migration', () => {
  const appData = tmpAppData();
  const out = migrateAndResolveUserData(appData);
  assert.equal(out, path.join(appData, BR_DIRNAME));
  assert.ok(fs.existsSync(out), 'BedReady dir is created so setPath gets a real path');
  assert.ok(!fs.existsSync(path.join(appData, LEGACY_DIRNAME)), 'no legacy dir invented');
});

test('migrates existing data from the shared khayt dir (copy, minus backups)', () => {
  const appData = tmpAppData();
  const legacy = path.join(appData, LEGACY_DIRNAME);
  write(path.join(legacy, 'store.json'), '{"v":1}');
  write(path.join(legacy, 'products', 'p1.png'), 'IMG');
  write(path.join(legacy, 'backups', '2026-07-01.json'), 'BIG');

  const out = migrateAndResolveUserData(appData);
  assert.equal(out, path.join(appData, BR_DIRNAME));
  // live data copied
  assert.equal(fs.readFileSync(path.join(out, 'store.json'), 'utf8'), '{"v":1}');
  assert.equal(fs.readFileSync(path.join(out, 'products', 'p1.png'), 'utf8'), 'IMG');
  // large, regenerable backups skipped
  assert.ok(!fs.existsSync(path.join(out, 'backups')), 'backups/ is not copied');
  // COPY not MOVE — legacy dir is left fully intact for a co-installed Khayt
  assert.equal(fs.readFileSync(path.join(legacy, 'store.json'), 'utf8'), '{"v":1}');
  assert.ok(fs.existsSync(path.join(legacy, 'backups', '2026-07-01.json')), 'legacy untouched');
  // no temp dir left behind
  assert.ok(!fs.existsSync(out + '.migrating'));
});

test('idempotent: an existing Bed Ready dir is used as-is, never re-seeded', () => {
  const appData = tmpAppData();
  write(path.join(appData, BR_DIRNAME, 'existing.json'), 'MINE');
  write(path.join(appData, LEGACY_DIRNAME, 'store.json'), '{"other":true}');

  const out = migrateAndResolveUserData(appData);
  assert.equal(out, path.join(appData, BR_DIRNAME));
  assert.equal(fs.readFileSync(path.join(out, 'existing.json'), 'utf8'), 'MINE');
  assert.ok(!fs.existsSync(path.join(out, 'store.json')), 'legacy data not merged over an existing dir');
});

test('legacy dir present but empty: treated as fresh install', () => {
  const appData = tmpAppData();
  fs.mkdirSync(path.join(appData, LEGACY_DIRNAME), { recursive: true });
  const out = migrateAndResolveUserData(appData);
  assert.equal(out, path.join(appData, BR_DIRNAME));
  assert.ok(fs.existsSync(out));
});
