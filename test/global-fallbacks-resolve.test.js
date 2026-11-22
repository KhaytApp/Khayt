/**
 * Every `global.X` a module falls back to must be a name something publishes.
 *
 * ── THE BUG THIS EXISTS FOR ───────────────────────────────────────────────
 *
 * A lib module that another one depends on is written to work in both worlds:
 *
 *     const dep = (typeof require === 'function') ? require('./dep') : global.KhaytDep;
 *
 * In Node the first branch runs and the second is never evaluated. So a WRONG
 * NAME in that fallback is invisible — until the day something loads the file
 * without `require`, and the dependency is silently `undefined`.
 *
 * Two were found this way. `mf-mesh.js` publishes `KhaytMfMesh`, and both
 * `full-spectrum.js` and `mf-convert.js` asked for `global.mfMesh` — which
 * broke the moment the Mac app tried to load the converter into
 * JavaScriptCore, months after it was written. `sdcp-client.js` asked for
 * `global.KhaytSdcp`, which nothing anywhere has ever defined.
 *
 * Neither could be caught by running the tests, because in Node that branch
 * does not run. It has to be read.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const dir = path.join(__dirname, '..', 'lib');
const files = fs.readdirSync(dir).filter((f) => f.endsWith('.js'));

/**
 * Names that are the RENDERER's page globals rather than a module's export.
 *
 * `calculator-cost.js` reads the shop's inventory and settings off the page
 * when it is given no `ctx`, which its own comment explains at length: the
 * renderer has them as globals, the LAN server and the Mac app pass a ctx
 * instead. They are not modules and nothing in lib/ publishes them.
 */
const PAGE_GLOBALS = new Set([
  'inventory', 'settings',
  // `fetch` is the PLATFORM's, not a module's. `gdrive-client.js` falls back to
  // it so the same file works against a caller-supplied fetch in a test and the
  // built-in one in Node 18+. Nothing in lib/ publishes it and nothing should.
  'fetch',
]);

test('every global a module falls back to is one something publishes', () => {
  const publishes = new Map();
  for (const file of files) {
    const source = fs.readFileSync(path.join(dir, file), 'utf8');
    for (const m of source.matchAll(/global(?:This)?\.([A-Za-z_$][\w$]*)\s*=/g)) {
      publishes.set(m[1], file);
    }
  }
  assert.ok(publishes.size > 100, `only ${publishes.size} globals found — the scan is wrong`);

  const unresolved = [];
  for (const file of files) {
    const source = fs.readFileSync(path.join(dir, file), 'utf8');
    for (const line of source.split('\n')) {
      if (line.trim().startsWith('*') || line.trim().startsWith('//')) continue;
      // The fallback shape: `? require(…) : global.NAME` or `|| global.NAME`.
      for (const m of line.matchAll(/(?::|\|\|)\s*global(?:This)?\.([A-Za-z_$][\w$]*)/g)) {
        const name = m[1];
        if (PAGE_GLOBALS.has(name) || publishes.has(name)) continue;
        unresolved.push(`${file}: falls back to global.${name}, which nothing publishes`);
      }
    }
  }

  assert.deepEqual(unresolved, [], `\n${unresolved.join('\n')}\n\n`
    + 'In Node the require branch runs and this is never evaluated, so a wrong\n'
    + 'name here is invisible until something loads the file without require.\n'
    + 'Either fix the name or drop the fallback and require outright.');
});
