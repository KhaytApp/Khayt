'use strict';

// The SHIPPED catalogue, not a fixture. `filament-catalog.test.js` pins the
// matching against a small hand-made catalogue and would pass on any data; this
// pins the corrections `scripts/filament-catalog-overrides.json` makes, so a
// monthly refresh that loses them fails here rather than in a tester's hands.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const ASSET = path.join(ROOT, 'assets', 'filament-catalog.json');
const MAC_COPY = path.join(ROOT, 'mac', 'KhaytCore', 'Sources', 'KhaytApp', 'Resources',
  'filament-catalog.json');
const CAT = JSON.parse(fs.readFileSync(ASSET, 'utf8'));

const row = (brand, name) => CAT.filaments.find((f) => f.b === brand && f.n === name);

// Bambu Lab's own PLA Matte list: Bambu Studio's
// resources/profiles/BBL/filament/filaments_color_codes.json (fila_id GFA01),
// which the store page agrees with — 25 colours, verified 2026-10-04.
const BAMBU_PLA_MATTE = {
  'Apple Green': '#C2E189', 'Ash Gray': '#9B9EA0', 'Bone White': '#CBC6B8',
  'Caramel': '#AE835B', 'Charcoal': '#000000', 'Dark Blue': '#042F56',
  'Dark Brown': '#7D6556', 'Dark Chocolate': '#4D3324', 'Dark Green': '#68724D',
  'Dark Red': '#BB3D43', 'Desert Tan': '#E8DBB7', 'Grass Green': '#61C680',
  'Ice Blue': '#A3D8E1', 'Ivory White': '#FFFFFF', 'Latte Brown': '#D3B7A7',
  'Lemon Yellow': '#F7D959', 'Lilac Purple': '#AE96D4', 'Mandarin Orange': '#F99963',
  'Marine Blue': '#0078BF', 'Nardo Gray': '#757575', 'Plum': '#950051',
  'Sakura Pink': '#E8AFCF', 'Scarlet Red': '#DE4343', 'Sky Blue': '#56B7E6',
  'Terracotta': '#B15533',
};

test('Bambu PLA Matte carries every official colour, by its official name and hex', () => {
  const matte = row('Bambu Lab', 'PLA Matte');
  assert.ok(matte, 'Bambu Lab PLA Matte is missing from the catalogue');
  const have = Object.fromEntries(matte.c.map((c) => [c[0], c[1].toUpperCase()]));
  for (const [name, hex] of Object.entries(BAMBU_PLA_MATTE)) {
    assert.equal(have[name], hex, `PLA Matte ${name}: expected ${hex}, catalogue has ${have[name]}`);
  }
  // The spellings the upstream had before the correction.
  assert.equal('Nardo Grey' in have, false, 'Bambu spells it Nardo Gray');
  assert.equal('Lilac purple' in have, false, 'Bambu capitalises Lilac Purple');
});

test('no Bambu PLA Matte colour is filed under PLA Basic', () => {
  const basic = row('Bambu Lab', 'PLA Basic');
  assert.ok(basic, 'Bambu Lab PLA Basic is missing from the catalogue');
  const matteNames = new Set(Object.keys(BAMBU_PLA_MATTE).map((n) => n.toLowerCase()));
  const misfiled = basic.c.map((c) => c[0]).filter((n) => matteNames.has(n.toLowerCase())
    || /matte/i.test(n));
  assert.deepEqual(misfiled, []);
});

test('the overrides file and this test agree on the Bambu PLA Matte list', () => {
  // Two copies of one list is a drift risk; this is what makes it one list.
  const o = JSON.parse(fs.readFileSync(path.join(ROOT, 'scripts', 'filament-catalog-overrides.json'), 'utf8'));
  const entry = o.filaments.find((f) => f.brand === 'Bambu Lab' && f.filament === 'PLA Matte');
  assert.ok(entry);
  assert.deepEqual(Object.fromEntries(entry.colours.map((c) => [c.name, c.hex])), BAMBU_PLA_MATTE);
});

