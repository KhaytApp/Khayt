const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

/**
 * Editing a cart line reloads it into the form, then re-adds it. Any field the cart
 * STORES but editPart() does not RESTORE is silently discarded on that round-trip.
 *
 * That was real: supportWeight (a cost driver — the part re-priced lower), plus colour,
 * note, layer height, infill, profile, file reference and spool id. This is a source-level
 * check because both functions are DOM-bound and cannot be exercised headlessly.
 */
const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'build.js'), 'utf8');

const between = (startMarker, endMarker) => {
  const i = src.indexOf(startMarker);
  assert.ok(i !== -1, `marker not found: ${startMarker}`);
  const j = src.indexOf(endMarker, i);
  assert.ok(j !== -1, `end marker not found after ${startMarker}`);
  return src.slice(i, j);
};

// Derived on save from the filament selection, so deliberately not restored.
const DERIVED = new Set(['material', 'baseCost']);

test('every field the cart stores is restored when the line is edited', () => {
  const stored = [...between('function snapshotPartFromFormRaw', '\n}')
    .matchAll(/^\s{4}(\w+):/gm)].map((m) => m[1]);
  assert.ok(stored.length > 20, `expected the full part shape, got ${stored.length}`);

  const editBody = between('function editPart', 'currentBuild.splice(index, 1);');
  const missing = stored.filter((f) => !DERIVED.has(f) && !editBody.includes(f));

  assert.deepEqual(missing, [],
    `editPart() drops these on a round-trip, silently losing them: ${missing.join(', ')}`);
});

test('the attached file is cleared after adding, so it cannot leak onto the next part', () => {
  const addBody = between('const part = snapshotPartFromForm();', 'currentExtraMaterials = [];');
  assert.ok(/#partFileRef'\)\)\s*\$\('#partFileRef'\)\.value\s*=\s*''/.test(addBody)
    || /partFileRef.*value = ''/.test(addBody),
    'addPart must clear #partFileRef, or part 2 references part 1’s model file');
});

test('the live cost preview snapshots the same cost inputs as the cart', () => {
  // Omitting qty made packaging un-amortised (a 20-unit part previewed at 17.00 and
  // landed in the cart at 7.50); omitting filamentId skipped the resin per-kg branch.
  const preview = between('function calculateLivePartCost', '\n}');
  for (const field of ['qty', 'filamentId', 'supportWeight', 'printWeight', 'printTime']) {
    assert.ok(new RegExp(`\\b${field}\\s*:`).test(preview),
      `the live preview omits ${field}, so it will disagree with the cart`);
  }
});
