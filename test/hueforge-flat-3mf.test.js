/**
 * lib/hueforge-3mf.js buildFlatU1_3mf — the flat mode's file, end to end from an image.
 *
 * Flat mode paints by REGION, not by height: the plate is a base slab plus one cap part per
 * colour, and each part is assigned a toolhead. So this file is shaped nothing like the
 * relief's. It has no layer ranges at all — a Z-range applies to everything at that height,
 * which on a flat plate is every colour at once — and instead carries one object per part,
 * referenced as components, each tagged with its own extruder.
 *
 * That layout is not invented here. It is what a real multi-part U1 export uses
 * (ToyCarRoad_V2.u1.3mf: 75 parts, every `<part id>` matching a `<component objectid>` and
 * carrying its own `extruder` key), so the assertions below are about matching a file that
 * prints rather than a structure that seemed reasonable.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const FLAT = require('../lib/hueforge-flat.js');
const M3 = require('../lib/hueforge-3mf.js');
const { openZip } = require('../lib/zip-read.js');

/** Four solid quadrants — a flat poster is exactly this problem. */
function quadImage(W = 64, H = 64) {
  const data = new Uint8ClampedArray(W * H * 4);
  const quad = [[220, 30, 30], [30, 90, 200], [245, 240, 220], [25, 25, 30]];
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const c = quad[(y < H / 2 ? 0 : 2) + (x < W / 2 ? 0 : 1)];
      const o = (y * W + x) * 4;
      data[o] = c[0]; data[o + 1] = c[1]; data[o + 2] = c[2]; data[o + 3] = 255;
    }
  }
  return { data, width: W, height: H };
}

const plan = () => FLAT.planFlat(quadImage(), { colors: 4, widthMm: 100, heightMm: 2.4 });
const build = (extra) => {
  const p = plan();
  return M3.buildFlatU1_3mf(Object.assign({
    parts: p.parts, filaments: p.filaments, sizeMm: p.sizeMm, baseHead: p.baseHead,
    layerH: 0.12, name: 'flat',
  }, extra || {}));
};
const open = (buf) => {
  assert.ok(buf && buf.length, 'no 3MF produced');
  const zip = openZip(buf);
  return { zip, names: zip.entries.map((e) => e.name), text: (n) => Buffer.from(zip.file(n)).toString('utf8') };
};

test('a flat plan becomes an openable 3MF with the members a project needs', () => {
  const z = open(build());
  for (const n of [
    '[Content_Types].xml', '_rels/.rels', '3D/3dmodel.model', '3D/_rels/3dmodel.model.rels',
    '3D/Objects/object_1.model', 'Metadata/project_settings.config', 'Metadata/model_settings.config',
  ]) assert.ok(z.names.includes(n), 'missing ' + n);
});

test('it carries NO layer ranges — colour here is a region, not a height', () => {
  const z = open(build());
  assert.ok(!z.names.includes('Metadata/layer_config_ranges.xml'),
    'a Z-range would apply to every colour at that height at once, which is the whole thing flat mode avoids');
});

test('every part is a component, and every component is a part', () => {
  const z = open(build());
  const root = z.text('3D/3dmodel.model');
  const settings = z.text('Metadata/model_settings.config');
  const parts = z.text('3D/Objects/object_1.model');

  const compIds = [...root.matchAll(/<component[^>]*objectid="(\d+)"/g)].map((m) => m[1]);
  const partIds = [...settings.matchAll(/<part id="(\d+)"/g)].map((m) => m[1]);
  const objIds = [...parts.matchAll(/<object id="(\d+)"/g)].map((m) => m[1]);

  assert.ok(compIds.length >= 2, 'a flat plate is a base plus at least one colour cap');
  assert.deepEqual(partIds, compIds, 'model_settings must describe exactly the components the root references');
  assert.deepEqual(objIds, compIds, 'and every referenced id must be a real mesh object');
});

