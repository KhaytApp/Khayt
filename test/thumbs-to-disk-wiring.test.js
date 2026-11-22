'use strict';
/**
 * Moving a shop's pictures without being able to lose one.
 *
 * The picture is 94% of a print-file record — 914 bytes without, 14,900 with —
 * and the store is one encrypted JSON document capped at 50 MB. At 5,000 files
 * the thumbnails alone are 71 MB, past which every save is refused and a shop
 * loses its day at the next launch. So this is a data-safety change, and what
 * is pinned here is the property that makes it safe rather than the feature.
 *
 * THE RULE: the copy in the store is dropped only after the copy on disk has
 * been read back and compared. Every test below is a way that could quietly
 * stop being true — the verification moving out of the write, a fallback that
 * discards instead of keeping, a migration that deletes what it could not
 * write.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const main = read('main.js');
const pf = read('renderer/printfiles.js');

/** The body of one ipcMain handler, by channel. */
function handler(channel) {
  const at = main.indexOf(`ipcMain.handle('${channel}'`);
  assert.ok(at > -1, `${channel} is gone`);
  return main.slice(at, main.indexOf("\nipcMain.handle(", at + 10));
}

test('the write and the read-back are one call, in main', () => {
  // A verification the renderer had to ask for separately is one a reload can
  // land in the middle of — leaving a record that has dropped its store copy
  // and never learned whether the disk copy is there.
  const h = handler('hub:printlib-save-thumb');
  assert.match(h, /await fs\.promises\.writeFile/);
  assert.match(h, /await fs\.promises\.readFile\(dest\)/, 'nothing reads the file back');
  assert.match(h, /back\.equals\(bytes\)/, 'the read-back is not compared to what went in');
  assert.match(h, /verified/, 'the caller is not told whether it landed');
  assert.doesNotMatch(h, /unlink|rm\(|rmSync/, 'the writer must never delete anything');
});

test('nothing drops the store copy without proof', () => {
  // Both places that can clear `rec.thumb` must be guarded by a verified write.
  const set = pf.slice(pf.indexOf('async function setThumb'), pf.indexOf('async function enrichPrintFile'));
  assert.match(set, /res\.ok && res\.verified && res\.filename/, 'setThumb clears on something weaker than proof');
  assert.match(set, /delete rec\.thumb/);
  assert.match(set, /rec\.thumb = dataUrl;/, 'an unverified write must keep the picture in the store');

  const mig = pf.slice(pf.indexOf('async function migrateThumbsToDisk'), pf.indexOf('const pub = {'));
  assert.match(mig, /if \(!patch\.migrated\) continue;/, 'the migration proceeds past a failed move');
  assert.match(mig, /completeMigration/, 'the migration does not go through the guarded helper');
  // The delete must come after the guard, not before it.
  assert.ok(mig.indexOf('if (!patch.migrated) continue;') < mig.indexOf('delete rec.thumb'),
    'the store copy is dropped before the failure check');
});

test('pictures are fetched by record id, not by a stored path', () => {
  // The library can be MOVED (lib/print-library-location.js). A full path in a
  // record would rot the moment somebody pointed the vault at another disk.
  const h = handler('hub:printlib-load-thumbs');
  assert.match(h, /printLibItemDir\(id\)/, 'the folder is not resolved from the id in main');
  assert.match(h, /printLibContains/, 'the resolved path is not confined to the library');
  assert.doesNotMatch(pf, /thumbPath/, 'a record is storing a full path again');
});

test('a grid of cards costs one call, not one per card', () => {
  assert.match(pf, /printLibLoadThumbs\(wanted\)/);
  const warm = pf.slice(pf.indexOf('async function warmThumbs'), pf.indexOf('function thumbHtml'));
  assert.match(warm, /\.filter\(/, 'every row is fetched, including the ones already in hand');
  assert.match(warm, /!_thumbCache\.has\(r\.id\)/, 'a cached picture is fetched again');
});

test('the cache is bounded — holding them all is what we are escaping', () => {
  assert.match(pf, /THUMB_CACHE_MAX/);
  const cache = pf.slice(pf.indexOf('function cacheThumb'), pf.indexOf('async function warmThumbs'));
  assert.match(cache, /while \(_thumbCache\.size > THUMB_CACHE_MAX\)/,
    'the cache grows without limit, which is the store problem moved into memory');
});

test('the migration is paced, not a single pass', () => {
  const mig = pf.slice(pf.indexOf('async function migrateThumbsToDisk'), pf.indexOf('const pub = {'));
  assert.match(mig, /plan\.slice\(0, \d+\)/, 'the whole library is migrated in one go');
  assert.match(mig, /setTimeout/, 'nothing yields to the window between records');
  assert.match(mig, /_migrating/, 'two runs can overlap');
});
