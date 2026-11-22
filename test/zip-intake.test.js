/**
 * What comes out of a dropped .zip.
 *
 * Model packs arrive as archives and Khayt could not open one — every file had
 * to be unzipped by hand and dragged in individually.
 *
 * The planning is where the dangerous cases live, so it is tested away from any
 * real archive. Three failure modes, in order of how badly they end:
 *
 *   ZIP SLIP     a member named ../../../.ssh/authorized_keys writing outside
 *                the destination
 *   ZIP BOMB     a few KB inflating to gigabytes
 *   SILENT LOSS  a budget that drops files without saying so — the bug
 *                lib/mf-convert.js shipped once, against a real 229 MB poster
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { plan, safeName, summarize, PRINT_EXT } = require('../lib/zip-intake.js');

const entry = (name, size = 100) => ({ name, size });

// --------------------------------------------------------------- zip slip

test('a member cannot escape the destination, however it is spelled', () => {
  // The defence is basename-only, so none of these have anywhere to go.
  const cases = [
    '../../../.ssh/authorized_keys.stl',
    '..\\..\\..\\Windows\\System32\\evil.stl',
    '/etc/cron.d/payload.stl',
    'C:\\Users\\me\\Desktop\\x.stl',
    'a/b/../../../../out.stl',
    './././deep/../x.stl',
  ];
  for (const c of cases) {
    const n = safeName(c, []);
    assert.ok(!n.includes('/') && !n.includes('\\'), `${c} kept a separator: ${n}`);
    assert.ok(!n.startsWith('..'), `${c} kept a traversal: ${n}`);
    assert.ok(n.length > 0, `${c} produced an empty name`);
  }
});

test('a member whose whole name is dots still gets a usable name', () => {
  for (const c of ['..', '.', '...', '../', 'a/..']) {
    const n = safeName(c, []);
    assert.ok(n && !/^\.+$/.test(n), `${c} -> ${n}`);
  }
});

test('control characters and NUL are stripped from the name', () => {
  const n = safeName('mo\u0000del\u0007.stl', []);
  assert.ok(!/[\u0000-\u001f]/.test(n), `control chars survived: ${JSON.stringify(n)}`);
});

test('two members that share a basename both survive', () => {
  // parts/a.stl and spares/a.stl collide once the folders are gone. Losing one
  // silently is the same class of bug as the budget dropping files.
  const taken = [];
  const a = safeName('parts/a.stl', taken); taken.push(a);
  const b = safeName('spares/a.stl', taken); taken.push(b);
  const c = safeName('extra/a.stl', taken);
  assert.equal(a, 'a.stl');
  assert.notEqual(b, a);
  assert.notEqual(c, a);
  assert.notEqual(c, b);
  for (const n of [b, c]) assert.match(n, /\.stl$/, `${n} lost its extension — it would not open`);
});

test('collision matching is case-insensitive', () => {
  // Two files differing only in case collide on a case-insensitive volume,
  // which is the default on macOS — where this app mostly runs.
  const n = safeName('B/Model.STL', ['model.stl']);
  assert.notEqual(n.toLowerCase(), 'model.stl');
});

// ------------------------------------------------------------ what is taken

test('only print files are taken, and the rest are named not dropped', () => {
  const p = plan([
    entry('parts/body.stl'), entry('README.txt'), entry('preview.png'),
    entry('plate.3mf'), entry('notes/licence.pdf'), entry('bench.gcode'),
    entry('x.obj'), entry('y.gco'),
  ]);
  assert.deepEqual(p.take.map((t) => t.name).sort(), ['bench.gcode', 'body.stl', 'plate.3mf', 'x.obj', 'y.gco']);
  assert.deepEqual(p.skipped.map((s) => s.name).sort(), ['README.txt', 'notes/licence.pdf', 'preview.png']);
  for (const s of p.skipped) assert.equal(s.reason, 'not-a-print-file');
});

test('directory entries are not files', () => {
  const p = plan([entry('parts/', 0), entry('parts\\', 0), entry('parts/a.stl')]);
  assert.equal(p.take.length, 1);
  assert.equal(p.skipped.length, 0, 'a folder was reported as a skipped file');
});

test("macOS's __MACOSX shadow tree is ignored without cluttering the report", () => {
  // A zip made on a Mac carries AppleDouble stubs. Listing them as skips buries
  // the real skips under junk.
  const p = plan([
    entry('__MACOSX/parts/._a.stl'), entry('parts/._a.stl'), entry('parts/a.stl'),
  ]);
  assert.equal(p.take.length, 1);
  assert.equal(p.skipped.length, 0);
});

test('the extension test is anchored at the end', () => {
  // "model.stl.exe" is not an STL, and "notes-about-stl.txt" is not one either.
  assert.equal(PRINT_EXT.test('model.stl.exe'), false);
  assert.equal(PRINT_EXT.test('notes-about-stl.txt'), false);
  assert.equal(PRINT_EXT.test('MODEL.STL'), true);
});

// ------------------------------------------------------------- the budgets

test('a bomb is bounded, and every file it cost is named', () => {
  const huge = [entry('a.stl', 600), entry('b.stl', 600), entry('c.stl', 600)];
  const p = plan(huge, { maxBytes: 1000 });
  assert.equal(p.take.length, 1);
  assert.equal(p.truncated, true, 'the cap was hit and nothing said so');
  const over = p.skipped.filter((s) => s.reason === 'over-budget');
  assert.deepEqual(over.map((s) => s.name), ['b.stl', 'c.stl']);
});

test('the member count is capped too, not just the bytes', () => {
  const many = Array.from({ length: 20 }, (_, i) => entry(`p${i}.stl`, 1));
  const p = plan(many, { maxMembers: 5 });
  assert.equal(p.take.length, 5);
  assert.equal(p.truncated, true);
  assert.equal(p.skipped.filter((s) => s.reason === 'over-budget').length, 15);
});

test('a zip that fits is not marked truncated', () => {
  const p = plan([entry('a.stl', 10), entry('b.stl', 10)], { maxBytes: 1000, maxMembers: 10 });
  assert.equal(p.truncated, false);
  assert.equal(p.take.length, 2);
});

test('a member with no usable size does not blow the budget open', () => {
  // A streaming-written zip can report 0 or undefined in the entry. Treating
  // that as "free" is right — the reader caps each member anyway — but it must
  // not also make the COUNT limit meaningless.
  const p = plan(Array.from({ length: 9 }, (_, i) => entry(`p${i}.stl`, undefined)), { maxMembers: 4 });
  assert.equal(p.take.length, 4);
  assert.equal(p.truncated, true);
});

// ---------------------------------------------------------------- reporting

test('an archive with nothing printable is empty, not a silent success', () => {
  const p = plan([entry('README.md'), entry('cover.jpg')]);
  const s = summarize(p);
  assert.equal(s.empty, true);
  assert.equal(s.files, 0);
  assert.equal(s.skipped, 2);
});

test('the summary carries the truncation forward', () => {
  const s = summarize(plan([entry('a.stl', 600), entry('b.stl', 600)], { maxBytes: 1000 }));
  assert.equal(s.files, 1);
  assert.equal(s.truncated, true);
  assert.equal(s.overBudget, 1);
});

test('junk in, no throw out', () => {
  for (const bad of [null, undefined, 'nope', 42, [null, undefined, {}, { name: '' }]]) {
    const p = plan(bad);
    assert.deepEqual(p.take, [], JSON.stringify(bad));
    assert.equal(p.truncated, false);
  }
  assert.deepEqual(summarize(null), { files: 0, bytes: 0, skipped: 0, overBudget: 0, truncated: false, empty: true });
});

test('a member that declares no size is charged what it may inflate to', () => {
  /* THE BUDGET AND THE INFLATION CAP READ DIFFERENT NUMBERS.
   *
   * This charged the DECLARED uncompressed size and charged nothing at all when
   * a member declared none — while lib/zip-read.js lets exactly those members
   * inflate to its full per-member ceiling. So an archive whose members all
   * declare `size: 0` passed the 2 GiB budget "costing 0 MB" and then wrote as
   * much as it liked.
   *
   * Measured on a crafted archive before the fix: 0.47 MB on disk, 8 members
   * taken, budget said 0.0 MB, actually inflated to 480 MB. At the 512-member
   * cap that is roughly 200 GB written to a temp folder. A shop dropping a
   * downloaded model pack is enough — no compromised renderer required.
   */
  const { MAX_INFLATED } = require('../lib/zip-read.js');
  const undeclared = (name) => ({ name, size: 0, compSize: 1024 });
  const many = Array.from({ length: 20 }, (_, i) => undeclared(`part${i}.stl`));
  const p = plan(many);

  const { MAX_TOTAL_BYTES } = require('../lib/zip-intake.js');
  assert.ok(p.take.length < many.length,
    'every undeclared member was taken — the budget charged them nothing');
  // Five 400 MB members fit a 2 GiB budget; the sixth must not.
  assert.equal(p.take.length, Math.floor(MAX_TOTAL_BYTES / MAX_INFLATED));
  assert.equal(p.truncated, true, 'the refusal has to be reported, not silent');
  assert.ok(p.skipped.some((x) => x.reason === 'over-budget'));

  // A member that declares an honest size is still charged that, not the cap.
  const honest = plan([{ name: 'a.stl', size: 1024, compSize: 300 }]);
  assert.equal(honest.bytes, 1024);
  assert.equal(honest.take.length, 1);
});

test('the budget and the inflation cap read the same number', () => {
  // They disagreed, and that WAS the bug. lib/zip-intake.js imports the ceiling
  // from the module that enforces it rather than repeating the literal.
  const { MAX_INFLATED } = require('../lib/zip-read.js');
  const src = require('fs').readFileSync(require('path').join(__dirname, '../lib/zip-intake.js'), 'utf8');
  assert.match(src, /require\('\.\/zip-read\.js'\)\.MAX_INFLATED/,
    'zip-intake repeats the ceiling instead of reading it — they will drift again');
  assert.equal(typeof MAX_INFLATED, 'number');
  assert.ok(MAX_INFLATED > 0);
});