test('each part names the head that prints it, 1-based like a real export', () => {
  const p = plan();
  const z = open(build());
  const settings = z.text('Metadata/model_settings.config');

  const extruders = [...settings.matchAll(/<part id="\d+"[\s\S]*?key="extruder" value="(\d+)"/g)].map((m) => +m[1]);
  assert.equal(extruders.length, p.parts.length, 'every part gets an extruder');
  assert.deepEqual(extruders, p.parts.map((x) => x.head + 1), 'head N prints on extruder N+1');
  for (const e of extruders) assert.ok(e >= 1 && e <= 4, 'the U1 has four heads, got extruder ' + e);
});

test('the loaded colours are indexed by head, not by part order', () => {
  const p = plan();
  const z = open(build());
  const cfg = JSON.parse(z.text('Metadata/project_settings.config'));

  assert.equal(cfg.filament_colour.length, 4, 'four slots, padded');
  // The base slab shares a head with one of the caps, so part order and head order differ —
  // deriving slot colours from part order would load the wrong spools.
  p.parts.forEach((part) => {
    assert.equal(cfg.filament_colour[part.head], String(part.hex).toUpperCase(),
      'head ' + part.head + ' should hold ' + part.hex);
  });
});

test('the prime tower stays off, and stays off through a preset reconcile', () => {
  const z = open(build());
  const cfg = JSON.parse(z.text('Metadata/project_settings.config'));
  assert.equal(cfg.enable_prime_tower, '0', 'SnapSwap needs no purge');
  assert.match(cfg.different_settings_to_system[0], /enable_prime_tower/,
    'without this listed, Orca reconciles the tower back on from the system preset');
});

test('a thumbnail is embedded, and its absence is still a valid file', () => {
  const PNG = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC',
    'base64');
  const withThumb = open(build({ thumbnailPng: PNG }));
  assert.ok(withThumb.names.includes('Metadata/plate_1.png'));
  assert.match(withThumb.text('_rels/.rels'), /plate_1\.png/, 'the thumbnail must be advertised or nothing shows it');
  assert.match(withThumb.text('Metadata/model_settings.config'), /thumbnail_file/);

  const without = open(build());
  assert.ok(!without.names.includes('Metadata/plate_1.png'));
  assert.ok(!/thumbnail_file/.test(without.text('Metadata/model_settings.config')));
});

test('the plate is centred on the bed rather than dumped in a corner', () => {
  const p = plan();
  const z = open(build({ bed: { x: 270, y: 270 } }));
  const m = z.text('3D/3dmodel.model').match(/<item objectid="2" transform="([^"]+)"/);
  assert.ok(m, 'the build item must place the object');
  const nums = m[1].trim().split(/\s+/).map(Number);
  assert.equal(nums.length, 12);
  assert.ok(Math.abs(nums[9] - (270 - p.sizeMm.x) / 2) < 0.01, 'x offset centres the plate');
  assert.ok(Math.abs(nums[10] - (270 - p.sizeMm.y) / 2) < 0.01, 'y offset centres the plate');
});

test('the mesh is welded by index, not a triangle soup', () => {
  const z = open(build());
  const parts = z.text('3D/Objects/object_1.model');
  const objects = parts.split('<object id=').slice(1);
  assert.ok(objects.length >= 2);
  for (const o of objects) {
    const verts = (o.match(/<vertex /g) || []).length;
    const tris = (o.match(/<triangle /g) || []).length;
    assert.ok(tris > 0, 'a part with no faces should never have been emitted');
    // Un-welded soup is exactly 3 vertices per triangle; a welded box shares corners.
    assert.ok(verts < tris * 3, 'part looks un-welded: ' + verts + ' vertices for ' + tris + ' triangles');
  }
});

test('bad input returns null, never throws', () => {
  for (const [why, arg] of [
    ['nothing at all', undefined],
    ['no parts', { filaments: ['#FFF'] }],
    ['empty parts', { parts: [] }],
    ['parts with no geometry', { parts: [{ head: 0, triangles: [] }] }],
  ]) assert.equal(M3.buildFlatU1_3mf(arg), null, why + ' should return null');
});

test('the parts file carries the <build/> the 3MF core spec requires', () => {
  // Same omission as the relief's object part, same fix (bedready.io, validated with lib3mf).
  const parts = open(build()).text('3D/Objects/object_1.model');
  assert.match(parts, /<\/resources><build\/><\/model>$/);
  assert.doesNotMatch(parts, /<item\b/);
});
