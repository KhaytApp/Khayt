const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const f = require('../lib/bambu-faults.js');

/**
 * Bambu print_error and HMS codes, in the format ha-bambulab writes them
 * (pybambu/models.py HMSNotification.hms_code, PrintError.print_update) and
 * Bambu's own screens show.
 */

test('HMS codes are four groups of four hex digits, as in ha-bambulab\'s own example', () => {
  // models.py: attr 50331904 "In hex this is 0300 0100", code 65543 "0001 0007"
  // → "HMS_0300_0100_0001_0007".
  assert.equal(f.hmsCode(50331904, 65543), '0300_0100_0001_0007');
  assert.equal(f.hmsCode(0, 65543), null);
  assert.equal(f.hmsCode(50331904, 0), null);
  assert.equal(f.hmsCode(-1, 5), null);
  assert.equal(f.hmsCode(2 ** 33, 5), null);
  assert.equal(f.hmsCode(1.5, 5), null);
});

test('print_error is two groups: 50348044 is 0300_400C, the cancelled task', () => {
  // models.py: "When a print is canceled by the user … print_error: 50348044".
  assert.equal(f.printErrorCode(50348044), '0300_400C');
  // models.py PrintError example: 117473286 → "0700-8006" (written 0700_8006 here).
  assert.equal(f.printErrorCode(117473286), '0700_8006');
  assert.equal(f.printErrorCode(0), null);
  assert.equal(f.printErrorCode('50348044'), '0300_400C');
  assert.equal(f.printErrorCode('junk'), null);
});

test('severity is code >> 16 and module is attr >> 24, per utils.py', () => {
  assert.equal(f.hmsSeverity(65543), 'fatal');         // 0x0001_0007
  assert.equal(f.hmsSeverity(0x00020001), 'serious');
  assert.equal(f.hmsSeverity(0x00030001), 'common');
  assert.equal(f.hmsSeverity(0x00040001), 'info');
  assert.equal(f.hmsSeverity(0x00090001), 'unknown');
  assert.equal(f.hmsModule(0x03000100), 'mc');
  assert.equal(f.hmsModule(0x07002000), 'ams');
  assert.equal(f.hmsModule(0x0C000300), 'xcam');
  assert.equal(f.hmsModule(0x05000400), 'mainboard');
  assert.equal(f.hmsModule(0x08000000), 'toolhead');
  assert.equal(f.hmsModule(0x12000000), 'unknown');
});

test('a known fault reads as its sentence and its code', () => {
  assert.equal(f.faultText({ gcode_state: 'FAILED', print_error: 50348044 }), 'The task was canceled. (0300_400C)');
  assert.equal(f.faultText({ hms: [{ attr: 50331904, code: 65543 }] }),
    'The heatbed temperature is abnormal; the sensor may have an open circuit. (HMS_0300_0100_0001_0007)');
});

test('an unknown print_error shows only once the job has stopped or paused', () => {
  const code = 0x03004FFF;
  assert.equal(f.faultText({ gcode_state: 'RUNNING', print_error: code }), null);
  assert.equal(f.faultText({ gcode_state: 'PAUSE', print_error: code }), 'Printer reported 0300_4FFF');
  assert.equal(f.faultText({ gcode_state: 'FAILED', print_error: code }), 'Printer reported 0300_4FFF');
});

test('info notices are not faults; the most severe leads, the rest are counted', () => {
  // 0C00_0300_0003_000B "Inspecting the first layer: please wait a moment." is severity info.
  assert.equal(f.faultText({ hms: [{ attr: 0x0C000300, code: 0x0004000B }] }), null);
  const text = f.faultText({ hms: [
    { attr: 0x0C000300, code: 0x00030008 },   // common
    { attr: 0x03000100, code: 0x00010007 },   // fatal
    { attr: 0x03000100, code: 0x00010007 },   // duplicate
  ] });
  assert.match(text, /^The heatbed temperature is abnormal/);
  assert.match(text, /\(\+1 more\)$/);
});

test('nothing wrong, or nothing readable, is null', () => {
  for (const p of [null, undefined, {}, [], 'x', { print_error: 0, hms: [] }, { hms: 'x' }, { hms: [null, 1, {}] }]) {
    assert.equal(f.faultText(p), null, JSON.stringify(p));
  }
});

test('the short table is copied verbatim from ha-bambulab\'s English HMS text', () => {
  // When the vendored source is to hand (it is fetched, not committed), check
  // every sentence against it. Otherwise only the shape is checked.
  const src = process.env.KHAYT_HMS_EN_JSON;
  for (const [k, v] of Object.entries({ ...f.PRINT_ERRORS, ...f.HMS })) {
    assert.match(k, /^[0-9A-F]{8}([0-9A-F]{8})?$/);
    assert.ok(v.length > 5);
  }
  if (!src || !fs.existsSync(src)) return;
  const zlib = require('zlib');
  const table = JSON.parse(zlib.gunzipSync(fs.readFileSync(path.resolve(src))).toString('utf8'));
  for (const [k, v] of Object.entries(f.PRINT_ERRORS)) assert.ok(table.device_error[k] && v in table.device_error[k], k);
  for (const [k, v] of Object.entries(f.HMS)) assert.ok(table.device_hms[k] && v in table.device_hms[k], k);
});
