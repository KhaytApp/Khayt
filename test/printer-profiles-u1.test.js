/**
 * The Snapmaker U1 entry in lib/printer-profiles.js, checked against the machine.
 *
 * That file is 226 lines of catalogue data with no tests, and data is exactly
 * what nobody re-checks: a build volume or a colour count is copied once and
 * then trusted forever. It feeds plate layout and the calculator's auto-fill,
 * so a wrong number here tells a shop a part does not fit, or fits when it
 * does not.
 *
 * Every figure below was read from a real U1 over Moonraker on 2026-08-02,
 * while it printed:
 *
 *   toolhead.axis_maximum   [271.0, 335.0, 275.0]
 *   toolhead.axis_minimum   [0.0, 0.0, -6.0]
 *   extruder objects        extruder, extruder1, extruder2, extruder3
 *   nozzle_diameter         0.4 on all four
 *   kinematics              corexy
 *
 * The Y figure is the one that looks wrong and is not. Klipper reports MOTION
 * limits, and the U1 is a CoreXY whose bed never moves in Y — the travel beyond
 * the 270mm plate is where the SnapSwap tool docks sit. Printable area is
 * necessarily smaller than reach, so these are bounds, not equalities.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/printer-profiles.js');

const MEASURED = { xMax: 271.0, yMax: 335.0, zMax: 275.0, heads: 4, nozzle: 0.4 };

const u1 = () => {
  const list = P.PRINTER_PROFILES || P.profiles || P.PROFILES || [];
  const found = (Array.isArray(list) ? list : Object.values(list)).find((p) => p && p.id === 'snapmaker-u1');
  assert.ok(found, 'the snapmaker-u1 profile is gone');
  return found;
};

test('the U1 profile claims no more machine than the machine has', () => {
  const p = u1();
  // Bounds, not equalities: the printable plate is smaller than the reach.
  assert.ok(p.bed.x <= MEASURED.xMax, `bed x ${p.bed.x} exceeds the measured ${MEASURED.xMax}`);
  assert.ok(p.bed.y <= MEASURED.yMax, `bed y ${p.bed.y} exceeds the measured ${MEASURED.yMax}`);
  assert.ok(p.bed.z <= MEASURED.zMax, `bed z ${p.bed.z} exceeds the measured ${MEASURED.zMax}`);
  // And not absurdly under, which would waste plate the shop paid for.
  assert.ok(p.bed.x > MEASURED.xMax * 0.9, `bed x ${p.bed.x} is far under the machine's reach`);
});

test('four colours because there are four extruders', () => {
  // maxColors drives the "automatic vs manual swap" split in the HueForge
  // export: above it, Bed Ready falls back to STL plus a swap guide.
  assert.equal(u1().maxColors, MEASURED.heads);
});

test('the nozzle matches what all four heads actually carry', () => {
  assert.equal(u1().nozzle, MEASURED.nozzle);
});

test('the printable area stays inside the measured envelope', () => {
  // Written verbatim from Orca's machine profile so plate layout lands right —
  // the comment in printer-profiles.js says a 220mm assumption once misplaced
  // every model. This checks that verbatim copy against the hardware.
  const p = u1();
  const pts = p.printableArea.map((s) => s.split('x').map(Number));
  for (const [x, y] of pts) {
    assert.ok(x >= 0 && x <= MEASURED.xMax, `printable x ${x} outside 0..${MEASURED.xMax}`);
    assert.ok(y >= 0 && y <= MEASURED.yMax, `printable y ${y} outside 0..${MEASURED.yMax}`);
  }
  assert.ok(Number(p.printableHeight) <= MEASURED.zMax,
    `printable height ${p.printableHeight} exceeds the measured ${MEASURED.zMax}`);
});
