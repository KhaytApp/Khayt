/**
 * Searching and filtering the Bed Ready design library.
 *
 * The panel that shows this is a self-contained IIFE in the renderer with no
 * harness of its own, which is exactly why the logic lives in lib/ — "which of
 * 400 designs match 'bracket', in what order" is testable; the drawing is not.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { browse, facets, typeOf, isDownloadable, labelOf, FILE_TYPES } = require('../lib/library-browse.js');

const lib = [
  { title: 'Étagère bracket', slug: 'etagere-bracket', fileType: 'stl', downloadUrl: 'u1' },
  { title: 'Vase spiral', slug: 'vase-spiral', fileType: '3mf', downloadUrl: 'u2' },
  { title: 'bracket v2', slug: 'bracket-v2', filename: 'bracket.obj', downloadUrl: 'u3' },
  { title: 'Gear set', slug: 'gear-set', fileType: 'step' },              // link only
  { title: 'حامل هاتف', slug: 'phone-stand', fileType: '3mf', downloadUrl: 'u4' },
  { title: 'Zebra', slug: 'zebra', fileType: 'stl' },                      // link only
];

const titles = (r) => r.map((i) => i.title);

test('an unknown or missing type is 3MF — the same lie extFor would not tell', () => {
  // lib/makerrun-library.js extFor() defaults to .3mf, so an item with no usable
  // type DOES arrive as a 3MF. Calling it anything else here would mean ticking
  // "3MF" and not seeing a file that lands as one.
  assert.equal(typeOf({ fileType: 'stl' }), 'stl');
  assert.equal(typeOf({ filename: 'thing.OBJ' }), 'obj', 'case-insensitive');
  assert.equal(typeOf({ fileType: 'gcode' }), '3mf', 'not a design type — defaults');
  assert.equal(typeOf({}), '3mf');
  assert.equal(typeOf(null), '3mf');
  assert.equal(typeOf({ filename: 'no-extension' }), '3mf');
  // fileType wins over the filename when both are usable.
  assert.equal(typeOf({ fileType: 'step', filename: 'x.stl' }), 'step');
});

test('search ignores accents, because a design library is not ASCII', () => {
  // Typing "etagere" must find "Étagère". A search that demands exact accents is
  // a search people stop using.
  //
  // The fixture deliberately has NO ascii slug or filename to fall back on — with
  // one, this passes whether or not accents are folded at all, and the test would
  // be reporting on nothing. Both normalisation forms are checked because the
  // server can return either.
  const nfc = [{ title: 'Étagère'.normalize('NFC') }];
  const nfd = [{ title: 'Étagère'.normalize('NFD') }];
  for (const [form, one] of [['NFC', nfc], ['NFD', nfd]]) {
    assert.equal(browse(one, { query: 'etagere' }).length, 1, `${form}: plain ascii query`);
    assert.equal(browse(one, { query: 'ÉTAGÈRE' }).length, 1, `${form}: accented, wrong case`);
    assert.equal(browse(one, { query: 'Étagère'.normalize('NFD') }).length, 1, `${form}: decomposed query`);
    assert.equal(browse(one, { query: 'etagerf' }).length, 0, `${form}: still discriminates`);
  }
  // And through the real fixture, which also has a slug.
  assert.deepEqual(titles(browse(lib, { query: 'ÉTAGÈRE' })), ['Étagère bracket']);
});

test('search matches title, slug and filename', () => {
  assert.deepEqual(titles(browse(lib, { query: 'phone-stand' })), ['حامل هاتف'], 'slug');
  assert.deepEqual(titles(browse(lib, { query: 'bracket.obj' })), ['bracket v2'], 'filename');
  assert.deepEqual(titles(browse(lib, { query: 'هاتف' })), ['حامل هاتف'], 'Arabic title');
});

test('every word must match, so typing more always narrows', () => {
  assert.equal(browse(lib, { query: 'bracket' }).length, 2);
  assert.deepEqual(titles(browse(lib, { query: 'bracket v2' })), ['bracket v2']);
  assert.deepEqual(browse(lib, { query: 'bracket zebra' }), [], 'no item has both');
  // Order of words must not matter.
  assert.deepEqual(titles(browse(lib, { query: 'v2 bracket' })), ['bracket v2']);
});

test('an empty or whitespace query returns everything', () => {
  for (const q of ['', '   ', null, undefined]) {
    assert.equal(browse(lib, { query: q }).length, lib.length, `query: ${String(q)}`);
  }
});

test('type filter keeps only the ticked kinds', () => {
  const stl = browse(lib, { types: ['stl'] });
  assert.deepEqual(titles(stl), ['Étagère bracket', 'Zebra']);
  assert.equal(stl.length, 2, 'Étagère bracket and Zebra');
  assert.ok(stl.every((i) => typeOf(i) === 'stl'));

  const multi = browse(lib, { types: ['stl', 'step'] });
  assert.equal(multi.length, 3);

  // An unknown type in the list is ignored rather than filtering everything out.
  assert.equal(browse(lib, { types: ['gcode'] }).length, lib.length);
  assert.equal(browse(lib, { types: [] }).length, lib.length, 'no types means all');
});

test('downloadableOnly hides link-only designs', () => {
  const d = browse(lib, { downloadableOnly: true });
  assert.equal(d.length, 4);
  assert.ok(d.every(isDownloadable));
  assert.ok(!titles(d).includes('Gear set'));
  assert.ok(!titles(d).includes('Zebra'));
});

test('filters combine', () => {
  const r = browse(lib, { query: 'bracket', types: ['stl'], downloadableOnly: true });
  assert.deepEqual(titles(r), ['Étagère bracket']);
});

test('sorting is by name, naturally, and stable across keystrokes', () => {
  const names = titles(browse(lib, { sort: 'name' }));
  // localeCompare with sensitivity:base — "bracket v2" sorts with the B's, not
  // after every capital letter the way a raw codepoint sort would.
  assert.equal(names[0], 'bracket v2');
  assert.deepEqual(titles(browse(lib, { sort: 'name-desc' })), [...names].reverse());

  // Numeric ordering: 2 before 10, which a plain string sort gets backwards.
  const n = [{ title: 'part 10' }, { title: 'part 2' }];
  assert.deepEqual(titles(browse(n, { sort: 'name' })), ['part 2', 'part 10']);
});

test('sorting by type still orders by name inside each group', () => {
  // A sort that leaves the second key to chance reshuffles the grid on every
  // refresh, which reads as a bug even though nothing changed.
  //
  // The fixture is deliberately in the WRONG name order within each type group.
  // Array#sort is stable, so a fixture that arrives already sorted would pass
  // even with no secondary key at all — the test would prove nothing.
  const unsorted = [
    { title: 'zeta', fileType: 'stl' },
    { title: 'alpha', fileType: 'stl' },
    { title: 'yankee', fileType: '3mf' },
    { title: 'bravo', fileType: '3mf' },
  ];
  assert.deepEqual(titles(browse(unsorted, { sort: 'type' })),
    ['bravo', 'yankee', 'alpha', 'zeta'], '3mf group first, each group A–Z');

  const r = browse(lib, { sort: 'type' });
  const types = r.map(typeOf);
  assert.deepEqual(types, [...types].sort(), 'grouped by type');
});

test('an unknown sort falls back to name rather than to insertion order', () => {
  assert.deepEqual(titles(browse(lib, { sort: 'nonsense' })), titles(browse(lib, { sort: 'name' })));
  assert.deepEqual(titles(browse(lib, {})), titles(browse(lib, { sort: 'name' })));
});

test('browse never mutates the caller\'s array', () => {
  // The panel keeps one `items` array and re-filters it on every keystroke. A
  // sort in place would permanently reorder the source.
  const original = lib.slice();
  browse(lib, { sort: 'name-desc' });
  assert.deepEqual(lib, original, 'input untouched');
});

test('facets count the WHOLE library, not the filtered view', () => {
  // A chip that renumbers as you type cannot be aimed at.
  const f = facets(lib);
  assert.equal(f.total, 6);
  assert.equal(f.downloadable, 4);
  assert.equal(f.linkOnly, 2);
  assert.deepEqual(f.types, { stl: 2, '3mf': 2, obj: 1, step: 1 });
  // Present types only, in a fixed order, so the chip row does not reshuffle.
  assert.deepEqual(f.presentTypes, ['3mf', 'stl', 'obj', 'step']);
  assert.ok(f.presentTypes.every((t) => FILE_TYPES.includes(t)));
});

test('junk in the library does not take the panel down', () => {
  // These items come off the network. One bad row must not empty the grid.
  const messy = [null, undefined, 42, 'text', {}, { title: null }, lib[0]];
  const r = browse(messy, {});
  assert.equal(r.length, 3, 'the three objects survive; primitives and null are dropped');
  assert.equal(facets(messy).total, 3);
  assert.doesNotThrow(() => browse(null, {}));
  assert.deepEqual(browse(null, {}), []);
  assert.equal(facets(undefined).total, 0);
});

test('an item with no title falls back to its slug', () => {
  assert.equal(labelOf({ slug: 'only-a-slug' }), 'only-a-slug');
  assert.equal(labelOf({ title: 'A', slug: 'b' }), 'A');
  assert.equal(labelOf({}), '');
  assert.equal(labelOf(null), '');
  // And is still findable by that slug.
  assert.equal(browse([{ slug: 'only-a-slug' }], { query: 'slug' }).length, 1);
});
