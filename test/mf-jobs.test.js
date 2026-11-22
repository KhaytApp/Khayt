/**
 * The converter's jobs, run the way the worker process runs them.
 *
 * lib/mf-jobs.js is the whole of the expensive work with the Electron taken out, so it can
 * be driven here directly — same code the utilityProcess executes, same code main.js falls
 * back to when no child will start.
 *
 * The property that matters most is that `run` NEVER throws. Its caller is a pipe: an
 * exception that escapes doesn't reject a promise, it kills the process and takes every
 * other job in flight with it. Missing files, unreadable ones, oversized ones and job names
 * nobody implements all have to come back as results.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const jobs = require('../lib/mf-jobs');
const { writeZip } = require('../lib/zip-write');
const { openZip } = require('../lib/zip-read');
const { analyze } = require('../lib/mf-convert');
const { trianglesToStl } = require('../lib/mf-write');

const CT = '<?xml version="1.0" encoding="UTF-8"?>\n'
  + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
  + '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>';

const TRIS = [
  [[0, 0, 0], [10, 0, 0], [0, 10, 0]],
  [[0, 0, 0], [0, 10, 0], [0, 0, 10]],
  [[0, 0, 0], [0, 0, 10], [10, 0, 0]],
  [[10, 0, 0], [0, 10, 0], [0, 0, 10]],
];

function modelXml() {
  const v = [], t = [];
  TRIS.forEach((tri, i) => {
    tri.forEach((p) => v.push(`<vertex x="${p[0]}" y="${p[1]}" z="${p[2]}"/>`));
    t.push(`<triangle v1="${i * 3}" v2="${i * 3 + 1}" v3="${i * 3 + 2}"/>`);
  });
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
    + `<resources><object id="1" type="model"><mesh><vertices>${v.join('')}</vertices>`
    + `<triangles>${t.join('')}</triangles></mesh></object></resources>`
    + '<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>';
}

const PROJECT = JSON.stringify({
  filament_colour: ['#FF0000', '#00FF00'],
  printable_area: ['0x0', '256x0', '256x256', '0x256'],
  printer_model: 'Bambu Lab P1S',
});

let DIR = null;
function dir() {
  if (!DIR) DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-mfjobs-'));
  return DIR;
}
function put(name, data) {
  const p = path.join(dir(), name);
  fs.writeFileSync(p, data);
  return p;
}
const src3mf = () => put('in.3mf', writeZip([
  { name: '[Content_Types].xml', data: Buffer.from(CT, 'utf8') },
  { name: 'Metadata/project_settings.config', data: Buffer.from(PROJECT, 'utf8') },
  { name: '3D/3dmodel.model', data: Buffer.from(modelXml(), 'utf8') },
]));
const srcStl = () => put('in.stl', trianglesToStl(TRIS));
const out = (ext) => path.join(dir(), `out-${Math.random().toString(36).slice(2)}.${ext}`);

test('analyze reads the file itself and reports what convert would see', async () => {
  const p = src3mf();
  const r = await jobs.run('analyze', { src: p, maxBytes: 50e6 });
  assert.equal(r.ok, true);
  assert.equal(r.hasGeometry, true);
  assert.deepEqual(r.filaments.map((f) => f.color), ['#FF0000', '#00FF00']);
  // Same answer as calling the library straight, since it IS the library.
  assert.equal(r.colorCount, analyze(fs.readFileSync(p)).colorCount);
});

test('convert writes its result to the caller-chosen path, not back over the pipe', async () => {
  const dest = out('3mf');
  const r = await jobs.run('convert', {
    src: src3mf(), maxBytes: 50e6, tmpOut: dest, opts: { targetId: 'generic', mode: 'normalize' },
  });
  assert.equal(r.ok, true, r.error);
  assert.equal(r.tmpPath, dest);
  assert.ok(!('buffer' in r), 'the converted bytes must not travel in the result');
  assert.equal(fs.statSync(dest).size, r.size, 'the reported size is the file on disk');
  assert.ok(r.report, 'the report does come back — it is small');

  const back = analyze(fs.readFileSync(dest));
  assert.equal(back.ok, true);
  assert.equal(back.hasGeometry, true);
});

test('mfToStl and stlTo3mf both produce a real file', async () => {
  const stlPath = out('stl');
  const a = await jobs.run('mfToStl', { src: src3mf(), maxBytes: 50e6, tmpOut: stlPath });
  assert.equal(a.ok, true, a.error);
  assert.equal(a.triangleCount, TRIS.length);
  assert.equal(fs.statSync(stlPath).size, 84 + TRIS.length * 50, 'binary STL of the right length');

  const mfPath = out('3mf');
  const b = await jobs.run('stlTo3mf', { src: srcStl(), maxBytes: 50e6, tmpOut: mfPath });
  assert.equal(b.ok, true, b.error);
  assert.equal(b.report.triangleCount, TRIS.length);
  assert.ok(openZip(fs.readFileSync(mfPath)).file('3D/3dmodel.model'), 'a readable 3MF came out');
});

test('mesh returns geometry for the preview, keyed off the file extension', async () => {
  const a = await jobs.run('mesh', { src: src3mf(), maxBytes: 50e6 });
  assert.equal(a.ok, true, a.error);
  assert.equal(a.count, TRIS.length);
  assert.equal(a.verts.length, TRIS.length * 9);

  const b = await jobs.run('mesh', { src: srcStl(), maxBytes: 50e6 });
  assert.equal(b.ok, true, b.error);
  assert.equal(b.count, TRIS.length);
});

test('the size ceiling belongs to the caller, and is enforced before the work', async () => {
  const p = src3mf();
  const big = fs.statSync(p).size;
  const r = await jobs.run('analyze', { src: p, maxBytes: big - 1 });
  assert.equal(r.ok, false);
  assert.match(r.error, /too large/i);
});

test('run never throws — every failure comes back as a result', async () => {
  const cases = [
    ['missing file', 'analyze', { src: path.join(dir(), 'nope.3mf'), maxBytes: 50e6 }],
    ['unknown job', 'frobnicate', { src: src3mf() }],
    ['no args at all', 'analyze', undefined],
    ['undefined source', 'convert', { tmpOut: out('3mf') }],
    ['unwritable destination', 'convert', {
      src: src3mf(), maxBytes: 50e6, tmpOut: path.join(dir(), 'no', 'such', 'dir', 'x.3mf'),
      opts: { targetId: 'generic', mode: 'normalize' },
    }],
  ];
  for (const [why, op, args] of cases) {
    const r = await jobs.run(op, args);
    assert.equal(typeof r, 'object', why + ': should resolve to a result');
    assert.equal(r.ok, false, why + ': should report failure');
    assert.equal(typeof r.error, 'string', why + ': should say why');
  }
});

test('an unknown job names itself, so a typo in a handler is findable', async () => {
  const r = await jobs.run('convertt', {});
  assert.match(r.error, /Unknown job: convertt/);
});

test('every op main.js dispatches actually exists', () => {
  for (const op of ['analyze', 'mesh', 'fsPlan', 'bands', 'convert', 'stlTo3mf', 'mfToStl']) {
    assert.ok(jobs.OPS.includes(op), op + ' must be implemented');
  }
});

test.after(() => { if (DIR) fs.rmSync(DIR, { recursive: true, force: true }); });
