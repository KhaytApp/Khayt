'use strict';
/**
 * Reading an OctoPrint server's answer.
 *
 * This lived inline in main.js, where its only guard was a scan of that file's
 * source — "the weakest kind of test there is", as printer-poll-wiring.test.js
 * says about itself. The 2026-08-27 audit found its defects in exactly this
 * shape of code, and the lesson it recorded was: drive the shipped module with
 * per-endpoint payloads.
 *
 * The payload shapes below are OctoPrint's own REST API: `/api/printer` returns
 * `state.text` and a `temperature` map keyed by tool, `/api/job` returns
 * `state`, `progress.{completion,printTimeLeft}` and `job.file.name`.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const O = require('../lib/octoprint.js');

const printing = {
  printer: {
    state: { text: 'Printing', flags: { printing: true } },
    temperature: { tool0: { actual: 214.9, target: 215 }, bed: { actual: 59.8, target: 60 } },
  },
  job: {
    state: 'Printing',
    job: { file: { name: 'bracket.gcode', display: 'bracket.gcode' } },
    progress: { completion: 42.7, printTime: 1800, printTimeLeft: 2400 },
  },
};

test('a printing machine reads as printing', () => {
  const s = O.readStatus(printing.printer, printing.job);
  assert.equal(s.state, 'Printing');
  assert.equal(s.progress, 43);              // clamped and rounded by printer-status
  assert.equal(s.filename, 'bracket.gcode');
  assert.equal(s.timeRemaining, 2400);
  assert.equal(s.tempNozzle, 214.9);
  assert.equal(s.tempBed, 59.8);
  assert.equal(s.type, 'octoprint');
});

test('no printer connected: the 409 payload is null and the job still answers', () => {
  // THE DEFECT THIS EXISTS FOR. `/api/printer` is guarded by
  // `abort(409, "Printer is not operational")` in server/api/printer.py — 1.11
  // and 2.0 alike — and that is not a fault, it is OctoPrint running with the
  // printer switched off, which is most of any working day. `/api/job` carries
  // no such guard and its `state` reads "Offline" straight from the
  // connection's own string.
  const job = { state: 'Offline', job: { file: { name: null } }, progress: {} };
  const s = O.readStatus(null, job);
  assert.equal(s.state, 'Offline', 'the card must say Offline, not Unknown and not an error');
  assert.equal(s.progress, 0);
  assert.equal(s.filename, '');
  assert.equal(s.tempNozzle, null);
  assert.equal(s.tempBed, null);
});

test('a printer payload with no state falls back to the job endpoint', () => {
  const s = O.readStatus({ temperature: {} }, { state: 'Operational', progress: {} });
  assert.equal(s.state, 'Operational');
});

test('neither endpoint knowing the state is Unknown, not blank', () => {
  const s = O.readStatus(null, {});
  assert.equal(s.state, 'Unknown');
});

test('a progress OctoPrint should never send is still clamped', () => {
  // The shared normaliser's job, and the reason every adapter goes through it:
  // Duet once rendered a 500 KB file offset as 50,000,000%.
  assert.equal(O.readStatus(null, { progress: { completion: 250 } }).progress, 100);
  assert.equal(O.readStatus(null, { progress: { completion: -3 } }).progress, 0);
  assert.equal(O.readStatus(null, { progress: { completion: 'soon' } }).progress, 0);
});

test('an empty answer does not throw', () => {
  for (const [p, j] of [[null, null], [{}, {}], [undefined, undefined]]) {
    const s = O.readStatus(p, j);
    assert.equal(s.type, 'octoprint');
    assert.equal(s.progress, 0);
  }
});
