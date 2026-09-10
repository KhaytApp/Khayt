'use strict';
/**
 * Reading a Klipper printer's answer.
 *
 * The fixtures below are the literal reply of the Snapmaker U1 on this bench,
 * captured mid-print on 2026-09-05 — a four-head toolchanger 53 layers into a
 * 212-layer PETG job. Vendor docs are the fixture for the six protocols with no
 * machine here; this one has a machine, so its own bytes are.
 *
 * Every assertion in this file is a correction that was found on that printer
 * and would be invisible without it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/moonraker.js');

/** `/printer/objects/query?` + M.QUERY, mid-print. Trimmed to the fields read. */
const printing = {
  result: {
    status: {
      print_stats: {
        filename: 'output_1_1_PETG_3h58m.gcode',
        total_duration: 7521.377,
        print_duration: 7291.599,
        filament_used: 20379.499,
        state: 'printing',
        info: { total_layer: 212, current_layer: 53 },
      },
      virtual_sdcard: {
        progress: 0.41637998,
        is_active: true,
        file_position: 4934794,
        file_size: 11851660,
      },
      // Toolhead ZERO, parked and cooling, while head 2 prints.
      extruder: { temperature: 44.0, target: 0.0 },
      heater_bed: { temperature: 80.0, target: 80.0 },
      toolhead: { extruder: 'extruder2' },
    },
  },
};

/** The second query, for the head that is actually printing. */
const liveHead = { result: { status: { extruder2: { temperature: 256.0, target: 255.0 } } } };

test('the live toolhead is the one whose temperature is shown', () => {
  // On a toolchanger `extruder` is head 0 and nothing else. This machine
  // reported 44 °C on a job printing PETG at 255: toolhead 0 was parked.
  assert.equal(M.activeExtruder(printing), 'extruder2');
  const status = M.readStatus(printing, liveHead, 'extruder2');
  assert.equal(status.tempNozzle, 256);
});

test('a single-head machine asks for nothing extra', () => {
  // Null means "the reading in front of you is the right one", so only the
  // machines that need it pay for a second request.
  const single = { result: { status: { toolhead: { extruder: 'extruder' } } } };
  assert.equal(M.activeExtruder(single), null);
  assert.equal(M.activeExtruder({ result: { status: { toolhead: {} } } }), null);
  assert.equal(M.activeExtruder({}), null);
});

test('a failed second request keeps toolhead zero rather than showing nothing', () => {
  const status = M.readStatus(printing, null, 'extruder2');
  assert.equal(status.tempNozzle, 44, 'a wrong temperature is worse than none, but none is worse still');
});

test('progress is layers, not bytes', () => {
  // 53 of 212 is 25%. The byte position says 42% on this file, and on a relief
  // whose detail is all in the upper layers it said 0.7% when the job was 19%
  // done — and the ETA extrapolated from that read 176 hours on a five-hour
  // print.
  const status = M.readStatus(printing, liveHead, 'extruder2');
  assert.equal(status.progress, 25);
  assert.equal(status.progressSource, 'layers');
});

test('bytes when the slicer never announced the layers', () => {
  const noLayers = JSON.parse(JSON.stringify(printing));
  delete noLayers.result.status.print_stats.info;
  const status = M.readStatus(noLayers, null, null);
  assert.equal(status.progress, 42);
  assert.equal(status.progressSource, 'bytes');
});

test('a slicer that sets the total and never the current layer falls back', () => {
  // Klipper stores `info_current_layer = None` until SET_PRINT_STATS_INFO
  // arrives. Number(null) is 0 and 0 is finite, so a naive read pinned this at
  // 0% for the whole job and never fell back.
  const halfSet = JSON.parse(JSON.stringify(printing));
  halfSet.result.status.print_stats.info = { total_layer: 212, current_layer: null };
  const status = M.readStatus(halfSet, null, null);
  assert.equal(status.progressSource, 'bytes');
  assert.equal(status.progress, 42);
});

test('the ETA is extrapolated from print_duration, not total_duration', () => {
  // total_duration includes the heating and idling either side of the job.
  // 7291.6s at 25% → about 21,875 remaining; from total_duration it would be
  // ~690 seconds longer, which is the heat-up being charged to the print.
  const status = M.readStatus(printing, liveHead, 'extruder2');
  assert.ok(Math.abs(status.timeRemaining - 21874) < 5, `got ${status.timeRemaining}`);
});

