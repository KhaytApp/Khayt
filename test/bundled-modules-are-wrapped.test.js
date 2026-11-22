/**
 * Every module the Mac app bundles must keep its names to itself.
 *
 * KhaytCore loads all of them into ONE JavaScriptCore context. A `const` at a
 * module's top level is a binding in that shared global scope, so the second
 * module to declare the same name fails with
 *
 *     SyntaxError: Can't create duplicate variable: 'api'
 *
 * and takes the whole runtime with it. That failure does not raise anywhere a
 * shop can see: `Shop.load` gets no engine, and the app comes up with no words
 * (the locale catalogue is loaded through the runtime, so every label renders
 * as its own key), no tax, no reports and no writes.
 *
 * It happened: `lib/upgrade-backup.js` and `lib/store-secret-paths.js` both
 * declared a top-level `api`, and bundling the first one for the Mac's daily
 * backup killed the runtime. Both are wrapped now, and this guard is what stops
 * the next one — because the cost of finding out the other way is a shop
 * opening an app that silently does nothing.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..');

/** The module list KhaytCore actually loads, read from the source of truth. */
function bundledModules() {
  const src = fs.readFileSync(path.join(ROOT, 'mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift'), 'utf8');
  const at = src.indexOf('static let modules = [');
  assert.notEqual(at, -1, 'the module list has moved — update this test');
  const block = src.slice(at, src.indexOf('\n    ]', at));
  // COMMENTS OUT FIRST. Every line of that list is documented, and a comment
  // that happens to quote a lowercase word — `"closest" means perceptual
  // distance` — reads as a module named `closest` and fails this test on a
  // file that does not exist. The same shape once truncated the list at a
  // `settings.slicers[]` in a comment; a parser that reads prose as code will
  // keep finding new ways to be wrong.
  const code = block.split('\n').map((l) => l.replace(/\/\/.*$/, '')).join('\n');
  return [...code.matchAll(/"([a-z0-9-]+)"/g)].map((m) => m[1]);
}

/** Names a file declares at the top level of a script — the shared scope. */
function topLevelNames(source) {
  const out = [];
  let depth = 0;
  let inBlockComment = false;
  for (const raw of source.split('\n')) {
    let line = raw;
    if (inBlockComment) {
      const end = line.indexOf('*/');
      if (end === -1) continue;
      line = line.slice(end + 2);
      inBlockComment = false;
    }
    line = line.replace(/\/\*.*?\*\//g, '');
    const open = line.indexOf('/*');
    if (open !== -1) { line = line.slice(0, open); inBlockComment = true; }
    line = line.replace(/\/\/.*$/, '');
    if (depth === 0) {
      const m = /^(?:const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/.exec(line.trim());
      if (m) out.push(m[1]);
    }
    for (const ch of line) {
      if (ch === '{' || ch === '(') depth++;
      else if (ch === '}' || ch === ')') depth--;
    }
  }
  return out;
}

test('no module the Mac app bundles declares anything at the top level', () => {
  const offenders = [];
  for (const name of bundledModules()) {
    const file = path.join(ROOT, 'lib', `${name}.js`);
    assert.ok(fs.existsSync(file), `${name}.js is bundled but not in lib/`);
    const names = topLevelNames(fs.readFileSync(file, 'utf8'));
    if (names.length) offenders.push(`lib/${name}.js declares ${names.join(', ')}`);
  }
  assert.deepEqual(offenders, [],
    'these leak names into the one JavaScriptCore context every module shares.\n'
    + '  Wrap the module in `(function (global) { … })(globalThis)`, as its siblings are.\n  '
    + offenders.join('\n  '));
});

test('and no two of them could collide even if one slipped through', () => {
  // Belt and braces, and it names the pair rather than one file — which is the
  // thing you need to know when the runtime will not start.
  const seen = new Map();
  const clashes = [];
  for (const name of bundledModules()) {
    const file = path.join(ROOT, 'lib', `${name}.js`);
    if (!fs.existsSync(file)) continue;
    for (const declared of topLevelNames(fs.readFileSync(file, 'utf8'))) {
      if (seen.has(declared)) clashes.push(`${declared}: lib/${seen.get(declared)}.js and lib/${name}.js`);
      else seen.set(declared, name);
    }
  }
  assert.deepEqual(clashes, []);
});

test('the guard can actually see a top-level declaration', () => {
  // A guard that cannot fail is a guard that proves nothing. These are the two
  // shapes that mattered: a bare `const api`, and one inside an IIFE.
  assert.deepEqual(topLevelNames("'use strict';\nconst api = { a: 1 };\n"), ['api']);
  assert.deepEqual(topLevelNames("(function (global) {\n  const api = { a: 1 };\n})(this);\n"), []);
  // Comments do not count, however they are written.
  assert.deepEqual(topLevelNames("/* const api = 1; */\n// const api = 2;\n(function () {\n})();\n"), []);
});
