/**
 * A renderer module must export what the rest of the app calls on it.
 *
 * These files are IIFEs with a hand-maintained `const api = { … }` at the
 * bottom, so a function can be defined, used, and simply not listed — and
 * nothing complains until someone calls it through the global at runtime.
 *
 * It has happened repeatedly:
 *
 *   `syncScopeToShop`  missing from app-state's list → cloud sign-in froze.
 *   `shopField`        declared above app-helpers' IIFE → invisible to require.
 *   `syncSidebarSubtitle` inserted into the WRONG object — a regex matching
 *      `const api = \{([^}]*)\}` stopped at the first `}`, which belonged to an
 *      arrow function's fallback literal three lines earlier. `node --check`
 *      passed, because it was still valid syntax: the entry landed inside
 *      `accentsForDesign`'s default, so that accessor started returning a
 *      function where an empty object belonged, and the export was never made.
 *      Found by launching the app, not by reading the diff or grepping for the
 *      name — which is exactly why this exists.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const RENDERER = path.join(__dirname, '..', 'renderer');
const files = fs.readdirSync(RENDERER).filter((f) => f.endsWith('.js'))
  .map((f) => [f, fs.readFileSync(path.join(RENDERER, f), 'utf8')]);

/**
 * The keys of the object literal starting at `from`, matching braces properly.
 *
 * Splitting on NEWLINES was the first attempt and it was wrong: an api written
 * on one line — `const api = { a, b, c };` — yielded no keys at all, so every
 * method looked unexported and the guard reported a file that was perfectly
 * fine. A key list has to be read as a key list, at depth zero, however it is
 * laid out.
 */
function literalKeys(src, from) {
  let depth = 0;
  let i = src.indexOf('{', from);
  const start = i;
  for (; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') { depth--; if (depth === 0) break; }
  }
  /* Comments come out FIRST, and that ordering is the whole trick.
   *
   * Stripping them per-segment after the split does not work: a comment
   * containing an apostrophe — "app-boot.js's keydown handler" — opens a string
   * that never closes, so every comma after it is read as being inside a string
   * and the entries below it vanish. shell.js has exactly that comment, and the
   * guard reported `isGlobalSearchOpen` as unexported when it is right there. */
  const body = src.slice(start + 1, i)
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/^[ \t]*\/\/[^\n]*/gm, ' ');

  // Top-level segments: split on commas that are not inside a nested
  // brace/bracket/paren, and not inside a string.
  const segments = [];
  let buf = '';
  let d = 0;
  let quote = null;
  for (let j = 0; j < body.length; j++) {
    const ch = body[j];
    if (quote) {
      if (ch === quote && body[j - 1] !== '\\') quote = null;
      buf += ch;
      continue;
    }
    if (ch === '"' || ch === "'" || ch === '`') { quote = ch; buf += ch; continue; }
    if (ch === '{' || ch === '[' || ch === '(') d++;
    else if (ch === '}' || ch === ']' || ch === ')') d--;
    if (ch === ',' && d === 0) { segments.push(buf); buf = ''; continue; }
    buf += ch;
  }
  segments.push(buf);

  const keys = new Set();
  for (const seg of segments) {
    // Strip comments, then take the identifier before `:` (or the whole thing,
    // for shorthand).
    const clean = seg.trim();
    if (!clean) continue;
    const m = clean.match(/^([A-Za-z_$][\w$]*)\s*(?::|$)/);
    if (m) keys.add(m[1]);
  }
  return keys;
}

test('every Khayt* global exports the methods the app calls on it', () => {
  const exported = new Map();
  for (const [file, src] of files) {
    const g = src.match(/\bglobal\.(Khayt[\w$]*)\s*=\s*api\s*;/);
    if (!g) continue;
    const at = src.lastIndexOf('const api = {');
    if (at === -1) continue;
    exported.set(g[1], { file, keys: literalKeys(src, at) });
  }
  assert.ok(exported.size >= 5, 'the scan itself must be finding modules');

  const missing = [];
  for (const [file, src] of files) {
    for (const m of src.matchAll(/\b(Khayt[\w$]*)\.([A-Za-z_$][\w$]*)\s*\(/g)) {
      const mod = exported.get(m[1]);
      if (!mod || mod.file === file) continue;      // not ours, or its own file
      if (mod.keys.has(m[2])) continue;
      const line = src.slice(0, m.index).split('\n').length;
      missing.push(`${file}:${line}  ${m[1]}.${m[2]}() — not in ${mod.file}'s api`);
    }
  }
  assert.deepEqual([...new Set(missing)], [],
    `these call through a global that does not export them — they throw the first time the path runs:\n  ${missing.join('\n  ')}`);
});

test('the accessor that broke keeps its own shape', () => {
  // The entry landed inside this arrow's fallback, so it returned a function
  // where callers expect a map of accents. Cheap to pin, and it was silent.
  const src = fs.readFileSync(path.join(RENDERER, 'themes.js'), 'utf8');
  assert.match(src, /accentsForDesign: \(id\) => reg\(\)\?\.accentsForTheme\(id\) \|\| \{\},/,
    'the fallback must be an empty object, not somewhere an export can hide');
});
