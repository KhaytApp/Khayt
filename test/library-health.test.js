'use strict';
// Library Health on the desktop: a port of the Mac's LibraryHealth
// (mac/KhaytCore/Sources/KhaytCore/LibraryHealth.swift). These are the Mac's
// own cases (Tests/KhaytCoreTests/LibraryHealthTests.swift), held against the
// JavaScript twin so the two say the same about the same book.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const H = require('../lib/library-health.js');

const KEY = '1000:5000.0:100x80x40';
const U1 = { x: 270, y: 270, z: 270 };
const LASER = { x: 1300, y: 900, z: 200 };
function model(id, presence = 'here', o = {}) {
  return { id, title: id, presence, contentHash: o.hash || null,
    geometryKey: 'key' in o ? o.key : KEY, slicedMinutes: o.minutes, slicedGrams: o.grams,
    tags: o.tags || ['t'], category: o.category, archived: !!o.archived,
    inArchive: o.inArchive, hasPicture: o.hasPicture };
}
const group = (kind, gs) => gs.find((g) => g.kind === kind);

test('a healthy library has no groups at all', () => {
  const ms = [model('a', 'here', { hash: 'h1' }), model('b', 'here', { hash: 'h2', key: '2:1:1x1x1' })];
  assert.deepEqual(H.groups(ms, [{ id: 'u1', bed: U1 }]), []);
});

test('missing, online-unmeasured and no-figures never overlap', () => {
  const ms = [
    model('gone', 'missing', { key: null }), model('cloud', 'online', { key: null }),
    model('cloud-sliced', 'online', { key: null, minutes: 60, grams: 20 }),
    model('here', 'here', { key: null }), model('sample', 'unknown', { key: null }),
    model('half', 'here', { key: null, minutes: 60 }), model('web', 'web', { key: null }),
  ];
  const gs = H.groups(ms);
  assert.deepEqual(group('missing', gs).modelIds, ['gone']);
  assert.deepEqual(group('onlineUnmeasured', gs).modelIds, ['cloud']);
  assert.deepEqual(group('noFigures', gs).modelIds, ['here', 'sample', 'half']);
});

test('a measured mesh counts as figures; an unreadable key does not', () => {
  assert.equal(H.hasFigures(model('m', 'here', { key: '500:10.0:10x10x10' })), true);
  assert.equal(H.hasFigures(model('z', 'here', { key: '0:0:0x0x0' })), false);
  assert.equal(H.hasFigures(model('bad', 'here', { key: 'garbage' })), false);
});

test('the same bytes are a certain duplicate, and not shown again as a look', () => {
  const gs = H.groups([model('a', 'here', { hash: 'H' }), model('b', 'here', { hash: 'H' }), model('c', 'here', { hash: 'o', key: null })]);
  assert.deepEqual(group('sameFile', gs).clusters, [['a', 'b']]);
  assert.equal(group('looksSame', gs), undefined);
});

test('the same key with different bytes is a look — mirrors share it', () => {
  const gs = H.groups([model('left', 'here', { hash: 'L' }), model('right', 'here', { hash: 'R' })]);
  assert.deepEqual(group('looksSame', gs).clusters, [['left', 'right']]);
  assert.equal(group('sameFile', gs), undefined);
  const turned = H.groups([model('a', 'here', { hash: 'A' }), model('b', 'here', { hash: 'B', key: '1000:5000.0:80x100x40' })]);
  assert.equal(group('looksSame', turned), undefined, 'a different box is a different shape');
});

test('a mixed cluster is shown in both; unhashed records are each their own file', () => {
  const gs = H.groups([model('a', 'here', { hash: 'H' }), model('b', 'here', { hash: 'H' }), model('c', 'here', { hash: 'X' })]);
  assert.deepEqual(group('sameFile', gs).clusters, [['a', 'b']]);
  assert.deepEqual(group('looksSame', gs).clusters, [['a', 'b', 'c']]);
  assert.deepEqual(group('looksSame', H.groups([model('p'), model('q')])).modelIds, ['p', 'q']);
});

