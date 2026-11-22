'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { renderStlThumbnail } = require('../lib/stl-thumbnail');

function stubCanvas(size) {
  const rec = { fills: 0, fillRects: 0, styles: [], moves: 0 };
  let cur = '';
  const ctx = {
    set fillStyle(v) { cur = v; },
    get fillStyle() { return cur; },
    fillRect() { rec.fillRects++; },
    beginPath() {},
    moveTo() { rec.moves++; },
    lineTo() {},
    closePath() {},
    fill() { rec.fills++; rec.styles.push(cur); },
  };
  return { width: size, height: size, _rec: rec, getContext: () => ctx, toDataURL: () => 'data:image/jpeg;base64,STUB' };
}

const TRIS = [
  [[0, 0, 0], [10, 0, 0], [0, 10, 0]],
  [[0, 0, 0], [0, 10, 0], [0, 0, 10]],
  [[0, 0, 10], [10, 0, 10], [0, 10, 10]],
];

test('renders each face and a background, returns a data URL', () => {
  const r = renderStlThumbnail(TRIS, { canvasFactory: stubCanvas, size: 128 });
  assert.equal(r.ok, true);
  assert.equal(r.dataUrl, 'data:image/jpeg;base64,STUB');
  assert.equal(r.canvas._rec.fillRects, 1);        // background
  assert.equal(r.canvas._rec.fills, TRIS.length);  // one fill per face
  assert.equal(r.canvas._rec.moves, TRIS.length);
  // Faces with different orientations get different shading.
  assert.ok(new Set(r.canvas._rec.styles).size >= 2);
});

test('empty / invalid mesh → ok:false', () => {
  assert.equal(renderStlThumbnail([], { canvasFactory: stubCanvas }).ok, false);
  assert.equal(renderStlThumbnail(null, { canvasFactory: stubCanvas }).ok, false);
});

test('no canvas factory available → ok:false (never throws)', () => {
  assert.equal(renderStlThumbnail(TRIS, {}).ok, false);
});

test('huge meshes are decimated for the thumbnail', () => {
  const many = [];
  for (let i = 0; i < 100; i++) many.push([[i, 0, 0], [i + 1, 0, 0], [i, 1, 0]]);
  const r = renderStlThumbnail(many, { canvasFactory: stubCanvas, maxTriangles: 10 });
  assert.equal(r.ok, true);
  assert.ok(r.triangleCount <= 10, `decimated to ${r.triangleCount}`);
  assert.equal(r.canvas._rec.fills, r.triangleCount);
});
