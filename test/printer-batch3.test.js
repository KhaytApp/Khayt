'use strict';
/**
 * Batch 3 of ~/Khayt-proposals/prusa-ideas-plan.md, the shared rules:
 *   P4 lib/run-result.js           one result per print run (+ the poll
 *                                  cache keeps how a job ended)
 *   P6 lib/printer-success.js      success rate per printer
 *   C4 lib/waiting-at-machine.js   "waiting at the machine", from stored stamps
 * Through JSON vectors the Mac and iPhone run in JSC.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const ROOT = path.join(__dirname, '..');
for (const f of ['printer-activity', 'printer-poll-cache', 'run-result', 'printer-success', 'waiting-at-machine']) require('../lib/' + f + '.js');
const RR = globalThis.KhaytRunResult, PS = globalThis.KhaytPrinterSuccess, W = globalThis.KhaytWaitingAtMachine;
const PC = require('../lib/printer-poll-cache.js');
const vec = (n) => require('./fixtures/' + n + '-vectors.json');

const RUNS = () => [{ machineId: 'M1', at: '2026-11-18T08:00:00Z', started: true }, { machineId: 'M2', at: '2026-11-18T09:00:00Z', started: true }, { machineId: 'M1', at: '2026-11-18T12:00:00Z', started: true }];
for (const c of vec('run-result').cases) test('P4 ' + c.why, () => {
  let o = { id: 'J1', printRuns: RUNS() };
  for (const s of c.steps) {
    const r = RR.withResult(o, s.mark);
    assert.equal(!!r, s.changed, JSON.stringify(s.mark));
    if (r) o = Object.assign({}, o, { printRuns: r });
  }
  assert.deepEqual(o.printRuns, c.want);
});
/** A vector's `calendar`: the day of `at` on a fixed-offset clock (what the Mac's book calendar does with a TimeZone). */
const fixedOffsetDayOf = (minutes) => (at) => {
  const s = String(at == null ? '' : at);
  if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return s;
  const t = Date.parse(s);
  return Number.isFinite(t) ? new Date(t + minutes * 60000).toISOString().slice(0, 10) : '';
};
for (const c of vec('printer-success').cases) test('P6 ' + c.why, () => {
  const input = c.calendar ? Object.assign({}, c.input, { dayOf: fixedOffsetDayOf(c.calendar.utcOffsetMinutes) }) : c.input;
  assert.deepEqual(PS.successRates(input), c.want);
});

test('P6: localDayOf reads a UTC stamp on this computer\'s calendar, and leaves a bare day as written', () => {
  const was = process.env.TZ;
  try {
    process.env.TZ = 'America/New_York';
    assert.equal(PS.localDayOf('2026-12-01T01:00:00.000Z'), '2026-11-30', 'an evening print west of UTC');
    assert.equal(PS.localDayOf('2026-11-01'), '2026-11-01', 'a bare day is not read as UTC midnight');
    process.env.TZ = 'Asia/Riyadh';
    assert.equal(PS.localDayOf('2026-10-31T21:30:00.000Z'), '2026-11-01', 'an early-morning print east of UTC');
    assert.equal(PS.localDayOf('2026-11-30T21:00:00.000Z'), '2026-12-01', 'local midnight is the next day');
    for (const junk of [null, undefined, '', 'yesterday', '2026', '2026-13-45T00:00:00Z', 1764000000000]) assert.equal(PS.localDayOf(junk), '', String(junk));
    // The desktop's call, end to end: the west-of-UTC vector, on this computer's own calendar.
    const ny = vec('printer-success').cases.find((c) => c.calendar && c.calendar.utcOffsetMinutes === -300 && c.input.orders && c.input.orders[0].printRuns && c.input.orders[0].printRuns.length);
    process.env.TZ = 'America/New_York';
    assert.deepEqual(PS.successRates(Object.assign({}, ny.input, { dayOf: PS.localDayOf })), ny.want);
  } finally {
    if (was === undefined) delete process.env.TZ; else process.env.TZ = was;
  }
});
for (const c of vec('waiting-at-machine').cases) test('C4 ' + c.why, () => assert.deepEqual(W.waiting(c.machine, c.opts), c.want));

test('P4: the poll cache keeps how a job ended, from the word it ended on', () => {
  for (const [w, want] of [['complete', 'finished'], ['FINISH', 'finished'], ['cancelled', 'cancelled'], ['stopped', 'cancelled'], ['error', 'failed'], ['FAILED', 'failed'], ['idle', null], ['Operational', null], ['', null]]) {
    assert.equal(PC.endedAs(w), want, w);
  }
  // A Bambu cancel ends on FAILED; its print_error says it was a cancel (correctness review).
  const B = require('../lib/bambu-faults.js');
  for (const code of [0x0300400C, 0x0500400E]) {
    const fault = B.faultText({ print_error: code });
    assert.ok(fault, 'decoded');
    assert.equal(PC.endedAs('FAILED', fault), 'cancelled', fault);
  }
  assert.equal(PC.endedAs('FAILED', B.faultText({ print_error: 0x03008004 }) || ''), 'failed', 'a runout is a failure');
  assert.equal(PC.endedAs('FAILED', null), 'failed');
});

test('P4: withResult never changes the job it is given, and junk is null', () => {
  const o = { id: 'J', printRuns: RUNS() };
  const before = JSON.stringify(o);
  RR.withResult(o, { machineId: 'M1', at: '2026-11-18T14:00:00Z', result: 'finished', source: 'printer' });
  assert.equal(JSON.stringify(o), before);
  for (const x of [null, {}, { printRuns: 'x' }]) assert.equal(RR.withResult(x, { machineId: 'M1', at: 1, result: 'finished', source: 'shop' }), null);
  assert.equal(RR.resultOf({ result: 'great' }), null);
});

test('C4: every reason is from the closed set; a persisted completion is enough on its own', () => {
  for (const c of vec('waiting-at-machine').cases) for (const x of c.want) assert.ok(W.REASONS.includes(x.reason), x.reason);
  // The state a restart leaves: no live entry, only what restoreCompletions brings back.
  const cache = PC.restoreCompletions({ M1: [{ at: 1000, filename: 'a.gcode', actuals: { durationS: 60 }, result: 'finished' }] });
  assert.deepEqual(W.waiting({ id: 'M1' }, { completions: cache.M1.completions }), [{ reason: 'print-to-take-off', since: 1000 }]);
});

test('each rule loads without require, as JavaScriptCore loads it', () => {
  const ctx = {}; vm.createContext(ctx);
  for (const f of ['run-result', 'printer-success', 'waiting-at-machine']) vm.runInContext(fs.readFileSync(path.join(ROOT, 'lib', f + '.js'), 'utf8'), ctx);
  assert.equal(vm.runInContext("KhaytPrinterSuccess.successRates({orders:[{printRuns:[{machineId:'A',at:'2026-11-01',result:'finished'}]}]})[0].rate", ctx), 1);
  assert.equal(vm.runInContext("KhaytWaitingAtMachine.waiting({id:'M'}, {completions:[{at:5, result:'failed'}]})[0].reason", ctx), 'bed-to-clear');
});
