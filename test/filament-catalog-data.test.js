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
