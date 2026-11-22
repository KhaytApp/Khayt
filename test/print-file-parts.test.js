'use strict';
/**
 * One print, several files — and every reader written before that existed still
 * working.
 *
 * Spiderman is a head, two arms and a torso and it is ONE thing you print. The
 * library modelled a record as exactly one file, so a kit downloaded as ten
 * STLs became ten unrelated entries.
 *
 * The risk in fixing that is not the new behaviour, it is the old: `sourceFile`
 * is read in twenty places — the icon, the size chip, which actions a card
 * offers, which file "Open in slicer" resolves — and every record already on
 * every shop's disk has no `files` array at all. So most of what is pinned here
 * is that a record from before this change reads exactly as it always did, and
 * that `sourceFile` never stops being the primary.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/print-file-parts.js');

const f = (name, size = 100, ext = 'stl') =>
  ({ filename: name, originalName: name, size, ext, kind: 'model' });

test('a record from before this change reads exactly as it always did', () => {
  const old = { id: 'PF1', sourceFile: f('head.stl') };
  assert.deepEqual(P.partsOf(old), [f('head.stl')]);
  assert.deepEqual(P.primaryOf(old), f('head.stl'));
  assert.equal(P.isMultiPart(old), false);
  assert.equal(P.totalSize(old), 100);
});

test('a record with no file at all is a legitimate state, not a crash', () => {
  // The library also holds entries made from a printer's own history, where
  // there is nothing on disk to point at.
  for (const rec of [null, undefined, {}, { sourceFile: null }, { files: [] }]) {
    assert.deepEqual(P.partsOf(rec), [], JSON.stringify(rec));
    assert.equal(P.primaryOf(rec), null);
    assert.equal(P.isMultiPart(rec), false);
    assert.equal(P.totalSize(rec), 0);
  }
});

test('adding files keeps sourceFile pointing at the primary', () => {
  // The safety property of the whole design: twenty existing readers go on
  // reading `sourceFile` and none of them has to know `files` exists.
  const rec = { sourceFile: f('head.stl') };
  const patch = P.addParts(rec, [f('left-arm.stl', 200), f('right-arm.stl', 300)]);
  assert.equal(patch.files.length, 3);
  assert.deepEqual(patch.sourceFile, f('head.stl'), 'the primary must not move when parts are added');
  Object.assign(rec, patch);
  assert.equal(P.isMultiPart(rec), true);
  assert.equal(P.totalSize(rec), 600, 'the size chip should speak for the whole print');
});

test('a print can be built from nothing, one file at a time', () => {
  const rec = {};
  Object.assign(rec, P.addParts(rec, f('head.stl')));
  assert.deepEqual(rec.sourceFile, f('head.stl'), 'the first file added becomes the primary');
  Object.assign(rec, P.addParts(rec, f('torso.stl')));
  assert.equal(P.partsOf(rec).length, 2);
});

test('the same file is not added twice', () => {
  // The import path can be re-run over an archive, and a second copy of one
  // part is indistinguishable on the card from a real second part.
  const rec = { sourceFile: f('head.stl') };
  Object.assign(rec, P.addParts(rec, [f('head.stl'), f('torso.stl')]));
  assert.deepEqual(P.partsOf(rec).map((x) => x.filename), ['head.stl', 'torso.stl']);
});

test('things that are not files are refused rather than stored', () => {
  const rec = { sourceFile: f('head.stl') };
  Object.assign(rec, P.addParts(rec, [null, {}, { size: 3 }, 'torso.stl']));
  assert.deepEqual(P.partsOf(rec).map((x) => x.filename), ['head.stl'],
    'a descriptor with no filename cannot be resolved on disk and must not join the print');
});

test('removing the primary promotes the next one', () => {
  // Otherwise every sourceFile reader is left pointing at a file that is gone.
  const rec = { files: [f('head.stl'), f('torso.stl'), f('arm.stl')] };
  Object.assign(rec, P.removePart(rec, 'head.stl'));
  assert.deepEqual(rec.sourceFile, f('torso.stl'));
  assert.equal(P.partsOf(rec).length, 2);
});

test('removing the last file leaves a record with no file, not a broken one', () => {
  const rec = { sourceFile: f('head.stl') };
  Object.assign(rec, P.removePart(rec, 'head.stl'));
  assert.equal(rec.sourceFile, null);
  assert.deepEqual(P.partsOf(rec), []);
});

test('removing something that is not there changes nothing', () => {
  const rec = { files: [f('head.stl'), f('torso.stl')] };
  const before = JSON.stringify(P.partsOf(rec));
  Object.assign(rec, P.removePart(rec, 'nope.stl'));
  assert.equal(JSON.stringify(P.partsOf(rec)), before);
});

test('the shop chooses which file the card speaks for', () => {
  // On a multi-part print "which file is this card about" is a choice, not a
  // fact: the thumbnail, the icon and Open-in-slicer all follow it.
  const rec = { files: [f('head.stl'), f('torso.3mf', 100, '3mf'), f('arm.stl')] };
  Object.assign(rec, P.makePrimary(rec, 'torso.3mf'));
  assert.equal(rec.sourceFile.filename, 'torso.3mf');
  assert.deepEqual(P.partsOf(rec).map((x) => x.filename), ['torso.3mf', 'head.stl', 'arm.stl'],
    'the others keep their order behind the new primary');
});

test('promoting the file that is already primary is a no-op, not a reshuffle', () => {
  const rec = { files: [f('head.stl'), f('torso.stl')] };
  Object.assign(rec, P.makePrimary(rec, 'head.stl'));
  assert.deepEqual(P.partsOf(rec).map((x) => x.filename), ['head.stl', 'torso.stl']);
});

test('a sourceFile that is not in the list is added rather than ignored', () => {
  /* This asserted that `files` simply wins — "the list is the truth". It is the
   * truth about which PARTS a print has, and it is not the truth about which
   * file somebody last pointed at: the older build's Identify writes
   * `sourceFile` alone, and dropping it lost the file the shop had just chosen.
   *
   * Both are kept, primary first, so neither writer's work is discarded. */
  const rec = { files: [f('torso.stl')], sourceFile: f('picked.stl') };
  assert.deepEqual(P.primaryOf(rec), f('picked.stl'));
  assert.deepEqual(P.partsOf(rec).map((x) => x.filename), ['picked.stl', 'torso.stl']);
});

test('a writer that only knows sourceFile does not lose the other parts', () => {
  /* The older build's "Identify" sets `rec.sourceFile` when a record has no file
   * on this computer, and never touches `files`. Sync carries such a record
   * between machines intact and self-contradicting.
   *
   * Preferring `files` dropped the file the shop had just chosen; preferring
   * `sourceFile` would drop every other part of a multi-part print. */
  const f = (n) => ({ filename: n, originalName: n, size: 1, ext: 'stl', kind: 'model' });
  const rec = { id: 'r', files: [f('head.stl'), f('arm.stl')], sourceFile: f('head.stl') };
  assert.deepEqual(P.partsOf(rec).map((x) => x.filename), ['head.stl', 'arm.stl']);

  rec.sourceFile = f('picked.stl');                    // the older build's Identify
  assert.deepEqual(P.partsOf(rec).map((x) => x.filename), ['picked.stl', 'head.stl', 'arm.stl'],
    'the parts were dropped, or the newly chosen file was');
  assert.equal(P.primaryOf(rec).filename, 'picked.stl',
    'the card should speak for the file somebody most recently pointed at');
  assert.equal(P.totalSize(rec), 3, 'the size chip should cover everything the record now holds');
});
