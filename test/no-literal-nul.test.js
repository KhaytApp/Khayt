/**
 * No source file may contain a literal NUL byte.
 *
 * NUL is a legitimate value to *use* — as a delimiter that cannot occur in the
 * strings it joins, or as a sentinel prefix that cannot collide with real data.
 * Both uses are in this codebase and both are correct. The rule is about how it
 * is SPELLED: written as an escape it is ordinary text, written as a raw 0x00
 * byte it turns the whole file binary to the tools that read it.
 *
 * That is not theoretical. `main.js` carried two raw NULs in a Drive cache key,
 * and BSD grep classifies a file containing NUL as binary — so every grep of the
 * app's largest and most important source file returned NOTHING, silently, with
 * no "binary file matches" line and no error. Searching it for the tiering
 * safety gate produced no hits, which reads exactly like a gate that was never
 * wired up. It was wired up. The file was simply invisible.
 *
 * Anything that greps loses main.js, and reports that loss as an absence.
 *
 * git is unaffected — its binary heuristic only inspects the first 8 kB and both
 * bytes sat past 83 kB — so diffs and review looked completely normal, which is
 * what let it survive. The tools that break are the ones used to ask questions
 * about the code, not the ones used to change it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const SKIP_DIRS = new Set(['node_modules', '.git', 'build', 'build-bedready', 'dist', 'export']);
const EXTS = /\.(js|mjs|cjs|json|html|css|md|yml|yaml)$/;

/** Every text-ish source file, excluding build output and dependencies. */
function sourceFiles(dir = root, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name.startsWith('.') && entry.name !== '.github') continue;
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) sourceFiles(p, out);
    } else if (EXTS.test(entry.name)) {
      out.push(p);
    }
  }
  return out;
}

test('no source file contains a literal NUL byte', () => {
  const offenders = [];
  for (const file of sourceFiles()) {
    const buf = fs.readFileSync(file);
    const count = buf.filter((b) => b === 0).length;
    if (count) offenders.push(`${path.relative(root, file)} (${count})`);
  }
  assert.deepEqual(
    offenders,
    [],
    `literal NUL bytes make a file binary to grep, which then reports no matches ` +
      `rather than an error. Write the escape instead: ${offenders.join(', ')}`
  );
});

test('the NUL-valued constants still hold a real NUL — the fix was spelling, not meaning', () => {
  // If someone "cleans up" the escape into a space or an empty string, the
  // sentinel starts colliding with data it was chosen to be distinct from.
  const { UNCATEGORISED } = require('../lib/consumable-categories.js');
  assert.equal(UNCATEGORISED.charCodeAt(0), 0, 'the uncategorised sentinel lost its NUL prefix');
  assert.equal(UNCATEGORISED, String.fromCharCode(0) + 'uncategorised');
});

test('the Drive cache key still separates its fields with NUL', () => {
  // A separator that can appear inside the values is not a separator: with ':'
  // a clientId ending in one and a refreshToken starting with one would produce
  // the same key as a different pair, and the cached client would be reused for
  // the wrong account.
  const mainJs = fs.readFileSync(path.join(root, 'main.js'), 'utf8');
  const at = mainJs.indexOf('printLibDriveCache.key !== key');
  assert.ok(at > -1, 'the Drive client cache went missing');
  const decl = mainJs.lastIndexOf('const key =', at);
  assert.ok(decl > -1 && at - decl < 400, 'the cache key is no longer built next to its use');
  const line = mainJs.slice(decl, mainJs.indexOf('\n', decl));
  assert.match(line, /\\u0000|\\0/, 'the Drive cache key no longer joins its fields with NUL');
});
