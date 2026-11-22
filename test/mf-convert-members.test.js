/**
 * The conversion, separated from the zip.
 *
 * `convert` reads a 3MF, decides, and writes one back. The reading and writing
 * are Node's `zlib` and nothing else here is — so the decisions were given a
 * door of their own, for a host that has its own zip. The native Mac app has
 * one; JavaScriptCore has no zlib and could not load this module at all.
 *
 * What these check is that the door leads to the same room: the same members
 * out, for the same file in.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const MF = require('../lib/mf-convert.js');
const Z = require('../lib/zip-write.js');

const MODEL = '<?xml version="1.0"?><model unit="millimeter"><resources><object id="1"/></resources></model>';

const CONFIG = 'Metadata/project_settings.config';

function threeMF(overrides = {}) {
  const settings = {
    printer_model: 'Original Prusa MK4', printer_settings_id: 'MK4',
    filament_colour: ['#FF0000', '#00FF00'],
    ...overrides,
  };
  return Z.writeZip([
    { name: '[Content_Types].xml', data: Buffer.from('<Types/>') },
    { name: '_rels/.rels', data: Buffer.from('<Relationships/>') },
    { name: '3D/3dmodel.model', data: Buffer.from(MODEL) },
    { name: CONFIG, data: Buffer.from(JSON.stringify(settings)) },
  ]);
}

test('convertMembers returns what convert writes', () => {
  const buf = threeMF();
  const opts = { targetId: 'snapmaker-u1' };

  const whole = MF.convert(buf, opts);
  assert.equal(whole.ok, true, whole.error);

  const planned = MF.convertMembers(MF.readMembers(buf), opts);
  assert.equal(planned.ok, true, planned.error);

  // The same members, by name and in the same order.
  const written = MF.readMembers(whole.buffer).map((m) => m.name);
  assert.deepEqual(planned.members.map((m) => m.name), written);

  // And the same account of what was done. `convert` nests its report rather
  // than spreading it, which is easy to get wrong from memory — the existing
  // suite passing while this line failed is what said so.
  assert.equal(planned.report.target, whole.report.target);
  assert.equal(planned.report.mode, whole.report.mode);
  assert.deepEqual(planned.report.fieldsChanged, whole.report.fieldsChanged);
});

test('the rewritten config is byte-identical either way', () => {
  const buf = threeMF();
  const opts = { targetId: 'snapmaker-u1' };
  const throughZip = MF.readMembers(MF.convert(buf, opts).buffer)
    .find((m) => m.name === CONFIG);
  const direct = MF.convertMembers(MF.readMembers(buf), opts).members
    .find((m) => m.name === CONFIG);
  assert.ok(direct.data, 'the config was passed through untouched, so nothing was retargeted');
  assert.equal(direct.data.toString('utf8'), throughZip.data.toString('utf8'));
});

// The geometry is the thing that must never change. An untouched member keeps
// its `src` — the bytes still compressed as they were read — which is both the
// speed of the repack and the guarantee behind it.
test('geometry comes back untouched, and still compressed', () => {
  const planned = MF.convertMembers(MF.readMembers(threeMF()), { targetId: 'snapmaker-u1' });
  const mesh = planned.members.find((m) => /\.model$/.test(m.name));
  assert.ok(mesh, 'the mesh went missing');
  assert.ok(mesh.src, 'the mesh was decompressed and re-encoded rather than passed through');
});

test('a refusal is the same refusal', () => {
  const notAZip = Buffer.from('this is not a 3MF');
  assert.equal(MF.convert(notAZip).ok, false);
  assert.equal(MF.convertMembers(MF.readMembers(notAZip)).ok, false);

  // A zip with no mesh in it: refused by the same sentence, from both doors.
  const noMesh = Z.writeZip([{ name: CONFIG, data: Buffer.from('{}') }]);
  assert.equal(MF.convert(noMesh).error, MF.convertMembers(MF.readMembers(noMesh)).error);
});

test('normalize strips the same members either way', () => {
  const buf = threeMF();
  const opts = { mode: 'normalize' };
  const whole = MF.convert(buf, opts);
  const planned = MF.convertMembers(MF.readMembers(buf), opts);
  assert.deepEqual(planned.members.map((m) => m.name),
                   MF.readMembers(whole.buffer).map((m) => m.name));
  assert.ok(!planned.members.some((m) => m.name === CONFIG), 'the slicer config survived');
});

// ── A HOST THAT DOES NOT HAND OVER THE MESH ────────────────────────────────
//
// Node reads the whole container, so every member arrives with its bytes. The
// native Mac app does not: a member over four megabytes crosses by NAME, which
// is what keeps a 400 MB mesh out of JavaScriptCore. The root `.model` is
// always that member on a real file.
//
// Reading its bytes unconditionally is what broke. `retilePlatesForBed` did,
// and threw before it had even asked whether there was a second plate — so
// EVERY same-family retarget to a differently-sized bed failed on the Mac,
// with "undefined is not an object" where a converted file should have been.

const PLATE_BUILD = `<build>
  <item objectid="2" transform="1 0 0 0 1 0 0 0 1 128 128 0"/>
  <item objectid="4" transform="1 0 0 0 1 0 0 0 1 435 128 0"/>
  </build>`;

const PLATE_MODEL = '<?xml version="1.0"?><model unit="millimeter"><resources>'
  + '<object id="2"/><object id="4"/></resources>' + PLATE_BUILD + '</model>';

const PLATE_SETTINGS = JSON.stringify({
  printer_model: 'X1C', nozzle_diameter: ['0.4'],
  printable_area: ['0x0', '256x0', '256x256', '0x256'],
  filament_colour: ['#FF0000'], filament_type: ['PLA'],
});

const PLATE_MSC = `<?xml version="1.0"?><config>
  <plate><metadata key="plater_id" value="1"/><model_instance><metadata key="object_id" value="2"/></model_instance></plate>
  <plate><metadata key="plater_id" value="2"/><model_instance><metadata key="object_id" value="4"/></model_instance></plate>
  </config>`;

/** The configs as a host with no zlib passes them: strings, with a size. */
function passedConfigs() {
  return [
    { name: 'Metadata/project_settings.config', size: PLATE_SETTINGS.length, data: PLATE_SETTINGS },
    { name: 'Metadata/model_settings.config', size: PLATE_MSC.length, data: PLATE_MSC },
  ];
}

