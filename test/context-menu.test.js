/**
 * The right-click menu, and the spellchecker behind it.
 *
 * Electron ships NO default context menu. Chromium still spellchecks and still
 * draws the red underline, so a shop typing a product description saw its
 * mistakes marked and had no way to reach a correction. Reported as: "I get
 * spelling errors highlighted but I can't right click to get the correct
 * spelling?"
 *
 * The same absence meant no Cut, Copy, Paste or Select All anywhere in the app.
 * On macOS the shortcuts still work from the application menu; on Windows and
 * Linux, right-click IS how people copy text.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const CM = require('../lib/main/context-menu.js');

// What this Electron build actually offers, checked at runtime before writing
// any of this: six English variants, and no Arabic, Japanese or Chinese.
const AVAILABLE = ['en', 'en-AU', 'en-CA', 'en-GB', 'en-GB-oxendict', 'en-US',
  'de', 'de-DE', 'es', 'es-ES', 'fr', 'fr-FR', 'tr'];

test('a language with a dictionary gets one', () => {
  assert.equal(CM.dictionaryFor('en', AVAILABLE), 'en-GB');
  assert.equal(CM.dictionaryFor('de', AVAILABLE), 'de-DE');
  assert.equal(CM.dictionaryFor('fr', AVAILABLE), 'fr-FR');
  assert.equal(CM.dictionaryFor('tr', AVAILABLE), 'tr');
});

test('a language with NO dictionary gets none, rather than English', () => {
  // This is the whole point. Chromium has no Arabic dictionary, and Khayt is a
  // bilingual app whose other language is Arabic: checking Arabic against
  // en-GB underlines every correct word.
  for (const lang of ['ar', 'ja', 'zh']) {
    assert.equal(CM.dictionaryFor(lang, AVAILABLE), null, `${lang} has no dictionary and must not borrow one`);
  }
});

test('macOS is left alone — its spellchecker is not Chromium\'s', () => {
  /* Electron delegates to NSSpellChecker on macOS: setSpellCheckerLanguages is
   * a SILENT no-op (verified against this build — no error, no change) because
   * the OS picks the language itself as you type. And NSSpellChecker DOES
   * support Arabic, which Chromium does not.
   *
   * So the disable rule below, written for Chromium's missing dictionaries,
   * would have switched off a spellchecker that was working correctly for the
   * exact language it was meant to protect. Found by checking what the platform
   * actually did rather than trusting the API to mean the same thing everywhere.
   */
  const calls = [];
  const session = {
    availableSpellCheckerLanguages: AVAILABLE,
    setSpellCheckerEnabled: (v) => calls.push(['enabled', v]),
    setSpellCheckerLanguages: (l) => calls.push(['languages', l]),
  };
  const r = CM.applyLanguage(session, 'ar', 'darwin');
  assert.equal(r.enabled, true, 'Arabic on macOS keeps the OS spellchecker');
  assert.deepEqual(calls, [], 'and nothing is set at all');
});

test('no dictionary means spellcheck OFF, not spellcheck wrong', () => {
  const calls = [];
  const session = {
    availableSpellCheckerLanguages: AVAILABLE,
    setSpellCheckerEnabled: (v) => calls.push(['enabled', v]),
    setSpellCheckerLanguages: (l) => calls.push(['languages', l]),
  };
  const r = CM.applyLanguage(session, 'ar', 'win32');
  assert.equal(r.enabled, false);
  assert.deepEqual(calls, [['enabled', false]], 'and no language is set at all');

  calls.length = 0;
  const r2 = CM.applyLanguage(session, 'en', 'win32');
  assert.equal(r2.enabled, true);
  assert.equal(r2.language, 'en-GB');
  assert.deepEqual(calls, [['enabled', true], ['languages', ['en-GB']]]);
});

test('a session that throws does not take the language change down', () => {
  const bad = { get availableSpellCheckerLanguages() { throw new Error('boom'); } };
  assert.doesNotThrow(() => CM.applyLanguage(bad, 'en', 'linux'));
  assert.equal(CM.applyLanguage(null, 'en', 'linux').enabled, false);
});

test('right-clicking a misspelling offers the corrections first', () => {
  const picked = [];
  const items = CM.buildTemplate(
    { isEditable: true, misspelledWord: 'colur', dictionarySuggestions: ['colour', 'color', 'col'],
      editFlags: { canCut: true, canCopy: true, canPaste: true, canSelectAll: true } },
    { replaceMisspelling: (w) => picked.push(w) });
  assert.equal(items[0].label, 'colour', 'the correction goes where the pointer already is');
  items[0].click();
  assert.deepEqual(picked, ['colour']);
  assert.ok(items.some((i) => i.label === 'Add to dictionary'));
  // And the ordinary verbs are still there, below.
  for (const role of ['cut', 'copy', 'paste', 'selectAll']) {
    assert.ok(items.some((i) => i.role === role), `${role} must still be offered`);
  }
});

