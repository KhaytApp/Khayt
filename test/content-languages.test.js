/**
 * Which languages a shop writes its content in.
 *
 * Khayt's interface speaks nine languages; its content spoke exactly two,
 * hard-coded. A shop selling only in Arabic still faced an English field, and a
 * Turkish or German shop could not enter its own language at all — the
 * interface translated for them, the thing they sell did not.
 *
 * The catalogue was inconsistent even within its two: a product had `nameEn`
 * and `nameAr` and a single `description`. The name could be bilingual and the
 * paragraph a customer reads to decide could not.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const CL = require('../lib/content-languages.js');

test('a shop that has never chosen gets exactly what it has today', () => {
  // The store file of a shop that never opens this setting must not change.
  assert.deepEqual(CL.contentLangs(undefined), ['en', 'ar']);
  assert.deepEqual(CL.contentLangs({}), ['en', 'ar']);
  assert.deepEqual(CL.contentLangs({ contentLangs: [] }), ['en', 'ar']);
});

test('a shop can pick one language, or two, and which ones', () => {
  assert.deepEqual(CL.contentLangs({ contentLangs: ['ar'] }), ['ar']);
  assert.deepEqual(CL.contentLangs({ contentLangs: ['tr'] }), ['tr']);
  assert.deepEqual(CL.contentLangs({ contentLangs: ['de', 'tr'] }), ['de', 'tr']);
  // The order is the shop's: it decides which field comes first.
  assert.deepEqual(CL.contentLangs({ contentLangs: ['ar', 'en'] }), ['ar', 'en']);
});

test('nonsense falls back rather than leaving a form with no fields', () => {
  // A product editor with no name field is a worse failure than one showing a
  // language the shop did not pick.
  assert.deepEqual(CL.contentLangs({ contentLangs: ['klingon'] }), ['en', 'ar']);
  assert.deepEqual(CL.contentLangs({ contentLangs: [null, ''] }), ['en', 'ar']);
  assert.deepEqual(CL.contentLangs({ contentLangs: 'en' }), ['en', 'ar']);
  assert.deepEqual(CL.contentLangs({ contentLangs: ['en', 'en'] }), ['en'], 'duplicates collapse');
  assert.equal(CL.contentLangs({ contentLangs: ['en', 'ar', 'tr'] }).length, 2, 'capped');
});

test('English and Arabic keep the keys every existing record uses', () => {
  // The whole back-compatibility story. Renaming these would be a migration
  // across the invoice templates, the storefront payload and the CSV importers
  // to buy nothing.
  assert.equal(CL.fieldKey('name', 'en'), 'nameEn');
  assert.equal(CL.fieldKey('name', 'ar'), 'nameAr');
  assert.equal(CL.fieldKey('description', 'en'), 'descriptionEn');
  // Everything else is suffixed, so a shop that stays on en/ar has a store file
  // identical to the one it has today.
  assert.equal(CL.fieldKey('name', 'tr'), 'name_tr');
  assert.equal(CL.fieldKey('name', 'pt-BR'), 'name_pt-BR');
});

test('reading falls back through the shop\'s languages, then anything filled in', () => {
  const p = { nameEn: 'Bracket', nameAr: 'حامل', name_tr: 'Braket' };
  assert.equal(CL.read(p, 'name', 'ar'), 'حامل');
  assert.equal(CL.read(p, 'name', 'tr'), 'Braket');
  // Asked for a language this product has no name in: fall back to the shop's.
  assert.equal(CL.read(p, 'name', 'de', { contentLangs: ['ar', 'en'] }), 'حامل');
  // A product filled in ONLY in a language nobody asked for still shows.
  // A Turkish name is a far better answer than a blank where the product goes.
  assert.equal(CL.read({ name_tr: 'Braket' }, 'name', 'en'), 'Braket');
  assert.equal(CL.read({}, 'name', 'en'), '');
});

test('an empty string is not an answer', () => {
  // A blank Arabic name must fall through to the English one, not win because
  // the key happens to exist.
  const p = { nameEn: 'Bracket', nameAr: '   ' };
  assert.equal(CL.read(p, 'name', 'ar'), 'Bracket');
});

test('the old single description is not lost', () => {
  // Products saved before this carry `description` with no language on it.
  const p = { description: 'A sturdy bracket.' };
  assert.equal(CL.read(p, 'description', 'en'), 'A sturdy bracket.');
  // And folding it in puts it where the shop will see and can edit it.
  CL.migratePlain(p, 'description', { contentLangs: ['ar', 'en'] });
  assert.equal(p.descriptionAr, 'A sturdy bracket.',
    'the first content language, which is a decision to keep it visible rather than a guess about what language it is in');
  // Never overwrites something already there.
  const q = { description: 'old', descriptionEn: 'new' };
  CL.migratePlain(q, 'description', { contentLangs: ['en'] });
  assert.equal(q.descriptionEn, 'new');
});

test('writing one language leaves the others alone', () => {
  const p = { nameEn: 'Bracket', nameAr: 'حامل' };
  CL.write(p, 'name', 'tr', 'Braket');
  assert.deepEqual(p, { nameEn: 'Bracket', nameAr: 'حامل', name_tr: 'Braket' });
  CL.write(p, 'name', 'ar', '');
  assert.equal(p.nameAr, '', 'clearing a field is a real edit, not a no-op');
  assert.equal(p.nameEn, 'Bracket');
});

test('every supported language has a name a shop would recognise', () => {
  for (const l of CL.SUPPORTED) {
    assert.ok(CL.languageName(l) && CL.languageName(l) !== l, `${l} needs a readable name`);
  }
  // In its OWN language: a shop picking Arabic should see العربية, not "Arabic".
  assert.equal(CL.languageName('ar'), 'العربية');
  assert.equal(CL.languageName('tr'), 'Türkçe');
});

/* ── the app-wide conversion ──────────────────────────────────────────────── */

