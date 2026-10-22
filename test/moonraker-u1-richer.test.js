'use strict';
/**
 * The richer printer card, and the runout the Mac could not raise, against
 * the Snapmaker U1's own bytes.
 *
 * Fixtures (test/fixtures/), each the literal body of a read-only GET to the
 * U1 on this bench, 2026-10-22, idle after a 750-layer job with head 1 docked
 * last:
 *
 *   u1-objects-list.json   /printer/objects/list
 *   u1-status-query.json   /printer/objects/query?print_stats&…&webhooks&fan
 *                          &filament_motion_sensor e0..e3_filament
 *                          &temperature_sensor cavity
 *   u1-status-hot.json     /printer/objects/query?extruder1
 *   u1-head-fans.json      /printer/objects/query?fan_generic e1..e3_fan
 *
 * Nothing on the printer was changed to get them. A runout cannot be produced
 * on a printer by reading it, so the runout cases flip ONE field of a copy of
 * the real reply and say so.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/moonraker.js');

const list = require('./fixtures/u1-objects-list.json');
const query = require('./fixtures/u1-status-query.json');
const hot = require('./fixtures/u1-status-hot.json');
const headFans = require('./fixtures/u1-head-fans.json');

const clone = (v) => JSON.parse(JSON.stringify(v));
/** The main reply with the head fans in it, as one query asking for both returns. */
function withFans(reply) {
  const r = clone(reply);
  Object.assign(r.result.status, clone(headFans.result.status));
  return r;
}

test('discovery finds the U1’s four motion sensors, its cavity and its head fans', () => {
  const d = M.discover(list);
  assert.deepEqual(d.sensors, [
    'filament_motion_sensor e0_filament', 'filament_motion_sensor e1_filament',
    'filament_motion_sensor e2_filament', 'filament_motion_sensor e3_filament',
  ]);
  // The cavity is a sensor, not a heater: it has a temperature and no target.
  assert.equal(d.chamber, 'temperature_sensor cavity');
  assert.deepEqual(d.headFans, ['fan_generic e1_fan', 'fan_generic e2_fan', 'fan_generic e3_fan']);
});

test('the query asks for what discovery found, encoded, and the bare list still works', () => {
  const d = M.discover(list);
  const q = M.queryWith(d).split('&');
  assert.ok(q.includes('filament_motion_sensor%20e2_filament'));
  assert.ok(q.includes('temperature_sensor%20cavity'));
  assert.ok(q.includes('fan_generic%20e3_fan'));
  // The desktop passes the sensor array on its own; that must keep meaning
  // "QUERY plus these sensors" and nothing else.
  assert.equal(M.queryWith(d.sensors), M.QUERY + '&' + d.sensors.map(encodeURIComponent).join('&'));
  assert.equal(M.queryWith(null), M.QUERY);
  assert.equal(M.queryWith([]), M.QUERY);
});

test('a machine with no list reply discovers nothing rather than throwing', () => {
  assert.deepEqual(M.discover(null), { sensors: [], chamber: null, headFans: [] });
  assert.deepEqual(M.discover({ result: { objects: 'nope' } }), { sensors: [], chamber: null, headFans: [] });
});

test('the U1 idle: every richer field read from its own reply', () => {
  const d = M.discover(list);
  const s = M.readStatus(withFans(query), hot, 'extruder1', d);
  assert.equal(s.state, 'complete');
  assert.equal(s.layer, 750);
  assert.equal(s.totalLayers, 750);
  // Head 1 is the live head (toolhead.extruder), so its reading and its target.
  assert.equal(s.tempNozzle, 35);
  assert.equal(s.targetNozzle, 0);
  assert.equal(s.tempBed, 32);
  assert.equal(s.targetBed, 0);
  assert.equal(s.tempChamber, 34);
  assert.equal(s.targetChamber, null, 'a temperature_sensor has no target to report');
  assert.equal(s.fanPart, 0);
  assert.equal(s.speedFactor, 100);
  assert.equal(s.flowFactor, 100);
  // "Printer is ready" is not news, and print_stats.message is "".
  assert.equal(s.message, null);
  assert.equal(s.filamentOut, false, 'all four heads report filament_detected: true');
});

