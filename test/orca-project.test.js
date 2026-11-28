'use strict';
/**
 * A model with no settings, made into a project 3MF for an Orca fork, on
 * Windows/Linux (lib/main/orca-project.js; the Mac's fix, #2731): Snapmaker
 * Orca 2.4.1 segfaults on preset flags, so the presets go INSIDE the project
 * and the slicer gets no flags.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const O = require('../lib/main/orca-project.js');
const P = require('../lib/slicer-project.js');
const ZipRead = require('../lib/zip-read.js');
const ZipWrite = require('../lib/zip-write.js');

const FIX = path.join(__dirname, 'fixtures', 'orca-project');
const TRIS = JSON.parse(fs.readFileSync(path.join(FIX, 'cube-tris.json'), 'utf8'));
const GOLDEN = fs.readFileSync(path.join(FIX, 'cube-3dmodel.model'), 'utf8');
const MACHINE = { name: 'U1', printable_area: ['0x0', '270x0', '270x270', '0x270'] };
const SETTINGS = P.configMember(JSON.stringify({ printer_settings_id: 'U1', from: 'project' }, null, 1)).text;

function binaryStl(tris) {
  const b = Buffer.alloc(84 + tris.length * 50);
  b.writeUInt32LE(tris.length, 80);
  tris.forEach((t, i) => {
    let off = 84 + i * 50 + 12;
    for (const v of t) for (const x of v) { b.writeFloatLE(x, off); off += 4; }
  });
  return b;
}
function asciiStl(tris) {
  return 'solid cube\n' + tris.map((t) => ' facet normal 0 0 0\n  outer loop\n'
    + t.map((v) => `   vertex ${v[0]} ${v[1]} ${v[2]}\n`).join('') + '  endloop\n endfacet\n').join('') + 'endsolid cube\n';
}
const tmpdir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'orca-proj-'));
const members = (file) => {
  const buf = fs.readFileSync(file);
  const out = {};
  for (const e of ZipRead.listEntries(buf)) out[e.name] = ZipRead.readEntry(buf, e);
  return out;
};

test('golden: an STL becomes a project whose model is exactly the shared rule\'s, standing on the bed, with the settings inside', () => {
  // The fixture is the shared modelXml (which the Mac's Parity tests pin), checked in.
  assert.equal(P.modelXml(TRIS, P.bedCentre(MACHINE)), GOLDEN, 'the shared rule still gives the checked-in model');
  const dir = tmpdir();
  try {
    for (const [kind, data] of [['binary', binaryStl(TRIS)], ['ascii', asciiStl(TRIS)]]) {
      const stl = path.join(dir, `cube-${kind}.stl`);
      fs.writeFileSync(stl, data);
      const out = path.join(dir, `cube-${kind}.3mf`);
      const r = O.buildStlProject({ stlPath: stl, outPath: out, settingsJson: SETTINGS, machine: MACHINE });
      assert.equal(r.ok, true, kind + ': ' + r.error);
      assert.deepEqual(r.counts, { vertices: 8, triangles: 12 });
      const m = members(out);
      assert.deepEqual(Object.keys(m), ['[Content_Types].xml', '_rels/.rels', '3D/3dmodel.model', 'Metadata/project_settings.config'], kind);
      assert.equal(m['3D/3dmodel.model'].toString('utf8'), GOLDEN, kind + ': streamed in pieces, byte for byte the golden model');
      assert.equal(m['Metadata/project_settings.config'].toString('utf8'), SETTINGS);
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('the streamed zip is a real zip: CRCs check, and the system unzip agrees when there is one', () => {
  const dir = tmpdir();
  try {
    const stl = path.join(dir, 'c.stl');
    fs.writeFileSync(stl, binaryStl(TRIS));
    const out = path.join(dir, 'c.3mf');
    assert.equal(O.buildStlProject({ stlPath: stl, outPath: out, settingsJson: SETTINGS, machine: MACHINE }).ok, true);
    const buf = fs.readFileSync(out);
    for (const e of ZipRead.listEntries(buf)) {
      const data = ZipRead.readEntry(buf, e);
      assert.equal(O.crcUpdate(0, data), e.crc >>> 0, e.name);
      assert.equal(ZipWrite.crc32(data) >>> 0, e.crc >>> 0, e.name + ': the same CRC as zip-write\'s');
    }
    const u = spawnSync('unzip', ['-t', out], { encoding: 'utf8' });
    if (u.status !== null && !u.error) assert.equal(u.status, 0, u.stdout + u.stderr);
    // Pieces: a CRC fed in pieces is the CRC of the whole.
    const whole = Buffer.from('a million triangles, never one string');
    assert.equal(O.crcUpdate(O.crcUpdate(0, whole.subarray(0, 7)), whole.subarray(7)), O.crcUpdate(0, whole));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('over the cap: refused with the Mac\'s sentence, nothing written', () => {
  const dir = tmpdir();
  try {
    const stl = path.join(dir, 'big.stl');
    fs.writeFileSync(stl, binaryStl(TRIS));
    const out = path.join(dir, 'big.3mf');
    const r = O.buildStlProject({ stlPath: stl, outPath: out, settingsJson: SETTINGS, machine: MACHINE, maxBytes: 100 });
    assert.deepEqual(r, { ok: false, error: O.TOO_LARGE });
    assert.equal(fs.existsSync(out), false);
    assert.equal(O.MAX_STL_BYTES, 150 * 1024 * 1024, 'the Mac\'s cap');
    // Not an STL at all, or no triangles: refused, not a crash.
    fs.writeFileSync(stl, 'hello');
    assert.equal(O.buildStlProject({ stlPath: stl, outPath: out, settingsJson: SETTINGS, machine: MACHINE }).ok, false);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('a 3MF with no project settings: the config is ADDED, every other member byte for byte', () => {
  const dir = tmpdir();
  try {
    const src = path.join(dir, 'model.3mf');
    const big = Buffer.alloc(200000, 'v');
    fs.writeFileSync(src, ZipWrite.writeZip([
      { name: '[Content_Types].xml', data: '<Types/>' },
      { name: '3D/3dmodel.model', data: big },                          // deflated
      { name: 'Metadata/model_settings.config', data: '<config/>', store: true },
      { name: 'Metadata/plate_1.png', data: Buffer.from([1, 2, 3]), store: true },
    ]));
    const out = path.join(dir, 'project.3mf');
    const r = O.addProjectConfig({ modelPath: src, outPath: out, settingsJson: SETTINGS });
    assert.equal(r.ok, true, r.error);
    const before = fs.readFileSync(src), after = fs.readFileSync(out);
    const eb = ZipRead.listEntries(before), ea = ZipRead.listEntries(after);
    assert.deepEqual(ea.map((e) => e.name), [...eb.map((e) => e.name), 'Metadata/project_settings.config']);
    for (const e of eb) {
      const a = ea.find((x) => x.name === e.name);
      assert.deepEqual([a.method, a.crc, a.size], [e.method, e.crc, e.size], e.name);
      assert.ok(ZipRead.readEntryRaw(after, a).comp.equals(ZipRead.readEntryRaw(before, e).comp), e.name + ': still compressed, the same bytes');
    }
    assert.equal(ZipRead.readEntry(after, ea[ea.length - 1]).toString('utf8'), SETTINGS);
    assert.equal(P.plan(out, ea.map((e) => e.name)), 'as-is', 'now a project');
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('main.js: a model that needs presets is sliced as a project, with NO preset flags', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const run = src.slice(src.indexOf('async function runSlice('), src.indexOf('const rmDir = '));
  assert.match(run, /target = sliceTarget\(bare, modelPath, outDir\)/);
  assert.match(run, /sliceArgv\(args, \{ model: target\.path, output: outPath, outdir: outDir, slicer: slicerPath \}\)/);
  assert.doesNotMatch(run, /presets: bare\.presets/, 'no presets handed to sliceArgv');
  const bare = src.slice(src.indexOf('function bareModelPresetsUnsafe('), src.indexOf('function sliceTarget('));
  assert.doesNotMatch(bare, /presetFileJson|khayt-\$\{kind\}\.json/, 'no preset files written for flags');
  const tgt = src.slice(src.indexOf('function sliceTarget('), src.indexOf('async function runSlice('));
  for (const k of ["'as-is'", "'unsupported'", 'buildStlProject', 'addProjectConfig', 'projectSettingsJson']) assert.ok(tgt.includes(k), k);
});
