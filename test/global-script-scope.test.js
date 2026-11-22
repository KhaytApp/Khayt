/**
 * Two classic scripts must not declare the same top-level name.
 *
 * The renderer loads its files with plain <script> tags, and those share ONE
 * global lexical scope. A `const _WW = …` at the top of two of them is not two
 * private constants — it is a redeclaration, and the second file throws
 *
 *     SyntaxError: Identifier '_WW' has already been declared
 *
 * which kills that file and every script after it. The failure surfaces nowhere
 * near the cause: settings.js never reached its export list, so wiring later
 * threw `saveCurrentFilterPreset is not defined`, and the settings sidebar
 * simply stopped switching panels.
 *
 * Nothing else catches it. `node --check` passes each file alone, and the full
 * unit suite passes because tests `require` these files as CommonJS modules,
 * where every file has its own scope. Only launching the app shows it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const RENDERER = path.join(__dirname, '..', 'renderer');

/** Top-level `const`/`let`/`class` names in a classic script, ignoring IIFE bodies. */
function topLevelNames(src) {
  const names = [];
  let depth = 0;
  let inBlockComment = false;
  for (const raw of src.split('\n')) {
    const line = raw.trim();
    if (inBlockComment) { if (line.includes('*/')) inBlockComment = false; continue; }
    if (line.startsWith('/*')) { if (!line.includes('*/')) inBlockComment = true; continue; }
    if (line.startsWith('//') || line.startsWith('*')) continue;
    if (depth === 0) {
      const m = line.match(/^(?:const|let|class)\s+([A-Za-z_$][\w$]*)/);
      if (m) names.push(m[1]);
    }
    for (const ch of raw) {
      if (ch === '{' || ch === '(' || ch === '[') depth++;
      else if (ch === '}' || ch === ')' || ch === ']') depth--;
    }
  }
  return names;
}

test('no two renderer scripts declare the same top-level binding', () => {
  const pages = ['index.html', 'bedready.html'];
  for (const page of pages) {
    const html = fs.readFileSync(path.join(RENDERER, page), 'utf8');
    // Only the scripts this page actually loads, in load order.
    const srcs = [...html.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
    const owner = new Map();
    const clashes = [];
    for (const rel of srcs) {
      const abs = path.join(RENDERER, rel);
      if (!fs.existsSync(abs)) continue;
      for (const name of topLevelNames(fs.readFileSync(abs, 'utf8'))) {
        if (owner.has(name) && owner.get(name) !== rel) {
          clashes.push(`${page}: '${name}' declared in both ${owner.get(name)} and ${rel}`);
        } else owner.set(name, rel);
      }
    }
    assert.deepEqual(clashes, [],
      `these redeclare a name in the shared script scope — the second file and everything after it dies:\n  ${clashes.join('\n  ')}`);
  }
});
