/**
 * E2E smoke — a shop's data survives an upgrade whose migration is wrong.
 *
 * The unit tests cover the DECISION (lib/upgrade-backup.js). They cannot cover
 * the thing that matters: that the copy is taken from the bytes actually on
 * disk, before this build's normalize step has run. That step is an allowlist,
 * so a collection a newer Khayt added and this one does not recognise is dropped
 * by it — and a backup taken after it would be a backup of the damage.
 *
 * So this plants a store written by an older schema, containing a collection
 * this build knows nothing about, launches the real app, and reads the backup
 * back off disk to check that collection is still in it.
 *
 * Run: npm run test:e2e:upgradebackup
 */
import fs from 'node:fs';
import path from 'node:path';
import { launchApp, makeUserDataDir, dismissWizard } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const userData = makeUserDataDir();
const storePath = path.join(userData, 'khayt-store.json');
const backupsPath = path.join(userData, 'backups');

// A store from an older schema. `version: 3` is well below any shipped build, and
// `inventedCollection` stands in for anything a future Khayt might add that this
// build's allowlist would drop.
const ORIGINAL = {
  version: 3,
  printLog: [{ id: 'OLD-1', client: 'Pre-upgrade order', status: 'completed', price: 250 }],
  clients: [{ id: 'C-OLD', name: 'A client from before the upgrade' }],
  settings: { bizEn: 'Upgrade Test Shop', currency: 'USD' },
  inventedCollection: [{ id: 'X1', note: 'a collection this build does not know' }],
};
fs.mkdirSync(userData, { recursive: true });
fs.writeFileSync(storePath, JSON.stringify(ORIGINAL), 'utf8');

// A full set of daily backups, so rotation runs and has something to delete.
fs.mkdirSync(backupsPath, { recursive: true });
for (let i = 1; i <= 34; i++) {
  fs.writeFileSync(path.join(backupsPath, `2026-06-${String(i).padStart(2, '0')}.json`), '{}', 'utf8');
}

const { electronApp, window } = await launchApp(userData);
let failed = false;
try {
  await dismissWizard(window);
  // Let the load path settle, then force a save so the whole upgrade round-trip
  // (read old → normalize → write new) actually happens.
  await window.evaluate(() => saveAll());
  await window.waitForTimeout(600);

  const files = fs.readdirSync(backupsPath);
  const preUpgrade = files.filter((f) => f.startsWith('pre-upgrade-'));
  ok(preUpgrade.length === 1, `exactly one pre-upgrade backup was taken (${preUpgrade.join(', ') || 'none'})`);
  ok(/v3-to-v\d+/.test(preUpgrade[0]), `and it names the hop it insures: ${preUpgrade[0]}`);

  // The backup is encrypted at rest exactly like the daily ones; on a machine
  // without OS encryption available it is stored as plain values, so accept both
  // rather than asserting a storage detail this test does not own.
  const rawBackup = fs.readFileSync(path.join(backupsPath, preUpgrade[0]), 'utf8');
  ok(rawBackup.includes('OLD-1'), 'the order that existed before the upgrade is in the backup');
  ok(rawBackup.includes('A client from before the upgrade'), 'and so is the client');
  ok(rawBackup.includes('inventedCollection'),
    'and so is the collection this build does not recognise — proof the copy predates normalization');

  // The live store has moved on: this is what makes the backup necessary rather
  // than redundant.
  const live = JSON.parse(fs.readFileSync(storePath, 'utf8'));
  ok(live.version > 3, `the store on disk was upgraded (now v${live.version})`);
  ok(live.inventedCollection === undefined,
    'and the unrecognised collection is gone from it — exactly the loss the backup covers');

  // Rotation must not treat the insurance as one of the 30.
  const daily = files.filter((f) => !f.startsWith('pre-upgrade-') && f.endsWith('.json'));
  ok(daily.length <= 31, `daily backups rotated down (${daily.length} left of 34)`);
  ok(fs.existsSync(path.join(backupsPath, preUpgrade[0])),
    'and the pre-upgrade backup survived the rotation that ran alongside it');

  console.log('\nupgrade backup smoke: all assertions passed');
} catch (err) {
  failed = true;
  console.error('\n' + (err && err.message ? err.message : String(err)));
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