test('archived models are put aside', () => {
  const ms = [model('a', 'here', { hash: 'H' }), model('b', 'here', { hash: 'H', archived: true }),
    model('gone', 'missing', { archived: true })];
  assert.deepEqual(H.groups(ms), []);
});

test('too big for every 3D printer; lasers and UV beds are not asked', () => {
  const huge = model('huge', 'here', { key: '10:1.0:1141x757x207' });
  const small = model('small', 'here', { key: '10:1.0:100x100x10' });
  const machines = [{ id: 'u1', kind: 'fdm', bed: U1 }, { id: 'laser', kind: 'laser', bed: LASER }, { id: 'uv', kind: 'uv', bed: LASER }];
  assert.deepEqual(group('tooBig', H.groups([huge, small], machines)).modelIds, ['huge']);
  assert.equal(group('tooBig', H.groups([huge], [machines[1]])), undefined);
  assert.equal(group('tooBig', H.groups([huge], [{ id: 'x', bed: null }])), undefined);
  assert.ok(group('tooBig', H.groups([huge], [{ id: 'x', bed: U1 }])), 'no kind reads as FDM');
  // Fits turned a quarter turn: not too big.
  const long = model('long', 'here', { key: '10:1.0:300x200x10' });
  assert.equal(group('tooBig', H.groups([long], [{ id: 'b', bed: { x: 250, y: 310, z: 250 } }])), undefined);
});

test('unorganised means neither a tag nor a category; blanks do not count', () => {
  const ms = [model('none', 'here', { tags: [] }), model('blank', 'here', { tags: ['  '], category: ' ' }),
    model('tagged', 'here', { tags: ['x'] }), model('filed', 'here', { tags: [], category: 'Busts' })];
  assert.deepEqual(group('unorganised', H.groups(ms)).modelIds, ['none', 'blank']);
});

test('a product whose model is gone — an archived model is not gone', () => {
  const ms = [model('here'), model('aside', 'here', { archived: true })];
  const products = H.productFacts([
    { id: 'P1', name: 'ok', parts: [{ printFileId: 'here' }] },
    { id: 'P2', name: 'aside', parts: [{ printFileId: 'aside' }] },
    { id: 'P3', name: 'lost', parts: [{ printFileId: 'here' }, { printFileId: 'deleted' }] },
    { id: 'P4', name: 'no file', parts: [{}] },
  ]);
  const g = group('orphanProducts', H.groups(ms, [], products));
  assert.deepEqual(g.productIds, ['P3']);
  assert.equal(g.count, 1);
});

test('a missing archive is one thing gone; its models all counted', () => {
  const ms = [model('a', 'missing', { inArchive: '/x/kit.zip' }), model('b', 'missing', { inArchive: '/x/kit.zip' }), model('c', 'missing')];
  const g = group('missing', H.groups(ms));
  assert.equal(g.count, 3);
  assert.deepEqual(g.archives, [{ path: '/x/kit.zip', modelIds: ['a', 'b'] }]);
});

test('no picture (desktop only): only a model here that was asked and has none', () => {
  const ms = [model('bare', 'here', { hasPicture: false }), model('drawn', 'here', { hasPicture: true }),
    model('unasked'), model('gone', 'missing', { hasPicture: false })];
  assert.deepEqual(group('noPicture', H.groups(ms)).modelIds, ['bare']);
});

test('groups come in the order a shop works through them', () => {
  const ms = [model('gone', 'missing', { key: null, tags: [] }), model('a', 'here', { hash: 'H' }), model('b', 'here', { hash: 'H' })];
  assert.deepEqual(H.groups(ms).map((g) => g.kind), ['missing', 'sameFile', 'unorganised']);
  for (const k of H.groups(ms).map((g) => g.kind)) assert.ok(H.KINDS.includes(k));
});
