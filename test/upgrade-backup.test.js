const { test } = require('node:test');
const assert = require('node:assert/strict');

const U = require('../lib/upgrade-backup.js');

/**
 * Khayt survives crashes well — atomic writes, a `.prev` generation, crash
 * recovery, and a guard that refuses to save over a store written by a newer
 * build. The gap this covers is the one where nothing crashes and nothing is
 * refused: a build whose own migration is wrong reads the old store, transforms
 * it, and writes the result. `.prev` covers exactly one save, and the daily
 * backup is keyed by DATE, so the first backup after the upgrade overwrites the
 * last good one from the same day.
 */

test('an older store on disk is backed up before this build touches it', () => {
  assert.equal(U.needsPreUpgradeBackup(9, 10), true);
  assert.equal(U.needsPreUpgradeBackup(1, 10), true);
});

test('a store from before versioning existed counts as older, not as unknown', () => {
  // The store carried no `version` at all until v10. Those are the oldest
  // installs in the field and the ones with most to lose, so a missing version
  // must not read as "cannot tell — skip the backup".
  for (const missing of [undefined, null, NaN, 'x']) {
    assert.equal(U.needsPreUpgradeBackup(missing, 10), true, `version=${String(missing)}`);
  }
});

test('a fresh install has nothing to back up', () => {
  assert.equal(U.needsPreUpgradeBackup(null, 10, false), false);
  assert.equal(U.needsPreUpgradeBackup(9, 10, false), false);
});

test('the same version is not an upgrade', () => {
  assert.equal(U.needsPreUpgradeBackup(10, 10), false);
});

test('a NEWER store is not backed up — it is refused', () => {
  // main.js declines to save over a store written by a newer build, so nothing
  // is at risk and a backup would only be noise. Backing it up would also imply
  // the upgrade is proceeding, which it is not.
  assert.equal(U.needsPreUpgradeBackup(11, 10), false);
});

test('the filename carries both versions and is legal on Windows', () => {
  const name = U.preUpgradeBackupName(9, 10, '2026-08-11T09:30:00.000Z');
  assert.ok(name.includes('v9-to-v10'), `both versions are visible: ${name}`);
  assert.ok(!name.includes(':'), 'a colon is not a legal Windows filename character');
  assert.ok(name.endsWith('.json'));
  // The rotation filter only looks at .json files, so the extension is load-bearing.
  assert.equal(U.isProtectedBackup(name), true);
});

test('an unversioned store is named v0 rather than vundefined', () => {
  assert.ok(U.preUpgradeBackupName(undefined, 10, '2026-08-11T09:30:00Z').includes('v0-to-v10'));
});

test('rotation may delete daily backups and may never delete upgrade ones', () => {
  const files = [
    '2026-08-01.json',
    'pre-upgrade-v9-to-v10-2026-08-02T00-00-00-000Z.json',
    '2026-08-03.json',
  ];
  const { protectedFiles, rotatable } = U.partitionForRotation(files);
  assert.deepEqual(rotatable, ['2026-08-01.json', '2026-08-03.json']);
  assert.deepEqual(protectedFiles, ['pre-upgrade-v9-to-v10-2026-08-02T00-00-00-000Z.json']);
});

test('a shop that opens the app for 30 days does not lose its upgrade backup', () => {
  // The failure this prevents: rotation counts 30 files including the upgrade
  // backup, so the oldest — which is the upgrade backup — is the first deleted.
  const daily = Array.from({ length: 40 }, (_, i) => `2026-07-${String(i + 1).padStart(2, '0')}.json`);
  const files = ['pre-upgrade-v9-to-v10-2026-06-01T00-00-00-000Z.json', ...daily];
  const { rotatable } = U.partitionForRotation(files);
  const doomed = rotatable.slice(0, rotatable.length - 30);
  assert.equal(doomed.length, 10, 'ten oldest daily backups rotate out');
  assert.ok(!doomed.some(U.isProtectedBackup), 'and none of them is the upgrade backup');
});

test('malformed input is safe', () => {
  assert.deepEqual(U.partitionForRotation(null), { protectedFiles: [], rotatable: [] });
  assert.equal(U.isProtectedBackup(null), false);
  assert.equal(U.isProtectedBackup(undefined), false);
  assert.equal(U.needsPreUpgradeBackup(9, NaN), false);
});

test('an app-update backup is protected too, by rule rather than by accident', () => {
  /* lib/updater.js copies the store aside before installing an update and names
   * it `pre-update-v<version>-<date>.json`. Two mechanisms, two confusingly
   * similar names, and this rule only knew the first — so an update backup was
   * counted as rotatable.
   *
   * It survived by accident: rotation sorts the filenames and deletes from the
   * front, and "pre-update-…" sorts after every "YYYY-MM-DD.json". The accident
   * still cost a shop backups — three update backups meant twenty-seven daily
   * ones instead of thirty — and it would have become a real deletion the
   * moment anything changed the sort or the slice. */
  const update = 'pre-update-v3.7.0-beta.8-2026-08-27.json';
  assert.equal(U.isProtectedBackup(update), true);

  const files = [update, 'pre-upgrade-v11-to-v12-2026-01-01.json'];
  for (let day = 1; day <= 35; day++) files.push(`2026-01-${String(day).padStart(2, '0')}.json`);
  const { protectedFiles, rotatable } = U.partitionForRotation(files);
  assert.equal(protectedFiles.length, 2, 'both kinds of insurance');
  assert.equal(rotatable.length, 35, 'and only the dailies are housekeeping\'s to count');
  assert.ok(!rotatable.includes(update));
});

test('a file that merely mentions an update is not one', () => {
  // The prefix, not a substring: a shop is free to name a file what it likes.
  assert.equal(U.isProtectedBackup('2026-01-01-pre-update-notes.json'), false);
  assert.equal(U.isProtectedBackup('pre-update-'), true);
  assert.equal(U.isProtectedBackup(''), false);
  assert.equal(U.isProtectedBackup(null), false);
});

// File-safety scan, Sep 2026: cloud snapshots and daily backups shared one
// pool of thirty, so a day of syncing pushed a month of dailies out.
test('dailies and snapshots rotate in their own pools, and nothing protected or excepted goes', () => {
  const UB = require('../lib/upgrade-backup.js');
  const days = Array.from({ length: 35 }, (_, i) => `2026-08-${String(i + 1).padStart(2, '0')}.json`.replace('2026-08-3', '2026-09-0'));
  const snaps = Array.from({ length: 60 }, (_, i) => `2026-09-24-${String(1000 + i)}.json`);
  const kept = [UB.PROTECTED_PREFIX + 'v1-to-v2-x.json'];
  const doomed = UB.backupsToDelete([...days, ...snaps, ...kept], { except: [days[0]] });
  const dailyLeft = days.filter((d) => !doomed.includes(d));
  const snapLeft = snaps.filter((d) => !doomed.includes(d));
  assert.equal(snapLeft.length, 48, 'the newest 48 snapshots stay');
  assert.equal(dailyLeft.length, 31, 'the newest 30 dailies stay, plus the excepted one');
  assert.ok(dailyLeft.includes(days[0]), 'the backup being restored is never deleted');
  assert.ok(!doomed.some((d) => d.includes('pre-upgrade')), 'upgrade insurance is never deleted');
  // Sixty snapshots in one day no longer touch the dailies at all.
  assert.ok(days.slice(-30).every((d) => !doomed.includes(d)));
});
