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
