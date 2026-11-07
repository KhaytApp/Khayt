'use strict';
// Find Similar on the desktop: a port of the Mac's LibrarySimilar and
// LibraryStacks.stem. The Mac's own cases (LibraryStage3bCoreTests.swift),
// held against the JavaScript twin.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const S = require('../lib/library-similar.js');

test('stem takes off variant words, sizes, versions and extensions', () => {
  assert.equal(S.stem('Dragon'), 'dragon');
  assert.equal(S.stem('Dragon supportless'), 'dragon');
  assert.equal(S.stem('Dragon_150%'), 'dragon');
  assert.equal(S.stem('Dragon (pre-supported) v2'), 'dragon');
  assert.equal(S.stem('dragon-0.4mm-LEFT.stl'), 'dragon');
  assert.equal(S.stem('Dragon Head'), 'dragon head');
  assert.equal(S.stem('Benchy 3DBenchy'), 'benchy 3dbenchy');
  assert.equal(S.stem('150%'), '');
});

const M = (id, title, o = {}) => ({ id, title, ...o });

test('the same file, then the same shape (with the mirror caveat), then near ones by score', () => {
  const me = M('me', 'Dragon', { group: 'Beasts', tags: ['pla'], contentHash: 'h', geometryKey: '1000:5000:40x30x20' });
  const all = [me,
    M('near', 'Wyvern', { group: 'Beasts', geometryKey: '1100:5200:41x29x21' }),
    M('twin', 'Dragon left', { geometryKey: '1000:5000:40x30x20' }),
    M('same', 'Copy', { contentHash: 'h' }),
    M('far', 'Bracket', { geometryKey: '20:3:300x2x1' }),
    M('old', 'Dragon', { group: 'Beasts', geometryKey: '1000:5000:40x30x20', archived: true }),
    M('turned', 'Lying', { geometryKey: '1000:5000:20x40x30' })];
  const r = S.ranked(me, all);
  assert.deepEqual(r.slice(0, 2).map((x) => x.id), ['same', 'twin']);
  assert.equal(r.find((x) => x.id === 'twin').mirrorCaveat, true);
  assert.equal(r.find((x) => x.id === 'same').mirrorCaveat, false);
  assert.ok(r.some((x) => x.id === 'near') && r.some((x) => x.id === 'turned'));
  assert.ok(!r.some((x) => ['far', 'old', 'me'].includes(x.id)));
  assert.ok(r.find((x) => x.id === 'turned').score > 0.7 && r.find((x) => x.id === 'near').score > 0.7);
});

test('with no mesh, the name, group and tags still find a model; a stranger is not found', () => {
  const me = M('me', 'Lantern small', { group: 'Ramadan', tags: ['gift', 'light'] });
  const all = [me, M('big', 'Lantern large', { group: 'Ramadan', tags: ['gift', 'light'] }), M('x', 'Gear', { group: 'Parts' })];
  assert.deepEqual(S.ranked(me, all).map((x) => x.id), ['big']);
  assert.deepEqual(S.ranked(me, all, 0), []);
});

test('closeness is 1 when equal and 0 at twice or more', () => {
  assert.equal(S.closeness(10, 10), 1);
  assert.equal(S.closeness(10, 20), 0);
  assert.equal(S.closeness(0, 0), 1);
  assert.equal(S.closeness(NaN, 1), 0);
});
