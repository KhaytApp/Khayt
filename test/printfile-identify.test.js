/**
 * An entry that arrived without an identity could never gain one.
 *
 * Identity was computed only while CREATING a library record. Nothing else ever
 * looked at a file again: dropping a model into the calculator does not touch
 * the library, and editing an entry does not re-read its file. So a record that
 * started life without a shape key stayed unrecognisable for good — and an
 * unrecognisable entry is one the calculator can never auto-link a part to,
 * which is what keeps per-file calibration out of reach and leaves every quote
 * priced off the machine-wide median.
 *
 * Two ways a record ended up like that, both real:
 *
 *   - reconstructed from print history, with no file attached at all
 *   - imported as a 3MF. hub:parse-print-file has always returned that file's
 *     geometry — volume, bbox, triangle count — and enrichPrintFile showed the
 *     figures to the shop and then dropped them on the floor. Only STL ever
 *     produced a key.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { geometryKey } = require('../lib/model-identity.js');

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'printfiles.js'), 'utf8');

/** The body of one function, by name, matched on braces. */
function fn(name) {
  const start = src.indexOf(`function ${name}(`);
  assert.ok(start > -1, `${name}() not found in renderer/printfiles.js`);
  const open = src.indexOf('{', start);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) return src.slice(start, i + 1);
  }
  throw new Error(`could not find the end of ${name}()`);
}

test('a 3MF measured by the parser yields the same key an STL would', () => {
  // Both go through mi.geometryKey with the same three numbers, so a model
  // imported as a 3MF and the same model imported as an STL recognise each
  // other rather than becoming two unrelated entries.
  const geo = { triangleCount: 1200, volumeMm3: 8000.5, bbox: { x: 20, y: 20, z: 20 } };
  assert.equal(geometryKey(geo), '1200:8000.5:20x20x20');
});

test('enrichPrintFile turns parsed geometry into an identity', () => {
  const enrich = fn('enrichPrintFile');
  assert.match(enrich, /p\.geometry\)/, 'the 3MF geometry is still read and discarded');
  assert.match(enrich, /rec\.geometryKey = mi\.geometryKey\(p\.geometry\)/,
    'a 3MF gets its figures shown and no key stored — exactly the old behaviour');
  // The g-code path must survive alongside it, not be replaced by it.
  assert.match(enrich, /mi\.gcodeGeometryKey\(p\.silhouette\)/, 'the g-code envelope key was lost');
});

test('identifying re-reads a file the entry already has, without asking', () => {
  const idf = fn('identifyPrintFile');
  assert.match(idf, /resolveModelPath\(rec\)/,
    'it asks for a file even when the entry already has one in its vault');
  assert.match(idf, /if \(!fullPath\) \{[\s\S]*?printLibPick\(id\)/,
    'the picker is not reserved for the case where there is no file');
});

test('a cancelled picker changes nothing', () => {
  const idf = fn('identifyPrintFile');
  assert.match(idf, /if \(!picked\) return;/,
    'cancelling the dialog would fall through and clear the record’s identity');
});

test('a stale key is cleared before the file is re-read', () => {
  // Whatever is on the record describes some earlier file. Keeping it while a
  // new one is attached would leave a key that matches the wrong model — worse
  // than no key, because a wrong match pools two models' measured histories.
  const idf = fn('identifyPrintFile');
  const clear = idf.indexOf('rec.geometryKey = null');
  const enrich = idf.indexOf('enrichPrintFile(rec, fullPath)');
  assert.ok(clear > -1, 'the old key is carried over onto the new file');
  assert.ok(enrich > -1, 'the file is never actually read');
  assert.ok(clear < enrich, 'the key is cleared after the read, wiping what was just measured');
});

test('the attached file is recorded so the entry can be re-read later', () => {
  const idf = fn('identifyPrintFile');
  assert.match(idf, /rec\.sourceFile = \{/, 'the file is read once and then forgotten');
  assert.match(idf, /rec\.contentHash = picked\.contentHash/, 'the exact-match key is not stored');
});

test('the button exists only where an identity is missing', () => {
  assert.match(src, /\$\{!rec\.geometryKey \? `<button[^`]*data-act="pf-identify"/,
    'the action is offered on entries that already have a key, or not at all');
});

test('the button is wired to something', () => {
  // A control that renders and does nothing is the failure this codebase has
  // shipped before: a handler written against a hook that did not exist.
  assert.match(src, /case 'pf-identify': identifyPrintFile\(id\); break;/,
    'pf-identify renders but no case handles it — a dead button');
});

test('every string the shop sees is translated', () => {
  for (const key of ['plib.identify', 'plib.identify_hint', 'plib.identified', 'plib.identify_failed']) {
    assert.match(src, new RegExp(`t\\('${key.replace('.', '\\.')}'`), `${key} is not looked up`);
    for (const code of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
      const loc = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'locales', `${code}.js`), 'utf8');
      assert.match(loc, new RegExp(`"${key.replace('.', '\\.')}":`), `${code} is missing ${key}`);
    }
  }
});

test('the shop is told which of the two outcomes happened', () => {
  // "Read it but could not measure a shape" is a different answer from "done",
  // and reporting success either way would leave someone waiting for a match
  // that can never come.
  const idf = fn('identifyPrintFile');
  assert.match(idf, /rec\.geometryKey\s*\?[\s\S]*?plib\.identified[\s\S]*?plib\.identify_failed/,
    'both outcomes report the same thing');
});
