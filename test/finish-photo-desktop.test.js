'use strict';
/**
 * The printer's own photo when a print finishes, on Windows/Linux — the Mac's
 * FinishCamera, over the shared rule in lib/print-finish-photo.js.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function harness(printLog) {
  const shots = []; const saved = []; let saves = 0;
  const ctx = {
    console, printLog, machines: [{ id: 'M1', name: 'X1C' }], saveAll: () => { saves++; }, toast() {},
    t: (k) => k, globalThis: null,
    window: { hubAPI: {
      webcamSnapshot: async ({ machineId }) => { shots.push(machineId); return { ok: true, dataUrl: 'data:image/jpeg;base64,AAAA' }; },
      saveOrderPhoto: async (id, idx, d) => { saved.push(id); return `${id}-finish.jpg`; },
    } },
    Image: class { set src(v) { setImmediate(() => this.onerror && this.onerror()); } },
    document: {}, setImmediate,
  };
  ctx.globalThis = ctx;
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', 'print-finish-photo.js'), 'utf8'), ctx);
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'integrations.js'), 'utf8');
  const a = src.indexOf('let _finishMemo = {};'); const b = src.indexOf('function dispatchPrinterAlerts(');
  vm.runInContext(src.slice(a, b) + '; this.captureFinishPhotos = captureFinishPhotos;', ctx);
  return { ctx, shots, saved, saves: () => saves };
}

test('a print that finishes puts the printer\'s photo on the job it belongs to', async () => {
  const log = [{ id: 'J1', machineId: 'M1', status: 'printing', parts: [] }];
  const { ctx, shots } = harness(log);
  await ctx.captureFinishPhotos({ M1: { state: 'printing', progress: 50, filename: 'a.gcode' } });
  assert.equal(shots.length, 0, 'not while printing');
  await ctx.captureFinishPhotos({ M1: { state: 'complete', progress: 100, filename: 'a.gcode' } });
  assert.deepEqual(shots, ['M1']);
  assert.equal(JSON.stringify(log[0].printPhotos.map((p) => p.filename)), JSON.stringify(['J1-finish.jpg']));
  assert.ok(log[0].printPhotos[0].thumb);
  await ctx.captureFinishPhotos({ M1: { state: 'complete', progress: 100, filename: 'a.gcode' } });
  assert.equal(shots.length, 1, 'once per print');
});

test('a cancelled print is not photographed, and neither is a print with two possible jobs', async () => {
  const one = harness([{ id: 'J1', machineId: 'M1', status: 'printing' }]);
  await one.ctx.captureFinishPhotos({ M1: { state: 'printing', progress: 40 } });
  await one.ctx.captureFinishPhotos({ M1: { state: 'cancelled', progress: 40 } });
  assert.equal(one.shots.length, 0);
  const two = harness([{ id: 'J1', machineId: 'M1', status: 'printing' }, { id: 'J2', machineId: 'M1', status: 'printing' }]);
  await two.ctx.captureFinishPhotos({ M1: { state: 'printing', progress: 40 } });
  await two.ctx.captureFinishPhotos({ M1: { state: 'complete', progress: 100 } });
  assert.equal(two.shots.length, 0, 'no guess between two jobs');
});