test('the live head’s target, never a parked head’s', () => {
  const r = clone(query);
  r.result.status.extruder.target = 0;          // head 0, parked
  const h = clone(hot);
  h.result.status.extruder1.target = 220;
  const s = M.readStatus(r, h, 'extruder1', M.discover(list));
  assert.equal(s.targetNozzle, 220);
});

test('a head with its own fan is read off that fan, not head 0’s', () => {
  const r = withFans(query);
  r.result.status.fan.speed = 1.0;                       // head 0's, parked
  r.result.status['fan_generic e1_fan'].speed = 0.35;    // the printing head
  assert.equal(M.readStatus(r, hot, 'extruder1', M.discover(list)).fanPart, 35);
  // Only one of the head fans answered: head 1's is missing, so the answer
  // is "cannot say" rather than head 0's 100% or a sibling's.
  const partial = withFans(query);
  partial.result.status.fan.speed = 1.0;
  delete partial.result.status['fan_generic e1_fan'];
  assert.equal(M.readStatus(partial, hot, 'extruder1', M.discover(list)).fanPart, null);
  // A reply that carries no per-head fans at all is a machine without them,
  // and Klipper's own `fan` is its part fan. (On a U1 that is head 0's — which
  // is why a caller has to query what `discover` found.)
  const bare = clone(query);
  bare.result.status.fan.speed = 1.0;
  const s = M.readStatus(bare, hot, 'extruder1', M.discover(list).sensors);
  assert.equal(s.fanPart, 100);
});

test('runout: the printing head’s sensor saying no is a runout (one field flipped)', () => {
  const r = clone(query);
  r.result.status['filament_motion_sensor e1_filament'].filament_detected = false;
  assert.equal(M.readStatus(r, hot, 'extruder1', M.discover(list)).filamentOut, true);
  // The same reply read with the bare sensor list (the desktop's shape) agrees.
  assert.equal(M.readStatus(r, hot, 'extruder1', M.discover(list).sensors).filamentOut, true);
});

test('runout: an empty spare head is not a runout', () => {
  const r = clone(query);
  r.result.status['filament_motion_sensor e3_filament'].filament_detected = false;
  assert.equal(M.readStatus(r, hot, 'extruder1', M.discover(list)).filamentOut, false);
});

test('runout: no sensors discovered is "cannot say", not "fine"', () => {
  assert.equal(M.readStatus(query, hot, 'extruder1', null).filamentOut, null);
});

test('Klippy’s own fault outranks the job message; a paused macro’s message is shown', () => {
  const down = clone(query);
  down.result.status.webhooks = { state: 'shutdown', state_message: "MCU 'e2' shutdown: Timer too close" };
  down.result.status.print_stats.message = 'something else';
  assert.equal(M.readStatus(down).message, "MCU 'e2' shutdown: Timer too close");
  const paused = clone(query);
  paused.result.status.print_stats.message = 'Filament runout on e1';
  assert.equal(M.readStatus(paused).message, 'Filament runout on e1');
});

test('a heated chamber has a target; a starting Klipper reports nothing at all', () => {
  const heated = { result: { status: { 'heater_generic chamber': { temperature: 45.2, target: 50 } } } };
  const s = M.readStatus(heated);
  assert.equal(s.tempChamber, 45.2);
  assert.equal(s.targetChamber, 50);
  // A starting Klipper omits every object; nothing becomes 0.
  const empty = M.readStatus({ result: { status: {} } });
  for (const k of ['targetNozzle', 'targetBed', 'tempChamber', 'targetChamber', 'layer', 'totalLayers',
                   'fanPart', 'speedFactor', 'flowFactor', 'message']) {
    assert.equal(empty[k], null, k);
  }
});

test('a board sensor is not a chamber', () => {
  const d = M.discover({ result: { objects: ['temperature_sensor mcu_temp', 'temperature_sensor raspberry_pi'] } });
  assert.equal(d.chamber, null);
});
