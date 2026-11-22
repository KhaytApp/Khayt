'use strict';
/**
 * lib/main/timelapse-keep.js (Figma 134:359, U1-3): a finished U1 print's
 * time-lapse is found and named on its job, and copied into the job's files
 * only on "Keep as proof", reading at most the cap whatever the printer said.
 * A fake printer and book; no network, no timers.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { createTimelapseKeep } = require('../lib/main/timelapse-keep.js');

const START = 1795400000; // seconds
const VIDEO = (stem, startS) => {
  const d = new Date(startS * 1000);
  const p = (n) => String(n).padStart(2, '0');
  return `${stem}_${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}.mp4`;
};
const FILE = 'bracket-kit-plate-2.gcode';
const video = VIDEO('bracket-kit-plate-2', START);

function rig(opts = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-tl-'));
  const book = {
    settings: {},
    machines: [{ id: 'U1', name: 'Workshop U1', printerApi: { type: 'moonraker', host: '192.0.2.40' } }],
    printLog: [Object.assign({ id: 'J1', machineId: 'U1', status: 'printing', parts: [{ fileRef: FILE }] }, opts.job || {})],
  };
  const told = [];
  const prog = [];
  const bytes = opts.bytes || 3 * 1024 * 1024;
  const k = createTimelapseKeep({
    read: async (_m, p) => {
      if (opts.offline) throw new Error('ECONNREFUSED');
      if (p.startsWith('/server/history')) return { result: { jobs: [{ job_id: '0000A7', filename: FILE, status: 'completed', start_time: START, end_time: START + 3600 }] } };
      if (p.startsWith('/server/files/list')) return { result: [{ path: video, modified: START + 3630, size: opts.claimed != null ? opts.claimed : bytes }] };
      throw new Error('unexpected ' + p);
    },
    stream: async (_m, _p, signal) => {
      if (opts.offline) throw new Error('ECONNREFUSED');
      const chunk = Buffer.alloc(256 * 1024, 7);
      const n = Math.ceil(bytes / chunk.length);
      return { ok: true, body: (async function* () {
        for (let i = 0; i < n; i++) {
          if (signal.aborted) throw new Error('aborted');
          if (opts.onChunk) opts.onChunk(i);
          yield chunk;
        }
      })() };
    },
    readBook: () => book,
    updateStoreOnDisk: async (mutate) => { const next = mutate(book); if (next !== book) Object.assign(book, next); return next; },
    filesDir: () => dir,
    fs,
    notify: (id, record) => told.push({ id, record }),
    progress: (id, got, total) => prog.push({ id, got, total }),
    sleep: async () => {},
    tries: [0],
  });
  return { k, book, dir, told, prog };
}
const printing = { state: 'printing', progress: 0.99, filename: FILE };
const complete = { state: 'complete', progress: 1, filename: FILE };

test('a finished print\'s video is found and named on its job, once', async () => {
  const r = rig();
  assert.equal(await r.k.noteEdge(r.book.machines[0], printing, complete), true);
  const rec = r.book.printLog[0].printerTimelapse;
  assert.equal(rec.video, video);
  assert.equal(rec.machineId, 'U1');
  assert.equal(r.told.length, 1);
  assert.equal(await r.k.noteEdge(r.book.machines[0], printing, complete), false, 'a job that has one is not asked again');
});

test('Keep as proof copies the video into the job\'s files and hands back the row', async () => {
  const r = rig();
  await r.k.noteEdge(r.book.machines[0], printing, complete);
  const out = await r.k.keep('J1');
  assert.equal(out.ok, true);
  assert.equal(out.row.kind, 'timelapse');
  assert.equal(out.row.from.video, video);
  assert.equal(out.row.size, Math.ceil((3 * 1024 * 1024) / (256 * 1024)) * 256 * 1024);
  assert.ok(fs.existsSync(path.join(r.dir, out.row.filename)));
  assert.ok(r.prog.length >= 1, 'progress was told');
  assert.equal(r.book.printLog[0].attachedFiles, undefined, 'main writes no attachment row: the window does');
});

test('the cap is on what is READ: a printer that under-states its size is cut off, and nothing is left behind', async () => {
  const r = rig({ bytes: 8 * 1024 * 1024, claimed: 1024 });
  await r.k.noteEdge(r.book.machines[0], printing, complete);
  const out = await r.k.keep('J1', { maxBytes: 2 * 1024 * 1024 });
  assert.equal(out.ok, false);
  assert.equal(out.reason, 'over-budget');
  assert.deepEqual(fs.readdirSync(r.dir), [], 'no partial file');
});

test('a video the printer says is too big is never fetched', async () => {
  const r = rig({ claimed: 310 * 1024 * 1024 });
  await r.k.noteEdge(r.book.machines[0], printing, complete);
  const out = await r.k.keep('J1');
  assert.deepEqual([out.ok, out.reason, out.maxBytes], [false, 'over-budget', 150 * 1024 * 1024]);
});

test('offline: unreachable, nothing copied; a cancel stops the copy', async () => {
  const off = rig();
  await off.k.noteEdge(off.book.machines[0], printing, complete);
  const book = off.book;
  const offline = createTimelapseKeep({
    read: async () => { throw new Error('x'); }, stream: async () => { throw new Error('ECONNREFUSED'); },
    readBook: () => book, updateStoreOnDisk: async (m) => m(book), filesDir: () => off.dir, fs,
  });
  assert.deepEqual(await offline.keep('J1'), { ok: false, reason: 'unreachable' });

  let k;
  const c = rig({ bytes: 4 * 1024 * 1024, onChunk: (i) => { if (i === 2) k.cancel('J1'); } });
  k = c.k;
  await c.k.noteEdge(c.book.machines[0], printing, complete);
  const out = await c.k.keep('J1');
  assert.deepEqual([out.ok, out.reason], [false, 'cancelled']);
  assert.deepEqual(fs.readdirSync(c.dir), []);
  assert.equal(c.k.isCopying('J1'), false);
});

test('a job with no time-lapse, or one already kept, copies nothing', async () => {
  const r = rig();
  assert.deepEqual(await r.k.keep('J1'), { ok: false, reason: 'none' });
  await r.k.noteEdge(r.book.machines[0], printing, complete);
  r.book.printLog[0].attachedFiles = [{ kind: 'timelapse', filename: 'x.mp4', from: { machineId: 'U1', video } }];
  assert.equal((await r.k.keep('J1')).reason, 'already');
});

test('wired: the poll notes the edge, the copy is gated and streamed through the pinned printer address', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /const q = timelapseKeep\.noteEdge\(machine, before, after\);/);
  assert.match(main, /ipcMain\.handle\('hub:timelapse-keep', async \(_e, \{ jobId \} = \{\}\) => \{\s*const gate = printerGate\('control'\);/);
  const stream = main.slice(main.indexOf('async function moonrakerStream('), main.indexOf('const timelapseKeep ='));
  assert.match(stream, /resolvePrinterTarget\(host\)/);
  assert.match(stream, /machineSecrets\.unsaved\(machine\)/);
});
