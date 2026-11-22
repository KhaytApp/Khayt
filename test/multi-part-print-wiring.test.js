'use strict';
/**
 * A print made of several files, as wired in.
 *
 * lib/print-file-parts.js has been right and unreachable since it was written:
 * `partsOf` was read for the size chip and nothing else, so a Spiderman was
 * still twelve entries and there was no way to make it one. That is this
 * codebase's signature failure — a module that is correct, tested, and plugged
 * into nothing — and this file exists to make it impossible here.
 *
 * What it pins is the plumbing, not the arithmetic:
 *
 *   1. Every one of the module's verbs is REACHED from the renderer. A verb no
 *      caller uses is a feature nobody can get to.
 *   2. Opening a multi-part print opens ALL of it. Four `spawn`s would be four
 *      slicer windows each holding one limb; the whole print goes as ONE command
 *      with several arguments, and the old single-path shape still works for
 *      the callers that mean exactly one file.
 *   3. No part launches without being confined and rehydrated FIRST. A slicer
 *      that came up holding three quarters of a print, with the fourth silently
 *      dropped, is how you print a Spiderman with one arm.
 *   4. The archive question is asked, and closing it imports nothing rather
 *      than picking an answer.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const mainJs = read('main.js');
const preload = read('preload.js');
const pf = read('renderer/printfiles.js');
const shell = read('renderer/shell.js');
const css = read('renderer/styles.css');
const html = read('renderer/index.html');

const P = require('../lib/print-file-parts.js');

test('the module is loaded by the app, not only by its tests', () => {
  assert.match(html, /lib\/print-file-parts\.js/, 'nothing loads the parts module');
});

test('every verb the module exports is reached from the library screen', () => {
  // The whole failure this file guards against: `partsOf` was called for the
  // size chip and the other six sat there correct and unreachable.
  for (const verb of ['partsOf', 'primaryOf', 'addParts', 'removePart', 'makePrimary']) {
    assert.ok(typeof P[verb] === 'function', `lib/print-file-parts.js lost ${verb}`);
    assert.ok(pf.includes(`.${verb}(`),
      `${verb}() is exported, tested and called by nothing — the shop cannot get to it`);
  }
});

test('a multi-part print shows its parts, and each part can be acted on', () => {
  assert.match(pf, /function partsListHtml\(rec\)/, 'the card never lists the files a print is made of');
  // Rendered onto the card, not merely defined. A function nothing calls is the
  // same bug one level down.
  assert.match(pf, /\$\{partsListHtml\(rec\)\}/, 'partsListHtml is defined and never rendered');
  for (const act of ['pf-part-open', 'pf-part-primary', 'pf-part-del', 'pf-add-parts']) {
    assert.ok(pf.includes(`data-act="${act}"`), `no control emits ${act}`);
    assert.ok(new RegExp(`case '${act}':`).test(pf), `${act} is emitted by a button and handled by nobody`);
  }
});

test('changing which file is the main one drops what the old one said', () => {
  // The record's print time, weight, colours and picture were read off the OLD
  // primary and describe that file alone. Left as they were, the card quietly
  // reports one part's figures under another part's name.
  //
  // And re-reading is NOT enough on its own: enrichPrintFile's STL branch merges
  // only triangleCount/volumeMm3/bbox onto whatever `parsed` already held and
  // never touches `colors`, so promoting a plain STL inside a five-colour print
  // left the dots, the swap count and the slicer time standing.
  //
  // Sliced to the NEXT function rather than a fixed number of characters: this
  // read `slice(at, at + 900)` and a comment explaining the fix pushed the line
  // it was looking for outside the window. Same trap, third time in this repo.
  const at = pf.indexOf('async function makePartPrimary(');
  assert.ok(at > -1, 'makePartPrimary went missing');
  const rest = pf.slice(at + 10);
  const next = rest.search(/\n {2}(?:async )?function [A-Za-z_$]/);
  const body = pf.slice(at, next === -1 ? pf.length : at + 10 + next);
  assert.ok(body.includes('makePrimary('), 'makePartPrimary does not reorder the parts');
  assert.ok(body.includes('enrichPrintFile('),
    'the new main file is never re-read — the card keeps the old part\'s numbers');
  for (const [field, what] of [['rec.parsed = {}', 'the time and weight'],
                               ['rec.colors = []', 'the colours'],
                               ['rec.swapCount = 0', 'the swap count']]) {
    assert.ok(body.includes(field),
      `${what} of the OLD main file survives — enrich does not overwrite it`);
  }
  // The re-read has to come AFTER the clear, or it clears what it just read.
  assert.ok(body.indexOf('rec.parsed = {}') < body.indexOf('enrichPrintFile('),
    'the record is cleared after it is re-read, which throws the new figures away');
});

test('every path that changes a print\'s parts writes the version back', () => {
  // The record MIRRORS its active version, so rec.files changing IS that version
  // changing. Without writing it back, the next press of a version chip restored
  // the frozen snapshot: parts added since disappeared, and a part removed AND
  // deleted from disk came back as a row that opens nothing.
  assert.match(pf, /function partsChanged\(rec\)/, 'there is no single place that persists a parts change');
  const at = pf.indexOf('function partsChanged(rec)');
  const body = pf.slice(at, at + 400);
  assert.ok(body.includes('syncActive('), 'partsChanged does not write the version back');
  assert.ok(body.includes('saveAll()'), 'partsChanged does not persist');
  const V = require('../lib/print-versions.js');
  assert.equal(typeof V.syncActive, 'function', 'lib/print-versions.js lost syncActive');
  // Every mutation goes through it — a fourth one added later must too.
  for (const fn of ['addPartsToPrint', 'makePartPrimary', 'removePartFromPrint']) {
    const f = pf.indexOf(fn === 'addPartsToPrint' ? 'async function addPartsToPrint(' : `function ${fn}(`);
    assert.ok(f > -1, `${fn} went missing`);
    const rest2 = pf.slice(f + 10);
    const nx = rest2.search(/\n {2}(?:async )?function [A-Za-z_$]/);
    const b = pf.slice(f, nx === -1 ? pf.length : f + 10 + nx);
    assert.ok(b.includes('partsChanged('), `${fn} changes the parts and never persists the version`);
  }
});

test('opening a print opens all of it, in one slicer', () => {
  assert.match(pf, /async function resolvePartPaths\(rec\)/, 'there is no way to resolve a print\'s parts to paths');
  assert.match(pf, /printLibOpenSlicerAll/, 'the renderer never asks for the multi-file open');
  assert.match(preload, /printLibOpenSlicerAll: \(filePaths, slicerPath\)/, 'the bridge for a whole print is missing');
  // ONE command with several arguments. Four spawns would be four windows.
  const at = mainJs.indexOf("ipcMain.handle('hub:printlib-open-in-slicer'");
  assert.ok(at > -1);
  const body = mainJs.slice(at, mainJs.indexOf('\nipcMain.handle(', at + 10));
  assert.match(body, /spawn\(slicerPath, safes\b/, 'the parts are not handed to one slicer invocation');
  assert.equal((body.match(/spawn\(/g) || []).length, 1, 'more than one spawn — that is a window per part');
  // The single-path shape still works: every existing caller sends it.
  assert.match(body, /Array\.isArray\(filePaths\).*\? filePaths : \[filePath\]/s,
    'the old single-file callers no longer work');
});

test('no part launches before every part has been checked', () => {
  // Confinement and rehydration happen for ALL of them, then the slicer starts.
  // Interleaved, a part that is missing or still in the bucket would be found
  // only after the slicer had already opened with the rest.
  const at = mainJs.indexOf("ipcMain.handle('hub:printlib-open-in-slicer'");
  const body = mainJs.slice(at, mainJs.indexOf('\nipcMain.handle(', at + 10));
  const lastCheck = Math.max(body.lastIndexOf('printLibContains(safe)'), body.lastIndexOf('printLibRehydrate(safe)'));
  assert.ok(lastCheck > -1 && lastCheck < body.indexOf('spawn('),
    'a part is launched before the others have been confined and fetched back');
});

test('an archive is asked about, and closing the question imports nothing', () => {
  assert.match(pf, /function askZipShape\(/, 'an archive is still assumed to be one thing or the other');
  const at = pf.indexOf('function askZipShape(');
  const body = pf.slice(at, at + 2600);
  // Closing the dialog resolves null, and null must not fall through to a default.
  assert.ok(body.includes('onClose() { resolve(choice); }'),
    'closing the question never resolves — the import hangs for ever');
  assert.match(pf, /if \(!zipShape\) \{[^}]*continue;/,
    'closing the question without answering still imports the archive somehow');
  // Asked once per drop, not once per archive.
  assert.match(pf, /zipShape = await askZipShape\(/);
  assert.match(pf, /z\.files\.length > 1 && zipShape == null/,
    'the question is asked again for every archive in the same drop');
});

test('an archive imported as one print is named after the archive', () => {
  // Not after whichever of its twelve files happened to be extracted first.
  assert.match(pf, /replace\(\/\\\.zip\$\/i, ''\)/, 'the pack name is not derived from the archive');
  // Not keyed on the function's NAME — that broke when the call was wrapped to
  // stop one bad file aborting a whole drop. What matters is the shape passed:
  // the archive's name, and every other member as a part of the same record.
  assert.match(pf, /ingest\w*\(zid, copied\[0\], \{ name: packName, parts: copied\.slice\(1\)/,
    'the record is built from the first file alone — the rest are not parts of it');
});

test('openFormModal tells its caller when it closes', () => {
  // askZipShape needs it: without a single place that runs on the way out,
  // "they closed it without answering" is invisible to the caller.
  assert.match(shell, /function openFormModal\(\{[^}]*onClose/, 'openFormModal has no close hook');
  const at = shell.indexOf('const close = () => {');
  const body = shell.slice(at, at + 500);
  assert.ok(body.includes('onClose()'), 'the close hook is accepted and never called');
});

test('the parts list and the archive question are styled', () => {
  for (const cls of ['.pf-parts', '.pf-part-list', '.pf-part-name', '.pf-zip-choices', '.pf-zip-pick']) {
    assert.ok(css.includes(cls), `${cls} is rendered with no styles`);
  }
  // The main file is marked; a list where they all look alike says nothing.
  assert.match(css, /\.pf-part\.is-primary/, 'nothing marks which part the card speaks for');
});

test('every string this adds is translated everywhere', () => {
  const keys = ['plib.part_primary', 'plib.make_primary', 'plib.remove_part', 'plib.remove_part_confirm',
    'plib.add_parts', 'plib.parts_added', 'plib.opened_slicer_n', 'plib.zip_shape_title',
    'plib.zip_shape_q', 'plib.zip_one', 'plib.zip_many', 'plib.zip_shape_all'];
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = read(`renderer/locales/${code}.js`);
    for (const k of keys) assert.ok(loc.includes(`"${k}":`), `${code} is missing ${k}`);
  }
});
