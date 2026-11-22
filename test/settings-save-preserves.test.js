/**
 * Saving the Settings page must not destroy settings the page does not show.
 *
 * saveSettingsFromForm() REPLACES `settings` with an object literal built from
 * the form. Every key that literal does not name is gone — silently, on a save
 * the shop made for an unrelated reason, with a green "Saved" toast over it.
 *
 * The file tried to hold that line by hand: two "preserve fields managed
 * outside this form — never silently drop them" blocks listing ~25 keys. A
 * hand-maintained list of everything anyone might add later is a list that goes
 * stale, and it had: nineteen keys were being dropped by the time this was
 * found. The worst was `cloud` — the shop's account, token and sync KEYSET — so
 * typing a business name signed them out of Khayt Cloud and destroyed the key
 * material for their encrypted backups. Also `slicers` (re-detect), `privacy`
 * and `telemetry` (consent choices, reset without asking), and the migration
 * flags `__designV26Migrated` / `_idDedupeDone`, which then re-ran.
 *
 * The fix is to spread the existing settings first, so omission preserves
 * instead of destroying. This pins that, because the failure is invisible in
 * review: the literal looks exhaustive whatever it happens to be missing.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
require('../lib/tax.js');
const { apply } = require('../lib/settings-edit.js');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');

test('the Settings save preserves keys the form does not name', () => {
  // The rule is lib/settings-edit.js now, so this asks it rather than reading
  // a literal: a save with an EMPTY form must hand back every key it was given.
  const before = { cloud: { token: 'T', keyset: 'K' }, anythingAtAll: 1, nested: { deep: [1] } };
  const after = apply(before, {}, { year: 2026 });
  for (const key of Object.keys(before)) {
    assert.deepEqual(after[key], before[key], `a Settings save would drop or change settings.${key}`);
  }
});

test('cloud, the migration flags and the consent choices survive a save', () => {
  // Named individually so a regression reads as the bug it is rather than as a
  // structural complaint.
  const before = { cloud: 1, slicers: 2, privacy: 3, telemetry: 4, __designV26Migrated: 5, _idDedupeDone: 6 };
  const after = apply(before, { phone: '050', enableVat: true, vatRate: 15 }, { year: 2026 });
  for (const key of Object.keys(before)) {
    assert.equal(after[key], before[key], `a Settings save would drop settings.${key}`);
  }
});

test('the renderer saves through the shared rule and has no literal of its own', () => {
  const fn = SRC.indexOf('function saveSettingsFromForm(');
  assert.notEqual(fn, -1, 'saveSettingsFromForm has been renamed — update this test');
  const body = SRC.slice(fn, SRC.indexOf('\n}\n', fn));
  assert.ok(/KhaytSettingsEdit\.apply\(/.test(body),
    'saveSettingsFromForm must call KhaytSettingsEdit.apply — the rule lives in lib/settings-edit.js');
  assert.ok(!/settings = \{/.test(body),
    'and must not rebuild settings from a literal of its own, or the two apps drift');
  assert.ok(/migrateLanApiSettings\(\)/.test(body),
    'the legacy webhook secrets must be migrated before the rule preserves lanApi');
});
