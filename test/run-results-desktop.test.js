'use strict';
/**
 * Gap 6 (desktop parity, Nov 22): when a print ends on a job the book names,
 * the window writes how it ended on that job's run, once (lib/run-result.js),
 * as the Mac's RunResults does (#2624). The renderer's own code is run here
 * against the real shared rules.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const ROOT = path.join(__dirname, '..');

function harness(job) {
  const ctx = { printLog: [job], saves: 0, console };
  ctx.globalThis = ctx;
  ctx.saveAll = () => { ctx.saves += 1; };
  vm.createContext(ctx);
  for (const f of ['printer-activity', 'printer-poll-cache', 'print-finish-photo', 'run-result']) {
    vm.runInContext(fs.readFileSync(path.join(ROOT, 'lib', f + '.js'), 'utf8'), ctx);
  }
  const src = fs.readFileSync(path.join(ROOT, 'renderer', 'integrations.js'), 'utf8');
  const from = src.indexOf('let _runEndMemo = {};');
  const to = src.indexOf('/* ── What each print drew from the wall');
  vm.runInContext(src.slice(from, to) + '; globalThis.recordRunResults = recordRunResults;', ctx);
  return ctx;
}
const job = () => ({ id: 'J1', machineId: 'M1', status: 'printing', parts: [{ fileRef: 'plate.gcode' }],
  printRuns: [{ machineId: 'M1', at: new Date(Date.now() - 3600e3).toISOString() }] });

test('a print that finishes: "finished" on its run, once', () => {
  const h = harness(job());
  h.recordRunResults({ M1: { state: 'printing', progress: 50, filename: 'plate.gcode' } });
  h.recordRunResults({ M1: { state: 'complete', progress: 100, filename: 'plate.gcode' } });
  assert.equal(h.printLog[0].printRuns[0].result, 'finished');
  assert.equal(h.printLog[0].printRuns[0].resultSource, 'printer');
  assert.equal(h.saves, 1);
  h.recordRunResults({ M1: { state: 'complete', progress: 100, filename: 'plate.gcode' } });
  assert.equal(h.saves, 1, 'a re-poll changes nothing');
});

test('a Bambu the shop cancelled ends on FAILED with a cancel code: "cancelled", not a failure', () => {
  const h = harness(job());
  h.recordRunResults({ M1: { state: 'RUNNING', progress: 40, filename: 'plate.gcode' } });
  h.recordRunResults({ M1: { state: 'FAILED', progress: 40, filename: 'plate.gcode', fault: 'The task was canceled. (0300_400C)' } });
  assert.equal(h.printLog[0].printRuns[0].result, 'cancelled');
});

test('the shop\'s own mark is never replaced; no job on the machine writes nothing', () => {
  const j = job(); j.printRuns[0].result = 'failed'; j.printRuns[0].resultSource = 'shop';
  const h = harness(j);
  h.recordRunResults({ M1: { state: 'printing', progress: 50, filename: 'plate.gcode' } });
  h.recordRunResults({ M1: { state: 'complete', progress: 100, filename: 'plate.gcode' } });
  assert.deepEqual([h.printLog[0].printRuns[0].result, h.printLog[0].printRuns[0].resultSource, h.printLog[0].printRuns[0].printerResult], ['failed', 'shop', 'finished']);
  const other = Object.assign(job(), { machineId: 'M2' });
  const k = harness(other);
  k.recordRunResults({ M1: { state: 'printing', progress: 50, filename: 'plate.gcode' } });
  k.recordRunResults({ M1: { state: 'complete', progress: 100, filename: 'plate.gcode' } });
  assert.equal(k.saves, 0);
});

test('wired: the window loads run-result.js and records at every printer-status update', () => {
  const html = fs.readFileSync(path.join(ROOT, 'renderer', 'index.html'), 'utf8');
  assert.ok(html.indexOf('<script src="../lib/run-result.js">') > html.indexOf('<script src="../lib/printer-poll-cache.js">'));
  assert.match(fs.readFileSync(path.join(ROOT, 'renderer', 'integrations.js'), 'utf8'), /try \{ recordRunResults\(currCache\); \}/);
});
