const { test } = require('node:test');
const assert = require('node:assert/strict');
const { mergeReport, parseBambuReport } = require('../lib/bambu-report.js');

/**
 * Holding a Bambu's state across deltas.
 *
 * OpenBambuAPI mqtt.md, pushing.pushall: "the P1 series only sends the values
 * that have been updated compared to the previous report". ha-bambulab keeps a
 * field the message does not mention at its last value (models.py print_update,
 * `data.get(key, self.key)`). These pin the same rule.
 */

const FULL = '{"print":{"gcode_state":"RUNNING","mc_percent":42,"subtask_name":"bracket.3mf","mc_remaining_time":87,"nozzle_temper":219.5,"bed_temper":60,"layer_num":134,"total_layer_num":318,"hms":[{"attr":50331904,"code":65543}],"ams":{"tray_now":"1","ams":[{"id":"0"}]},"command":"push_status"}}';

test('a delta lays over the held full report and keeps what it does not name', () => {
  const held = mergeReport(null, FULL);
  const next = mergeReport(held, '{"print":{"mc_percent":43,"layer_num":135,"command":"push_status"}}');
  const s = parseBambuReport(JSON.stringify(next));
  assert.equal(s.progress, 43);
  assert.equal(s.layer, 135);
  assert.equal(s.state, 'Printing');
  assert.equal(s.filename, 'bracket.3mf');
  assert.equal(s.tempNozzle, 219.5);
});

test('a delta alone is not a report, and merging it into nothing does not invent one', () => {
  const only = mergeReport(null, '{"print":{"nozzle_temper":200}}');
  assert.equal(parseBambuReport(JSON.stringify(only)), null);
});

test('nested objects merge by key; arrays are replaced, so cleared warnings clear', () => {
  const held = mergeReport(null, FULL);
  const next = mergeReport(held, '{"print":{"ams":{"tray_now":"2"},"hms":[]}}');
  assert.equal(next.print.ams.tray_now, '2');
  assert.deepEqual(next.print.ams.ams, [{ id: '0' }]);
  assert.deepEqual(next.print.hms, []);
});

test('the held state is never mutated', () => {
  const held = mergeReport(null, FULL);
  const before = JSON.stringify(held);
  mergeReport(held, '{"print":{"mc_percent":99,"ams":{"tray_now":"3"}}}');
  assert.equal(JSON.stringify(held), before);
});

test('messages with no print object leave the held state as it was', () => {
  const held = mergeReport(null, FULL);
  for (const m of ['{"info":{"command":"get_version"}}', '{"system":{"command":"ledctrl"}}',
                   '{"print":null}', '{"print":[]}', '{"print":"x"}', 'not json', '', '[]', 'null']) {
    assert.equal(mergeReport(held, m), held, m);
  }
  assert.equal(mergeReport(null, 'not json'), null);
});

test('a null in the delta overwrites; prototype keys are dropped', () => {
  const held = mergeReport(null, FULL);
  const next = mergeReport(held, '{"print":{"subtask_name":null,"__proto__":{"polluted":1},"constructor":{"x":1}}}');
  assert.equal(next.print.subtask_name, null);
  assert.equal({}.polluted, undefined);
  assert.equal(Object.getPrototypeOf(next.print), Object.prototype);
  assert.equal(Object.prototype.hasOwnProperty.call(next.print, 'constructor'), false);
});

test('an already-parsed object merges the same as its text', () => {
  const a = mergeReport(null, FULL);
  const b = mergeReport(null, JSON.parse(FULL));
  assert.deepEqual(a, b);
});