test('no empty-spool weight is a barcode', () => {
  // Grass Green carried 6975337030119 upstream. Subtracted from a scale
  // reading, that is a spool with negative filament on it.
  for (const f of CAT.filaments) {
    for (const c of f.c) {
      assert.ok(c[3] == null || (c[3] > 0 && c[3] <= 2000),
        `${f.b} ${f.n} ${c[0]}: empty spool weight ${c[3]}`);
    }
  }
});

test('the Mac app bundles the same catalogue', () => {
  // `mac/sync-js.sh` copies it; a correction that reaches one app and not the
  // other is the bug coming back on the platform nobody re-tested.
  assert.ok(fs.readFileSync(MAC_COPY).equals(fs.readFileSync(ASSET)),
    'mac/KhaytCore/Sources/KhaytApp/Resources/filament-catalog.json differs — run mac/sync-js.sh');
});

// ── The merged catalogue as a whole ────────────────────────────────────────
//
// Three sources go into this file (scripts/fetch-filament-catalog.py) and the
// merge is heuristic, so what it must never produce is pinned here: two rows
// for one product, two entries for one colour, a hex the swatch cannot draw,
// a row nobody can trace back to a source, or a source without its licence.

const SOURCE_LETTERS = new Set(Object.keys(CAT.sources || {}));
const colourKey = (name) => String(name).trim().toLowerCase().replace(/\s+/g, ' ')
  .replace(/\bgrey\b/g, 'gray');

test('every row is complete and says where it came from', () => {
  assert.ok(SOURCE_LETTERS.size >= 3, 'the catalogue does not list its sources');
  for (const f of CAT.filaments) {
    const id = `${f.b} / ${f.n}`;
    assert.ok(typeof f.b === 'string' && f.b.trim(), `${id}: no brand`);
    assert.ok(typeof f.n === 'string' && f.n.trim(), `${id}: no name`);
    assert.ok(typeof f.m === 'string' && f.m.trim(), `${id}: no material`);
    assert.ok(Array.isArray(f.c) && f.c.length > 0, `${id}: no colours`);
    assert.ok(Array.isArray(f.t) && f.t.length === 2, `${id}: temperatures are not a pair`);
    assert.ok(f.d == null || (f.d > 0.5 && f.d < 12), `${id}: density ${f.d}`);
    assert.ok(typeof f.s === 'string' && f.s.length > 0, `${id}: no source`);
    for (const s of f.s) assert.ok(SOURCE_LETTERS.has(s), `${id}: unknown source ${s}`);
  }
});

