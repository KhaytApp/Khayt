/**
 * A part that is not linked to a print file teaches nothing.
 *
 * Per-file calibration is what stops a quote being priced off the shop's recent
 * average mix. It needs `parts[].printFileId`, and the only thing that has ever
 * set that is a dropdown in the part form — one nobody is prompted to touch. So
 * in practice it stayed empty, the narrow scopes were never reached, and every
 * quote fell back to the machine-wide median: measured on 16 real jobs, 21%
 * under on a tall part and 27% over on a flat one.
 *
 * The app could already answer "have I seen this model before" —
 * lib/model-identity.js does it for the print library on import. What was
 * missing was asking at the moment the link is actually made.
 *
 * These cover the DECISION, which is where the damage would be. Matching by
 * shape can only ever be a likely match, so the rules about when NOT to act
 * matter more than the happy path: guessing over a shop's own answer, or picking
 * one of several candidates, would pool two models' measured histories and cause
 * exactly the mispricing this exists to prevent.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { gcodeGeometryKey } = require('../lib/model-identity.js');
const { silhouetteFromText } = require('../lib/gcode-geometry.js');

/**
 * The rule the renderer applies, extracted so it can be exercised without a DOM.
 * Kept in step with renderer/wire-events.js by the source guards below.
 */
function chooseLink(library, key, alreadyChosen) {
  if (alreadyChosen) return null;
  if (!key) return null;
  const hits = (library || []).filter((f) => f && f.geometryKey && f.geometryKey === key);
  return hits.length === 1 ? hits[0].id : null;
}

const LIB = [
  { id: 'PF-a', name: 'Plaque A', geometryKey: 'g:200x200x10:1/1,1/1,1/1,1/1,1/1,1/1,1/1,1/1' },
  { id: 'PF-b', name: 'Figure B', geometryKey: 'g:34.5x49.5x86.5:0.5/0.3,0.5/0.4,0.8/0.9,0.9/0.9,0.9/1,1/0.9,0.7/0.5,0.7/0.4' },
  { id: 'PF-c', name: 'No key yet', geometryKey: null },
];

test('a file whose shape matches exactly one library entry is linked to it', () => {
  assert.equal(chooseLink(LIB, LIB[1].geometryKey, ''), 'PF-b');
});

test('a shop that has already chosen is never overruled', () => {
  // The whole feature is a guess. A guess that overwrites a person's answer is
  // worse than no guess at all.
  assert.equal(chooseLink(LIB, LIB[1].geometryKey, 'PF-a'), null);
});

test('two entries with the same shape means no link, not an arbitrary one', () => {
  // Two plaques of the same outer size with different reliefs share an envelope.
  // Picking either would pool their measured histories — the exact mispricing
  // this feature is meant to remove.
  const twins = [
    { id: 'PF-x', geometryKey: 'g:200x200x10:1/1,1/1,1/1,1/1,1/1,1/1,1/1,1/1' },
    { id: 'PF-y', geometryKey: 'g:200x200x10:1/1,1/1,1/1,1/1,1/1,1/1,1/1,1/1' },
  ];
  assert.equal(chooseLink(twins, twins[0].geometryKey, ''), null);
});

test('an unidentifiable file links to nothing', () => {
  // A file too large to read, an unreadable one, or a mesh the parser could not
  // measure. Silence is the correct outcome; the dropdown stays as it was.
  assert.equal(chooseLink(LIB, null, ''), null);
  assert.equal(chooseLink(LIB, undefined, ''), null);
});

test('library entries without a key are never matched by a missing key', () => {
  // `PF-c` has geometryKey null. A candidate with no key must not match it —
  // null === null would link every unidentifiable file to the same entry.
  assert.equal(chooseLink(LIB, null, ''), null);
  const keyless = [{ id: 'PF-c', geometryKey: null }];
  assert.equal(chooseLink(keyless, null, ''), null);
});