const fs = require('fs');
const path = require('path');
const RENDERER = path.join(__dirname, '..', 'renderer');
/* BOTH directories, and that is the point.
 *
 * This scanned renderer/ alone, so lib/lan-server.js — which answers the phone
 * and serves the customer-facing quote page — was never looked at. It held
 * three hard-coded pairs, including a quote page that titled itself with the
 * literal word "Khayt" for any shop that did not write English.
 */
const jsFiles = () => ['renderer', 'lib'].flatMap((dir) => {
  const abs = path.join(__dirname, '..', dir);
  return fs.readdirSync(abs).filter((f) => f.endsWith('.js'))
    .map((f) => [`${dir}/${f}`, stripComments(fs.readFileSync(path.join(abs, f), 'utf8'))]);
});

/**
 * Blank out comments, keeping every newline so line numbers still point home.
 *
 * These guards match a SHAPE, and the clearest way to explain a shape is to
 * write it down — so the doc comment above readAlt() quotes the exact ternary
 * this file refuses, and reported itself as an offender. A guard that flags the
 * description of the bug it prevents is one people learn to ignore.
 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/^\s*\/\/.*$/gm, (m) => ' '.repeat(m.length));
}

test('nothing reads the shop\'s own text as a hard-coded English/Arabic pair', () => {
  /* `settings.bizEn || settings.bizAr` appeared in eighteen files. It is correct
   * for a shop writing those two languages and returns an EMPTY STRING for one
   * writing Turkish — so a Turkish shop printed an invoice with a blank business
   * name, published a storefront with no shop name, and had no way to notice
   * except by looking at the document.
   *
   * shopField() runs the same fallback chain everywhere instead.
   */
  const offenders = [];
  for (const [file, src] of jsFiles()) {
    // app-helpers.js holds the fallback shopField() itself uses when the module
    // is absent, which is the one place the raw fields are still the answer.
    if (file.endsWith('app-helpers.js')) continue;
    // `settings?.bizEn` is the same bug and slipped past the un-optional dot.
    for (const m of src.matchAll(/settings\??\.(biz|addr|footer|invTerms|tagline)(En|Ar)\b/g)) {
      const line = src.slice(0, m.index).split('\n').length;
      // A WRITE is fine — the settings form and the wizard have to put text
      // somewhere, and they choose the key from the shop's languages.
      const context = src.slice(Math.max(0, m.index - 60), m.index + m[0].length + 20);
      if (/=\s*$|=\s*[^=]/.test(context.slice(context.indexOf(m[0]) + m[0].length))) continue;
      offenders.push(`${file}:${line}  ${m[0]}`);
    }
  }
  assert.deepEqual(offenders, [],
    `these read the shop's text as English-or-Arabic and return '' for any other language:\n  ${offenders.join('\n  ')}`);
});

