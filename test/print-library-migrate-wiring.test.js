/**
 * The move, as wired into the app.
 *
 * lib/print-library-migrate.js is where the decisions are tested. What can only
 * go wrong here is the plumbing around them, and three of those failures are
 * quiet enough to ship:
 *
 *   1. The run trusting a plan the renderer sends it. The scan is a preview; a
 *      list gathered minutes ago moves files the shop has since deleted and
 *      misses the ones they added.
 *   2. Two runs at once. Each sees the other's half-finished copies, and
 *      "the destination already exists" is the branch that ends in a deletion.
 *   3. Nobody being told there is anything to move. The shop that needs this
 *      most is the one looking at a library that just went empty — and they have
 *      no reason to suspect the files are elsewhere rather than gone.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const mainJs = read('main.js');
const preload = read('preload.js');
const settingsJs = read('renderer/settings.js');
const wire = read('renderer/wire-events.js');
const html = read('renderer/index.html');

const handler = (name) => {
  const at = mainJs.indexOf(`ipcMain.handle('hub:${name}'`);
  assert.ok(at > -1, `hub:${name} went missing`);
  const next = mainJs.indexOf('\nipcMain.handle(', at + 10);
  return mainJs.slice(at, next > -1 ? next : at + 4000);
};

test('the run gathers its own list rather than trusting one it was handed', () => {
  const body = handler('printlib-migrate-run');
  assert.match(body, /printLibStrandedFiles\(\)/, 'the run does not re-scan');
  assert.doesNotMatch(body, /async \(event, ?\{/, 'the run accepts a plan from the renderer');
  assert.match(preload, /printLibMigrateRun: \(\) *=> ipcRenderer\.invoke\('hub:printlib-migrate-run'\)/,
    'the renderer can pass something into the run');
});

test('two moves cannot run at once', () => {
  assert.match(mainJs, /let printLibMigrating = false;/);
  const body = handler('printlib-migrate-run');
  assert.match(body, /if \(printLibMigrating\) return/, 'a second run is not turned away');
  assert.match(body, /printLibMigrating = true;/);
  assert.match(body, /finally \{[\s\S]{0,80}printLibMigrating = false;/,
    'a run that throws leaves the flag set and the button dead until restart');
});

test('the move refuses when the library cannot be written to', () => {
  // Same rule as every other write: refuse by name rather than half-move into a
  // folder that is not there.
  const body = handler('printlib-migrate-run');
  const guard = body.indexOf('requirePrintLib()');
  const firstMove = body.indexOf('PLM.moveOne');
  assert.ok(guard > -1, 'the move is not guarded at all');
  assert.ok(guard < firstMove, 'files are moved before the destination is checked');
});

test('room is checked before the first copy, not discovered at file 400', () => {
  const body = handler('printlib-migrate-run');
  const check = body.indexOf('enoughSpace');
  assert.ok(check > -1 && check < body.indexOf('PLM.moveOne'), 'the space check comes after the copying starts');
  assert.match(body, /if \(!space\.ok\)[\s\S]{0,160}return \{ ok: false/, 'a move that will not fit is attempted anyway');
});

test('the backup folder is passed in as something to leave alone', () => {
  // sources() can only protect the mirror if it is told what the mirror is.
  assert.match(mainJs, /PLM\.sources\(roots, primary, mirror\)/,
    'the mirror is not excluded, so the migration would empty the backup');
});

test('the source is removed by the tested path, not by a second copy of the logic', () => {
  // Every unlink in the move belongs to moveOne, which is the function the
  // truncated-copy tests actually exercise.
  const body = handler('printlib-migrate-run');
  assert.doesNotMatch(body, /unlink\(src\)/, 'the handler deletes sources itself, outside the tested path');
  assert.match(body, /PLM\.moveOne\(printLibMoveIO/);
});

test('only empty folders are tidied up, and never a root', () => {
  const body = handler('printlib-migrate-run');
  assert.match(body, /rmdir\(/, 'the emptied item folders are left behind');
  assert.doesNotMatch(body, /rm\([^)]*recursive: true/, 'a recursive delete in the move would take real files with it');
  assert.match(body, /\.filter\(\(d\) => d && d !== '\.'\)/, 'the root itself is a candidate for removal');
});

test('the walk does not follow symlinks or count folders as files', () => {
  const at = mainJs.indexOf('async function printLibWalk(');
  const body = mainJs.slice(at, mainJs.indexOf('\n}', at));
  assert.match(body, /e\.isFile\(\)/, 'a symlink would be moved, breaking whatever it pointed at');
  assert.match(body, /withFileTypes: true/);
});

test('an unreachable old folder scans as empty rather than throwing', () => {
  // The old location is very often the one that is gone — that is why the
  // library moved. A scan that throws makes the settings page unusable.
  const at = mainJs.indexOf('async function printLibWalk(');
  const body = mainJs.slice(at, mainJs.indexOf('\n}', at));
  assert.match(body, /catch \(_\) \{ return out; \}/, 'a missing source folder takes the whole scan down');
});

test('the shop is told without having to go looking', () => {
  // renderPrintLibLocation runs whenever the settings page is drawn.
  const at = settingsJs.indexOf('async function renderPrintLibLocation(');
  const body = settingsJs.slice(at, settingsJs.indexOf('\n}', at));
  assert.match(body, /scanPrintLibMigrate\(\)/, 'the offer only appears if someone presses something first');
  assert.match(settingsJs, /if \(!r \|\| !r\.ok \|\| !r\.files\) \{[\s\S]{0,60}display = 'none'/,
    'the box shows even when there is nothing to move');
});

test('the outcome reports what did not move, not just what did', () => {
  // "412 files moved" with three failures folded into it is the kind of success
  // message that gets believed.
  const at = settingsJs.indexOf('async function runPrintLibMigrate(');
  const body = settingsJs.slice(at, settingsJs.indexOf('\n}\n', at));
  for (const k of ['r.duplicates', 'r.collisions', 'r.failed']) {
    assert.ok(body.includes(k), `${k} is never shown`);
  }
  assert.match(body, /r\.failed \? '⚠ ' : '✓ '/, 'a partial failure is reported as a success');
});

test('a root change records the folder being left', () => {
  // Both ways out of a custom folder: choosing another, and going back to this
  // Mac. Missing either one orphans the files it left behind.
  assert.match(mainJs, /ipcMain\.handle\('hub:printlib-remember-root'/);
  assert.match(mainJs, /PLM\.rememberRoot\(printLibSettings\(\), String\(nextRoot \|\| ''\), printLibDefaultRoot\(\)\)/);
  assert.match(settingsJs, /async function printLibRootPatch\(which, next\)/);
  assert.match(settingsJs, /if \(which !== 'root' \|\| !window\.hubAPI\?\.printLibRememberRoot\) return patch;/,
    'the backup folder is being recorded as a past library location');
  for (const fn of ['pickPrintLibFolder', 'clearPrintLibFolder']) {
    const at = settingsJs.indexOf(`async function ${fn}(`);
    assert.ok(at > -1, `${fn} is not async, so it cannot await the history`);
    assert.match(settingsJs.slice(at, settingsJs.indexOf('\n}', at)), /await printLibRootPatch\(which,/,
      `${fn} changes the root without recording the old one`);
  }
});

test('the button is wired to a function the other IIFE can see', () => {
  assert.match(html, /id="btnPlibMove"/, 'the button is not in the markup');
  assert.match(html, /id="plibMoveBox"[^>]*display:none/, 'the box is shown before anything has been scanned');
  assert.match(wire, /#btnPlibMove'\)\?\.addEventListener/, 'a dead button');
  const api = settingsJs.slice(settingsJs.indexOf('const api = {'), settingsJs.indexOf('const api = {') + 700);
  for (const fn of ['scanPrintLibMigrate', 'runPrintLibMigrate']) {
    assert.match(settingsJs, new RegExp(`function ${fn}\\(`), `${fn} is not defined`);
    assert.match(api, new RegExp(`\\b${fn},`), `${fn} is not exported — its button does nothing`);
  }
  assert.match(preload, /printLibMigrateScan:/);
  assert.match(preload, /onPrintLibMigrateProgress:/, 'a long move gives no sign it is still working');
});

test('the section is translated everywhere', () => {
  const keys = ['set.plib_move_title', 'set.plib_move_hint', 'set.plib_move_do', 'set.plib_move_what',
    'set.plib_move_done', 'set.plib_move_failed', 'set.plib_move_space'];
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = read(`renderer/locales/${code}.js`);
    for (const k of keys) assert.ok(loc.includes(`"${k}":`), `${code} is missing ${k}`);
  }
  // The counts are interpolated, so a translation that drops the placeholder
  // renders "{n} moved" verbatim.
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = read(`renderer/locales/${code}.js`);
    const line = loc.split('\n').find((l) => l.includes('"set.plib_move_what"'));
    for (const ph of ['{n}', '{size}', '{from}', '{to}']) {
      assert.ok(line.includes(ph), `${code}'s set.plib_move_what dropped ${ph}`);
    }
  }
});
