'use strict';
/**
 * One list of failure types, wherever it is read.
 *
 * When a print fails QC, the shop picks why from a fixed list of nine:
 * `bed_adhesion`, `nozzle_jam`, `warping`, `stringing`, `operator_error`,
 * `design_issue`, `power_failure`, `material_quality`, `other`.
 *
 * That list was written out FOUR times: in `lib/qc-failure.js`, which records
 * the failure; in `lib/waste-entry.js`, which records the filament it wasted;
 * as nine typed-out `<option>` tags in `renderer/order-flows.js`; and in
 * `renderer/bedready-queue.js`, which builds its options from a constant.
 *
 * Four copies of a list is three chances to add a tenth type to one of them.
 * The consequences are not symmetrical, which is why this is a test rather
 * than a tidy-up:
 *
 *   - A type the dropdown offers and `lib/qc-failure.js` does not know is
 *     saved onto the order anyway, and the analytics defect chart labels it
 *     with `t('waste.ft.' + type)`. A missing key renders as the literal
 *     string "waste.ft.whatever" — Khayt's i18n returns the key, so the
 *     `|| type` fallback beside that call can never fire.
 *   - A type in the rule that the dropdown does not offer is simply
 *     unreachable, and nobody finds out.
 *
 * `renderer/order-flows.js` now builds its options from the rule's own list,
 * so there are two lists left and this holds them together, along with every
 * locale that has to name them.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const QC = require('../lib/qc-failure.js');
const WASTE = require('../lib/waste-entry.js');

const read = rel => fs.readFileSync(path.join(ROOT, rel), 'utf8');

test('the rule and the waste entry agree on the nine types, in order', () => {
  assert.deepEqual(WASTE.FAILURE_TYPES, QC.FAILURE_TYPES);
  assert.equal(QC.FAILURE_TYPES.length, 9);
  assert.equal(QC.FAILURE_TYPES[QC.FAILURE_TYPES.length - 1], 'other',
    '"other" is the default and the last resort; it belongs at the end');
});

test('no screen types the list out by hand', () => {
  for (const file of ['renderer/order-flows.js', 'renderer/bedready-queue.js']) {
    const src = read(file);
    const typed = [...src.matchAll(/<option value="(bed_adhesion|nozzle_jam|warping|stringing|operator_error|design_issue|power_failure|material_quality)"/g)];
    assert.deepEqual(typed.map(m => m[1]), [],
      `${file} types failure types into markup — build the options from FAILURE_TYPES instead`);
  }
});

test('the QC dropdown is built from the rule and defaults to other', () => {
  const src = read('renderer/order-flows.js');
  assert.match(src, /KhaytQcFailure\.FAILURE_TYPES\.map/,
    'the QC fail dropdown must read the rule\'s list');
  assert.match(src, /k === 'other' \? ' selected' : ''/,
    'an unclassified failure defaults to other, as it did before');
});

test('every locale names every failure type', () => {
  const dir = path.join(ROOT, 'renderer/locales');
  const locales = fs.readdirSync(dir).filter(f => f.endsWith('.js'));
  assert.ok(locales.length >= 2, 'expected several locales');

  const missing = [];
  for (const file of locales) {
    const src = fs.readFileSync(path.join(dir, file), 'utf8');
    for (const type of QC.FAILURE_TYPES) {
      if (!src.includes(`"waste.ft.${type}"`) && !src.includes(`'waste.ft.${type}'`)) {
        missing.push(`${file}: waste.ft.${type}`);
      }
    }
  }
  // A missing key does not fall back: t() returns the key, so the defect chart
  // would print "waste.ft.warping" at a shop reading Khayt in that language.
  assert.deepEqual(missing, [], missing.join('\n'));
});

test('no locale names a failure type the rule does not have', () => {
  const dir = path.join(ROOT, 'renderer/locales');
  const known = new Set(QC.FAILURE_TYPES);
  const strays = [];
  for (const file of fs.readdirSync(dir).filter(f => f.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(dir, file), 'utf8');
    for (const m of src.matchAll(/["']waste\.ft\.([a-z_]+)["']/g)) {
      if (!known.has(m[1])) strays.push(`${file}: waste.ft.${m[1]}`);
    }
  }
  assert.deepEqual(strays, [],
    'a translation for a type nothing can record — either the rule lost it or the key is a typo:\n'
    + strays.join('\n'));
});
