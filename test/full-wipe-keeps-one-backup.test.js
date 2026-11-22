'use strict';

/**
 * A full wipe keeps one copy of the book (maintainer's decision, 2026-09-24).
 *
 * It used to delete everything under userData, backups included, with nothing
 * kept — so a wipe made by mistake was unrecoverable. Now it writes and reads
 * back one protected copy first, refuses to schedule the wipe if it cannot,
 * and the wipe leaves that copy behind.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const UB = require('../lib/upgrade-backup');

const mainJs = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
const bodyOf = (marker, len) => { const at = mainJs.indexOf(marker); assert.ok(at >= 0, marker); return mainJs.slice(at, at + len); };

test('the safety copy is protected from rotation, in both pools', () => {
  const name = UB.preWipeBackupName('2026-09-24T01:02:03.456Z');
  assert.match(name, /^pre-wipe-2026-09-24T01-02-03-456Z\.json$/);
  assert.equal(UB.isProtectedBackup(name), true);
  // 60 dailies and 60 snapshots: both pools overflow, and the copy must survive both.
  const days = Array.from({ length: 60 }, (_, i) => `2026-0${1 + Math.floor(i / 28)}-${String(1 + (i % 28)).padStart(2, '0')}.json`);
  const snaps = Array.from({ length: 60 }, (_, i) => `2026-09-01-${String(1000 + i)}.json`);
  const gone = UB.backupsToDelete([name, ...days, ...snaps]);
  assert.ok(gone.length > 0, 'the fixture must actually trigger rotation');
  assert.ok(!gone.includes(name), 'rotation deletes the copy a wipe kept');
});

test('the copy is taken BEFORE the wipe is scheduled, and a failure deletes nothing', () => {
  const body = bodyOf("ipcMain.handle('hub:request-full-wipe'", 2600);
  const copy = body.indexOf('writePreWipeBackup()');
  const flag = body.indexOf('PENDING_WIPE_FLAG');
  assert.ok(copy > 0 && flag > 0 && copy < flag, 'the wipe is scheduled before the copy exists');
  assert.match(body.slice(copy, flag), /return \{ ok: false, error: 'safety-backup-failed'/,
    'a failed copy still falls through to scheduling the wipe');
});

test('the copy is written without overwriting, and read back before it counts', () => {
  const body = bodyOf('function writePreWipeBackup()', 1200);
  assert.match(body, /recoverStoreRaw\(/, 'not read the way a launch reads the book');
  assert.match(body, /encryptForDisk\(rec\.data\)/, 'not in the format Settings → Backups restores');
  assert.match(body, /flag: 'wx'/);
  assert.match(body, /readFileSync\(fullPath/, 'never read back');
});

test('the wipe leaves the safety copy and nothing else in backups', () => {
  const body = bodyOf('function completePendingFullWipe()', 1400);
  assert.match(body, /entry === 'backups'/);
  assert.match(body, /startsWith\(upgradeBackup\.WIPE_PREFIX\)/);
});

test('"last backup" is the newest DAILY, never an insurance copy', () => {
  const body = bodyOf("ipcMain.handle('hub:last-backup-date'", 900);
  assert.ok(body.includes(String.raw`/^\d{4}-\d{2}-\d{2}\.json$/.test(f)`), 'insurance copies still count as the last backup');
});