test('a misspelling with no suggestions still says something', () => {
  // An empty menu is what "right-click does nothing" looks like, which is the
  // report this started from.
  const items = CM.buildTemplate({ isEditable: true, misspelledWord: 'zzqq', dictionarySuggestions: [], editFlags: {} }, {});
  assert.equal(items[0].label, 'No suggestions');
  assert.equal(items[0].enabled, false);
  assert.ok(items.some((i) => i.label === 'Add to dictionary'), 'and it can still be taught the word');
});

test('the verbs are gated on what is actually possible', () => {
  const items = CM.buildTemplate({ isEditable: true, editFlags: { canPaste: true } }, {});
  const by = Object.fromEntries(items.filter((i) => i.role).map((i) => [i.role, i.enabled]));
  assert.equal(by.paste, true);
  assert.equal(by.copy, false, 'Copy with nothing selected is offered disabled, not offered working');
  assert.equal(by.cut, false);
});

test('right-clicking nothing shows nothing', () => {
  // An empty menu popping up over a dashboard is its own small bug.
  assert.deepEqual(CM.buildTemplate({}, {}), []);
  assert.deepEqual(CM.buildTemplate(null, null), []);
});

test('selected text on a non-editable element can still be copied', () => {
  const items = CM.buildTemplate({ isEditable: false, selectionText: 'hello', editFlags: { canCopy: true } }, {});
  assert.ok(items.some((i) => i.role === 'copy' && i.enabled), 'reading a value and copying it is the common case');
});

test('the menu speaks the shop\'s language', () => {
  // main has no access to the locale files, so the labels travel with the
  // language over the bridge. A right-click menu that says "Cut" to an Arabic
  // shop is a smaller version of the problem this whole file fixes.
  const strings = { 'menu.cut': 'قص', 'menu.copy': 'نسخ', 'menu.paste': 'لصق',
    'menu.select_all': 'تحديد الكل', 'menu.add_to_dictionary': 'إضافة إلى القاموس' };
  const items = CM.buildTemplate(
    { isEditable: true, editFlags: { canCut: true, canCopy: true, canPaste: true, canSelectAll: true } },
    { t: (k, fallback) => strings[k] || fallback });
  assert.deepEqual(items.filter((i) => i.role).map((i) => i.label), ['قص', 'نسخ', 'لصق', 'تحديد الكل']);
});

test('attach passes the translator all the way through', () => {
  // The path that matters: attach → buildTemplate → label. Asserted because a
  // translator that is accepted and then dropped looks exactly like no
  // translator at all.
  let built = null;
  const win = {
    webContents: {
      on: (_evt, fn) => { win._handler = fn; },
      replaceMisspelling() {}, session: { addWordToSpellCheckerDictionary() {} },
    },
  };
  const Menu = { buildFromTemplate: (tpl) => { built = tpl; return { popup() {} }; } };
  assert.equal(CM.attach(win, { Menu }, (k, fallback) => (k === 'menu.copy' ? 'نسخ' : fallback)), true);
  win._handler({}, { isEditable: true, editFlags: { canCopy: true } });
  assert.ok(built, 'the menu was built');
  assert.equal(built.find((i) => i.role === 'copy').label, 'نسخ');
});

test('the preload bridge forwards the labels, not just the language', () => {
  /* It did not, for one round of testing: the parameter was added to the
   * handler and to the renderer and NOT to the bridge between them, so the
   * strings were built, sent into a function that dropped them, and the menu
   * stayed English while every unit test passed. A bridge that silently
   * truncates its arguments is invisible from both ends.
   */
  const fs = require('fs');
  const path = require('path');
  const pre = fs.readFileSync(path.join(__dirname, '..', 'preload.js'), 'utf8');
  const line = pre.split('\n').find((l) => l.includes('setAppLanguage'));
  assert.ok(line, 'setAppLanguage must be exposed');
  assert.match(line, /setAppLanguage:\s*\(lang,\s*menuStrings\)/, 'it must accept the labels');
  assert.match(line, /invoke\('hub:set-app-language',\s*lang,\s*menuStrings\)/, 'and pass them on');
});
