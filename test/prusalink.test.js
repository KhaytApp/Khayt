'use strict';
/**
 * Reading a PrusaLink printer's answer.
 *
 * Same argument as test/octoprint.test.js: this lived inline in main.js and its
 * only guard was a source scan.
 *
 * The shapes are Prusa's own. `/api/v1/status` returns
 * `printer.{state,temp_nozzle,temp_bed}` and a `job` object that is exactly
 * `{id, progress, time_remaining, filament_change_in, time_printing}` —
 * lib/WUI/nhttp/status_renderer.cpp in the Buddy firmware, and the OpenAPI
 * spec's StatusJob agrees. `/api/v1/job` is where the file lives.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/prusalink.js');

const status = {
  printer: { state: 'PRINTING', temp_nozzle: 219.4, temp_bed: 59.9, axis_z: 12.4 },
  job: { id: 4, progress: 61, time_remaining: 1980, time_printing: 3120 },
};
const jobEndpoint = { id: 4, file: { name: 'SPICE~1.GCO', display_name: 'spice rack v2.gcode' } };

test('the filename comes from /api/v1/job, because the status endpoint has none', () => {
  // THE DEFECT THIS EXISTS FOR. `job.file` does not exist on /api/v1/status at
  // any firmware version, so the filename was always the empty string — not
  // "usually", always.
  const s = P.readStatus(status, jobEndpoint);
  assert.equal(s.filename, 'spice rack v2.gcode');
});

test('the long name wins over the 8.3 short form', () => {
  // Prusa's own spec illustrates `name` as "SPICE~1.gco". A shop looking at its
  // queue needs the one it saved the file under.
  const s = P.readStatus(status, { file: { name: 'SPICE~1.GCO' } });
  assert.equal(s.filename, 'SPICE~1.GCO', 'the short form is better than nothing');
  const long = P.readStatus(status, jobEndpoint);
  assert.equal(long.filename, 'spice rack v2.gcode');
});

test('the second request answering 204 costs nothing but the name', () => {
  // /api/v1/job answers 204 No Content when nothing is printing, and a missing
  // name must not cost the temperatures and progress the first request returned.
  const s = P.readStatus(status, null);
  assert.equal(s.filename, '');
  assert.equal(s.progress, 61);
  assert.equal(s.tempNozzle, 219.4);
  assert.equal(s.tempBed, 59.9);
  assert.equal(s.timeRemaining, 1980);
  assert.equal(s.state, 'PRINTING');
});

test('an idle printer is idle, not unknown', () => {
  const idle = { printer: { state: 'IDLE', temp_nozzle: 24.2, temp_bed: 23.9 } };
  const s = P.readStatus(idle, null);
  assert.equal(s.state, 'IDLE');
  assert.equal(s.progress, 0);
  assert.equal(s.timeRemaining, null);
});

test('an empty answer does not throw', () => {
  for (const [d, j] of [[null, null], [{}, {}], [undefined, undefined]]) {
    const s = P.readStatus(d, j);
    assert.equal(s.type, 'prusalink');
    assert.equal(s.state, 'Unknown');
    assert.equal(s.progress, 0);
  }
});