test('nothing picks between an English field and an Arabic one by hand', () => {
  /* The guard above covers the five SETTINGS fields and no record fields, so
   * this shape sat under it untouched:
   *
   *     const altName = i18n.current === 'ar' ? p.nameEn : p.nameAr;
   *
   * That is the second line on a catalogue card and a client row — the name in
   * the shop's other language. Written this way it is blank for every shop not
   * writing English and Arabic, so a German-and-French shop had an empty line
   * under every product and every client, in its own app.
   *
   * altLocalName() asks the shop which languages it writes instead. Two live
   * instances existed when this was written; the regex found the second.
   */
  const offenders = [];
  const RE = /(?:i18n\.current|lang)\s*===?\s*'ar'\s*\?[^;\n]*\b\w+(?:En|Ar)\b[^;\n]*:[^;\n]*\b\w+(?:En|Ar)\b/g;
  for (const [file, src] of jsFiles()) {
    // app-helpers.js holds localName()/altLocalName()'s own fallback for when the
    // content-language module is absent — the one place this shape is the answer.
    if (file.endsWith('app-helpers.js')) continue;
    for (const m of src.matchAll(RE)) {
      offenders.push(`${file}:${src.slice(0, m.index).split('\n').length}  ${m[0].trim()}`);
    }
  }
  assert.deepEqual(offenders, [],
    `these choose between two hard-coded languages and are blank for any other:\n  ${offenders.join('\n  ')}`);
});

test('nothing falls back from an English field to an Arabic one and stops there', () => {
  /* The sibling of the ternary guard, and the shape it does not match:
   *
   *     const clientName = client.nameEn || client.nameAr || '';
   *
   * Eight of these were live. Two of them produced text SENT TO A CUSTOMER — a
   * campaign's {{name}} merge field and the waiting-list reminder — so a shop
   * writing German mailed its whole client list a message opening "Hi ,".
   * Another compared a typed client name against an empty string and offered to
   * create a duplicate of a client the shop already had.
   *
   * A search filter reading `(c.nameEn || '')` alone does not match this and is
   * not the bug: it is one field, not a two-language pick that excludes seven.
   */
  const offenders = [];
  // Either order. Neither direction is live today; a guard that only knows the
  // one that happened to be written is half a guard.
  const RE = /\w+\.(?:name|desc|description)(?:En|Ar)\s*\|\|\s*\w+\.(?:name|desc|description)(?:En|Ar)/g;
  for (const [file, src] of jsFiles()) {
    // app-helpers.js holds localName()'s own module-absent fallback; lan-server
    // asks `hasEnAr` on purpose, to decide whether to backfill a legacy field.
    if (file.endsWith('app-helpers.js')) continue;
    for (const m of src.matchAll(RE)) {
      const line = src.slice(0, m.index).split('\n').length;
      if (file.endsWith('lan-server.js') && /hasEnAr/.test(src.split('\n')[line - 1])) continue;
      offenders.push(`${file}:${line}  ${m[0].trim()}`);
    }
  }
  assert.deepEqual(offenders, [],
    `these fall back English→Arabic and are blank for any other language:\n  ${offenders.join('\n  ')}`);
});

