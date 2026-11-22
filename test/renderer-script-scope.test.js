/**
 * A lib/ module loaded by a <script> tag must not declare anything at top level.
 *
 * Plain script tags share ONE global scope. Two modules that each declare
 * `const api` do not shadow each other politely — the second file fails to parse
 * with "Identifier 'api' has already been declared", and every export it was
 * going to publish silently never appears. Whatever called into it then breaks
 * somewhere else entirely, which is a long way from the actual cause.
 *
 * This is not hypothetical. Adding lib/pricing.js with a top-level `const api`
 * collided with lib/printer-profiles.js, which had the same name. Nothing in the
 * unit suite noticed: each file parses perfectly on its own, and Node's `require`
 * gives every module its own scope, so the collision only exists in the browser-
 * like environment the app actually runs in. It surfaced in the populated-screens
 * e2e as one line — a SyntaxError with no file attached.
 *
 * Cheaper to check statically, and it names the file.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

/** Every lib/ module pulled in by a renderer <script src>. */
function scriptLoadedLibModules() {
  const html = ['renderer/index.html', 'renderer/bedready.html']
    .filter((f) => fs.existsSync(path.join(ROOT, f)))
    .map((f) => fs.readFileSync(path.join(ROOT, f), 'utf8'))
    .join('\n');
  return [...new Set([...html.matchAll(/src="\.\.\/(lib\/[^"]+\.js)"/g)].map((m) => m[1]))];
}

const isWrapped = (src) => /^\s*\(function\s*\(/m.test(src) || /^\s*\(\(\)\s*=>/m.test(src);

/** Top-level `const`/`let`/`var` names — column 0, so nothing nested counts. */
function topLevelDeclarations(src) {
  return [...src.matchAll(/^(?:const|let|var)\s+([A-Za-z_$][\w$]*)/gm)].map((m) => m[1]);
}

test('the check can still find the renderer\'s lib modules', () => {
  // Guards the guard: if the <script src> pattern stopped matching, every
  // assertion below would pass against an empty list.
  const mods = scriptLoadedLibModules();
  assert.ok(mods.length > 30, `expected many lib modules, found ${mods.length}`);
  for (const m of mods) {
    assert.ok(fs.existsSync(path.join(ROOT, m)), `${m} is script-tagged but does not exist`);
  }
});

test('no script-loaded lib module leaks a declaration into the global scope', () => {
  const offenders = [];
  for (const rel of scriptLoadedLibModules()) {
    const src = fs.readFileSync(path.join(ROOT, rel), 'utf8');
    if (isWrapped(src)) continue;
    const names = topLevelDeclarations(src);
    if (names.length) offenders.push(`${rel} declares ${names.join(', ')} at top level`);
  }
  assert.deepEqual(offenders.sort(), [],
    `wrap these in an IIFE — a name collision makes the whole file fail to parse:\n  ${offenders.join('\n  ')}`);
});

test('the wrapper detector recognises the styles actually in use', () => {
  // If isWrapped() silently stopped matching, every module would look unwrapped
  // and the test above would fail loudly — which is safe. The dangerous
  // direction is the opposite: matching too eagerly and excusing a real leak.
  assert.ok(isWrapped('(function (global) {\n})(globalThis);'));
  assert.ok(isWrapped("'use strict';\n(function () {\n})();"));
  assert.ok(isWrapped('(() => {\n})();'));
  assert.ok(!isWrapped('const api = {};'), 'a bare declaration is not a wrapper');
  assert.ok(!isWrapped('// (function () { in a comment\nconst api = {};'),
    'a mention inside a comment must not excuse a file');
});
