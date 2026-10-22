'use strict';
/**
 * The richer printer card for the protocols with no machine on the bench.
 *
 * The U1 (Moonraker) is tested against its own bytes in
 * moonraker-u1-richer.test.js. Here the vendor's documents are the fixture,
 * and every payload below is copied from one:
 *
 *   OctoPrint   docs/api/printer.rst (full state + chamber examples),
 *               docs/api/job.rst (`error`), server/api/printer.py (chamber
 *               key deleted unless the profile has a heated chamber)
 *   PrusaLink   prusa3d/Prusa-Link-Web spec/openapi.yaml, `StatusPrinter`
 *               examples
 *   Duet        RepRapFirmware wiki "Object Model Documentation" field names
 *   Repetier    repetier-server.com API reference, the `stateList` example;
 *               RepetierSharp `PrinterState` / `Printer` for `heatedChambers`,
 *               `fans` and `ofLayer`
 *   SDCP        cbd-tech SDCP v3.0.0 spec, the status message example
 *
 * Bambu is absent on purpose: its LAN report is documented only by community
 * reverse-engineering, so no new Bambu field is read. Its layers were already
 * parsed by bambu-report.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const octoprint = require('../lib/octoprint.js');
const prusalink = require('../lib/prusalink.js');
const duet = require('../lib/duet.js');
const repetier = require('../lib/repetier.js');
const sdcp = require('../lib/sdcp.js');
const { normalizeProgress } = require('../lib/printer-status.js');

test('OctoPrint: targets from Temperature Data; chamber only when the profile has one', () => {
  const printer = {
    temperature: {
      tool0: { actual: 214.8821, target: 220.0, offset: 0 },
      tool1: { actual: 25.3, target: null, offset: 0 },
      bed: { actual: 50.221, target: 70.0, offset: 5 },
    },
    state: { text: 'Operational' },
  };
  const s = octoprint.readStatus(printer, { state: 'Operational', progress: {} });
  assert.equal(s.targetNozzle, 220);
  assert.equal(s.targetBed, 70);
  assert.equal(s.tempChamber, null, 'no chamber key: the profile has none');
  assert.equal(s.message, null);
  const withChamber = octoprint.readStatus(
    { ...printer, temperature: { ...printer.temperature, chamber: { actual: 50.221, target: 70.0, offset: 5 } } },
    { state: 'Printing', progress: {} });
  assert.equal(withChamber.tempChamber, 50.221);
  assert.equal(withChamber.targetChamber, 70);
  // "may be null if no target temperature is set"
  const unset = octoprint.readStatus({ temperature: { tool0: { actual: 25.3, target: null } } }, {});
  assert.equal(unset.targetNozzle, null);
  // OctoPrint keeps no layers, fans or factors.
  for (const k of ['layer', 'totalLayers', 'fanPart', 'speedFactor', 'flowFactor']) assert.equal(s[k], undefined, k);
});

test('OctoPrint: the job’s error is the message', () => {
  const s = octoprint.readStatus(null, { state: 'Offline after error', error: 'Too many consecutive timeouts, printer still connected?' , progress: {} });
  assert.equal(s.message, 'Too many consecutive timeouts, printer still connected?');
});

test('PrusaLink: targets, speed and flow from StatusPrinter; fan RPM is not a percentage', () => {
  const status = {
    printer: {
      state: 'PRINTING', temp_nozzle: 214.9, target_nozzle: 215.0, temp_bed: 59.5, target_bed: 60.0,
      axis_x: 23.2, axis_y: 24.3, axis_z: 0.5, flow: 95, speed: 100, fan_hotend: 420, fan_print: 420,
      status_printer: { ok: true, message: 'OK' },
    },
    job: { id: 1, progress: 12 },
  };
  const s = prusalink.readStatus(status, null);
  assert.equal(s.targetNozzle, 215);
  assert.equal(s.targetBed, 60);
  assert.equal(s.speedFactor, 100);
  assert.equal(s.flowFactor, 95);
  assert.equal(s.fanPart, undefined, 'fan_print is RPM (example 420)');
  assert.equal(s.message, null, '"OK" is not news');
  const bad = prusalink.readStatus({ printer: { state: 'ATTENTION', status_printer: { ok: false, message: 'Filament runout' } } }, null);
  assert.equal(bad.message, 'Filament runout');
  // A heater switched off reads 0, not absent; an absent one stays null.
  const off = prusalink.readStatus({ printer: { state: 'IDLE', target_nozzle: 0 } }, null);
  assert.equal(off.targetNozzle, 0);
  assert.equal(off.targetBed, null);
});

test('Duet (SBC model): targets, chamber, layers, fan, speed and flow by the object model’s names', () => {
  const model = {
    heat: {
      bedHeaters: [0, -1], chamberHeaterMapping: [[2]],
      heaters: [{ current: 60.1, active: 60 }, { current: 210.4, active: 215 }, { current: 39.8, active: 45 }],
    },
    tools: [{ heaters: [1], fans: [0], extruders: [0] }],
    fans: [{ actualValue: 0.5, requestedValue: 0.5 }],
    move: { speedFactor: 1.0, extruders: [{ factor: 0.95 }] },
    job: { layer: 12, file: { fileName: 'part.gcode', size: 1000, numLayers: 100 }, filePosition: 500 },
    state: { status: 'processing', displayMessage: 'Layer 12' },
  };
  const s = duet.statusFromObjectModel(model);
  assert.deepEqual(
    [s.tempNozzle, s.targetNozzle, s.tempBed, s.targetBed, s.tempChamber, s.targetChamber],
    [210.4, 215, 60.1, 60, 39.8, 45]);
  assert.deepEqual([s.layer, s.totalLayers, s.fanPart, s.speedFactor, s.flowFactor, s.message],
    [12, 100, 50, 100, 95, 'Layer 12']);
});

test('Duet (standalone live query): what the f flag leaves out is null, not guessed', () => {
  // `f` returns live fields only: heaters' active, fans' actualValue and
  // job.layer are there; speedFactor, factor and displayMessage are not.
  const live = { result: {
    heat: { bedHeaters: [0], heaters: [{ current: 20, active: 0 }, { current: 21, active: 0 }] },
    tools: [{ heaters: [1], fans: [0] }],
    fans: [{ actualValue: -1 }],
    job: { layer: null },
    state: { status: 'idle' },
  } };
  const s = duet.statusFromObjectModel(live, { numLayers: 0 });
  assert.equal(s.targetNozzle, 0);
  assert.equal(s.fanPart, null, '-1 is "unknown"');
  assert.equal(s.layer, null);
  assert.equal(s.totalLayers, null, 'numLayers 0 is "unknown"');
  assert.equal(s.speedFactor, null);
  assert.equal(s.flowFactor, null);
  assert.equal(s.message, null);
  assert.equal(s.tempChamber, null);
});

test('Duet: the existing temperature mapping is unchanged by the refactor', () => {
  const heat = { heaters: [{ current: 210 }, { current: 60 }], bedHeaters: [1] };
  assert.equal(duet.duetHeaterTemp(heat, [{ heaters: [0] }], 'tool'), 210);
  assert.equal(duet.duetHeaterTemp(heat, [{ heaters: [0] }], 'bed'), 60);
  assert.equal(duet.duetHeaterTemp({ heaters: [{ current: 1 }], bedHeaters: [-1] }, [], 'bed'), null);
  assert.equal(duet.duetHeaterTemp({ heaters: [{ current: 1 }, { current: 2 }] }, [{ heaters: [] }], 'tool'), null);
  assert.equal(duet.duetHeaterTemp({ heaters: [{ current: 1 }, { current: 2 }] }, undefined, 'tool'), 2);
});

/** Repetier's own `stateList` example, verbatim apart from the history arrays. */
const repetierState = { data: { delta: {
  activeExtruder: 0, debugLevel: 6,
  extruder: [{ output: 0, tempRead: 25.4, tempSet: 0 }, { output: 0, tempRead: 25.39999961853027, tempSet: 0 }],
  fanOn: false, fanVoltage: 0, firmware: 'Repetier_0.92', firmwareURL: 'https://github.com/repetier/Repetier-Firmware/',
  flowMultiply: 100, hasXHome: false, hasYHome: false, hasZHome: false,
  heatedBed: { output: 0, tempRead: 0, tempSet: 0 }, layer: 0, numExtruder: 2, powerOn: false,
  sdcardMounted: true, speedMultiply: 100, x: -21, y: 0, z: 0,
} } };

