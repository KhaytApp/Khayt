'use strict';
/**
 * Duet's legacy progress field, read both ways because the vendor cannot say.
 *
 * From the Duet3D wiki's JSON-responses page (fetched 2026-09-03), describing
 * the pre-RRF-3 `rr_status?type=3` response:
 *
 *     "fractionPrinted": Fraction of the file printed on a scale of
 *     0.0 to 100.0. This equals filePosition / fileSize
 *
 * Those two clauses cannot both be true — the second is a ratio between 0 and 1.
 * The adjacent `// one decimal place` comment leans towards 0-100 (one decimal
 * on a 0-1 fraction gives eleven usable values). The reprap.org mirror asserts
 * 0-1 but reasons from the field's NAME. `fileSize` is absent from the type-3
 * response, so the ratio cannot be recomputed independently.
 *
 * Khayt multiplied by 100 unconditionally:
 *
 *     progress: normalizeProgress((data.fractionPrinted || 0) * 100)
 *
 * If 0-100 is the right reading, every print from 1% onward showed as COMPLETE
 * after the clamp — on the one Duet surface nobody here can test, which is why
 * it could sit there unreported.
 *
 * docs/PRINTER-PROTOCOL-AUDIT.md records the sources; this pins the behaviour.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { legacyProgressPercent } = require('../lib/duet.js');
const { normalizeProgress } = require('../lib/printer-status.js');

const ROOT = path.join(__dirname, '..');
const code = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8')
  .replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

/** What the queue would actually display. */
const shown = (raw) => normalizeProgress(legacyProgressPercent(raw));

test('under the 0-100 reading, a running print is not called finished', () => {
  // The bug. Every one of these used to clamp to 100.
  for (const [raw, want] of [[5, 5], [45, 45], [99.9, 100], [100, 100]]) {
    assert.equal(shown(raw), want, `fractionPrinted ${raw} showed as ${shown(raw)}%`);
  }
});

test('under the 0-1 reading, a fraction still scales correctly', () => {
  for (const [raw, want] of [[0.05, 5], [0.45, 45], [0.999, 100], [1, 100]]) {
    assert.equal(shown(raw), want, `fractionPrinted ${raw} showed as ${shown(raw)}%`);
  }
});

test('the boundary belongs to the fraction reading', () => {
  // 1 is "finished" as a fraction and "1%" as a percentage. Reporting 100 is the
  // safe way round: a print at 1% briefly reading high is a cosmetic error; a
  // finished print reading 1% would look stuck.
  assert.equal(shown(1), 100);
  assert.equal(shown(1.0001), 1, 'just above the boundary is read as a percentage');
});

test('the one case it gets wrong is named, not hidden', () => {
  // Under the 0-100 reading a genuine 0.5% is reported as 50%. That is the
  // accepted cost of not picking a reading, and it errs towards showing
  // progress rather than towards calling a running print complete.
  assert.equal(shown(0.5), 50);
});

test('junk is zero, not NaN and not a guess', () => {
  for (const v of [undefined, null, '', 'x', NaN, -1, -0.5, {}, []]) {
    assert.equal(shown(v), 0, `${JSON.stringify(v)} produced ${shown(v)}`);
  }
});

test('an over-range value is still clamped by the caller', () => {
  // legacyProgressPercent does not clamp; normalizeProgress does, and main.js
  // wraps one in the other. Both halves matter.
  assert.equal(legacyProgressPercent(250), 250);
  assert.equal(shown(250), 100);
});

test('the shared legacy shape clamps, and both apps go through it', () => {
  // ── THIS GUARD MOVED WITH THE CODE ──────────────────────────────────────
  //
  // It used to read `main.js` for
  // `normalizeProgress(legacyProgressPercent(data.fractionPrinted))`. That
  // expression is now in `lib/duet.js` as `legacyStatus`, because the Mac app
  // needed the same shape and an inline object needed twice is two objects
  // that drift. So `main.js` no longer mentions `fractionPrinted` at all — and
  // the two properties this test exists for are unchanged: the clamp is
  // applied, and the unconditional multiplication has not come back.
  const duet = fs.readFileSync(path.join(ROOT, 'lib/duet.js'), 'utf8');
  assert.match(duet, /clamp\(legacyProgressPercent\(d\.fractionPrinted\)\)/,
    'the legacy Duet path multiplies by 100 again, or stopped clamping');
  assert.ok(!/fractionPrinted \|\| 0\) \* 100/.test(duet),
    'the unconditional multiplication is back');

  // And BOTH hosts reach it, which is the point of it being shared. A rule
  // with one caller is the shape this repo keeps finding.
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  assert.match(main, /KhaytDuet\.legacyStatus\(data, normalizeProgress\)/,
    'main.js builds the legacy shape itself again');
  const engine = fs.readFileSync(
    path.join(ROOT, 'mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift'), 'utf8');
  assert.match(engine, /KhaytDuet\.legacyStatus\(ARG0/,
    'the Mac app does not call the shared legacy shape');
});

test('legacyStatus is the whole shape, not only the number', () => {
  // The endpoint carries no filename, and inventing one would be worse than
  // the empty string a caller can see is empty.
  const Duet = require('../lib/duet.js');
  const s = Duet.legacyStatus(
    { status: 'P', fractionPrinted: 0.42, temps: { heads: { current: [211] }, bed: { current: 60 } } },
    shown);
  assert.equal(s.progress, 42);
  assert.equal(s.filename, '');
  assert.equal(s.timeRemaining, null);
  assert.equal(s.tempNozzle, 211);
  assert.equal(s.tempBed, 60);
  assert.equal(s.type, 'duet');
  // A payload with nothing in it is nulls, never zeros — "we do not know" and
  // "it is cold" must not look the same on a card.
  const empty = Duet.legacyStatus({}, shown);
  assert.equal(empty.tempNozzle, null);
  assert.equal(empty.tempBed, null);
  assert.equal(empty.state, 'Unknown');
});

test('the audit records the source, per its own rule', () => {
  // "an audit nobody can retrace is a rumour" — docs/PRINTER-PROTOCOL-AUDIT.md
  const doc = fs.readFileSync(path.join(ROOT, 'docs/PRINTER-PROTOCOL-AUDIT.md'), 'utf8');
  assert.match(doc, /fractionPrinted/, 'the finding is not in the audit');
  assert.match(doc, /JSON-responses/, 'the source is not cited');
});