/** The same file as Node reads it — every member with its bytes. */
function platesAsNode() {
  return [
    { name: '3D/3dmodel.model', data: Buffer.from(PLATE_MODEL) },
    { name: 'Metadata/project_settings.config', data: Buffer.from(PLATE_SETTINGS) },
    { name: 'Metadata/model_settings.config', data: Buffer.from(PLATE_MSC) },
  ];
}

const buildOf = (text) => String(text).match(/<build[\s\S]*?<\/build>/)[0].replace(/\s+/g, ' ');

test('a mesh passed by name does not fail the conversion', () => {
  // No bytes and no layout: the least a host can say about a member.
  const planned = MF.convertMembers(
    [{ name: '3D/3dmodel.model', size: 40 << 20 }, ...passedConfigs()],
    { targetId: 'snapmaker-u1' });

  assert.equal(planned.ok, true, planned.error);
  // Not silently, either — the plates are left where the source slicer put
  // them, and a file whose plates may sit off-centre says so.
  assert.ok(planned.report.warnings.some((w) => /Multi-plate layout was left/.test(w)),
            'the plates were not re-tiled and nothing said so');
});

test('the plates re-tile from the build block alone, exactly as from the whole mesh', () => {
  const opts = { targetId: 'snapmaker-u1' };

  const whole = MF.convertMembers(platesAsNode(), opts);
  assert.equal(whole.report.platesRetiled, 2, 'the Node path stopped re-tiling');

  const byBlock = MF.convertMembers(
    [{ name: '3D/3dmodel.model', size: 40 << 20, build: PLATE_BUILD }, ...passedConfigs()],
    opts);
  assert.equal(byBlock.ok, true, byBlock.error);
  assert.equal(byBlock.report.platesRetiled, 2);

  const mesh = byBlock.members.find((m) => m.name === '3D/3dmodel.model');
  // The mesh does NOT come back — only the block, for the host to splice in.
  assert.equal(mesh.data, undefined, 'the whole mesh came back from a host that never sent it');
  assert.ok(mesh.buildBlock, 'the re-tiled layout has nowhere to go');

  // THE POINT: the same arithmetic, whichever way the file arrived.
  const fromWhole = whole.members.find((m) => m.name === '3D/3dmodel.model');
  assert.equal(buildOf(mesh.buildBlock), buildOf(fromWhole.data));

  // And it really moved: 128 was the source bed's centre, and the target's is
  // not 128. A block that came back identical would pass every check above.
  assert.ok(!/transform="1 0 0 0 1 0 0 0 1 128 128 0"/.test(mesh.buildBlock),
            'the layout came back exactly as it went in');
});