test('Repetier: the vendor’s idle example — factors in percent, fan off, no layers without a job', () => {
  const s = repetier.repetierStatus({ stateData: repetierState, listData: [{ slug: 'delta', job: 'none', online: 1 }],
                                      slug: 'delta', normalizeProgress });
  assert.equal(s.speedFactor, 100);
  assert.equal(s.flowFactor, 100);
  assert.equal(s.fanPart, 0, 'fanOn: false');
  assert.equal(s.targetNozzle, 0);
  assert.equal(s.targetBed, 0);
  assert.equal(s.layer, null, '`layer: 0` with no job is not "layer 0 of"');
  assert.equal(s.tempChamber, null);
});

test('Repetier: printing, with the newer fans[] and heatedChambers[] shape', () => {
  const st = { data: { p: {
    activeExtruder: 0, extruder: [{ tempRead: 210, tempSet: 215 }],
    heatedBeds: [{ tempRead: 60, tempSet: 60 }], heatedChambers: [{ tempRead: 38, tempSet: 40 }],
    fans: [{ on: true, voltage: 255 * 0.4 }], layer: 37, speedMultiply: 120, flowMultiply: 98,
  } } };
  const s = repetier.repetierStatus({ stateData: st, listData: [{ slug: 'p', job: 'part.gcode', ofLayer: 200, done: 18, online: 1 }],
                                      slug: 'p', normalizeProgress });
  assert.deepEqual([s.targetNozzle, s.targetBed, s.tempChamber, s.targetChamber], [215, 60, 38, 40]);
  assert.deepEqual([s.layer, s.totalLayers, s.fanPart, s.speedFactor, s.flowFactor], [37, 200, 40, 120, 98]);
});

