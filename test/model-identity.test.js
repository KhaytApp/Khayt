/**
 * Recognising a model the shop already has.
 *
 * The case that matters is not tidiness. A repeat customer sends the same
 * bracket they sent in March; without this it becomes a second library entry
 * with no history, and the shop re-slices a part it already has a known-good
 * setup and a measured cost for.
 *
 * The load-bearing distinction, and most of what these tests check: identical
 * BYTES is a certainty, identical GEOMETRY is a hint. Presenting the second as
 * the first would eventually merge two different customers' parts, which is far
 * worse than missing a duplicate.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { contentHash, geometryKey, identify, findMatches, duplicateGroups } = require('../lib/model-identity.js');
const { parseObj } = require('../lib/obj-parse.js');

const CUBE = ['v 0 0 0', 'v 20 0 0', 'v 20 20 0', 'v 0 20 0',
  'v 0 0 20', 'v 20 0 20', 'v 20 20 20', 'v 0 20 20',
  'f 1 4 3', 'f 1 3 2', 'f 5 6 7', 'f 5 7 8', 'f 1 2 6', 'f 1 6 5',
  'f 2 3 7', 'f 2 7 6', 'f 3 4 8', 'f 3 8 7', 'f 4 1 5', 'f 4 5 8'].join('\n');

test('the same bytes hash the same, different bytes do not', () => {
  assert.equal(contentHash(CUBE), contentHash(CUBE));
  assert.notEqual(contentHash(CUBE), contentHash(CUBE + '\n'));
  assert.match(contentHash(CUBE), /^[0-9a-f]{64}$/, 'sha-256 hex');
});

test('a hash is computed the same way whatever container it arrives in', () => {
  // The renderer hands over an ArrayBuffer, the main process a Buffer.
  const buf = Buffer.from(CUBE, 'utf8');
  const expected = contentHash(buf);
  assert.equal(contentHash(new Uint8Array(buf)), expected);
  assert.equal(contentHash(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength)), expected);
  assert.equal(contentHash(CUBE), expected);
});

test('an empty file has no identity', () => {
  // Hashing it would give every empty file the same one, so the next empty file
  // would "already exist".
  for (const empty of ['', Buffer.alloc(0), new Uint8Array(0), null, undefined]) {
    assert.equal(contentHash(empty), null, JSON.stringify(empty));
  }
  assert.equal(contentHash(42), null);
  assert.equal(contentHash({}), null);
});

test('geometry survives a re-container, which is exactly what it is for', () => {
  // The same STL saved binary instead of ascii, or wrapped into a 3MF: different
  // bytes, same part. A hash misses that; the geometry key catches it.
  const reformatted = CUBE.replace(/\n/g, '\r\n').replace(/^f /gm, 'f  ');
  assert.notEqual(contentHash(CUBE), contentHash(reformatted), 'the bytes really did change');
  assert.equal(geometryKey(parseObj(CUBE)), geometryKey(parseObj(reformatted)));
});

test('a genuinely different part gets a different key', () => {
  const bigger = CUBE.replace(/20/g, '40');
  assert.notEqual(geometryKey(parseObj(CUBE)), geometryKey(parseObj(bigger)));
});

test('a re-meshed part is NOT the same part', () => {
  // Triangle count is matched exactly on purpose. A re-mesh slices differently,
  // so for a print shop it is a different model however similar it looks.
  const a = { triangleCount: 12, volumeMm3: 8000, bbox: { x: 20, y: 20, z: 20 } };
  const b = { triangleCount: 4800, volumeMm3: 8000, bbox: { x: 20, y: 20, z: 20 } };
  assert.notEqual(geometryKey(a), geometryKey(b));
});

test('geometry with no substance has no key', () => {
  // Otherwise every unparsed model would share an identity with every other.
  for (const g of [
    null, undefined, {},
    { triangleCount: 0, volumeMm3: 8000, bbox: { x: 1, y: 1, z: 1 } },
    { triangleCount: 12, volumeMm3: 0, bbox: { x: 1, y: 1, z: 1 } },
    { triangleCount: 12, volumeMm3: 8000 },
    { triangleCount: 12, volumeMm3: 8000, bbox: { x: NaN, y: 1, z: 1 } },
    { triangleCount: -5, volumeMm3: 10, bbox: { x: 1, y: 1, z: 1 } },
  ]) {
    assert.equal(geometryKey(g), null, JSON.stringify(g));
  }
});

test('tiny float noise does not split one part into two', () => {
  const a = { triangleCount: 12, volumeMm3: 8000.001, bbox: { x: 20.001, y: 20, z: 20 } };
  const b = { triangleCount: 12, volumeMm3: 8000.004, bbox: { x: 20.002, y: 20, z: 20 } };
  assert.equal(geometryKey(a), geometryKey(b));
});

test('an exact match is never ALSO reported as a look-alike', () => {
  // The caller shows a different sentence for each. A record in both lists would
  // be described two ways at once.
  const lib = [
    { id: 'a', contentHash: 'h1', geometryKey: 'k1' },
    { id: 'b', contentHash: 'h2', geometryKey: 'k1' },
  ];
  const m = findMatches(lib, { contentHash: 'h1', geometryKey: 'k1' });
  assert.deepEqual(m.exact.map((r) => r.id), ['a']);
  assert.deepEqual(m.similar.map((r) => r.id), ['b']);
  const ids = new Set([...m.exact, ...m.similar].map((r) => r.id));
  assert.equal(ids.size, m.exact.length + m.similar.length, 'the two lists are disjoint');
});

test('a record never matches itself', () => {
  // Re-checking an existing entry after an edit must not report it duplicates
  // itself.
  const lib = [{ id: 'a', contentHash: 'h1', geometryKey: 'k1' }];
  const m = findMatches(lib, { id: 'a', contentHash: 'h1', geometryKey: 'k1' });
  assert.deepEqual(m.exact, []);
  assert.deepEqual(m.similar, []);
});

test('a candidate with no identity matches nothing', () => {
  // An unreadable file must not be declared a duplicate of every other
  // unreadable file.
  const lib = [
    { id: 'a', contentHash: null, geometryKey: null },
    { id: 'b', contentHash: 'h1', geometryKey: 'k1' },
  ];
  const m = findMatches(lib, { contentHash: null, geometryKey: null });
  assert.deepEqual(m.exact, []);
  assert.deepEqual(m.similar, []);
});

test('records with no identity are never matched against', () => {
  // Older library entries predate hashing entirely.
  const lib = [{ id: 'old' }, { id: 'a', contentHash: 'h1' }];
  const m = findMatches(lib, { contentHash: 'h1', geometryKey: 'k1' });
  assert.deepEqual(m.exact.map((r) => r.id), ['a']);
  assert.deepEqual(m.similar, []);
});

test('findMatches tolerates junk', () => {
  for (const bad of [null, undefined, 'nope', [null, 5, 'x']]) {
    const m = findMatches(bad, { contentHash: 'h1' });
    assert.deepEqual(m.exact, [], JSON.stringify(bad));
  }
  assert.doesNotThrow(() => findMatches([{ id: 'a' }], null));
});

test('identify builds both fields from one file', () => {
  const id = identify({ bytes: CUBE, geometry: parseObj(CUBE) });
  assert.match(id.contentHash, /^[0-9a-f]{64}$/);
  assert.equal(id.geometryKey, '12:8000:20x20x20');

  // A G-code file has no mesh, and gets a hash but no geometry key.
  const gcode = identify({ bytes: '; a gcode file\nG28\n', geometry: null });
  assert.match(gcode.contentHash, /^[0-9a-f]{64}$/);
  assert.equal(gcode.geometryKey, null);
});

test('duplicate groups find byte-identical entries, biggest first', () => {
  const lib = [
    { id: 'a', contentHash: 'h1' }, { id: 'b', contentHash: 'h1' }, { id: 'c', contentHash: 'h1' },
    { id: 'd', contentHash: 'h2' }, { id: 'e', contentHash: 'h2' },
    { id: 'f', contentHash: 'h3' },
    { id: 'g' },
  ];
  const groups = duplicateGroups(lib);
  assert.equal(groups.length, 2, 'only genuine duplicates form a group');
  assert.deepEqual(groups[0].map((r) => r.id), ['a', 'b', 'c']);
  assert.deepEqual(groups[1].map((r) => r.id), ['d', 'e']);
  assert.deepEqual(duplicateGroups([{ id: 'x' }, { id: 'y' }]), [],
    'entries with no hash are not all duplicates of each other');
  assert.deepEqual(duplicateGroups(null), []);
});

test('in a sandboxed renderer it degrades instead of throwing', () => {
  // The renderer runs with contextIsolation and sandbox on, so there is no
  // `require` and no node:crypto. Hashing happens in the main process at
  // import; the renderer only ever COMPARES stored hashes. Loading the module
  // there must not take the print library down.
  const vm = require('node:vm');
  const fs = require('node:fs');
  const path = require('node:path');
  const ctx = {};                       // no require, no module — like the page
  vm.createContext(ctx);
  // BOTH files, in the order index.html loads them. `geometryKey` moved into
  // lib/geometry-key.js so the Mac app could bundle it — model-identity falls
  // back to require('crypto') and a bundled module may not name Node — and the
  // page therefore loads two scripts where it loaded one. Loading only the
  // second here would be testing a page that does not exist; what is still
  // being tested is that neither of them needs `require`.
  for (const file of ['lib/geometry-key.js', 'lib/model-identity.js']) {
    vm.runInContext('var globalThis = this;' + fs.readFileSync(path.join(__dirname, '..', file), 'utf8'), ctx);
  }
  const sandboxed = ctx.KhaytModelIdentity;
  assert.ok(sandboxed, 'the module loads at all');
  assert.equal(sandboxed.contentHash('anything'), null, 'no hasher — no hash, and no crash');
  // The two things the renderer actually needs still work there.
  assert.equal(sandboxed.geometryKey({ triangleCount: 12, volumeMm3: 8000, bbox: { x: 20, y: 20, z: 20 } }),
    '12:8000:20x20x20');
  assert.equal(sandboxed.findMatches([{ id: 'a', contentHash: 'h1' }], { contentHash: 'h1' }).exact.length, 1);
});

test('an injected hasher is used in preference to node:crypto', () => {
  let saw = null;
  const fake = { createHash: () => ({ update(b) { saw = b; return this; }, digest: () => 'deadbeef' }) };
  assert.equal(contentHash('abc', fake), 'deadbeef');
  assert.ok(Buffer.isBuffer(saw), 'the bytes reach the hasher as a Buffer');
});
