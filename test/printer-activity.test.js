'use strict';
/**
 * C2 (Prusa batch 1): lib/printer-activity.js, two closed sets per printer,
 * and lib/attention.js machineState as their projection. Every word each
 * protocol's adapter writes runs through test/fixtures/printer-activity-
 * vectors.json; `main` is what machineState read before C2. A word class is
 * read from its activity only once it is in FIXED: until then it must read
 * exactly `main`, and a word no table knows always reads by the old rule.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const PA = require('../lib/printer-activity.js');
const A = require('../lib/attention.js');
const V = require('./fixtures/printer-activity-vectors.json');

test('the sets are closed: every status is a known link and (when online) a known activity', () => {
  for (const c of V.cases) {
    const s = PA.machineStatus(c.machine, c.entry);
    assert.ok(PA.LINKS.includes(s.link), c.why);
    if (s.link === 'online') assert.ok(PA.ACTIVITIES.includes(s.activity), c.why);
    else assert.equal(s.activity, null, c.why);
    assert.deepEqual({ link: s.link, activity: s.activity }, c.status, c.why);
  }
});

test('machineState is the projection: each class not yet fixed reads as main, each fixed class as designed', () => {
  for (const c of V.cases) {
    const want = c.cls && PA.FIXED.includes(c.cls) ? c.legacy : c.main;
    assert.equal(A.machineState(c.machine, c.entry), want, `${c.why} (class ${c.cls || '-'})`);
  }
});

test('a word no table knows reads exactly as on main (the substring rule)', () => {
  const unknown = V.cases.filter((c) => c.entry && !c.entry.error && !c.cls);
  assert.ok(unknown.length >= 10);
  for (const c of unknown) assert.equal(A.machineState(c.machine, c.entry), c.main, c.why);
  for (const w of ['zz top', 'PRINTER_IS_HAPPY', 'erroneous', 'reprinting soon']) {
    for (const progress of [0, 7]) {
      const e = { state: w, progress };
      assert.equal(A.machineState({ printerApi: { type: 'octoprint' } }, e), PA.substringRule(e), w);
    }
  }
});

test('every word in the tables is in the fixture, so none is untested', () => {
  const seen = new Set(V.cases.filter((c) => c.entry && c.entry.state != null).map((c) => PA.word(c.entry.state)));
  const missing = Object.keys(PA.WORDS).filter((w) => !seen.has(w) && !['pause', 'printing from sd', 'completed', 'canceled', 'canceling', 'connected', 'finish', 'running', 'changing tool'].includes(w));
  assert.deepEqual(missing, []);
});

test('FIX: a paused printer is busy, never offered as free (was idle)', () => {
  const m = { printerApi: { type: 'moonraker' } };
  for (const w of ['paused', 'Paused', 'PAUSED', 'pausing', 'Pausing']) {
    assert.equal(PA.machineStatus(m, { state: w }).activity, 'paused', w);
    assert.equal(A.machineState(m, { state: w, progress: 0 }), 'printing', w);
  }
});

test('FIX: a printer that is preparing, homing or otherwise working is busy, never free (was idle)', () => {
  const m = { printerApi: { type: 'bambu' } };
  for (const w of ['Preparing', 'Slicing', 'BUSY', 'homing', 'exposing', 'lifting', 'transferring', 'self_testing', 'changingTool', 'processing', 'starting', 'resuming', 'Cancelling', 'Sending file to SD', 'Finishing']) {
    assert.equal(PA.machineStatus(m, { state: w }).activity, 'printing', w);
    assert.equal(A.machineState(m, { state: w, progress: 0 }), 'printing', w);
  }
});