test('the settings form builds its fields from the chosen languages', () => {
  const src = fs.readFileSync(path.join(RENDERER, 'settings.js'), 'utf8');
  assert.match(src, /function renderContentFields\(\)/,
    'the five shop-text fields are built per language, not hard-coded as pairs');
  // Read back into the form the shared save rule is handed (the save itself
  // is lib/settings-edit.js now, which spreads `content` over the settings).
  assert.match(src, /content:\s*readContentFields\(\)/,
    'and read back from whatever fields are on screen');
  // The old ten hard-coded save lines are gone.
  assert.doesNotMatch(src, /bizEn:\s*\$\('#set_bizEn'\)/);
  assert.doesNotMatch(src, /invTermsAr:\s*\$\('#set_invTermsAr'\)/);
});

test('a language the shop stops using keeps its text', () => {
  // Removing a language must not erase what was written in it: putting the
  // language back should bring the text with it. readContentFields only reads
  // fields that are ON SCREEN, and the save spreads over the existing settings.
  const src = fs.readFileSync(path.join(RENDERER, 'settings.js'), 'utf8');
  const fn = src.slice(src.indexOf('function readContentFields()'), src.indexOf('function renderContentLangsPicker'));
  assert.match(fn, /if \(el\) out\[key\] = el\.value\.trim\(\);/,
    'only on-screen fields are collected, so the rest survive the spread');
});

test('an interface language the shop does not write in does not win', () => {
  /* A shop that writes only Turkish, viewed on an English interface, must show
   * its TURKISH name — not the stale `bizEn` left over from setup, which is a
   * name it stopped using and may not recognise. What the reader's interface is
   * set to does not decide what the business is called.
   *
   * Found because shopField() defaults to the interface language: with the
   * module reading correctly, the helper still returned 'Khayt' for a shop
   * called Atölye Baskı.
   */
  const shop = { bizEn: 'Khayt', biz_tr: 'Atölye Baskı' };
  const settings = { contentLangs: ['tr'] };
  assert.equal(CL.read(shop, 'biz', 'en', settings), 'Atölye Baskı');
  assert.equal(CL.read(shop, 'biz', 'tr', settings), 'Atölye Baskı');
  // But a shop that DOES write English still gets English when English is asked for.
  assert.equal(CL.read(shop, 'biz', 'en', { contentLangs: ['en', 'tr'] }), 'Khayt');
  assert.equal(CL.read(shop, 'biz', 'tr', { contentLangs: ['en', 'tr'] }), 'Atölye Baskı');
  // With no settings at all, the caller's request is all there is to go on.
  assert.equal(CL.read(shop, 'biz', 'en'), 'Khayt');
});

/* ── the second line ───────────────────────────────────────────────────────
 *
 * A bilingual shop shows both languages at once: the catalogue card prints the
 * name in the working language and the other underneath. That second slot was
 * written as `i18n.current === 'ar' ? p.nameEn : p.nameAr` — correct for
 * exactly one pair of languages, and blank for every other. A German-and-French
 * shop had an empty line under every product in its own catalogue.
 */

test('the second line is the shop\'s other language, whatever that is', () => {
  const de_fr = { contentLangs: ['de', 'fr'] };
  const p = { name_de: 'Halterung', name_fr: 'Support' };
  assert.equal(CL.read(p, 'name', 'en', de_fr), 'Halterung', 'an English interface still leads with the shop\'s first language');
  assert.equal(CL.readAlt(p, 'name', 'en', de_fr), 'Support');
  // And it follows the reader: a French interface leads with French.
  assert.equal(CL.read(p, 'name', 'fr', de_fr), 'Support');
  assert.equal(CL.readAlt(p, 'name', 'fr', de_fr), 'Halterung');
});

test('the two lines are never the same language twice', () => {
  for (const langs of [['en', 'ar'], ['de', 'fr'], ['tr', 'en'], ['ja', 'zh']]) {
    const s = { contentLangs: langs };
    for (const want of ['en', 'ar', 'de', 'fr', 'tr']) {
      const other = CL.otherLang(want, s);
      assert.ok(langs.includes(other), `${other} is not one of the shop's languages`);
      // The primary is whichever read() would show; the second must not be it.
      const shown = langs.includes(want) ? want : langs[0];
      assert.notEqual(other, shown, `${langs.join('/')} viewed as ${want} printed one language twice`);
    }
  }
});

