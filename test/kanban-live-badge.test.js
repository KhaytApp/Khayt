'use strict';
/**
 * The board's live badge colour comes from lib/printer-activity.js (C2
 * follow-up): a paused, preparing or homing printer is busy, a failed one
 * needs a person, an unplugged one is not "idle"; a word no table knows reads
 * by the old substring rule. The real renderer function runs here.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const PA = require('../lib/printer-activity.js');

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'kanban.js'), 'utf8');
const at = src.indexOf('function _kStateClass(');
const fn = src.slice(at, src.indexOf('\n}\n', at) + 3);
const box = { KhaytPrinterActivity: PA, String };
vm.createContext(box);
vm.runInContext(fn + '\nthis.cls = _kStateClass;', box);

test('busy words are busy, paused included (was idle)', () => {
  for (const w of ['Paused', 'pausing', 'Preparing', 'Slicing', 'BUSY', 'homing', 'exposing', 'changingTool', 'Printing']) {
    assert.equal(box.cls({ state: w }), 'printing', w);
  }
});
test('needs a person, or not linked: error, never idle', () => {
  for (const w of ['Failed', 'ATTENTION', 'halted', 'Offline', 'Connecting']) assert.equal(box.cls({ state: w }), 'error', w);
});
test('free words stay idle', () => {
  for (const w of ['idle', 'Operational', 'READY', 'standby', 'complete', 'Finished']) assert.equal(box.cls({ state: w }), 'idle', w);
});
test('a word no table knows: the old substring rule', () => {
  assert.equal(box.cls({ state: 'Printing (custom)' }), 'printing');
  assert.equal(box.cls({ state: 'warming up error' }), 'error');
  assert.equal(box.cls({ state: 'Kneading' }), 'idle');
});
test('the board calls it', () => {
  assert.match(src, /const stateClass = _kStateClass\(s\);/);
});
