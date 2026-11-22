/**
 * Converting a 3MF that is mostly geometry.
 *
 * Measured against a real 229 MB Bambu poster (19 meshes, 1168 MB inflated) that the
 * converter could not open at all: the front door refused it at 200 MB, and with that
 * raised the member budget dropped one of them — 240 MB of geometry — without a word,
 * then reported a successful convert.
 *
 * The file itself can't live in the repo, so these pin the two behaviours it exposed on
 * a small archive of the same shape: geometry nobody rewrote is copied across still
 * compressed, and a read that has to leave parts behind refuses instead of writing a
 * model quietly smaller than the one it was given.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const zlib = require('node:zlib');

const { convert, analyze, readMembers } = require('../lib/mf-convert');
const { writeZip } = require('../lib/zip-write');
const { openZip, listEntries } = require('../lib/zip-read');

/**
 * Store a member at a CHOSEN compression level.
 *
 * The meshes in these fixtures are deflated at level 1, and that detail is what makes the
 * passthrough assertions mean anything. zip-write compresses at level 9, so a convert that
 * inflates a mesh and deflates it again lands on the level-9 length — while a convert that
 * copies the stored bytes keeps the level-1 one. Build the fixture with the same level the
 * writer uses and both paths produce identical bytes, so the test passes either way and
 * proves nothing. (It did, until an honest mutant walked through all seven.)
 */
function storedAt(data, level) {
  return { method: 8, comp: zlib.deflateRawSync(data, { level }), crc: zlib.crc32(data) >>> 0, size: data.length };
}
const SOURCE_LEVEL = 1;

const CT = '<?xml version="1.0" encoding="UTF-8"?>\n'
  + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
  + '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>';

/** One object mesh, big and repetitive enough that DEFLATE is the obvious choice. */
function meshXml(seed, tris) {
  const v = [];
  const t = [];
  for (let i = 0; i < tris; i++) {
    const b = i * 3;
    for (let k = 0; k < 3; k++) v.push(`<vertex x="${seed + i}.5" y="${k}.25" z="${(i % 7)}.125"/>`);
    t.push(`<triangle v1="${b}" v2="${b + 1}" v3="${b + 2}"/>`);
  }
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">'
    + `<resources><object id="${seed}" type="model"><mesh><vertices>${v.join('')}</vertices>`
    + `<triangles>${t.join('')}</triangles></mesh></object></resources>`
    + `<build><item objectid="${seed}" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>`;
}

const PROJECT = JSON.stringify({
  filament_colour: ['#FF0000', '#00FF00', '#0000FF'],
  printable_area: ['0x0', '256x0', '256x256', '0x256'],
  printer_model: 'Bambu Lab P1S',
});

/** A Bambu-flavoured 3MF whose bulk is meshes — the shape of the file that broke. */
function bigish({ objects = 6, tris = 400 } = {}) {
  const members = [
    { name: '[Content_Types].xml', data: Buffer.from(CT, 'utf8') },
    { name: '_rels/.rels', data: Buffer.from('<?xml version="1.0"?><Relationships/>', 'utf8') },
    { name: 'Metadata/project_settings.config', data: Buffer.from(PROJECT, 'utf8') },
    { name: 'Metadata/slice_info.config', data: Buffer.from('<config><header/></config>', 'utf8') },
    { name: '3D/3dmodel.model', data: Buffer.from(meshXml(1, 4), 'utf8') },
  ];
  for (let i = 1; i <= objects; i++) {
    members.push({ name: `3D/Objects/object_${i}.model`, raw: storedAt(Buffer.from(meshXml(i + 1, tris), 'utf8'), SOURCE_LEVEL) });
  }
  return writeZip(members);
}

const entriesByName = (buf) => new Map(listEntries(buf).map((e) => [e.name, e]));
const meshNames = (buf) => listEntries(buf).map((e) => e.name).filter((n) => /Objects\/.*\.model$/i.test(n));

test('normalizing keeps every object mesh byte-for-byte', () => {
  const src = bigish();
  const res = convert(src, { targetId: 'generic', mode: 'normalize' });
  assert.equal(res.ok, true, res.error);

  const zin = openZip(src), zout = openZip(res.buffer);
  const names = meshNames(src);
  assert.ok(names.length >= 6, 'fixture should carry several objects');
  for (const n of names) {
    assert.deepEqual(zout.file(n), zin.file(n), n + ' must survive a normalize unchanged');
  }
});

