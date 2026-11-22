'use strict';
/**
 * Windows/Linux: filament used per head after a finished U1 (Moonraker) print,
 * with each head's colour and material (lib/main/head-actuals.js, the Mac's
 * HeadActuals.swift). A fake printer (its history and the real U1
 * filament_detect reading) and a fake book; no network, no timers.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const H = require('../lib/main/head-actuals.js');
const U1 = require('./fixtures/u1-filament-detect.json');

const ROOT = path.join(__dirname, '..');
const ENDED = Date.UTC(2026, 10, 22, 12, 0, 0);
const FILE = 'plate_1.gcode';
const U1M = { id: 'M1', printerApi: { type: 'moonraker', host: '192.168.1.50' } };

function row(over) {
  return Object.assign({
    job_id: '0000A7', filename: FILE, status: 'completed', end_time: ENDED / 1000 - 30,
    filament_used: 9000, metadata: { filament_weight: [10, 10, 10], filament_total: 10000 },
  }, over || {});
}

function rig(opts = {}) {
  const book = {
    settings: Object.assign({}, opts.settings || {}),
    operators: opts.operators || [],
    machines: [{ id: 'M1', printerApi: { type: 'moonraker', host: '192.168.1.50' }, loaded: [{ slot: 2, hex: '#ff8800', material: 'PETG' }] }],
    printLog: [Object.assign({ id: 'J1', machineId: 'M1', status: 'printing', parts: [{ fileRef: FILE }] }, opts.job || {})],
  };
  const reads = [];
  const writes = [];
  const told = [];
  const history = opts.history || { result: { jobs: [row()] } };
  const h = H.createHeadActuals({
    read: async (_m, p) => {
      reads.push(p);
      if (p.startsWith('/server/history/list')) return history;
      if (p.startsWith('/printer/objects/query?filament_detect')) return U1;
      throw new Error('unexpected ' + p);
    },
    readBook: () => book,
    updateStoreOnDisk: async (mutate) => {
      const next = mutate(book);
      writes.push(next);
      if (next !== book) Object.assign(book, next);
      return next;
    },
    notify: (id, fields) => told.push({ id, fields }),
    sleep: opts.sleep || (async () => {}),
    stopped: opts.stopped,
  });
  return { book, h, reads, writes, told };
}

const printing = { state: 'printing', progress: 0.97, filename: FILE };
const complete = { state: 'complete', progress: 1, filename: FILE };

test('a finished print writes once, colours from the tag and from loaded', async () => {
  const r = rig();
  assert.equal(await r.h.noteEdge(U1M, printing, complete, ENDED), true);
  const job = r.book.printLog[0];
  assert.equal(job.actualHeadsJobId, '0000A7');
  assert.equal(job.actualHeadsBasis, 'proportional');
  assert.equal(job.actualHeads.length, 3);
  assert.equal(job.actualHeads[0].colourFrom, 'rfid');
  assert.equal(job.actualHeads[0].hex, '#080A0D');
  assert.equal(job.actualHeads[1].colourFrom, 'rfid');
  assert.deepEqual(job.actualHeads[2], { head: 2, grams: 9, estimateG: 10, hex: '#FF8800', material: 'PETG', colourFrom: 'loaded' });
  // Only the three keys; the job's own fields untouched.
  assert.equal(job.status, 'printing');
  assert.deepEqual(Object.keys(r.told[0].fields).sort(), ['actualHeads', 'actualHeadsBasis', 'actualHeadsJobId']);
  assert.equal(r.told[0].id, 'J1');
  assert.deepEqual(r.reads, ['/server/history/list?limit=5', '/printer/objects/query?filament_detect']);

  // A second completion (a re-poll, a restart, the Mac) writes nothing.
  r.reads.length = 0;
  assert.equal(await r.h.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(r.writes.length, 1);
  assert.equal(r.told.length, 1);
  assert.deepEqual(r.reads, [], 'a job that holds a split does not even ask the printer');
});

test('the split written by someone else meanwhile is kept (re-checked inside the write)', async () => {
  const r = rig();
  const split = { actualHeads: [{ head: 0, grams: 1, estimateG: 1 }], actualHeadsJobId: 'MAC', actualHeadsBasis: 'proportional' };
  // The Mac writes between the rule's answer and the write.
  const book = r.book;
  const wrapped = H.createHeadActuals({
    read: async (_m, p) => (p.startsWith('/server') ? { result: { jobs: [row()] } } : U1),
    readBook: () => book,
    updateStoreOnDisk: async (mutate) => {
      Object.assign(book.printLog[0], split);
      const next = mutate(book);
      r.writes.push(next);
      return next;
    },
    notify: (id, fields) => r.told.push({ id, fields }),
    sleep: async () => {},
  });
  assert.equal(await wrapped.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(book.printLog[0].actualHeadsJobId, 'MAC');
  assert.equal(r.told.length, 0);
});

test(`recorded whoever is signed in: the printer's own record, not a person's edit (overnight, nobody signed in since #2608)`, async () => {
  // The print finishes with the lock on and nobody signed in: the figures are on the job afterwards.
  const n = rig({ settings: { operatorLockEnabled: true } });
  assert.equal(await n.h.noteEdge(U1M, printing, complete, ENDED), true);
  assert.ok(Array.isArray(n.book.printLog[0].actualHeads) && n.book.printLog[0].actualHeads.length > 0, 'the figures are on the job');
  assert.ok(n.book.printLog[0].actualHeadsJobId);
  // A viewer signed in: recorded too.
  const v = rig({ settings: { operatorLockEnabled: true, activeOperatorId: 'V' }, operators: [{ id: 'V', roleKey: 'viewer' }] });
  assert.equal(await v.h.noteEdge(U1M, printing, complete, ENDED), true);
  assert.ok(v.book.printLog[0].actualHeadsJobId);
});

test('nothing when the history row is older than 20 minutes', async () => {
  const r = rig({ history: { result: { jobs: [row({ end_time: ENDED / 1000 - 21 * 60 })] } } });
  assert.equal(await r.h.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(r.writes.length, 0);
  // Both tries asked, neither found it.
  assert.equal(r.reads.filter((p) => p.startsWith('/server/history')).length, 2);
});

test('nothing when the filename differs, or the row did not complete', async () => {
  const r = rig({ history: { result: { jobs: [row({ filename: 'other.gcode' }), row({ status: 'cancelled' })] } } });
  assert.equal(await r.h.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(r.writes.length, 0);
});

test('nothing when the history has no per-head figures', async () => {
  const r = rig({ history: { result: { jobs: [row({ metadata: { filament_total: 10000 } })] } } });
  assert.equal(await r.h.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(r.writes.length, 0);
});

test('only a FINISHED Moonraker print on a job the book names starts a look', async () => {
  const r = rig();
  assert.equal(r.h.noteEdge(U1M, printing, { state: 'cancelled', filename: FILE }, ENDED), null);
  assert.equal(r.h.noteEdge(U1M, printing, { state: 'error', filename: FILE }, ENDED), null);
  assert.equal(r.h.noteEdge(U1M, printing, printing, ENDED), null, 'no edge');
  assert.equal(r.h.noteEdge({ id: 'M1', printerApi: { type: 'octoprint' } }, printing, complete, ENDED), null);
  assert.equal(r.h.noteEdge({ id: 'M2', printerApi: { type: 'moonraker' } }, printing, complete, ENDED), null, 'no job on that machine');
  assert.deepEqual(r.reads, []);
});

test('a printer that does not answer filament_detect still writes, colours from loaded only', async () => {
  const book = rig().book;
  const told = [];
  const h = H.createHeadActuals({
    read: async (_m, p) => { if (p.startsWith('/server')) return { result: { jobs: [row()] } }; throw new Error('404'); },
    readBook: () => book,
    updateStoreOnDisk: async (mutate) => Object.assign(book, mutate(book)),
    notify: (id, fields) => told.push({ id, fields }),
    sleep: async () => {},
  });
  assert.equal(await h.noteEdge(U1M, printing, complete, ENDED), true);
  assert.equal(book.printLog[0].actualHeads[0].hex, undefined);
  assert.equal(book.printLog[0].actualHeads[2].colourFrom, 'loaded');
});

test('wired: main notes the edge in both polls, reads through the pinned path, and the window applies the push', () => {
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  assert.equal((main.match(/noteHeadActuals\(machine, before, printerStatusCache\[/g) || []).length, 2);
  const read = main.slice(main.indexOf('async function moonrakerRead('));
  assert.match(read.slice(0, 1500), /machineSecrets\.fill\(machine\)/);
  assert.match(read.slice(0, 1500), /resolvePrinterTarget\(host\)/);
  assert.match(read.slice(0, 1500), /redirect: 'manual'/);
  assert.match(main, /webContents\.send\('printer-head-actuals'/);
  const preload = fs.readFileSync(path.join(ROOT, 'preload.js'), 'utf8');
  assert.match(preload, /onPrinterHeadActuals:.*'printer-head-actuals'/);
  const boot = fs.readFileSync(path.join(ROOT, 'renderer/app-boot.js'), 'utf8');
  assert.ok(boot.includes('window.hubAPI.onPrinterHeadActuals((payload)'));
});


// ── The review (Nov 22) ───────────────────────────────────────────────────

test('an earlier run of the same file, already on another job, is never written onto this one; the closest run wins', async () => {
  // Job A printed part.gcode and holds A1; job B prints it again and finishes 10 min later.
  const r = rig({ history: { result: { jobs: [row({ job_id: 'A1', end_time: ENDED / 1000 - 600 })] } } });
  r.book.printLog.unshift({ id: 'A', machineId: 'M1', status: 'completed', parts: [{ fileRef: FILE }], actualHeadsJobId: 'A1' });
  assert.equal(await r.h.noteEdge(U1M, printing, complete, ENDED), false, 'B\'s own row is not there yet: nothing, rather than A\'s');
  assert.equal(r.book.printLog[1].actualHeadsJobId, undefined);
  // With both rows, B gets its own, the closest.
  const both = rig({ history: { result: { jobs: [row({ job_id: 'A1', end_time: ENDED / 1000 - 600 }), row({ job_id: 'B1', end_time: ENDED / 1000 - 5 })] } } });
  both.book.printLog.unshift({ id: 'A', machineId: 'M1', status: 'completed', parts: [{ fileRef: FILE }], actualHeadsJobId: 'A1' });
  assert.equal(await both.h.noteEdge(U1M, printing, complete, ENDED), true);
  assert.equal(both.book.printLog[1].actualHeadsJobId, 'B1');
  // The closest of two unrecorded runs.
  assert.equal(H.historyJob({ result: { jobs: [row({ job_id: 'far', end_time: ENDED / 1000 - 900 }), row({ job_id: 'near', end_time: ENDED / 1000 - 20 })] } }, FILE, ENDED).job_id, 'near');
});

test('only the printing job that names the file: never the only printing job running another file, never a moved-on job', async () => {
  // The shop's job X is mine.gcode; the printer ran a calibration print from its screen.
  const x = rig({ job: { parts: [{ fileRef: 'mine.gcode' }] } });
  assert.equal(await x.h.noteEdge(U1M, printing, complete, ENDED), null);
  assert.equal(x.reads.length, 0, 'the printer is not even asked');
  // An old completed job naming the file gets nothing from a reprint started at the printer.
  const old = rig({ job: { status: 'completed' } });
  assert.equal(await old.h.noteEdge(U1M, printing, complete, ENDED), null);
  // Moved to another machine between the edge and the write: nothing.
  const moved = rig();
  moved.book.printLog[0].machineId = 'M2';
  assert.equal(await moved.h.lookAfter({ machine: U1M, jobId: 'J1', filename: FILE, endedAt: ENDED }), false);
  assert.equal(moved.book.printLog[0].actualHeadsJobId, undefined);
});

test('a hostile printer cannot put an oversized or odd job id, or infinite grams, in the book', async () => {
  for (const job_id of ['x'.repeat(5000), { a: 1 }, 'has space', '']) {
    const r = rig({ history: { result: { jobs: [row({ job_id })] } } });
    assert.equal(await r.h.noteEdge(U1M, printing, complete, ENDED), false, JSON.stringify(job_id).slice(0, 30));
    assert.equal(r.book.printLog[0].actualHeadsJobId, undefined);
  }
  const inf = rig({ history: { result: { jobs: [row({ filament_used: 1e308, metadata: { filament_weight: [10, 10, 10], filament_total: 1e-300 } })] } } });
  assert.equal(await inf.h.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(inf.book.printLog[0].actualHeads, undefined);
});

test('a look ends when the app quits or polling stops, or the printer is gone or re-addressed', async () => {
  const q = rig({ stopped: () => true });
  assert.equal(await q.h.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(q.reads.length, 0);
  const gone = rig();
  gone.book.machines = [];
  assert.equal(await gone.h.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(gone.reads.length, 0);
  const moved = rig();
  moved.book.machines[0].printerApi.host = '192.168.1.99';
  assert.equal(await moved.h.noteEdge(U1M, printing, complete, ENDED), false);
  assert.equal(moved.reads.length, 0, 'never asks the old address');
});

test('main reads the printer with a size cap', () => {
  const src = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  assert.match(src, /const MOONRAKER_READ_MAX = 1024 \* 1024;/);
  assert.match(src, /if \(size > MOONRAKER_READ_MAX\) throw/);
  assert.match(src, /stopped: \(\) => _quittingNow \|\| _flushedForQuit \|\| !printerPollInterval/);
});
