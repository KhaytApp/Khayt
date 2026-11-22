/**
 * A g-code file must still be recognisable after it has been sliced again.
 *
 * Both existing identity keys fail at that. contentHash hashes the bytes, which
 * a re-slice rewrites — and so does merely exporting to a different filename,
 * because slicers stamp the output path and a timestamp into the header.
 * geometryKey came from the mesh and was only ever computed for STL, so a shop
 * that slices elsewhere and keeps only g-code had no second chance.
 *
 * The consequence was not an error. Per-file calibration simply never reached
 * MIN_JOBS, quotes fell back to the machine-wide median, and on real data that
 * misprices by 20%+ in either direction because grams-per-hour tracks a part's
 * geometry far more than it tracks the machine.
 *
 * The numbers in these fixtures were taken from real slices: one clip and one
 * figure, put through PrusaSlicer at 0.2 mm and 0.3 mm layer height and at two
 * infills. Same model across settings measured 0.000–0.002 apart; the two models
 * measured 0.304–0.306 apart.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createSilhouette, silhouetteFromText } = require('../lib/gcode-geometry.js');
const { gcodeGeometryKey } = require('../lib/model-identity.js');

/** A box: a footprint repeated at every layer, drawn with absolute E. */
function box({ w = 20, d = 10, h = 4, layer = 0.2, x0 = 50, y0 = 50 } = {}) {
  const out = ['G90', 'M82', 'G21'];
  let e = 0;
  for (let z = layer; z <= h + 1e-9; z += layer) {
    out.push(`G1 Z${z.toFixed(3)} F300`);
    out.push(`G1 X${x0} Y${y0} F9000`);                 // travel — no E, must not count
    for (const [px, py] of [[x0 + w, y0], [x0 + w, y0 + d], [x0, y0 + d], [x0, y0]]) {
      e += 1;
      out.push(`G1 X${px} Y${py} E${e.toFixed(4)}`);
    }
  }
  return out.join('\n');
}

/** A cone: the footprint shrinks with height, so the bands differ from a box's. */
function cone({ w = 20, h = 8, layer = 0.2, x0 = 50, y0 = 50 } = {}) {
  const out = ['G90', 'M83', 'G21'];                    // relative E this time
  for (let z = layer; z <= h + 1e-9; z += layer) {
    const k = 1 - (z / h) * 0.8;                        // 100% wide at the base, 20% at the top
    const ww = w * k;
    out.push(`G1 Z${z.toFixed(3)}`);
    out.push(`G1 X${x0} Y${y0} F9000`);
    for (const [px, py] of [[x0 + ww, y0], [x0 + ww, y0 + ww], [x0, y0 + ww], [x0, y0]]) {
      out.push(`G1 X${px.toFixed(3)} Y${py.toFixed(3)} E0.5`);
    }
  }
  return out.join('\n');
}

test('the envelope comes from extruded material, not from where the head travelled', () => {
  const s = silhouetteFromText([
    'G90', 'M82',
    'G1 Z0.2',
    'G1 X0 Y0 F9000',           // travel to the far corner of the bed
    'G1 X200 Y200 F9000',       // still travel — 200 mm of it
    'G1 X50 Y50 F9000',
    'G1 X60 Y50 E1',            // the only extrusion: 10 mm wide
    'G1 X60 Y60 E2',
  ].join('\n'));
  assert.equal(s.bbox.x, 10, 'a travel move was counted into the envelope');
  assert.equal(s.bbox.y, 10);
});

test('a file with no extrusion has no envelope, rather than a zero-sized one', () => {
  assert.equal(silhouetteFromText('G90\nG1 X10 Y10 F9000\nG1 X20 Y20 F9000'), null);
  assert.equal(silhouetteFromText(''), null);
  assert.equal(silhouetteFromText('; just a comment\n'), null);
  assert.equal(gcodeGeometryKey(null), null);
});

test('the same model sliced at different layer heights keeps one key', () => {
  // The whole point: this is what re-slicing does, and what used to lose the link.
  const a = gcodeGeometryKey(silhouetteFromText(box({ layer: 0.2 })));
  const b = gcodeGeometryKey(silhouetteFromText(box({ layer: 0.3 })));
  const c = gcodeGeometryKey(silhouetteFromText(box({ layer: 0.15 })));
  assert.ok(a, 'no key at all');
  assert.equal(a, b, '0.2 mm and 0.3 mm produced different keys');
  assert.equal(a, c, '0.2 mm and 0.15 mm produced different keys');
});