test('an empty library links nothing', () => {
  assert.equal(chooseLink([], 'g:1x1x1:1/1', ''), null);
  assert.equal(chooseLink(null, 'g:1x1x1:1/1', ''), null);
});

test('the same model re-sliced still reaches its library entry', () => {
  // End to end on the thing that broke: two slices of one object, at different
  // layer heights, must produce the key already stored on the record.
  const box = (layer) => {
    const out = ['G90', 'M82'];
    let e = 0;
    for (let z = layer; z <= 4 + 1e-9; z += layer) {
      out.push(`G1 Z${z.toFixed(3)}`, 'G1 X50 Y50 F9000');
      for (const [px, py] of [[70, 50], [70, 60], [50, 60], [50, 50]]) out.push(`G1 X${px} Y${py} E${(++e).toFixed(3)}`);
    }
    return out.join('\n');
  };
  const stored = gcodeGeometryKey(silhouetteFromText(box(0.2)));
  const resliced = gcodeGeometryKey(silhouetteFromText(box(0.3)));
  assert.ok(stored, 'no key from the original');
  const lib = [{ id: 'PF-box', geometryKey: stored }];
  assert.equal(chooseLink(lib, resliced, ''), 'PF-box', 'a re-slice failed to find its own entry');
});

/* ---- the renderer must keep applying these rules ---------------------- */

const wire = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'wire-events.js'), 'utf8');

test('the renderer bails when the shop has already chosen', () => {
  assert.match(wire, /const sel = \$\('#partPrintFile'\);\s*\n\s*if \(!sel \|\| sel\.value\) return;/,
    'suggestLibraryLink no longer refuses to overwrite an existing choice');
  // Re-checked after the await, because reading a large g-code file takes long
  // enough for the shop to have picked one meanwhile.
  const fn = wire.slice(wire.indexOf('async function suggestLibraryLink'));
  assert.match(fn.slice(0, 1400), /if \(sel\.value\) return;/,
    'the choice is not re-checked after the asynchronous read');
});

test('the renderer links only on a single match', () => {
  const fn = wire.slice(wire.indexOf('async function suggestLibraryLink'));
  assert.match(fn.slice(0, 1400), /hits\.length !== 1\) return;/,
    'more than one candidate would be resolved by guessing');
  assert.match(fn.slice(0, 1400), /f\.geometryKey && f\.geometryKey === key/,
    'entries without a key must not match a candidate without one');
});

test('linking recomputes the quote', () => {
  // Selecting the file is only half of it: the estimate has to be redone so the
  // number reflects that file's own history instead of the machine median.
  const fn = wire.slice(wire.indexOf('async function suggestLibraryLink'));
  assert.match(fn.slice(0, 1600), /sel\.dispatchEvent\(new Event\('change', \{ bubbles: true \}\)\)/,
    'the estimate is not recomputed, so the link changes nothing the shop can see');
});

test('the shop is told, in their own language', () => {
  assert.match(wire, /t\('link\.matched_shape'/, 'the link happens silently');
  for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const loc = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'locales', `${code}.js`), 'utf8');
    assert.match(loc, /"link\.matched_shape":/, `${code} has no translation for the message`);
  }
});

test('identifying a file never blocks the quote it was dropped for', () => {
  // Reading a 60 MB toolpath takes seconds. It happens after applyIntake, and
  // its result is not awaited, so the number appears immediately.
  const intake = wire.slice(wire.indexOf('async function intakeFile'));
  const applyAt = intake.indexOf('applyIntake(res, name);');
  const linkAt = intake.indexOf('suggestLibraryLink(');
  assert.ok(applyAt > -1 && linkAt > -1, 'the intake path changed shape');
  assert.ok(applyAt < linkAt, 'the file is identified before the quote is shown');
  // Look BEFORE the call, not after it: indexOf lands on the name, so slicing
  // forward from there can never see an `await` that precedes it.
  assert.doesNotMatch(intake.slice(Math.max(0, linkAt - 12), linkAt), /await\s+$/,
    'awaiting it makes the shop wait for a toolpath read to see their quote');
});
