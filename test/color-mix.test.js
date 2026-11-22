'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { hexToRgb, rgbToHex, deltaE, nearest, blend, gradient } = require('../lib/color-mix');

test('hex ↔ rgb round-trip (incl. shorthand + alpha)', () => {
  assert.deepEqual(hexToRgb('#ff8800'), { r: 255, g: 136, b: 0 });
  assert.deepEqual(hexToRgb('#f80'), { r: 255, g: 136, b: 0 });
  assert.deepEqual(hexToRgb('112233aa'), { r: 17, g: 34, b: 51 }); // alpha ignored
  assert.equal(rgbToHex(255, 136, 0), '#FF8800');
  assert.equal(hexToRgb('nope'), null);
});

test('deltaE: identical = 0, black↔white ≈ 100', () => {
  assert.equal(deltaE('#345678', '#345678'), 0);
  const bw = deltaE('#000000', '#ffffff');
  assert.ok(bw > 95 && bw < 105, `black↔white ΔE=${bw}`);
  assert.equal(deltaE('#000000', 'garbage'), Infinity);
});

test('deltaE: near colours are closer than far colours', () => {
  const near = deltaE('#ff0000', '#fe0300'); // two reds
  const far = deltaE('#ff0000', '#0000ff');  // red vs blue
  assert.ok(near < 5, `near reds ΔE=${near}`);
  assert.ok(far > near, `far (${far}) should exceed near (${near})`);
});

test('nearest ranks candidates by colour distance, closest first', () => {
  const spools = [
    { id: 'a', color: '#0000ff', material: 'Blue' },
    { id: 'b', color: '#ff2200', material: 'Red-ish' },
    { id: 'c', color: '#00ff00', material: 'Green' },
  ];
  const ranked = nearest('#ff0000', spools);
  assert.equal(ranked[0].id, 'b');          // red-ish wins
  assert.ok('deltaE' in ranked[0]);
  assert.ok(ranked[0].deltaE <= ranked[1].deltaE && ranked[1].deltaE <= ranked[2].deltaE);
  assert.equal(nearest('#ff0000', spools, { limit: 1 }).length, 1);
  // candidates with an invalid/missing colour are dropped, never throw
  assert.equal(nearest('#ff0000', [{ id: 'x' }, { id: 'y', color: 'zzz' }]).length, 0);
});

test('blend midpoint + endpoints', () => {
  assert.equal(blend('#000000', '#ffffff', 0), '#000000');
  assert.equal(blend('#000000', '#ffffff', 1), '#FFFFFF');
  // linear-light 50% grey is brighter than sRGB 0x80
  const mid = hexToRgb(blend('#000000', '#ffffff', 0.5));
  assert.ok(mid.r > 150 && mid.r < 200, `mid grey r=${mid.r}`);
  assert.equal(blend('#000000', 'zzz', 0.5), null);
});

test('gradient includes endpoints and has the requested length', () => {
  const g = gradient('#ff0000', '#0000ff', 5);
  assert.equal(g.length, 5);
  assert.equal(g[0], '#FF0000');
  assert.equal(g[4], '#0000FF');
  assert.equal(gradient('#ff0000', 'zzz', 4).length, 0); // bad input → empty, no throw
  assert.equal(gradient('#ff0000', '#0000ff', 1).length, 2); // clamped to min 2
});
