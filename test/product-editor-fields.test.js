/**
 * The product editor has to be able to save what it asks you to type.
 *
 * Reported: "I keep writing a description and save only to find it not saved."
 * Every description, in every shop. Three separate faults, all from the same
 * root — the content-language work converted what the form RENDERS and left
 * three places that decide what it KEEPS:
 *
 *   1. The [data-f] sync writes a field only if the draft already has that key
 *      (a whitelist, so a stray input cannot inject properties). The draft was
 *      seeded with `nameEn`, `nameAr` and a plain `description`, while the
 *      inputs are named `descriptionEn`, `name_de`, `description_tr`. The guard
 *      rejected every one of them and the typed value was dropped in silence.
 *      `nameEn` survived only because it happens to be a seeded key.
 *
 *   2. So a shop writing German lost its product NAMES the same way.
 *
 *   3. And could not save at all: the name check read `nameEn`/`nameAr` only,
 *      so a filled-in German name was met with "Give the product a name first".
 *      The editor was unusable for seven of the nine languages Khayt offers.
 *
 * Verified against the running app, not just here: saving as en/ar, de/fr and
 * tr each produced a product carrying the name and description that were typed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'inventory.js'), 'utf8');
const EDITOR = SRC.slice(SRC.indexOf('function openProductEditor'), SRC.indexOf('function resizeImage'));

test('every per-language field exists on the draft before the form is built', () => {
  // The whitelist is kept — it is the right shape — so the keys have to be
  // there for it to let them through.
  assert.match(EDITOR, /for \(const lang of KhaytContentLanguages\.contentLangs\(/,
    'the draft must be seeded from the shop\'s content languages');
  assert.match(EDITOR, /for \(const base of \['name', 'description'\]\)/);
  assert.match(EDITOR, /if \(!\(key in draft\)\) draft\[key\] = '';/);
});

test('the sync still refuses keys that are not the shop\'s fields', () => {
  // Seeding must not turn into "write whatever an input claims" — that guard is
  // why a stray data-f cannot inject a property.
  assert.match(EDITOR, /Object\.prototype\.hasOwnProperty\.call\(draft, f\)/);
});

test('a description written before languages existed is carried forward', () => {
  // Otherwise it sits in `description` behind an empty `descriptionEn` box and
  // looks deleted — which is the same complaint from the other direction.
  assert.match(EDITOR, /migratePlain\(draft, 'description'/);
});

test('the name check accepts any of the shop\'s languages', () => {
  assert.doesNotMatch(EDITOR, /!draft\.nameEn\?\.trim\(\) && !draft\.nameAr\?\.trim\(\)/,
    'checking two of nine languages blocks the save for the other seven');
  assert.match(EDITOR, /KhaytContentLanguages\.read\(draft, 'name', null,[\s\S]{0,80}\)\.trim\(\)/);
});

test('the fields the form renders are the fields it seeds', () => {
  /* The bug was these two lists disagreeing. Both are built from
   * fieldKey(base, lang), so they cannot drift apart without this failing. */
  const rendered = [...EDITOR.matchAll(/KhaytContentLanguages\.fieldKey\('(\w+)', lang\)/g)].map((m) => m[1]);
  assert.ok(rendered.includes('name') && rendered.includes('description'),
    'the form renders name and description per language');
  const seeded = EDITOR.match(/for \(const base of \[([^\]]+)\]\)/);
  assert.ok(seeded, 'and seeds a list of bases');
  for (const base of new Set(rendered)) {
    assert.match(seeded[1], new RegExp(`'${base}'`), `${base} is rendered per language but never seeded, so it cannot save`);
  }
});
