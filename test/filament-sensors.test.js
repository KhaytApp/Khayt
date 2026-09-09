'use strict';
/**
 * Reading a Klipper machine's filament sensors.
 *
 * The fixtures are the literal replies of the Snapmaker U1 on this bench,
 * captured on 2026-09-09 from `/printer/objects/list` and
 * `/printer/objects/query`. Every assertion here is something the printer
 * itself said, and several of them contradict what another Moonraker client
 * on GitHub hardcodes.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const F = require('../lib/filament-sensors.js');

/** Trimmed from the U1's own 196-object list. */
const objectList = { result: { objects: [
  'gcode_move', 'toolhead', 'print_stats', 'virtual_sdcard', 'heater_bed',
  'extruder', 'extruder1', 'extruder2', 'extruder3', 'extruder_offset_calibration',
  'filament_detect',
  'temperature_sensor cavity', 'adc_current_sensor I_AD',
  'filament_motion_sensor e0_filament', 'filament_entangle_detect e0_filament',
  'filament_motion_sensor e1_filament', 'filament_entangle_detect e1_filament',
  'filament_motion_sensor e2_filament', 'filament_entangle_detect e2_filament',
  'filament_motion_sensor e3_filament', 'filament_entangle_detect e3_filament',
  'filament_feed left', 'filament_feed right', 'filament_parameters',
] } };

/** The U1's own query reply, all four heads loaded. */
const loaded = {
  'filament_motion_sensor e0_filament': { filament_detected: true, enabled: true },
  'filament_motion_sensor e1_filament': { filament_detected: true, enabled: true },
  'filament_motion_sensor e2_filament': { filament_detected: true, enabled: true },
  'filament_motion_sensor e3_filament': { filament_detected: true, enabled: true },
  'filament_entangle_detect e0_filament': { detect_factor: 1.0 },
};

test('the sensor a hardcoded name would look for is not on this printer', () => {
  const names = F.sensorNames(objectList);
  assert.ok(!names.includes('filament_switch_sensor filament_sensor'),
    'the conventional name exists here, so the discovery is unnecessary');
  assert.deepEqual(names, [
    'filament_motion_sensor e0_filament',
    'filament_motion_sensor e1_filament',
    'filament_motion_sensor e2_filament',
    'filament_motion_sensor e3_filament',
  ]);
});

test('Snapmaker’s own detectors are not runout sensors', () => {
  const names = F.sensorNames(objectList);
  // `filament_entangle_detect` reports a float, not a boolean; reading
  // `filament_detected` off it gives undefined, which must not become false.
  assert.ok(!names.some((n) => n.startsWith('filament_entangle_detect')));
  // And bare `filament_detect` is the RFID tray reader, not a sensor.
  assert.ok(!names.includes('filament_detect'));
});

test('all four heads loaded is not a runout', () => {
  const names = F.sensorNames(objectList);
  assert.deepEqual(F.runout(loaded, names, 'extruder1'),
    { out: false, sensor: 'filament_motion_sensor e1_filament', watched: 4 });
});

test('an empty head that is NOT printing is an empty slot, not a runout', () => {
  const names = F.sensorNames(objectList);
  const one = Object.assign({}, loaded, {
    'filament_motion_sensor e3_filament': { filament_detected: false, enabled: true },
  });
  // The job is on head 1 and is printing perfectly well.
  const r = F.runout(one, names, 'extruder1');
  assert.equal(r.out, false, 'a spare head with no filament stopped the shop');
  assert.equal(r.sensor, 'filament_motion_sensor e1_filament');
});

test('the printing head running out IS a runout', () => {
  const names = F.sensorNames(objectList);
  const one = Object.assign({}, loaded, {
    'filament_motion_sensor e1_filament': { filament_detected: false, enabled: true },
  });
  assert.equal(F.runout(one, names, 'extruder1').out, true);
});

test('head zero is `extruder`, with no digit', () => {
  const names = F.sensorNames(objectList);
  assert.equal(F.sensorForHead(names, 'extruder'), 'filament_motion_sensor e0_filament');
  assert.equal(F.sensorForHead(names, 'extruder3'), 'filament_motion_sensor e3_filament');
});

test('a sensor switched off answers nothing, and is not an answer of false', () => {
  const names = F.sensorNames(objectList);
  const off = {};
  for (const n of names) off[n] = { filament_detected: false, enabled: false };
  assert.deepEqual(F.runout(off, names, 'extruder1'), { out: null, sensor: null, watched: 0 },
    'a disabled sensor sent the shop to load a spool that was already loaded');
});

test('no sensors at all is null, which is not the same as filament present', () => {
  assert.deepEqual(F.runout({}, [], 'extruder'), { out: null, sensor: null, watched: 0 });
  assert.deepEqual(F.runout({}, ['filament_switch_sensor x'], null),
    { out: null, sensor: null, watched: 0 });
  assert.deepEqual(F.sensorNames(null), []);
  assert.deepEqual(F.sensorNames({ result: {} }), []);
});

test('a single-sensor printer with a conventional name still works', () => {
  const names = F.sensorNames({ result: { objects: [
    'toolhead', 'extruder', 'filament_switch_sensor filament_sensor'] } });
  assert.deepEqual(names, ['filament_switch_sensor filament_sensor']);
  // Its name pairs with no head, so the fallback answers: any enabled sensor
  // saying no is a runout.
  const out = { 'filament_switch_sensor filament_sensor': { filament_detected: false, enabled: true } };
  assert.equal(F.runout(out, names, 'extruder').out, true);
  const ok = { 'filament_switch_sensor filament_sensor': { filament_detected: true, enabled: true } };
  assert.equal(F.runout(ok, names, 'extruder').out, false);
});

test('the space in the object name is encoded, because Moonraker needs it', () => {
  assert.equal(F.queryFor(['filament_motion_sensor e1_filament']),
    'filament_motion_sensor%20e1_filament');
  assert.equal(F.queryFor([]), '');
});
