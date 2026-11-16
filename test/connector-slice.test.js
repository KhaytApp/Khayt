const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const S = require('../lib/connector-slice');

const SHA = '9c1e'.padEnd(64, '0');
const PNG = Buffer.alloc(300, 1).toString('base64');

function capture(over = {}) {
  return {
    v: 1, kind: 'slice', id: '0b6f1d2e3c4a5b6c', idem: 'sha256:' + SHA, at: '2026-11-15T09:12:03Z',
    intent: 'inbox', jobId: null, machineId: null, startPrint: false,
    file: { name: 'Bracket_PLA.gcode', bytes: 18234112, sha256: SHA, type: 'gcode', fileId: null },
    slicer: { name: 'OrcaSlicer', version: '2.5.1', plugin: '0.1.0' },
    printer: { preset: 'Snapmaker U1 (0.4 nozzle)', nozzle: 0.4 },
    process: { preset: '0.20mm Standard @U1', layerHeight: 0.2 },
    plate: { index: 1, name: 'Plate 1', objects: ['Bracket'] },
    timeSec: 3725, layers: 120, toolchanges: 3,
    filaments: [
      { slot: 2, preset: 'Generic PETG @U1', type: 'PETG', colour: '#00aa00', grams: 3.5, cm3: 2.7, mm: 1100, density: 1.27, costPerKg: 25, cost: 0.09 },
      { slot: 1, preset: 'Generic PLA @U1', type: 'PLA', colour: '#FFFFFF', grams: 12.34, cm3: 9.95, mm: 4136.2, density: 1.24, costPerKg: 20, cost: 0.25 },
      { slot: 3, type: 'PLA', grams: 0 },
    ],
    thumbnail: { type: 'png', w: 300, h: 300, b64: PNG },
    ...over,
  };
}

test('a good capture passes, copied field by field, slots in order and empty slots dropped', () => {
  const r = S.check(capture());
  assert.equal(r.ok, true);
  assert.deepEqual(r.dropped, []);
  assert.deepEqual(r.capture.file, { name: 'Bracket_PLA.gcode', bytes: 18234112, sha256: SHA, type: 'gcode' });
  assert.deepEqual(r.capture.filaments.map((f) => f.slot), [1, 2]);
  assert.equal(r.capture.filaments[1].colour, '#00AA00');
  assert.deepEqual(r.capture.suggested, { intent: 'inbox' });
});

test('unknown keys never pass (an allowlist)', () => {
  const r = S.check(capture({ customer: 'Fatima', price: 99, file: { ...capture().file, owner: 'x' } }));
  assert.equal(r.ok, true);
  const json = JSON.stringify(r.capture);
  for (const s of ['customer', 'Fatima', 'price', 'owner', 'fileId', '"kind"']) assert.ok(!json.includes(s), s);
});

test('what binds the file is refused when wrong', () => {
  const cases = [
    [capture({ v: 2 }), 'version'],
    [capture({ kind: 'model' }), 'kind'],
    [capture({ id: 'short' }), 'bad-id'],
    [capture({ file: undefined }), 'no-file'],
    [capture({ file: { ...capture().file, name: '' } }), 'bad-name'],
    [capture({ file: { ...capture().file, name: 'part.stl' } }), 'wrong-kind'],
    [capture({ file: { ...capture().file, bytes: 0 } }), 'bad-size'],
    [capture({ file: { ...capture().file, bytes: 1.5 } }), 'bad-size'],
    [capture({ file: { ...capture().file, bytes: S.MAX_FILE_BYTES + 1 } }), 'too-large'],
    [capture({ file: { ...capture().file, sha256: 'xyz' } }), 'bad-hash'],
    [capture({ idem: 'sha256:' + 'b'.repeat(64) }), 'idem-mismatch'],
    [null, 'not-an-object'],
  ];
  for (const [input, reason] of cases) assert.equal(S.check(input).reason, reason, reason);
});

test('the Mac\'s own cap applies, never above 1 GiB', () => {
  assert.equal(S.check(capture(), { maxFileBytes: 1000 }).reason, 'too-large');
  assert.equal(S.check(capture(), { maxFileBytes: 2 ** 40 }).ok, true);
});

test('file names lose folders and control characters; the kinds the inbox takes', () => {
  const r = S.check(capture({ file: { ...capture().file, name: '../../etc/\u0000plate.GCODE' } }));
  assert.equal(r.capture.file.name, '_.._etc_plate.GCODE');
  assert.equal(S.fileType('a.gcode.3mf'), 'gcode.3mf');
  assert.equal(S.fileType('a.bgcode'), 'bgcode');
  assert.equal(S.fileType('a.gco'), 'gcode');
  assert.equal(S.fileType('a.3mf'), null);
});

test('intents are only suggestions; v1 never starts a print but keeps what was asked', () => {
  assert.deepEqual(S.check(capture({ intent: 'attach', jobId: 'J-1042' })).capture.suggested, { intent: 'attach', jobId: 'J-1042' });
  assert.deepEqual(S.check(capture({ intent: 'print', machineId: 'm_1', startPrint: true })).capture.suggested,
    { intent: 'print', machineId: 'm_1', startPrint: true });
  const noJob = S.check(capture({ intent: 'attach' }));
  assert.deepEqual(noJob.capture.suggested, { intent: 'inbox' });
  assert.deepEqual(noJob.dropped, ['jobId']);
  const odd = S.check(capture({ intent: 'pause' }));
  assert.deepEqual(odd.capture.suggested, { intent: 'inbox' });
  assert.deepEqual(odd.dropped, ['intent']);
});

test('what only describes the slice is dropped, named, and the file still goes in', () => {
  const r = S.check(capture({
    timeSec: -1, layers: 'many',
    filaments: [{ slot: 0, grams: 1 }, { slot: 1, grams: -2 }, { slot: 1, grams: 1 }, { slot: 1, grams: 2 }],
    thumbnail: { type: 'png', w: 300, h: 300, b64: Buffer.alloc(S.MAX_THUMB_BYTES + 1).toString('base64') },
  }));
  assert.equal(r.ok, true);
  assert.deepEqual(r.dropped.sort(), ['filaments[0]', 'filaments[1]', 'filaments[3]', 'layers', 'thumbnail', 'timeSec'].sort());
  assert.deepEqual(r.capture.filaments.map((f) => [f.slot, f.grams]), [[1, 1]]);
  assert.equal(r.capture.thumbnail, undefined);
});

test('shared vectors (docs/connector-capture.vectors.json) match, for the plugin to check against', () => {
  const v = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'docs', 'connector-capture.vectors.json'), 'utf8'));
  assert.ok(v.cases.length >= 6);
  for (const c of v.cases) assert.deepEqual(S.check(c.input, c.opts), c.expect, c.name);
});
