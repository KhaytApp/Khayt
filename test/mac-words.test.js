/**
 * The Mac app's own dictionary, checked from here.
 *
 * WHY THIS IS A NODE TEST AND NOT A SWIFT ONE. `Words.own` is a Swift
 * dictionary literal, and a duplicate key in one of those is not a compile
 * error — it is `Fatal error: Dictionary literal contains duplicate keys`, at
 * first access, **naming nothing**. It takes the whole test process with it, so
 * a Swift test cannot reliably run before the trap and cannot report it
 * afterwards. It has cost an afternoon three times now: `mac.what_went_wrong`,
 * `mac.margin`, and `mac.reveal_in_finder`.
 *
 * Read as text, from the side that always runs in CI, it is a named failure.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const WORDS = path.join(__dirname, '..', 'mac', 'KhaytCore', 'Sources', 'KhaytApp', 'Words.swift');

/** Every `"key": ["en": …, "ar": …]` entry, with the line it is on. */
function entries() {
  const text = fs.readFileSync(WORDS, 'utf8');
  const from = text.indexOf('static let own');
  assert.ok(from > 0, 'Words.own has been renamed — this test is reading nothing');
  const out = [];
  text.slice(from).split('\n').forEach((line, i) => {
    const m = line.match(/^\s*"([a-z][A-Za-z0-9_.]*)"\s*:\s*\[/);
    if (m) out.push({ key: m[1], line: i + 1, text: line });
  });
  return out;
}

test('the Mac app supplies each of its own words once', () => {
  const seen = new Map();
  const dupes = [];
  for (const e of entries()) {
    if (seen.has(e.key)) dupes.push(`${e.key} (first at +${seen.get(e.key)}, again at +${e.line})`);
    else seen.set(e.key, e.line);
  }
  assert.deepEqual(dupes, [], `duplicate keys in Words.own:\n  ${dupes.join('\n  ')}`);
  assert.ok(seen.size > 150, `only ${seen.size} words found — the parse is wrong, not the file`);
});

/**
 * A key with no Arabic is a screen a Saudi shop reads in English. The Swift
 * suite checks this too, but only on a Mac — and there is no macOS CI job.
 */
test('every word the Mac app supplies carries both languages', () => {
  const text = fs.readFileSync(WORDS, 'utf8');
  const body = text.slice(text.indexOf('static let own'));
  // An entry may wrap over several lines; take each from its key to the `],`
  // that closes it.
  const missing = [];
  const re = /"([a-z][A-Za-z0-9_.]*)"\s*:\s*\[([\s\S]*?)\],\n/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    const [, key, value] = m;
    if (!/"en"\s*:/.test(value)) missing.push(`${key} has no English`);
    if (!/"ar"\s*:/.test(value)) missing.push(`${key} has no Arabic`);
  }
  assert.deepEqual(missing, [], `\n  ${missing.join('\n  ')}`);
});

/**
 * A placeholder the other language drops is a sentence that comes out missing
 * its number — "{n} unpaid jobs" reading as " unpaid jobs" in Arabic.
 *
 * ── EXCEPT IN THE SINGULAR AND THE DUAL, WHERE ARABIC SPELLS IT ───────────
 *
 * Arabic's natural `one` and `two` forms carry the number IN WORDS: آلة واحدة
 * is "one machine", آلتان is "two machines", and neither contains a numeral at
 * all. Held to strict parity, correct Arabic fails this test — and the way it
 * fails is quiet: somebody adds `{n}` to the Arabic to make the build pass and
 * ships "١ آلة واحدة", which reads as "one one machine".
 *
 * That happened here. The fix is the guard, not the copy: parity is required
 * per plural CATEGORY rather than per key, and the `one`/`two` categories are
 * where a language is allowed to say the number rather than place it.
 *
 * Every other category — and every string that is not a plural at all — is
 * still held to strict parity, which is almost all of them.
 */
test('both languages carry the same placeholders', () => {
  const text = fs.readFileSync(WORDS, 'utf8');
  const body = text.slice(text.indexOf('static let own'));
  const wrong = [];
  const re = /"([a-z][A-Za-z0-9_.]*)"\s*:\s*\[([\s\S]*?)\],\n/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    const [, key, value] = m;
    const side = (lang) => {
      const at = value.indexOf(`"${lang}"`);
      if (at < 0) return null;
      const next = ['"en"', '"ar"'].map((l) => value.indexOf(l, at + 4)).filter((i) => i > 0);
      const end = next.length ? Math.min(...next) : value.length;
      return value.slice(at, end);
    };
    const marks = (s) => (s ? [...s.matchAll(/\{([a-zA-Z]+)\}/g)].map((x) => x[1]).sort() : []);
    const en = marks(side('en'));
    const ar = marks(side('ar'));
    // The singular and the dual may spell the number out in Arabic; every
    // other category must place it. An Arabic form that drops the placeholder
    // in `one`/`two` is correct, so only the reverse — Arabic carrying a mark
    // English does not — is wrong there.
    const spellsItOut = /_(one|two)$/.test(key);
    const same = en.join(',') === ar.join(',');
    const arabicMayOmit = spellsItOut && ar.length === 0;
    if (!same && !arabicMayOmit) {
      wrong.push(`${key}: en has [${en}] and ar has [${ar}]`);
    }
  }
  assert.deepEqual(wrong, [], `\n  ${wrong.join('\n  ')}`);
});