test('a different shape of the same footprint gets a different key', () => {
  // A box and a cone that start from the same 20 mm base. The bbox alone cannot
  // separate them at every height; the bands can, which is why the key carries
  // both.
  const boxKey = gcodeGeometryKey(silhouetteFromText(box({ w: 20, d: 20, h: 8 })));
  const coneKey = gcodeGeometryKey(silhouetteFromText(cone({ w: 20, h: 8 })));
  assert.ok(boxKey && coneKey);
  assert.notEqual(boxKey, coneKey, 'a tapering shape keyed the same as a straight-sided one');
});

test('a bigger print of the same shape is not the same model', () => {
  const small = gcodeGeometryKey(silhouetteFromText(box({ w: 20, d: 10, h: 4 })));
  const large = gcodeGeometryKey(silhouetteFromText(box({ w: 40, d: 20, h: 8 })));
  assert.notEqual(small, large, 'scale is part of identity — a 2× print is a different job');
});

test('relative and absolute extrusion describe the same object', () => {
  // M83 (PrusaSlicer, Orca) and M82 are both common, and reading one as the
  // other turns every move into a phantom extrusion or none at all.
  const abs = silhouetteFromText(['G90', 'M82', 'G1 Z0.2', 'G1 X50 Y50 F9000',
    'G1 X70 Y50 E1', 'G1 X70 Y60 E2'].join('\n'));
  const rel = silhouetteFromText(['G90', 'M83', 'G1 Z0.2', 'G1 X50 Y50 F9000',
    'G1 X70 Y50 E1', 'G1 X70 Y60 E1'].join('\n'));
  assert.deepEqual(abs.bbox, rel.bbox);
});

test('G92 E0 is a reset, not twenty metres of filament', () => {
  // Absolute-E slicers zero the extruder between objects. Missing it makes the
  // next move look like an enormous extrusion and drags the envelope with it.
  const s = silhouetteFromText([
    'G90', 'M82', 'G1 Z0.2',
    'G1 X50 Y50 F9000', 'G1 X60 Y50 E5',
    'G92 E0',                       // reset
    'G1 X150 Y150 F9000',           // travel after the reset
    'G1 X160 Y150 E5',              // a second real extrusion, 10 mm wide
  ].join('\n'));
  // Both extrusions count; the travel between them does not.
  assert.equal(s.bbox.x, 110, 'the reset was misread and the travel became extrusion');
});

test('relative positioning (G91) is followed', () => {
  const s = silhouetteFromText(['G90', 'M82', 'G1 Z0.2', 'G1 X50 Y50 F9000',
    'G91', 'G1 X10 Y0 E1', 'G1 X0 Y10 E2'].join('\n'));
  assert.equal(s.bbox.x, 10);
  assert.equal(s.bbox.y, 10);
});

test('a comment that looks like a move is not one', () => {
  const s = silhouetteFromText(['G90', 'M82', 'G1 Z0.2',
    'G1 X50 Y50 F9000', 'G1 X60 Y50 E1',
    '; G1 X999 Y999 E99', 'G1 X60 Y60 E2 ; G1 X999 Y999 E99'].join('\n'));
  assert.equal(s.bbox.x, 10, 'a commented-out move reached the envelope');
});

test('the key is prefixed so a toolpath measurement is never read as a mesh one', () => {
  const k = gcodeGeometryKey(silhouetteFromText(box()));
  assert.match(k, /^g:/, 'without the prefix the two kinds of key are indistinguishable in storage');
});

test('a malformed silhouette yields no key rather than a broken one', () => {
  assert.equal(gcodeGeometryKey({}), null);
  assert.equal(gcodeGeometryKey({ bbox: { x: 1, y: 2, z: 3 } }), null, 'bands missing');
  assert.equal(gcodeGeometryKey({ bbox: { x: 0, y: 2, z: 3 }, bands: [[1, 1]] }), null, 'zero dimension');
  assert.equal(gcodeGeometryKey({ bbox: { x: 1, y: 2, z: 3 }, bands: [[null, 1]] }), null, 'unmeasured band');
});

test('streaming a file line by line matches parsing it whole', () => {
  // main.js streams, because the toolpath of a real print does not belong in
  // memory. The two paths must not drift.
  const text = box({ h: 6 });
  const s = createSilhouette();
  for (const line of text.split('\n')) s.push(line);
  assert.deepEqual(s.result(), silhouetteFromText(text));
});
