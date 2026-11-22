/**
 * The library can live elsewhere, and every path that touches it must agree.
 *
 * Three things go wrong quietly here, so each is pinned:
 *
 *   1. A confinement check written against ONE root. Every handler confines
 *      paths to the library; if that means "under the current root" then moving
 *      the library makes yesterday's files unreadable rather than merely
 *      relocated.
 *   2. A read that throws. Writes must refuse loudly when the share is away, but
 *      a READ that throws turns "no files here" into an unhandled rejection in
 *      every caller that only wanted to know whether a record has a file —
 *      resolveModelPath() does not catch.
 *   3. A button with no listener, or a function the other IIFE cannot see.
 *      settings.js only exposes what is in its `api` object, and wire-events.js
 *      guards with typeof — so an unexported function is a control that renders
 *      and silently does nothing. This codebase has shipped that before.
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

test('no confinement check is written against a single root any more', () => {
  // The shape that breaks on a move: resolve one root, compare a prefix.
  assert.doesNotMatch(mainJs, /startsWith\(root \+ path\.sep\)/,
    'a handler still confines to one root — moving the library would orphan older files');
  // Stronger than counting: every handler that accepts a path FROM THE CALLER
  // must confine it. One added later without a check is the hole this closes.
  // Sliced between handler declarations rather than brace-matched — handler
  // bodies contain nested closures, and a lazy regex stops at the first of them.
  const marks = [...mainJs.matchAll(/ipcMain\.handle\('(hub:printlib-[a-z-]+)'/g)];
  const bodies = marks.map((m, i) => ({
    name: m[1],
    body: mainJs.slice(m.index, i + 1 < marks.length ? marks[i + 1].index : m.index + 4000),
  }));
  // Keyed on what the handler ACCEPTS, not on how it happens to normalise it.
  // This read `path.resolve(String(fullPath|filePath` — the exact spelling of
  // one line inside the body — so a handler that took a caller's path and then
  // resolved it any other way (a list resolved in a loop, say) stopped being
  // seen as one that takes a path at all, and its confinement stopped being
  // checked. The signature is the thing that cannot be rewritten without
  // changing what the handler is.
  const takesAPath = bodies.filter((h) => /\b(?:filePaths?|fullPath)\b/.test(h.body.slice(0, h.body.indexOf('=> {') + 4)));
  assert.ok(takesAPath.length >= 5,
    `expected the handlers that take a caller path, found ${takesAPath.length}: ${bodies.map((b) => b.name).join(', ')}`);
  for (const h of takesAPath) {
    assert.match(h.body, /printLibContains\(safe\)/, `${h.name} does not confine its path to the library`);
  }
});

test('reads do not go through the guard that throws', () => {
  // printLibItemDir is on the read path (hub:printlib-list calls it first).
  assert.match(mainJs, /const printLibItemDir = \(id\) => path\.join\(printLibRoots\(\)\.primary/,
    'printLibItemDir throws, so listing a record fails instead of finding nothing');
  assert.match(mainJs, /const printLibDir = \(\) => printLibRoots\(\)\.primary;/);
});

test('every write refuses by name before it writes', () => {
  const guards = (mainJs.match(/requirePrintLib\(\);/g) || []).length;
  assert.ok(guards >= 3, `expected the copy/pick/save-image writes to be guarded, found ${guards}`);
  assert.match(mainJs, /function requirePrintLib\(\) \{[\s\S]*?throw new Error\(st\.error/,
    'the guard does not carry the message naming the folder');
});

test('a folder the shop chose is never created for them', () => {
  // Creating it would hide a mistyped path or an unmounted share behind an
  // empty library that looks like it is working.
  assert.match(mainJs, /if \(!isCustom\) \{ printLibDefaultRoot\(\); return \{ ok: true/,
    'a custom root is auto-created, so a wrong path looks fine and stays empty');
});

test('the mirror is written after the primary, and never read from', () => {
  assert.match(mainJs, /async function printLibMirrorFile\(/);
  // It must not appear in any confinement or resolution used for reading.
  const mirrorReads = mainJs.match(/readFile\([^)]*mirror/gi) || [];
  assert.deepEqual(mirrorReads, [], 'something reads from the backup — that makes it a second primary');
  assert.match(mainJs, /printLibMirrorFile\(id, filename, destPath\)/, 'copies are never mirrored');
});

test('a failing mirror cannot fail the save, and says it failed', () => {
  // The function now serves two backup targets — a folder and a bucket — and
  // reports each separately ({folder, s3}). Both must be caught, and both must
  // be REPORTED: a backup that fails silently is worse than none, because the
  // shop believes it has one.
  const fnStart = mainJs.indexOf('async function printLibMirrorFile(');
  // Bounded by whatever comes next, so unrelated catch blocks in a later
  // handler cannot stand in for the ones this function is supposed to have.
  const ends = [mainJs.indexOf('\nasync function ', fnStart + 10), mainJs.indexOf('\nipcMain.handle(', fnStart + 10)]
    .filter((i) => i > -1);
  const body = mainJs.slice(fnStart, Math.min(...ends));
  const caught = (body.match(/catch \(e\) \{/g) || []).length;
  assert.ok(caught >= 2, `each backup target must swallow its own failure, found ${caught}`);
  assert.match(body, /out\.folder = false;/, 'a folder copy that failed is not reported');
  assert.match(body, /out\.s3 = false;/, 'an upload that failed is not reported');
});

test('the status handler exists and reports the folder', () => {
  assert.match(mainJs, /ipcMain\.handle\('hub:printlib-status'/);
  assert.match(preload, /printLibStatus:\s+\(\)\s+=> ipcRenderer\.invoke\('hub:printlib-status'\)/,
    'the renderer cannot ask, so it can never explain an empty library');
  assert.match(preload, /printLibPickFolder:\s+\(\)\s+=> ipcRenderer\.invoke\('hub:printlib-pick-folder'\)/);
});

test('the location is chosen with a picker, never typed', () => {
  // A typed path is one that can silently not exist, and this setting decides
  // where the shop's most expensive asset is written.
  assert.match(html, /id="set_plibRoot"[^>]*readonly/, 'the library path is a free-text field');
  assert.match(html, /id="set_plibMirror"[^>]*readonly/, 'the backup path is a free-text field');
});

test('every button in the section is wired to something that exists', () => {
  for (const [id, fnName] of [
    ['btnPlibRoot', 'pickPrintLibFolder'],
    ['btnPlibMirror', 'pickPrintLibFolder'],
    ['btnPlibRootClear', 'clearPrintLibFolder'],
    ['btnPlibMirrorClear', 'clearPrintLibFolder'],
  ]) {
    assert.match(html, new RegExp(`id="${id}"`), `${id} is not in the markup`);
    assert.match(wire, new RegExp(`#${id}'\\)\\?\\.addEventListener`), `${id} has no listener — a dead button`);
    assert.match(wire, new RegExp(`${fnName}\\(`), `${id}'s listener calls nothing`);
  }
});

test('the settings functions are exported, or the other IIFE cannot see them', () => {
  // wire-events.js guards with `typeof === 'function'`, so an unexported
  // function is not an error — it is a button that does nothing at all.
  const api = settingsJs.slice(settingsJs.indexOf('const api = {'), settingsJs.indexOf('const api = {') + 600);
  for (const f of ['renderPrintLibLocation', 'pickPrintLibFolder', 'clearPrintLibFolder']) {
    assert.match(settingsJs, new RegExp(`function ${f}\\(`), `${f} is not defined`);
    assert.match(api, new RegExp(`\\b${f},`), `${f} is defined but not exported — its button is dead`);
  }
});

test('the section is translated everywhere, not just in English', () => {
  const keys = ['set.plib_loc_section', 'set.plib_loc_hint', 'set.plib_ready', 'set.plib_saved',
    'set.plib_mirror_missing', 'set.plib_this_mac'];
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = read(`renderer/locales/${code}.js`);
    for (const k of keys) {
      assert.ok(loc.includes(`"${k}":`), `${code} is missing ${k}`);
    }
  }
});
