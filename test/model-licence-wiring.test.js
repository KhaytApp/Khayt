/**
 * The licence fields have to be REACHED, and the menu has to have words in it.
 *
 * `model-licence.js` is pure and tested next door, which proves nothing about
 * whether a shop can set a licence. Two ways this fails silently and neither
 * throws: the editor never offers the fields, or it offers a `<select>` whose
 * options are raw ids because the strings are missing in that language.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const L = require('../lib/model-licence.js');

const root = path.join(__dirname, '..');
const editor = fs.readFileSync(path.join(root, 'renderer/printfiles.js'), 'utf8');

test('the model editor offers both fields, and saves both', () => {
  assert.match(editor, /id="pfSource"/, 'no Source field in the model editor');
  assert.match(editor, /id="pfLicence"/, 'no Licence field in the model editor');
  assert.match(editor, /rec\.source = /, 'Source is offered and never saved');
  assert.match(editor, /rec\.licence = /, 'Licence is offered and never saved');
});

// The list comes from the rule, not from a copy in the dialog — a second list
// is a menu offering a licence the rule cannot resolve.
test('the licence menu is built from the shared rule', () => {
  assert.match(editor, /KhaytModelLicence\.list\(\)/,
    'the editor has its own idea of what the licences are');
});

// "Not recorded" must be an option and must be the empty value, or a shop
// cannot say it does not know — and unknown is the state every model starts in.
test('not-recorded is an option, and it is the empty one', () => {
  assert.match(editor, /<option value="">/, 'there is no way to leave the licence unset');
});

test('every licence the rule offers has words in every locale', () => {
  const locales = fs.readdirSync(path.join(root, 'renderer/locales'))
    .filter((f) => f.endsWith('.js'));
  assert.ok(locales.length >= 9, `only ${locales.length} locales found`);

  for (const file of locales) {
    const text = fs.readFileSync(path.join(root, 'renderer/locales', file), 'utf8');
    for (const entry of L.list()) {
      const key = `plib.licence_${entry.id.replace(/-/g, '_')}`;
      assert.ok(text.includes(`"${key}"`),
        `${file} has no words for ${entry.id} — the menu would show ${key}`);
    }
    for (const key of ['plib.source', 'plib.licence', 'plib.licence_unknown', 'plib.provenance']) {
      assert.ok(text.includes(`"${key}"`), `${file} is missing ${key}`);
    }
  }
});

// A shop reads the menu to decide whether it may sell a print, so the entries
// that forbid it must SAY so rather than leaving the shop to know what NC means.
test('the non-commercial licences say they cannot be sold, in every language', () => {
  const locales = fs.readdirSync(path.join(root, 'renderer/locales')).filter((f) => f.endsWith('.js'));
  for (const file of locales) {
    const text = fs.readFileSync(path.join(root, 'renderer/locales', file), 'utf8');
    for (const id of ['cc_by_nc', 'cc_by_nc_sa', 'cc_by_nc_nd']) {
      const line = text.split('\n').find((l) => l.includes(`"plib.licence_${id}"`));
      assert.ok(line, `${file} is missing plib.licence_${id}`);
      // The name alone ("CC BY-NC") is not an explanation. Every one carries a
      // phrase after a dash saying what it means for selling.
      assert.match(line, /—/,
        `${file}: plib.licence_${id} is just the initials — it must say it cannot be sold`);
    }
  }
});
