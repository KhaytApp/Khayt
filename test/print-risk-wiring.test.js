'use strict';
/**
 * Print risk is six pieces, and every one of them can pass its own tests while
 * the feature quietly does nothing.
 *
 *   lib/print-risk.js          counts overhangs, judges them, owns the schedule
 *   lib/intake-view.js         turns findings into localised lines
 *   lib/settings-edit.js       saves the schedule through that same reader
 *   Mesh.swift                 the Swift transcription of the counting
 *   LibraryImport.swift        walks the mesh at import, when asked
 *   Shop.swift / LibraryInspector.swift   asks on demand, and draws the answer
 *
 * Each is proven on its own — the parity suite runs both counters on the same
 * triangles, `PrintRiskTests` runs a file on disk through to findings. What is
 * pinned HERE is that they are connected to each other, because the failure
 * shape is specific and silent:
 *
 * `analyseRisk:` has a default of `false`. A caller that forgets it COMPILES,
 * runs, imports the file, and writes a record with no summary in it — and the
 * setting the shop just turned on does nothing at all. That is not a test
 * failure anywhere; it is a control that lies.
 *
 * BEHAVIOUR IS PROVEN ELSEWHERE, and the first version of this file was wrong
 * about that. It claimed proving it needed "a real store, a real library root
 * and a real ten-million-facet file" — but `LibraryImport.add` takes the store
 * and the root as arguments, so it needs a temp directory and a 24-triangle
 * STL. `PrintRiskTests.walksAtImport` and `.skipsWhenNotAsked` do exactly that
 * and assert on what lands in the book.
 *
 * What is left for this file is the part behaviour cannot reach: there are four
 * call sites, and a test that imports through ONE of them says nothing about
 * the other three. A caller that omits `analyseRisk:` compiles clean, so only
 * reading the call sites catches it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

const IMPORT = 'mac/KhaytCore/Sources/KhaytApp/LibraryImport.swift';
const SHOP = 'mac/KhaytCore/Sources/KhaytApp/Shop.swift';
const INSPECTOR = 'mac/KhaytCore/Sources/KhaytApp/LibraryInspector.swift';
const COMMAND = 'mac/KhaytCore/Sources/KhaytApp/ImportCommand.swift';
const MESH = 'mac/KhaytCore/Sources/KhaytApp/Mesh.swift';

/* ============================================================
   The schedule reaches the import
   ============================================================ */

test('every path that calls addMany says whether to walk the mesh', () => {
  // Two callers, and they must not drift: the File menu, which shows a banner
  // and a Stop button, and `--import`, which prints lines. A shop that asked
  // for the walk at import and got it from one of them has a setting that
  // depends on which way it opened the app.
  for (const file of [SHOP, COMMAND]) {
    const src = read(file);
    const at = src.indexOf('LibraryImport.addMany(');
    assert.notEqual(at, -1, `${file} no longer calls addMany — this guard is stale`);
    const call = src.slice(at, src.indexOf('\n\n', at));
    assert.match(call, /analyseRisk:/,
      `${file} calls addMany without analyseRisk: — the setting does nothing there`);
  }
});

test('the single-file path says so too', () => {
  // Drag-and-drop, and the one the Library screen's own Add button uses.
  const src = read(IMPORT);
  const at = src.indexOf('static func add(_ source: URL, shop: Shop');
  assert.notEqual(at, -1, 'the single-file entry point has been renamed');
  const body = src.slice(at, src.indexOf('\n    }', at));
  assert.match(body, /analyseRisk: shop\.analysesRiskAtImport/,
    'a file added one at a time never gets walked, whatever the setting says');
});

test('addMany hands it down to the per-file add rather than swallowing it', () => {
  const src = read(IMPORT);
  const at = src.indexOf('static func addMany(');
  const body = src.slice(at, src.indexOf('\n    }\n', at));
  assert.match(body, /analyseRisk: Bool/, 'addMany does not take the flag');
  assert.match(body, /analyseRisk: analyseRisk/,
    'addMany takes the flag and does not pass it on — the batch path is dead');
});