test('a single-language shop has no second line at all', () => {
  const only = { contentLangs: ['ar'] };
  assert.equal(CL.otherLang('ar', only), null);
  assert.equal(CL.readAlt({ nameAr: 'حامل' }, 'name', 'ar', only), '');
});

test('an unfilled second language prints nothing, not the first name again', () => {
  // read() falls back so a product is never nameless. readAlt must NOT: repeating
  // the primary underneath itself reads as a bug, and a blank is the truth.
  const s = { contentLangs: ['en', 'ar'] };
  assert.equal(CL.read({ nameEn: 'Bracket' }, 'name', 'en', s), 'Bracket');
  assert.equal(CL.readAlt({ nameEn: 'Bracket' }, 'name', 'en', s), '');
  assert.equal(CL.readAlt({ nameEn: 'Bracket', nameAr: '   ' }, 'name', 'en', s), '',
    'whitespace is not a name');
});

test('the second line does not throw on junk', () => {
  assert.equal(CL.readAlt(null, 'name', 'en', { contentLangs: ['en', 'ar'] }), '');
  assert.equal(CL.readAlt({}, 'name', 'en', null), '');
});

/* ── settings keys that were never settings ───────────────────────────────
 *
 * Not a language bug, found by the same sweep: `settings.address` is read in
 * three places and written in none. The field is `addr`, per language. Two of
 * those three reads fill sellerStreet in the ZATCA e-invoice XML, so every
 * Phase-2 invoice went to the tax authority with the seller's street blank.
 *
 * `settings.orderPrefix` was the same shape: read once, in the LAN server, so
 * an order raised on the phone ignored the prefix the shop had set and came out
 * numbered differently from every order raised at the desk.
 *
 * A read with a sensible default (`|| 'QUO'`, `|| 0.01`) is not this. These two
 * had no default worth having: an empty compliance field, and a constant that
 * disagreed with the rest of the app.
 */
test('no settings key is read that nothing ever writes', () => {
  const RETIRED = ['address', 'orderPrefix'];
  const sources = [...jsFiles().map(([, s]) => s), fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8')];
  const all = sources.join('\n');
  for (const key of RETIRED) {
    const read = new RegExp(`settings\\??\\.${key}\\b`);
    assert.equal(read.test(all), false,
      `settings.${key} is read but nothing writes it — it is always the fallback`);
  }
  // And the two that replaced them are real: written, with a form field.
  const state = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-state.js'), 'utf8');
  assert.match(state, /invPrefix:\s*'INV'/, 'the prefix the desktop actually mints orders with');
});

test('the phone numbers an order the way the desk does', () => {
  // Different prefixes meant one shop's orders arrived under two schemes
  // depending on which device raised them. The desk's copy of the rule is gone:
  // what a new job IS lives in lib/order-new.js, which the desk, the phone and
  // the Mac app all build the record with. So this now pins the LAN server to
  // that one rule rather than to a second copy in the renderer.
  // `POST /api/orders` is lib/lan-rest.js's `orderCreate` now, which both LAN
  // servers (the desktop's and the Mac's) build the record with.
  const lan = fs.readFileSync(path.join(__dirname, '..', 'lib', 'lan-rest.js'), 'utf8');
  const shared = fs.readFileSync(path.join(__dirname, '..', 'lib', 'order-new.js'), 'utf8');
  const of = (src) => (src.match(/asQuote \? \(settings\.quotePrefix \|\| 'QUO'\) : \(settings\.(\w+) \|\| '(\w+)'\)/) || []).slice(1);
  // Since Nov 2026 it does not copy the prefix line at all: it asks the shared
  // rule for the whole record, so there is no second copy to drift.
  assert.match(lan, /N\.newOrder\(\{/, 'POST /api/orders builds its record with lib/order-new.js newOrder');
  assert.deepEqual(of(lan), [], 'and has no order prefix of its own to drift');
  assert.deepEqual(of(shared), ['invPrefix', 'INV']);

  // And the renderer must not have grown one back.
  const desk = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'order-flows.js'), 'utf8');
  assert.deepEqual(of(desk), [], 'the renderer has its own order prefix again');
});
