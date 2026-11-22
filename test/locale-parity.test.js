'use strict';

// Guards against silent locale drift. `check-locale-files.js` only syntax-checks
// each bundle; this asserts key coverage. English is the source of truth.
//
// Hard gate: EVERY shipped locale must cover every English key. A new English
// string without a translation silently falls back to English (and breaks RTL
// for ar) — which is exactly how the whole 3.1 feature suite shipped untranslated
// in de/es/fr/ja/tr/zh before this gate was tightened. All 7 non-en locales are
// now at full parity; keep them there.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname, '../renderer/locales');
const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js')).sort();
for (const f of files) require(path.join(dir, f));

const L = global.KhaytLocales || {};
/* Read from the directory, not hand-kept. `pt-BR` was missing from this list —
 * a complete, shipped locale that the parity gate simply did not check, saved
 * only by i18n-locales.test.js happening to duplicate the coverage. A locale
 * added later would have been in the same position with nothing to catch it. */
const LOCALES = fs.readdirSync(dir)
  .filter((f) => f.endsWith('.js') && f !== 'en.js')
  .map((f) => f.replace(/\.js$/, ''))
  .sort();

test('all locale bundles load', () => {
  assert.ok(L.en, 'en bundle present');
  for (const code of LOCALES) {
    assert.ok(L[code], `${code} bundle present`);
  }
});

test('every locale covers every English key (parity gate)', () => {
  const en = Object.keys(L.en);
  for (const code of LOCALES) {
    const have = new Set(Object.keys(L[code]));
    const missing = en.filter((k) => !have.has(k));
    assert.deepEqual(
      missing,
      [],
      `${code} is missing ${missing.length} key(s) present in en: ${missing.slice(0, 20).join(', ')}`,
    );
  }
});

test('locale orphan report (informational — does not fail)', () => {
  const en = new Set(Object.keys(L.en));
  for (const code of LOCALES) {
    const orphans = Object.keys(L[code]).filter((k) => !en.has(k));
    if (orphans.length) {
      console.log(`  [locale-parity] ${code}: orphans(notInEn)=${orphans.length} — ${orphans.slice(0, 10).join(', ')}`);
    }
  }
  assert.ok(true);
});

test('every locale preserves every English {placeholder} (interpolation parity)', () => {
  // A translation that drops a {token} silently shows the user a string missing
  // its dynamic value (amounts, dates, counts) — see the credit-limit/overcommit
  // confirm dialogs. Guard every locale against that drift.
  const ph = (s) => [...new Set(String(s).match(/\{[a-zA-Z0-9_]+\}/g) || [])].sort();
  const bad = [];
  for (const code of LOCALES) {
    for (const k of Object.keys(L.en)) {
      if (L[code][k] === undefined) continue;
      const e = ph(L.en[k]).join(','), a = ph(L[code][k]).join(',');
      if (e !== a) bad.push(`${code}:${k} (en:[${e}] ${code}:[${a}])`);
    }
  }
  assert.deepEqual(bad, [], `${bad.length} key(s) drop/alter placeholders: ${bad.slice(0, 15).join('; ')}`);
});

test('no key is defined twice in the same bundle', () => {
  /* JS keeps the LAST of two identical keys, silently, and `node --check` — the
   * only thing that reads these files in `npm run lint` — is perfectly happy.
   *
   * `notif.recurring_due` was defined twice in en and ar, once as a title and
   * once as a sentence with {name} and {days} in it. The title therefore
   * rendered "Recurring order due: {name} ({days} days since last)" — braces and
   * all — on the notification card, in every language. Nothing anywhere failed.
   *
   * Read from the SOURCE rather than the loaded object, because by the time it
   * is an object one of the two is already gone. */
  const offenders = [];
  for (const f of files) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    const seen = new Set();
    for (const m of src.matchAll(/^  "([a-zA-Z0-9_.]+)":/gm)) {
      if (seen.has(m[1])) offenders.push(`${f}  ${m[1]}`);
      seen.add(m[1]);
    }
  }
  assert.deepEqual(offenders, [],
    `these keys are defined twice; the second silently wins:\n    ${offenders.join('\n    ')}`);
});
