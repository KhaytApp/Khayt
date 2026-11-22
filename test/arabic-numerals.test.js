const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { fmtCount } = require('../renderer/format.js');

/**
 * Saudi products ship WESTERN digits, not Arabic-Indic ones.
 *
 * Codepoint scans of live Arabic pages — Al Rajhi, SNB, Absher, Tawakkalna,
 * Salla, Zid, STC, DGA, SAMA — found Western digits essentially everywhere.
 * The one exception proves it: Al Rajhi's news dates render ٢١ يوليو ٢٠٢٦
 * while every financial figure on the same page is Western, including its
 * Hijri date. That is a locale-aware formatter leaking, not a house style.
 *
 * Khayt had the identical leak: `toLocaleDateString('ar-SA')` yields
 * ٢٢ يوليو ٢٠٢٦, and a bare `.toLocaleString()` inherits the SYSTEM locale, so
 * a Saudi machine rendered Arabic-Indic digits even with the UI in English.
 */

const ARABIC_INDIC = /[٠-٩]/;           // ٠-٩
const ARABIC_SEPARATORS = /[٫٬]/;       // decimal + thousands

test('fmtCount never emits Arabic-Indic digits', () => {
  for (const n of [0, 7, 1000, 18750, 1234567, -42, 0.5]) {
    const out = fmtCount(n);
    assert.ok(!ARABIC_INDIC.test(out), `${n} rendered as ${out}`);
    assert.ok(!ARABIC_SEPARATORS.test(out), `${n} used an Arabic separator: ${out}`);
  }
});

test('fmtCount groups thousands', () => {
  assert.equal(fmtCount(18750), '18,750');
  assert.equal(fmtCount(1234567), '1,234,567');
  assert.equal(fmtCount(999), '999');
});

test('fmtCount survives junk rather than printing NaN at a customer', () => {
  assert.equal(fmtCount(undefined), '0');
  assert.equal(fmtCount(null), '0');
  assert.equal(fmtCount('not a number'), '0');
  assert.equal(fmtCount(Infinity), '0');
});

test('fmtCount is exported on the module AND as a global', () => {
  // These files are plain <script> tags in a non-bundled renderer: anything not
  // assigned to the global is module-scoped, and a cross-file call becomes a
  // ReferenceError only visible on the screen that uses it. That exact bug has
  // shipped here more than once.
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'format.js'), 'utf8');
  assert.match(src, /const api = \{[^}]*\bfmtCount\b/, 'missing from the api object');
  assert.match(src, /global\.fmtCount\s*=\s*fmtCount/, 'never assigned to the global');
});

test('every ar-SA locale tag pins Latin numerals', () => {
  // Bare 'ar-SA' resolves to numberingSystem "arab" in CLDR, so it must always
  // carry -nu-latn. A new call site added without it is invisible until someone
  // in Riyadh sees ٢٢ يوليو ٢٠٢٦ on their dashboard.
  const dir = path.join(__dirname, '..', 'renderer');
  const offenders = [];
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.js'))) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const m of src.matchAll(/'(ar-SA[^']*)'/g)) {
      if (!m[1].includes('nu-latn')) offenders.push(`${f}: ${m[1]}`);
    }
  }
  assert.deepEqual(offenders, [],
    `these will render Arabic-Indic digits: ${offenders.join(', ')}`);
});

test('the pinned tags actually produce Western digits, calendar intact', () => {
  // Guards the BCP-47 spelling itself — a malformed extension is silently
  // ignored by Intl rather than throwing, so a typo would look like it worked.
  const d = new Date('2026-07-22T14:30:00Z');
  const greg = d.toLocaleDateString('ar-SA-u-nu-latn', { year: 'numeric', month: 'long', day: 'numeric' });
  assert.ok(!ARABIC_INDIC.test(greg), `Gregorian still Arabic-Indic: ${greg}`);

  const hijri = d.toLocaleDateString('ar-SA-u-ca-islamic-umalqura-nu-latn',
    { year: 'numeric', month: 'long', day: 'numeric' });
  assert.ok(!ARABIC_INDIC.test(hijri), `Hijri still Arabic-Indic: ${hijri}`);
  assert.equal(
    new Intl.DateTimeFormat('ar-SA-u-ca-islamic-umalqura-nu-latn').resolvedOptions().calendar,
    'islamic-umalqura', 'adding -nu-latn must not drop the Hijri calendar');
});
