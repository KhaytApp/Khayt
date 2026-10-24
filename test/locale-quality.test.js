'use strict';
/**
 * Two ways a locale bundle passes every existing gate and is still wrong.
 *
 * `locale-parity.test.js` proves every English key EXISTS in every language and
 * that its {placeholders} survive. Neither says anything about the value. A
 * bundle can be at full parity and still show a German user an English
 * sentence, because the "translation" is the English string copied across.
 *
 * Found by auditing rather than by anyone reporting it: 40 keys were sitting in
 * de/es/fr/zh as untouched English — the whole CSV import dialog, the resin
 * calculator's fields, the order status page, the waste report. Nothing was
 * broken, nothing threw, and every gate was green.
 *
 * The second one is smaller and stranger. Fifty-six English values carry a
 * glyph of their own — "+ Add Client", "✓ Paid", "← Back" — because the markup
 * does not supply an icon for them. Where a translator dropped that glyph, the
 * same button gained or lost a "+" depending on the language. Eight keys had
 * done exactly that.
 *
 * ── WHY THE GLYPHS ARE NOT SIMPLY DELETED ──────────────────────────────────
 * They are doing real work: nothing else marks those buttons as "add". Moving
 * them into the markup as icons is the right end state and is a separate piece
 * of work; until then the requirement is that every language shows the SAME
 * button. What is not acceptable is a glyph in some languages and not others.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '../renderer/locales');
for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.js')).sort()) require(path.join(dir, f));
const L = global.KhaytLocales || {};
const EN = L.en;
const OTHERS = Object.keys(L).filter((k) => k !== 'en').sort();

/**
 * Values that are the same in English and everywhere else ON PURPOSE.
 *
 * Each is a format, not a sentence: a mask the user types over, or a line with
 * no words in it at all. A translator has nothing to do here, so "untranslated"
 * is the correct state and the guard must not nag about it.
 */
const SAME_ON_PURPOSE = new Set([
  'calc.elec_preview',  // "≈ {rate} {base}/kWh" — no words, only units
  'cplan.vault',        // "Khayt Vault — {size}" — the product's name and a size; Arabic writes its own name
  'set.iban_ph',        // "SAxx xxxx xxxx xxxx xxxx xxxx" — a Saudi IBAN mask
  'set.supplier_ph',    // "+966 5x xxx xxxx" — a Saudi phone mask
  'zatca2.egs_cn',      // "EGS Common Name" — the X.509 term German PKI keeps
]);

/** A real sentence, not a cognate. "Material" is German; "Choose CSV file" is not. */
const isProse = (v) => {
  const s = String(v).trim();
  return s.length >= 14 && s.split(/\s+/).length >= 3 && /[A-Za-z]{3}/.test(s);
};

test('no language shows an English sentence because nobody translated it', () => {
  const offenders = [];
  for (const key of Object.keys(EN)) {
    if (SAME_ON_PURPOSE.has(key) || !isProse(EN[key])) continue;
    for (const loc of OTHERS) {
      const v = L[loc][key];
      if (v != null && String(v).trim() === String(EN[key]).trim()) offenders.push(`${loc}  ${key}`);
    }
  }
  assert.deepEqual(offenders, [],
    `${offenders.length} value(s) are the English string verbatim. Translate them, or — if the `
    + 'value really is a format with nothing to translate — add the key to SAME_ON_PURPOSE '
    + `with the reason:\n    ${offenders.slice(0, 25).join('\n    ')}`);
});

/**
 * The glyph an English value leads with must lead every other language's.
 *
 * Checked on the LEADING run only. A glyph inside a sentence is prose and is the
 * translator's business; a glyph at the front is the button's affordance and is
 * not.
 */
const LEADING = /^\s*((?:[+＋✕✓✗×→←↩⏸▶■]|[\u{1F300}-\u{1FAFF}]|[\u{2190}-\u{21FF}]|[\u{2600}-\u{27BF}])+)/u;

test('a button that says "+" in English says "+" in all nine languages', () => {
  const offenders = [];
  let checked = 0;
  for (const key of Object.keys(EN)) {
    const m = LEADING.exec(EN[key]);
    if (!m) continue;
    checked++;
    const want = m[1].trim();
    for (const loc of OTHERS) {
      const v = L[loc][key];
      if (v == null) continue;
      const got = LEADING.exec(v);
      if (!got || got[1].trim() !== want) {
        offenders.push(`${loc}  ${key}  expected ${JSON.stringify(want)}, got ${JSON.stringify(String(v).slice(0, 24))}`);
      }
    }
  }
  // The check is worthless if it stops finding the strings it is about.
  assert.ok(checked > 40, `only ${checked} English values lead with a glyph — this guard has stopped looking at anything`);
  assert.deepEqual(offenders, [],
    `${offenders.length} value(s) drop or change the glyph the English one leads with, so the same `
    + `button looks different per language:\n    ${offenders.slice(0, 25).join('\n    ')}`);
});

test('the guard can tell a cognate from an untranslated sentence', () => {
  // Single words that are legitimately identical must NOT be reported: German
  // "Material", French "Total", "Documents". This is why the check needs three
  // words and fourteen characters rather than simple inequality.
  assert.equal(isProse('Material'), false);
  assert.equal(isProse('Total'), false);
  assert.equal(isProse('Port'), false);
  assert.equal(isProse('Choose CSV file'), true);
  assert.equal(isProse('Waste as % of revenue'), true);
});
