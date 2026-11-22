'use strict';
/**
 * Big and small, coloured and plain — printed INSTEAD OF each other.
 *
 * A version is not a part (head and arms are printed together) and not a group
 * member (the Saudi Kings are separate prints kept together). It is an
 * alternative, and it earns its own concept because IT HAS ITS OWN TIME AND
 * WEIGHT: Small Spiderman and Big Spiderman cost different amounts, and quoting
 * both from one estimate would be wrong for both.
 *
 * The risk here is not the feature, it is everything already written against a
 * record that has one file and one estimate. So most of what is pinned below is
 * that a print with no versions behaves exactly as it always did, and that
 * nothing — adding, selecting, removing, folding in converted files — can lose
 * the files or the numbers of a version nobody was looking at.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const V = require('../lib/print-versions.js');

const f = (name, size = 100) => ({ filename: name, originalName: name, size, ext: 'stl', kind: 'model' });

test('a print that has never had a second version has exactly one', () => {
  // Callers should never need "if it has versions" — a print always has at
  // least one, it just usually has exactly one.
  const rec = { sourceFile: f('spiderman.stl'), parsed: { printTimeMins: 300 } };
  const all = V.versionsOf(rec);
  assert.equal(all.length, 1);
  assert.deepEqual(all[0].files, [f('spiderman.stl')]);
  assert.equal(V.hasVersions(rec), false);
  assert.equal(V.activeVersion(rec).parsed.printTimeMins, 300);
});

test('a record with nothing at all yields nothing, not a broken version', () => {
  assert.deepEqual(V.versionsOf(null), []);
  assert.deepEqual(V.versionsOf({}), []);
  assert.equal(V.activeVersion({}), null);
});

test('adding a version keeps the one that was already there', () => {
  // Otherwise adding "the small one" silently throws away the big one nobody
  // had got round to naming.
  const rec = { sourceFile: f('big.stl', 900), parsed: { printTimeMins: 600, filamentGrams: 400 } };
  Object.assign(rec, V.addVersion(rec, { name: 'Small', files: [f('small.stl', 200)], parsed: { printTimeMins: 150, filamentGrams: 90 } }));
  assert.equal(V.versionsOf(rec).length, 2);
  const [first, second] = V.versionsOf(rec);
  assert.deepEqual(first.files, [f('big.stl', 900)], 'the original files survive');
  assert.equal(first.parsed.printTimeMins, 600, 'and so do its numbers');
  assert.equal(second.name, 'Small');
});

test('the record mirrors the selected version, so old readers keep working', () => {
  // sourceFile, files and parsed are what every existing screen reads. They
  // must equal the version on show or the card describes something else.
  const rec = { sourceFile: f('big.stl', 900), parsed: { printTimeMins: 600 } };
  Object.assign(rec, V.addVersion(rec, { name: 'Small', files: [f('small.stl', 200)], parsed: { printTimeMins: 150 } }));
  assert.deepEqual(rec.sourceFile, f('small.stl', 200), 'adding selects the new version');
  assert.equal(rec.parsed.printTimeMins, 150, 'and the estimate follows it');

  Object.assign(rec, V.selectVersion(rec, V.versionsOf(rec)[0].id));
  assert.deepEqual(rec.sourceFile, f('big.stl', 900));
  assert.equal(rec.parsed.printTimeMins, 600, 'switching back brings the big one\'s numbers back');
});

test('each version keeps its own time and weight — the reason this exists', () => {
  const rec = { sourceFile: f('big.stl'), parsed: { printTimeMins: 600, filamentGrams: 400 } };
  Object.assign(rec, V.addVersion(rec, { name: 'Small', files: [f('small.stl')], parsed: { printTimeMins: 150, filamentGrams: 90 } }));
  const [big, small] = V.versionsOf(rec);
  assert.equal(big.parsed.filamentGrams, 400);
  assert.equal(small.parsed.filamentGrams, 90);
});

test('selecting a version that is not there changes nothing', () => {
  const rec = { sourceFile: f('big.stl'), parsed: {} };
  Object.assign(rec, V.addVersion(rec, { name: 'Small', files: [f('small.stl')] }));
  const before = JSON.stringify(rec);
  Object.assign(rec, V.selectVersion(rec, 'nope'));
  assert.equal(JSON.stringify(rec), before, 'the record must not point at a version it does not have');
});

test('removing the selected version falls back to another, never to none', () => {
  const rec = { sourceFile: f('big.stl'), parsed: {} };
  Object.assign(rec, V.addVersion(rec, { name: 'Small', files: [f('small.stl')] }));
  const smallId = rec.activeVersionId;
  Object.assign(rec, V.removeVersion(rec, smallId));
  assert.equal(V.versionsOf(rec).length, 1);
  assert.deepEqual(rec.sourceFile, f('big.stl'), 'the card shows what is left');
});

test('the last version is never removed — that would be a delete in disguise', () => {
  const rec = { sourceFile: f('only.stl'), parsed: {} };
  const id = V.versionsOf(rec)[0].id;
  assert.deepEqual(V.removeVersion(rec, id), {});
  assert.deepEqual(V.versionsOf(rec)[0].files, [f('only.stl')]);
});

test('converted files become versions named after the printer they were made for', () => {
  // `converted[]` was a versions list built for one case. Folding it in beats a
  // second parallel list, which would be a fourth vocabulary for one idea.
  const rec = {
    sourceFile: f('spiderman.3mf'), parsed: { printTimeMins: 300 },
    converted: [
      { filename: 'spiderman-u1.3mf', ext: '3mf', size: 500, targetName: 'Snapmaker U1' },
      { filename: 'spiderman-p1.3mf', ext: '3mf', size: 520, targetName: 'Bambu P1S' },
    ],
  };
  Object.assign(rec, V.fromConverted(rec));
  const all = V.versionsOf(rec);
  assert.equal(all.length, 3);
  assert.deepEqual(all.map((v) => v.name), ['', 'Snapmaker U1', 'Bambu P1S']);
  assert.deepEqual(rec.sourceFile, f('spiderman.3mf'), 'the original stays selected');
  assert.equal(rec.parsed.printTimeMins, 300, 'and nothing about the card changes');
});

test('folding converted files in twice does not duplicate them', () => {
  const rec = { sourceFile: f('a.3mf'), converted: [{ filename: 'b.3mf', ext: '3mf', size: 1, targetName: 'U1' }] };
  Object.assign(rec, V.fromConverted(rec));
  const after = JSON.stringify(V.versionsOf(rec));
  Object.assign(rec, V.fromConverted(rec));
  assert.equal(JSON.stringify(V.versionsOf(rec)), after);
});

test('a record with no converted files is left alone', () => {
  assert.deepEqual(V.fromConverted({ sourceFile: f('a.stl') }), {});
  assert.deepEqual(V.fromConverted({}), {});
  assert.deepEqual(V.fromConverted(null), {});
});

test('version ids do not collide, however the list was built', () => {
  const rec = { versions: [{ id: 'v1', files: [] }, { id: 'v3', files: [] }] };
  assert.equal(V.nextVersionId(rec), 'v2');
  Object.assign(rec, V.addVersion(rec, { name: 'x', files: [f('x.stl')] }));
  const ids = V.versionsOf(rec).map((v) => v.id);
  assert.equal(new Set(ids).size, ids.length, 'two versions share an id, so selecting one shows the other');
});