test('the flag is what turns the walk on, and it is the real walk', () => {
  const src = read(IMPORT);
  assert.match(src, /if analyseRisk[\s\S]{0,120}Mesh\.overhangs\(of:/,
    'nothing in the import calls Mesh.overhangs behind the flag');
});

test('the summary is written onto the record', () => {
  // A walk whose answer is not stored is a walk the library repeats on every
  // look, which is the whole reason the setting exists.
  const src = read(IMPORT);
  assert.match(src, /riskAnalysis: riskAnalysis/, 'the walk is not handed to record()');
  assert.match(src, /out\["printRisk"\] = \.object\(/, 'record() does not store it');
  // Absent rather than null when the walk did not happen: null is
  // indistinguishable from "walked and found nothing", and the inspector has
  // to offer the button for one and not the other.
  assert.match(src, /if let riskAnalysis, !riskAnalysis\.isEmpty \{/,
    'the field is written unconditionally, so "not looked" and "nothing found" become the same');
});

/* ============================================================
   The schedule itself
   ============================================================ */

test('the app reads the schedule through the shared rule, not off the dictionary', () => {
  const src = read(SHOP);
  assert.match(src, /riskWhen = try\? await engine\?\.riskWhen\(settings:/,
    'Shop works out the schedule itself instead of asking lib/print-risk.js');
  assert.match(src, /analysesRiskAtImport: Bool \{ riskWhen == "import" \}/,
    'the at-import test has been rewritten and may no longer fail safe');
});

test('the Swift side does not keep its own copy of the default', () => {
  // The default lives in `lib/print-risk.js` and nowhere else. A second copy in
  // Swift is a second thing to get wrong when it changes, and getting it wrong
  // in the `import` direction adds an hour to a four-hundred-file import.
  const src = read(SHOP);
  assert.doesNotMatch(src, /var riskWhen: String = "/,
    'Shop.riskWhen has been given a literal default again');
  assert.doesNotMatch(src, /riskWhen: String = "demand"/, 'a literal default crept back in');
});

test('the save goes through the same reader that reads it back', () => {
  const src = read('lib/settings-edit.js');
  assert.match(src, /when: rules \? rules\.riskWhen\(/,
    'settings-edit validates the schedule against its own list again');
  // A screen that can save a value its own reader rejects is a screen with a
  // dead option in it.
  const risk = require('../lib/print-risk.js');
  const edit = require('../lib/settings-edit.js');
  for (const v of risk.RISK_WHEN) {
    assert.equal(edit.apply({}, { printRisk: { when: v } }).printRisk.when, v,
      `the settings save refuses "${v}", which its own reader accepts`);
  }
});

/* ============================================================
   The answer is shown
   ============================================================ */

test('the inspector draws the findings, and the sentences come from the shared rule', () => {
  const src = read(INSPECTOR);
  assert.match(src, /shop\.risks\[file\.id\]/, 'the inspector never reads the report');
  assert.match(src, /report\.note/, 'the inspector does not render the note lines');
  // Rendered through the shop's own language like every other note. A Swift
  // `switch` over finding ids building English sentences would be a second set
  // of words for one set of findings.
  assert.match(src, /callIt\(line\.key, line\.vars/,
    'the lines are not going through the translation path');
});

test('the note lines are built by intake-view, not written again in Swift', () => {
  const engine = read('mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift');
  assert.match(engine, /KhaytIntakeView\.riskNote\(/,
    'assessModel no longer asks intake-view for the sentences');
  for (const module of ['"print-risk"', '"intake-view"']) {
    assert.ok(engine.includes(module), `${module} is not bundled, so the runtime cannot load it`);
  }
});

test('there are three states, because "not looked" is not "nothing wrong"', () => {
  // An empty section headed "before you quote this" reads as reassurance. It
  // is a different and much worse answer than "not looked yet".
  const src = read(INSPECTOR);
  for (const key of ['risk.looking', 'risk.clear', 'risk.not_looked', 'risk.look']) {
    assert.ok(src.includes(key), `the inspector has no ${key} state`);
  }
});

test('the on-demand button actually walks the mesh', () => {
  const src = read(INSPECTOR);
  assert.match(src, /await shop\.analyseRisk\(file\)/,
    'the Check button does not call anything');
  assert.match(read(SHOP), /func analyseRisk\(_ file: LibraryFile\) async/,
    'Shop.analyseRisk is gone or has been renamed');
});

/* ============================================================
   What the two passes cost, and where they run
   ============================================================ */

test('the walk is off the main actor', () => {
  // Seconds of arithmetic on a real file, on the thread drawing the app. The
  // library screen has hung this way before.
  const src = read(SHOP);
  const at = src.indexOf('func analyseRisk(_ file: LibraryFile) async');
  const body = src.slice(at, src.indexOf('\n    }', at));
  assert.match(body, /Task\.detached/,
    'analyseRisk walks the mesh on the main actor');
});

test('the 3MF reader is one traversal with two uses', () => {
  // A second traversal that read `<build>` even slightly differently would
  // report overhangs for a model in a position Khayt never measured — both
  // answers plausible, one of them wrong.
  const src = read(MESH);
  assert.match(src, /static func each3MFTriangle\(/, 'the shared 3MF traversal is gone');
  const at = src.indexOf('static func measure3MF(');
  const body = src.slice(at, src.indexOf('\n    }', at));
  assert.match(body, /each3MFTriangle\(url\)/,
    'measure3MF has its own traversal again, so measuring and judging can disagree');
});

test('what the measurement knows is not asked of the overhang pass', () => {
  // The accumulator tracks which way surfaces face and never the extent, so
  // the box has to come from the measurement. Pass none and the thin-wall
  // figure loses the volume it is derived from.
  const engine = read('mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift');
  assert.match(engine, /if let g = bbox \{/, 'assessModel no longer takes the box');
  assert.match(read(INSPECTOR) + read(SHOP), /bbox: mesh\.map/,
    'nothing passes the measured box to assessModel');
});

test('the plate question is answered once, not twice', () => {
  // `shop.fits` answers it per machine through lib/print-fit.js and the
  // inspector prints that three lines above the risk section. Passing a bed
  // here made the Mesh section say "Too big for every machine you have" and
  // this one say "It does not fit: 1435x1057x185 mm against …" — one fact,
  // two sentences, and a reader left wondering if they are the same one.
  const shop = read(SHOP);
  const at = shop.indexOf('private func judge(');
  const body = shop.slice(at, shop.indexOf('\n    }', at));
  assert.doesNotMatch(body, /bed:/,
    'the inspector passes a bed again, so the plate verdict is printed twice');
});

test('the parity suite exists and runs both counters on the same triangles', () => {
  // The Swift accumulator is a TRANSCRIPTION of a JS rule, and a transcription
  // drifts unless something is watching.
  const tests = read('mac/KhaytCore/Tests/KhaytAppTests/PrintRiskParityTests.swift');
  assert.match(tests, /analyzeTriangles/, 'the parity suite no longer calls the shared rule');
  assert.match(tests, /Mesh\.Overhangs\(minZ:/, 'the parity suite no longer runs the Swift side');
  // Bucket by bucket, not with a tolerance over the whole histogram: a
  // one-degree shift is exactly the drift this is for.
  assert.match(tests, /bucket \\\(i\)°/,
    'the histogram comparison no longer names the bucket it disagrees on');
});
