'use strict';
/**
 * Every order status the phone can show has a word in both its languages.
 *
 * ── THE SAME BUG, THREE TIMES ─────────────────────────────────────────────
 *
 * `OrderStatus` in the companion is a closed enum. When the desktop gained a
 * status the enum did not follow, every use site fell back to
 * `status.capitalized` — so an Arabic shop read the raw English word. Nothing
 * crashed, nothing was reported; it just quietly stopped being translated.
 *
 * It happened with `quote`, with `delivered`, and again with `shipped`.
 *
 * `scripts/ios-contract-decode.swift` catches the first half — a desktop status
 * with no enum case — by decoding live server responses. NOTHING caught the
 * second half: an enum case with no entry in `Localizable.strings`, or an entry
 * in English with none in Arabic. There was no test over those tables at all.
 *
 * So this is the grep, committed, in the pattern [[sweep-with-a-ratchet]]
 * describes. It reads the enum rather than a list typed here, because a
 * hand-copied list is a guard that stops guarding the day somebody adds a case.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');
const MODELS = path.join(ROOT, 'ios/KhaytCompanion/Models/KhaytModels.swift');
const TABLES = {
  en: path.join(ROOT, 'ios/KhaytCompanion/Resources/en.lproj/Localizable.strings'),
  ar: path.join(ROOT, 'ios/KhaytCompanion/Resources/ar.lproj/Localizable.strings'),
};

/** The cases of `enum OrderStatus`, read from the enum itself. */
function orderStatuses() {
  const src = fs.readFileSync(MODELS, 'utf8');
  const at = src.indexOf('enum OrderStatus');
  assert.ok(at > 0, 'could not find enum OrderStatus — this guard has rotted');
  const body = src.slice(at, src.indexOf('\n}', at));
  const line = body.split('\n').find((l) => /^\s*case\s+\w+\s*(,|$)/.test(l));
  assert.ok(line, 'could not read the case list — this guard has rotted');
  const names = line.replace(/^\s*case\s+/, '').split(',').map((s) => s.trim()).filter(Boolean);
  assert.ok(names.length >= 5, `parsed implausibly few statuses: ${JSON.stringify(names)}`);
  return names;
}

/** The keys defined in one `.strings` table. */
function keysOf(file) {
  const out = new Set();
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/^\s*"([^"]+)"\s*=\s*"(.*)"\s*;\s*$/);
    if (m) out.add(m[1]);
  }
  assert.ok(out.size > 20, `${file} parsed implausibly small`);
  return out;
}

test('every OrderStatus case has a word in English AND Arabic', () => {
  const statuses = orderStatuses();
  for (const [lang, file] of Object.entries(TABLES)) {
    const keys = keysOf(file);
    const missing = statuses.filter((s) => !keys.has(`status.${s}`));
    assert.deepEqual(missing, [],
      `${lang} has no word for ${missing.map((s) => `status.${s}`).join(', ')} — `
      + 'the phone falls back to the raw English status name, silently');
  }
});

test('the two tables carry the same keys', () => {
  // A key in one table and not the other is the same failure with a smaller
  // blast radius: it reads correctly in the language somebody tested in.
  const en = keysOf(TABLES.en);
  const ar = keysOf(TABLES.ar);
  const onlyEn = [...en].filter((k) => !ar.has(k)).sort();
  const onlyAr = [...ar].filter((k) => !en.has(k)).sort();
  assert.deepEqual(onlyEn, [], `English-only keys — Arabic falls back: ${onlyEn.join(', ')}`);
  assert.deepEqual(onlyAr, [], `Arabic-only keys — dead weight: ${onlyAr.join(', ')}`);
});

test('no status is left with the English word standing in for Arabic', () => {
  // A copied placeholder is worse than a missing key: the parity test above
  // passes and the shop still reads English.
  const en = fs.readFileSync(TABLES.en, 'utf8');
  const ar = fs.readFileSync(TABLES.ar, 'utf8');
  const read = (src) => Object.fromEntries([...src.matchAll(/^\s*"(status\.[^"]+)"\s*=\s*"(.*)"\s*;\s*$/gm)]
    .map((m) => [m[1], m[2]]));
  const e = read(en), a = read(ar);
  const untranslated = Object.keys(e).filter((k) => a[k] && a[k] === e[k] && /[A-Za-z]/.test(a[k]));
  assert.deepEqual(untranslated, [],
    `Arabic still holds the English word for: ${untranslated.join(', ')}`);
});