test('an untouched mesh is copied across still compressed, not deflated again', () => {
  const src = bigish();
  const res = convert(src, { targetId: 'generic', mode: 'normalize' });
  assert.equal(res.ok, true, res.error);

  const before = entriesByName(src), after = entriesByName(res.buffer);
  for (const n of meshNames(src)) {
    const a = before.get(n), b = after.get(n);
    const plain = openZip(src).file(n);
    const ifRecompressed = zlib.deflateRawSync(plain, { level: 9 }).length;

    // Without this the rest is theatre: if the two levels happen to agree on this
    // payload, "kept its stored length" cannot tell passthrough from a round trip.
    assert.notEqual(a.compSize, ifRecompressed,
      n + ': fixture must be stored at a level zip-write would not reproduce');

    assert.equal(b.method, a.method, n + ': same storage method');
    assert.equal(b.crc, a.crc, n + ': the source CRC is carried through');
    assert.equal(b.compSize, a.compSize,
      n + ': kept the length it was STORED at — a re-deflate would have landed on ' + ifRecompressed);
  }
});

test('retargeting rewrites the config and still passes the object meshes through', () => {
  const src = bigish();
  const res = convert(src, { targetId: 'bambu-a1' });
  assert.equal(res.ok, true, res.error);

  const zin = openZip(src), zout = openZip(res.buffer);
  for (const n of meshNames(src)) {
    assert.deepEqual(zout.file(n), zin.file(n), n + ' is not touched by a retarget');
  }
  assert.notDeepEqual(
    zout.file('Metadata/project_settings.config'),
    zin.file('Metadata/project_settings.config'),
    'the config IS rewritten — otherwise this test proves nothing about passthrough',
  );
});

test('the converted file still analyses as the model it came from', () => {
  const src = bigish();
  const before = analyze(src);
  const res = convert(src, { targetId: 'bambu-a1' });
  assert.equal(res.ok, true, res.error);

  const after = analyze(res.buffer);
  assert.equal(after.ok, true);
  assert.equal(after.hasGeometry, true);
  assert.equal(after.colorCount, before.colorCount, 'colours survive the round trip');
  assert.equal(res.report.verified, true, 'the converter re-validates its own output');
});

test('geometry is inflated only when something actually reads it', () => {
  const members = readMembers(bigish());
  const mesh = members.find((m) => /Objects\/.*\.model$/i.test(m.name));
  assert.ok(mesh, 'meshes should be present');
  assert.ok(Number.isFinite(mesh.size) && mesh.size > 0,
    'a mesh knows its uncompressed length without being inflated');
  assert.ok(mesh.src && mesh.src.comp, 'and carries its stored bytes for passthrough');
  assert.equal(mesh.data.length, mesh.size, 'reading .data inflates it, and to the declared length');
});

test('a read that leaves parts behind refuses the convert instead of shrinking the model', () => {
  // The real trigger is 2 GiB of inflated members, which no test should allocate. The
  // member cap is the same door: fill it with small entries so the meshes behind them
  // are the ones dropped.
  const filler = [];
  for (let i = 0; i < 4200; i++) {
    filler.push({ name: `Metadata/pad_${i}.txt`, data: Buffer.from('x', 'utf8') });
  }
  const src = writeZip([
    { name: '[Content_Types].xml', data: Buffer.from(CT, 'utf8') },
    { name: 'Metadata/project_settings.config', data: Buffer.from(PROJECT, 'utf8') },
    ...filler,
    { name: '3D/3dmodel.model', data: Buffer.from(meshXml(1, 4), 'utf8') },
    { name: '3D/Objects/object_1.model', data: Buffer.from(meshXml(2, 200), 'utf8') },
  ]);

  const members = readMembers(src);
  assert.ok(members.truncated, 'the read should record what it could not take');
  assert.ok(members.truncated.members > 0);

  const res = convert(src, { targetId: 'generic', mode: 'normalize' });
  assert.equal(res.ok, false, 'a partial model must not be written as a successful convert');
  assert.match(res.error, /too large to convert in one piece/);
  assert.match(res.error, /would be left out/);

  assert.ok(analyze(src).truncated, 'and analyze says so too, before the maker hits convert');
});

test('an ordinary file reports no truncation at all', () => {
  const members = readMembers(bigish());
  assert.equal(members.truncated, null, 'nothing was dropped');
  assert.equal(analyze(bigish()).truncated, null);
});