test('every colour has a name, a drawable hex and plausible spool facts', () => {
  for (const f of CAT.filaments) {
    for (const c of f.c) {
      const id = `${f.b} / ${f.n} / ${c[0]}`;
      assert.equal(c.length, 5, `${id}: not a five-field colour`);
      assert.ok(String(c[0]).trim(), `${f.b} / ${f.n}: a colour with no name`);
      assert.match(c[1], /^#[0-9A-F]{6}$/, `${id}: hex ${c[1]}`);
      assert.ok(Array.isArray(c[2]) && c[2].every((w) => w > 0 && w <= 15000), `${id}: weights ${c[2]}`);
      assert.ok(c[4] == null || [1.75, 2.85, 3].includes(c[4]), `${id}: diameter ${c[4]}`);
    }
  }
});

test('one row per brand and product, one entry per colour', () => {
  const rows = new Set();
  for (const f of CAT.filaments) {
    const k = `${f.b.toLowerCase()}|${f.n.toLowerCase().trim()}`;
    assert.ok(!rows.has(k), `${f.b} / ${f.n} is listed twice`);
    rows.add(k);
    const colours = new Set();
    for (const c of f.c) {
      const ck = colourKey(c[0]);
      assert.ok(!colours.has(ck), `${f.b} / ${f.n}: ${c[0]} is listed twice`);
      colours.add(ck);
    }
  }
});

test('every source is named with its licence, and the MIT notice travels with the data', () => {
  for (const [letter, s] of Object.entries(CAT.sources)) {
    assert.ok(s.name && s.url && s.licence, `source ${letter} is missing its name, url or licence`);
  }
  assert.equal(CAT.sources.o.licence, 'MIT');
  assert.equal(CAT.sources.s.licence, 'MIT');
  assert.ok(CAT.sources.o.copyright && CAT.sources.s.copyright);
  assert.match(CAT.mitNotice || '', /Permission is hereby granted, free of charge/);
  // And THIRD-PARTY-NOTICES.md names each one.
  const notices = fs.readFileSync(path.join(ROOT, 'THIRD-PARTY-NOTICES.md'), 'utf8');
  for (const s of Object.values(CAT.sources)) {
    assert.ok(notices.includes(s.url), `THIRD-PARTY-NOTICES.md does not list ${s.url}`);
  }
});

// What a Gulf print shop buys, by line. A refresh that loses one of these —
// a source gone, a brand renamed upstream, a merge rule that swallowed a line —
// fails here instead of on the shop's counter.
const MUST_HAVE = {
  'Bambu Lab': ['PLA Basic', 'PLA Matte', 'PLA Silk+', 'PLA Glow', 'PLA Marble', 'PLA Sparkle',
    'PLA Metal', 'PLA Galaxy', 'PLA Translucent', 'PLA Wood', 'PLA Tough+', 'PLA-CF',
    'PETG HF', 'PETG Basic', 'PETG Translucent', 'PETG-CF', 'ABS', 'ASA', 'TPU for AMS',
    'PAHT-CF', 'PC', 'Support for PLA'],
  Polymaker: ['Panchroma Matte PLA', 'Panchroma Silk PLA', 'Polylite PLA', 'Polymax PLA', 'Polylite PETG'],
  'eSUN 3D': ['PLA+'],
  SUNLU: ['PLA Matte', 'PLA+', 'PETG'],
  ELEGOO: ['PLA', 'PLA MATTE', 'RAPID PETG'],
  Creality: ['Hyper PLA', 'Hyper PETG'],
  Prusament: ['PLA', 'PETG'],
  Overture: ['Matte PLA', 'PETG'],
};

test('the lines a shop buys are there', () => {
  for (const [brand, lines] of Object.entries(MUST_HAVE)) {
    for (const line of lines) {
      const r = row(brand, line);
      assert.ok(r, `${brand} ${line} is missing`);
      assert.ok(r.c.length > 0, `${brand} ${line} has no colours`);
    }
  }
});

test('the catalogue did not shrink below what it was when it grew', () => {
  // 1,945 filaments / 14,500 colours from the OFD alone (Sep 2026); 2,110 /
  // 16,477 merged (Oct 2026). A drop well under that is a lost source.
  assert.ok(CAT.filaments.length >= 2000, `${CAT.filaments.length} filaments`);
  const colours = CAT.filaments.reduce((n, f) => n + f.c.length, 0);
  assert.ok(colours >= 15500, `${colours} colours`);
  for (const brand of ['Bambu Lab', 'Polymaker', 'eSUN 3D', 'SUNLU', 'ELEGOO', 'Overture', 'R3D']) {
    assert.ok(CAT.filaments.some((f) => f.b === brand), `${brand} is gone`);
  }
});

test('Bambu Lab is spelled the way Bambu spells it', () => {
  // Bambu's own list (source b) renames the community's spellings; a row it
  // touched must not carry "Grey" for Bambu's "Gray".
  for (const f of CAT.filaments.filter((x) => x.b === 'Bambu Lab' && x.s.includes('b'))) {
    for (const c of f.c) assert.doesNotMatch(c[0], /\bGrey\b/, `${f.n} ${c[0]}`);
  }
});