test('an idle printer reads as idle rather than as an error', () => {
  const idle = {
    result: {
      status: {
        print_stats: { state: 'standby', filename: '', print_duration: 0 },
        virtual_sdcard: { progress: 0 },
        extruder: { temperature: 24.4 },
        heater_bed: { temperature: 23.1 },
        toolhead: { extruder: 'extruder' },
      },
    },
  };
  const status = M.readStatus(idle, null, null);
  assert.equal(status.state, 'standby');
  assert.equal(status.progress, 0);
  assert.equal(status.timeRemaining, null, 'nothing is printing, so there is nothing to wait for');
  assert.equal(status.filename, '');
});

test('an answer with nothing in it does not throw', () => {
  // A printer that is up but has not finished starting Klipper answers with an
  // empty status object. A poller that threw there showed an error where the
  // machine card should have said what it was doing.
  for (const junk of [{}, { result: {} }, { result: { status: {} } }, null]) {
    const status = M.readStatus(junk, null, null);
    assert.equal(status.state, 'Unknown');
    assert.equal(status.progress, 0);
    assert.equal(status.type, 'moonraker');
  }
});

test('the query asks for every object the reading needs, and no more', () => {
  // A request that forgot one produced a screen that silently read zero — the
  // fields are optional in the parse on purpose, because a starting Klipper
  // omits them.
  assert.deepEqual(M.QUERY.split('&').sort(),
    ['extruder', 'heater_bed', 'print_stats', 'toolhead', 'virtual_sdcard']);
});

/**
 * ── THE SLICER'S ESTIMATE FOR THE FILE ─────────────────────────────────────
 *
 * Moonraker publishes no time-remaining of its own — every other adapter reads
 * one from the printer — so this adapter worked it out from elapsed ÷ done.
 * Two percent into a print that is worthless, and the number it produced was on
 * the dashboard: see `etaWithEstimate` in lib/printer-status.js.
 *
 * `/server/files/metadata` carries `estimated_time`, extracted by Moonraker's
 * own metadata.py from what the slicer wrote into the G-code.
 */
test('the metadata path is asked for by name, and not at all when idle', () => {
  assert.equal(M.metadataPath('output_1_1_PETG_3h58m.gcode'),
               '/server/files/metadata?filename=output_1_1_PETG_3h58m.gcode');
  // A path in a subfolder, and a space, both of which Klipper allows.
  assert.equal(M.metadataPath('jobs/a b.gcode'),
               '/server/files/metadata?filename=jobs%2Fa%20b.gcode');
  for (const idle of ['', '   ', null, undefined]) {
    assert.equal(M.metadataPath(idle), null,
      'an idle printer has no file to ask about, and the request would 404');
  }
});

test('an absent estimate is absent, not zero', () => {
  assert.equal(M.slicerTotalSeconds({ result: { estimated_time: 14280 } }), 14280);
  for (const none of [{}, { result: {} }, { result: { estimated_time: 0 } },
                      { result: { estimated_time: 'soon' } }, null]) {
    assert.equal(M.slicerTotalSeconds(none), null);
  }
});

test('the ETA falls back to extrapolation when the slicer left no estimate', () => {
  // Which is exactly what this adapter did before the metadata was fetched, so
  // a file sliced by something that writes no estimate is no worse off.
  const status = M.readStatus(printing, liveHead, 'extruder2', [], null);
  assert.ok(Math.abs(status.timeRemaining - 21874) < 5, `got ${status.timeRemaining}`);
});

test('two percent in, the metadata is what saves the figure', () => {
  // The bench reply, rewound to the state the shop's dashboard was showing on
  // 2026-09-10: 27 minutes elapsed, 2% of the layers done.
  const early = JSON.parse(JSON.stringify(printing));
  early.result.status.print_stats.print_duration = 1653;
  early.result.status.print_stats.info = { total_layer: 212, current_layer: 4 };
  early.result.status.print_stats.filename = 'BLHT_PETG_4h24m.gcode';

  const guessing = M.readStatus(early, liveHead, 'extruder2', [], null);
  assert.ok(guessing.timeRemaining > 20 * 3600,
    `without the estimate this is the twenty-two-hour answer, got ${guessing.timeRemaining}`);

  const told = M.readStatus(early, liveHead, 'extruder2', [],
                            { result: { estimated_time: 4.4 * 3600 } });
  assert.ok(told.timeRemaining > 4 * 3600 && told.timeRemaining < 4.5 * 3600,
    `expected about four and a quarter hours, got ${(told.timeRemaining / 3600).toFixed(2)}h`);
});
