/**
 * A product part's prep and post time, when the shop never typed them, cost at
 * the shop's default rates (lib/print-rates.js withRates) — so the editor must
 * not write a 0 back for them.
 *
 * The part row drew `part.prepTime ?? 0` and saved `num(v, 0)`: opening and
 * saving a product turned "the shop's default" into "no labour" without anyone
 * choosing it. And a new part was seeded with a fixed 0.1/0.2 h that overrode
 * whatever the shop had set.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const PR = require('../lib/print-rates.js');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'inventory.js'), 'utf8');
const EDITOR = SRC.slice(SRC.indexOf('function openProductEditor'), SRC.indexOf('function resizeImage'));

test('an unset prep/post time costs at the default; a typed 0 is kept', () => {
  const settings = {};
  const d = PR.ratesFor({ settings });
  assert.equal(PR.withRates({}, { settings }).prepTime, d.prepTime);
  assert.equal(PR.withRates({ prepTime: '' }, { settings }).prepTime, d.prepTime);
  assert.equal(PR.withRates({ prepTime: 0 }, { settings }).prepTime, 0);
});

test('the part row draws an unset time empty, with the default as a hint', () => {
  assert.doesNotMatch(EDITOR, /data-f="(prep|post)Time" value="\$\{part\.\w+ \?\? 0\}"/);
  for (const f of ['prepTime', 'postTime']) {
    assert.match(EDITOR, new RegExp(`data-f="${f}" value="\\$\\{rateValue\\(part\\.${f}\\)\\}" placeholder="\\$\\{escapeHtml\\(String\\(partDefaults\\.${f}`));
  }
});

test('a blank prep/post time is saved as unset, not 0', () => {
  assert.match(EDITOR, /RATE_FIELDS\.has\(f\) && String\(input\.value\)\.trim\(\) === ''\) delete draft\.parts\[pi\]\[f\]/);
});

test('a new part does not pin prep/post time over the shop default', () => {
  const add = EDITOR.slice(EDITOR.indexOf('[data-act="add-part"]'), EDITOR.indexOf('refreshParts();', EDITOR.indexOf('[data-act="add-part"]')));
  assert.doesNotMatch(add, /prepTime:|postTime:/);
});