test('SDCP: the spec’s status example — enclosure as the chamber, layers under the shared names', () => {
  const msg = {
    Status: {
      CurrentStatus: [0, 1, 2, 3], PreviousStatus: 0, PrintScreen: 0, ReleaseFilm: 0, TempOfUVLED: 0,
      TimeLapseStatus: 0, TempOfBox: 0, TempTargetBox: 0,
      PrintInfo: { Status: 0, CurrentLayer: 100, TotalLayer: 1000, CurrentTicks: 65535, TotalTicks: 65535,
                   Filename: 'HitWork.ctb', ErrorNumber: 1, TaskId: 'xxx' },
    },
    MainboardID: 'ffffffff', TimeStamp: 1687069655, Topic: 'sdcp/status/ffffffff',
  };
  const s = sdcp.statusFrom(msg);
  assert.equal(s.tempChamber, 0);
  assert.equal(s.targetChamber, 0);
  assert.equal(s.layer, 100);
  assert.equal(s.totalLayers, 1000);
  assert.equal(s.message, 'File checksum failed');
  // The old names are kept for their callers.
  assert.equal(s.currentLayer, 100);
  assert.equal(s.tempBox, 0);
  const none = sdcp.statusFrom({ Status: { PrintInfo: {} } });
  assert.equal(none.tempChamber, null);
  assert.equal(none.layer, null);
  assert.equal(none.message, null);
});

test('Duet: a heater switched off or on standby has no target, though RRF keeps its last setpoint', () => {
  const model = {
    heat: {
      bedHeaters: [0], chamberHeaterMapping: [[2]],
      heaters: [{ current: 22, active: 60, state: 'off' }, { current: 150, active: 215, state: 'standby' },
        { current: 30, active: 45, state: 'off' }],
    },
    tools: [{ heaters: [1], fans: [0], extruders: [0] }],
    state: { status: 'idle' },
  };
  const s = duet.statusFromObjectModel(model);
  assert.deepEqual([s.targetNozzle, s.targetBed, s.targetChamber], [null, null, null]);
  model.heat.heaters[1].state = 'active';
  assert.equal(duet.statusFromObjectModel(model).targetNozzle, 215);
});
