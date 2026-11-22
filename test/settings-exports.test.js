const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const SRC = fs.readFileSync(path.join(__dirname, '../renderer/settings.js'), 'utf8');

/**
 * renderer/settings.js is an IIFE whose public surface is a hand-maintained
 * `api` object literal. That list drifted: four settings panels were declared
 * exactly like their 47 siblings but never added to it, so no code outside the
 * IIFE could call them. It surfaced when AI consent needed to re-render the
 * privacy panel and `renderPrivacySettings` turned out to be undefined on the
 * global — the same failure mode as the hand-listed lint chain in package.json.
 *
 * A panel is public by convention: if it is named render*Settings, something
 * outside will eventually need to refresh it.
 */

function declaredFunctions() {
  // `async` matters: 11 of the exported names are async declarations, and a
  // regex that misses them reports every one as a dangling export.
  return new Set([...SRC.matchAll(/^(?:async )?function ([A-Za-z_]\w*)\s*\(/gm)].map((m) => m[1]));
}

function exportedNames() {
  const start = SRC.indexOf('  const api = {');
  const end = SRC.indexOf('  Object.assign(global, api);');
  assert.ok(start > 0 && end > start, 'could not locate the api export block');
  return new Set([...SRC.slice(start, end).matchAll(/^\s{4}(\w+),/gm)].map((m) => m[1]));
}

test('every settings panel is exported from the IIFE', () => {
  const declared = declaredFunctions();
  const exported = exportedNames();
  const panels = [...declared].filter((n) => /^render.*Settings$/.test(n));
  assert.ok(panels.length > 20, `expected many panels, found ${panels.length}`);
  const missing = panels.filter((n) => !exported.has(n)).sort();
  assert.deepEqual(missing, [], `panels declared but not exported: ${missing.join(', ')}`);
});

test('the four panels that drifted are exported', () => {
  // Named explicitly so a future trim of the api list cannot quietly drop them.
  const exported = exportedNames();
  for (const n of ['renderPrivacySettings', 'renderApiTokensSettings', 'renderShippingSettings', 'renderTelemetrySettings']) {
    assert.ok(exported.has(n), `${n} must stay exported`);
  }
});

test('the export list names only functions that exist', () => {
  // The mirror-image drift: a rename would leave a dangling name and the IIFE
  // would throw at load, taking the whole settings tab with it.
  const declared = declaredFunctions();
  const constNames = new Set([...SRC.matchAll(/^(?:const|let|var) ([A-Za-z_]\w*)\s*=/gm)].map((m) => m[1]));
  const dangling = [...exportedNames()].filter((n) => !declared.has(n) && !constNames.has(n));
  assert.deepEqual(dangling, [], `exported but not defined: ${dangling.join(', ')}`);
});
