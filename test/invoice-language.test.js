const { test } = require('node:test');
const assert = require('node:assert/strict');

const L = require('../lib/invoice-language.js');

/**
 * Customer-facing documents printed every label twice — the working language and
 * then Arabic — for every shop in the world (#664, reported in #364 by a shop in
 * the US whose English quotes came out captioned عرض سعر).
 *
 * The governing constraint is that this cannot become "always one language":
 * ZATCA Phase 1 requires Arabic on a Saudi tax invoice, so a shop under that
 * mandate must not be able to switch it off.
 */

const R = (o) => L.resolveDocumentLanguage(o);

test('an English shop gets English, and only English', () => {
  const r = R({ mode: 'auto', lang: 'en', enableZatca: false });
  assert.equal(r.bilingual, false);
  assert.equal(r.secondary, null);
  assert.equal(r.primary, 'en');
});

test('every non-Arabic language behaves the same way — Arabic was never "the other language"', () => {
  // The reported case was English, but the secondary is hardcoded Arabic, so a
  // French shop was getting French+Arabic and a German shop German+Arabic.
  for (const lang of ['fr', 'de', 'es', 'tr', 'pt', 'id', 'zh']) {
    const r = R({ mode: 'auto', lang, enableZatca: false });
    assert.equal(r.bilingual, false, `${lang} must not be paired with Arabic`);
    assert.equal(r.primary, lang);
  }
});

test('an Arabic shop keeps its English pairing', () => {
  // The one combination where the second line does real work: Gulf shops
  // invoicing international customers. Removing it would be a regression for
  // exactly the users the document was designed for.
  const r = R({ mode: 'auto', lang: 'ar', enableZatca: false });
  assert.equal(r.bilingual, true);
  assert.equal(r.secondary, 'en');
});

test('ZATCA forces bilingual, whatever the setting says', () => {
  // Arabic on a tax invoice is a legal requirement under Phase 1. A shop must
  // not be able to quietly issue non-compliant invoices by picking a dropdown.
  for (const mode of ['auto', 'both', 'single']) {
    const r = R({ mode, lang: 'en', enableZatca: true });
    assert.equal(r.bilingual, true, `mode=${mode} must not defeat ZATCA`);
    assert.equal(r.secondary, 'ar');
    assert.equal(r.forced, true, 'the caller needs to know the setting was overridden');
  }
});

test('forced is only true when ZATCA is what decided it', () => {
  // The flag drives a "locked by ZATCA" hint in settings. If it were true for
  // every bilingual result, the hint would appear on shops that simply chose it.
  assert.equal(R({ mode: 'both', lang: 'en', enableZatca: false }).forced, false);
  assert.equal(R({ mode: 'auto', lang: 'ar', enableZatca: false }).forced, false);
});

test('both and single are honoured when ZATCA is off', () => {
  assert.equal(R({ mode: 'both', lang: 'en', enableZatca: false }).bilingual, true);
  assert.equal(R({ mode: 'single', lang: 'ar', enableZatca: false }).bilingual, false);
});

test('an unknown or missing mode reads as auto, never as bilingual-for-everyone', () => {
  // Stores written before this setting existed have no mode at all. Falling back
  // to the old always-bilingual behaviour would mean the fix never reaches them.
  for (const mode of [undefined, null, '', 'yes', 'BOTH', 0, {}]) {
    assert.equal(R({ mode, lang: 'en', enableZatca: false }).bilingual, false, `mode=${JSON.stringify(mode)}`);
    assert.equal(R({ mode, lang: 'ar', enableZatca: false }).bilingual, true, `mode=${JSON.stringify(mode)}`);
  }
});

test('no arguments at all is safe', () => {
  const r = R();
  assert.equal(r.bilingual, false);
  assert.equal(r.primary, 'en');
});

test('the default pairing is Arabic, or English for an Arabic shop', () => {
  assert.equal(L.defaultSecondaryFor('ar'), 'en');
  for (const lang of ['en', 'fr', 'de', 'zh']) assert.equal(L.defaultSecondaryFor(lang), 'ar');
});

test('a shop can choose which language goes second', () => {
  // The reported bug was not only that documents were bilingual — it was that
  // the second language could only ever be Arabic, in all nine translations.
  for (const sec of ['fr', 'de', 'ja', 'pt-BR', 'zh']) {
    const r = R({ mode: 'both', lang: 'en', secondary: sec, enableZatca: false });
    assert.equal(r.bilingual, true);
    assert.equal(r.secondary, sec, `en + ${sec} must be honoured`);
  }
});

test('an Arabic shop can pair with something other than English', () => {
  const r = R({ mode: 'auto', lang: 'ar', secondary: 'fr', enableZatca: false });
  assert.deepEqual({ bi: r.bilingual, sec: r.secondary }, { bi: true, sec: 'fr' });
});

test('a nonsense or self-referential choice falls back to the default pair', () => {
  // Two copies of the same language is not a bilingual document, and an
  // untranslatable code would print the raw keys as the second half.
  for (const bad of ['en', 'klingon', '', null, undefined, 'EN', 42]) {
    assert.equal(R({ mode: 'both', lang: 'en', secondary: bad }).secondary, 'ar', `secondary=${JSON.stringify(bad)}`);
  }
  assert.equal(L.resolveSecondary('ar', 'ar'), 'en', 'an Arabic shop picking Arabic gets the default back');
});

test('ZATCA pins the second language to Arabic, not merely to "some second language"', () => {
  // A tax invoice in English and French carries no Arabic and is not compliant.
  // Picking another language must not be a route around the mandate.
  const r = R({ mode: 'both', lang: 'en', secondary: 'fr', enableZatca: true });
  assert.equal(r.secondary, 'ar', 'the French choice is overridden');
  assert.equal(r.forced, true);
});

test('an Arabic shop under ZATCA keeps its own second language', () => {
  // The mandate is satisfied by the primary language, so nothing is overridden
  // and the "locked by ZATCA" hint must not appear.
  const r = R({ mode: 'both', lang: 'ar', secondary: 'fr', enableZatca: true });
  assert.deepEqual({ sec: r.secondary, forced: r.forced }, { sec: 'fr', forced: false });
});

test('every shipped language can be chosen as the second', () => {
  // A language the app is translated into but cannot print as a second language
  // would be an arbitrary gap in the picker.
  for (const lang of L.LANGS) {
    if (lang === 'en') continue;
    assert.equal(R({ mode: 'both', lang: 'en', secondary: lang }).secondary, lang);
  }
});

test('ZATCA defaults on only for an Arabic setup', () => {
  // It shipped on for everyone, which is how a shop in Ohio ended up sending
  // customers a "ZATCA Phase 1 compliant invoice".
  assert.equal(L.zatcaDefaultFor('ar'), true);
  for (const lang of ['en', 'fr', 'de', 'es', undefined, null, '']) {
    assert.equal(L.zatcaDefaultFor(lang), false, `${lang} must not default to ZATCA`);
  }
});
