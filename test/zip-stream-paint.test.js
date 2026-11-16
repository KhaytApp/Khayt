'use strict';
/**
 * A 3MF whose mesh member inflates past lib/zip-read.js MAX_INFLATED (400 MB)
 * could not be read whole, so its paint check said "unread" and the desktop
 * showed no colours: 11 unpainted U1 models of 436 MB each (46 MB zipped) in a
 * real shop, where the Mac, which streams the member, names 4 (Nov 2026).
 * entryContainsAsync searches a member as a stream; colours3mfAsync uses it
 * for exactly the members readEntry cannot hold. Synthetic files only.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('node:zlib');
const Z = require('../lib/zip-read');
const T = require('../lib/thumbnail-extract');
const { makeZip } = require('./helpers/make-zip');

const NEEDLES = ['paint_color=', 'mmu_segmentation='];
const entryOf = (zip, name) => Z.listEntries(zip).find((e) => e.name === name);

test('entryContainsAsync: found, not found, stored and deflated', async () => {
  const zip = makeZip([
    { name: 'a.model', data: '<triangle v1="0" paint_color="4"/>', method: 8 },
    { name: 'b.model', data: '<triangle v1="0"/>', method: 8 },
    { name: 'c.model', data: 'x mmu_segmentation="8" y', method: 0 },
    { name: 'd.model', data: 'nothing', method: 0 },
  ]);
  assert.equal(await Z.entryContainsAsync(zip, entryOf(zip, 'a.model'), NEEDLES), true);
  assert.equal(await Z.entryContainsAsync(zip, entryOf(zip, 'b.model'), NEEDLES), false);
  assert.equal(await Z.entryContainsAsync(zip, entryOf(zip, 'c.model'), NEEDLES), true);
  assert.equal(await Z.entryContainsAsync(zip, entryOf(zip, 'd.model'), NEEDLES), false);
});

test('entryContainsAsync: a needle split across two inflated chunks is found', async () => {
  // Chunks are 1 MiB: put the needle across the boundary, for both kinds.
  const pad = Buffer.alloc((1 << 20) - 5, 'v');
  const data = Buffer.concat([pad, Buffer.from('paint_color="1"'), Buffer.alloc(4096, 'w')]);
  const zip = makeZip([{ name: 'd.model', data, method: 8 }, { name: 's.model', data, method: 0 }]);
  assert.equal(await Z.entryContainsAsync(zip, entryOf(zip, 'd.model'), NEEDLES), true);
  assert.equal(await Z.entryContainsAsync(zip, entryOf(zip, 's.model'), NEEDLES), true);
});

test('entryContainsAsync: corrupt data or a member longer than it declares cannot say', async () => {
  const zip = makeZip([{ name: 'a.model', data: Buffer.alloc(200000, 'q'), method: 8 }]);
  const e = entryOf(zip, 'a.model');
  assert.equal(await Z.entryContainsAsync(zip, Object.assign({}, e, { size: 1000 }), NEEDLES), null);
  const bad = Buffer.from(zip);
  // Garbage over the deflate stream (after the 30-byte header and the name).
  bad.fill(0xff, e.localOffset + 30 + 'a.model'.length, e.localOffset + 30 + 'a.model'.length + 64);
  assert.equal(await Z.entryContainsAsync(bad, e, NEEDLES), null);
  assert.equal(await Z.entryContainsAsync(zip, Object.assign({}, e, { method: 12 }), NEEDLES), null);
});

/** Raw-deflate `count` copies of `chunk` without holding them all. */
function deflateRepeated(chunk, count) {
  return new Promise((resolve, reject) => {
    const d = zlib.createDeflateRaw({ level: 1 });
    const out = [];
    d.on('data', (b) => out.push(b));
    d.on('end', () => resolve(Buffer.concat(out)));
    d.on('error', reject);
    let i = 0;
    const pump = () => {
      while (i < count) { i++; if (!d.write(chunk)) return d.once('drain', pump); }
      d.end();
    };
    pump();
  });
}

test('an unpainted mesh over MAX_INFLATED: colours3mfAsync names the slots, colours3mf could not', async () => {
  const MB = 1 << 20;
  const count = Math.ceil(Z.MAX_INFLATED / MB) + 2;
  const chunk = Buffer.alloc(MB, '<vertex x="1" y="2" z="3"/>\n');
  const comp = await deflateRepeated(chunk, count);
  // Two objects on two filament slots, set per object as Orca writes it.
  const modelSettings = '<config><object id="1"><metadata key="extruder" value="1"/></object>'
    + '<object id="2"><metadata key="extruder" value="3"/></object></config>';
  const project = JSON.stringify({ filament_colour: ['#111111', '#222222', '#333333'] });
  const zip = makeZip([
    { name: '3D/3dmodel.model', data: '<model/>', method: 8 },
    { name: '3D/Objects/object_1.model', comp, size: count * MB },
    { name: 'Metadata/project_settings.config', data: project, method: 8 },
    { name: 'Metadata/model_settings.config', data: modelSettings, method: 8 },
  ]);
  const old = T.colours3mf(zip);
  assert.equal(old.slotsKnown, false, 'the whole-member read cannot hold it');
  assert.deepEqual(old.colors, []);
  const r = await T.colours3mfAsync(zip);
  assert.equal(r.slotsKnown, true);
  assert.deepEqual(r.colors.map((c) => c.hex), ['#111111', '#333333']);
});

test('colours3mfAsync gives colours3mf\'s answer for a file readEntry can hold', async () => {
  const project = JSON.stringify({ filament_colour: ['#AA0000', '#00AA00'] });
  const cases = [
    makeZip([
      { name: '3D/3dmodel.model', data: '<triangle paint_color="8"/>', method: 8 },
      { name: 'Metadata/project_settings.config', data: project, method: 8 },
    ]),
    makeZip([
      { name: '3D/3dmodel.model', data: '<triangle/>', method: 8 },
      { name: 'Metadata/project_settings.config', data: project, method: 8 },
      { name: 'Metadata/slice_info.config', data: '<filament id="1" color="#AA0000" used_g="3.5"/>', method: 8 },
    ]),
  ];
  for (const zip of cases) assert.deepEqual(await T.colours3mfAsync(zip), T.colours3mf(zip));
});

test('the desktop colour job reads with colours3mfAsync', () => {
  const src = require('node:fs').readFileSync(require('node:path').join(__dirname, '..', 'lib', 'mf-jobs.js'), 'utf8');
  assert.match(src, /await require\('\.\/thumbnail-extract'\)\.colours3mfAsync\(await readSource\(src, maxBytes\)\)/);
});
