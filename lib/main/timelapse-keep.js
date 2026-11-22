'use strict';
/**
 * A Snapmaker U1's time-lapse, found and kept as the customer's proof
 * (Figma 134:359, U1-3; the Mac's Timelapse.swift).
 *
 * FOUND: after a FINISHED Moonraker print on a job the book names
 * (lib/printer-actuals.js actualsJob), look a few times (the video is written
 * after the job ends: 35 s on the bench) for the job's video in the printer's
 * camera folder: its history for the run, then `files/list?root=camera`,
 * matched by name and time (lib/webcam.js matchTimelapse). The job records
 * only names (`printerTimelapse`, lib/webcam.js timelapseRecord), never a URL,
 * and only if it has none yet. The printer's own record: no person's gate,
 * as the per-head figures (#2662).
 *
 * KEPT ONLY ON "KEEP AS PROOF" (Turki, Nov 19): `keep(jobId)` asks
 * lib/timelapse-attach.js for the plan and copies the video into the job's
 * files, reading at most `maxBytes` whatever the printer claimed (#2611
 * review): a copy that runs over is dropped. Progress is told as it goes and
 * the copy can be cancelled. Nothing is written to the book here: the window
 * adds the attachment row it is handed, as it does for an attached file.
 */
const path = require('path');
const Webcam = require('../webcam.js');
const Attach = require('../timelapse-attach.js');
const PrinterActuals = require('../printer-actuals.js');
const FinishPhoto = require('../print-finish-photo.js');

const TRIES_MS = Object.freeze([45 * 1000, 120 * 1000, 300 * 1000]);
const HISTORY_PATH = '/server/history/list?limit=5';
const CAMERA_PATH = '/server/files/list?root=camera';
const recordId = (o) => (o && o.id != null ? String(o.id) : '');

/**
 * @param {object} deps
 * @param {(machine, path) => Promise<object>} deps.read       a JSON GET on the printer (throws on failure)
 * @param {(machine, path, signal) => Promise<Response>} deps.stream  a GET whose body is read as it comes
 * @param {() => object} deps.readBook
 * @param {(mutate: Function) => Promise<object>} deps.updateStoreOnDisk
 * @param {() => string} deps.filesDir                    the order-files folder
 * @param {object} deps.fs
 * @param {(jobId, record) => void} [deps.notify]         a record was written
 * @param {(jobId, got, total) => void} [deps.progress]
 * @param {(ms) => Promise<void>} [deps.sleep]
 * @param {number[]} [deps.tries]
 * @param {() => boolean} [deps.stopped]
 */
function createTimelapseKeep(deps) {
  const notify = typeof deps.notify === 'function' ? deps.notify : () => {};
  const progress = typeof deps.progress === 'function' ? deps.progress : () => {};
  const sleep = deps.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
  const tries = Array.isArray(deps.tries) ? deps.tries : TRIES_MS;
  const stopped = typeof deps.stopped === 'function' ? deps.stopped : () => false;
  const looking = new Set();
  const copying = new Map();   // jobId → AbortController

  const machineOf = (book, id) => (Array.isArray(book && book.machines) ? book.machines : []).find((m) => recordId(m) === String(id || '')) || null;
  const jobOf = (book, id) => (Array.isArray(book && book.printLog) ? book.printLog : []).find((o) => recordId(o) === String(id || '')) || null;

  /** One look: the newest completed run of `filename`, and its video. */
  async function look(machine, filename) {
    const history = await deps.read(machine, HISTORY_PATH);
    const jobs = history && history.result && Array.isArray(history.result.jobs) ? history.result.jobs : [];
    const job = jobs.find((j) => j && j.filename === filename && j.status === 'completed');
    if (!job) return null;
    const files = await deps.read(machine, CAMERA_PATH);
    return Webcam.matchTimelapse(job, files);
  }

  async function write(jobId, machineId, match) {
    const record = Webcam.timelapseRecord(machineId, match, new Date().toISOString());
    if (!record) return false;
    let wrote = false;
    await deps.updateStoreOnDisk((cur) => {
      const log = Array.isArray(cur.printLog) ? cur.printLog : [];
      const i = log.findIndex((o) => recordId(o) === jobId);
      if (i === -1 || log[i].printerTimelapse) return cur;   // the Mac or a second look got there first
      const next = log.slice();
      next[i] = { ...log[i], printerTimelapse: record };
      wrote = true;
      return { ...cur, printLog: next };
    });
    if (wrote) notify(jobId, record);
    return wrote;
  }

  /** After a finished Moonraker print: look for its video, at most `tries.length` times. */
  async function lookAfter({ machine, jobId, filename }) {
    if (!jobId || looking.has(jobId)) return false;
    looking.add(jobId);
    try {
      for (const wait of tries) {
        await sleep(wait);
        if (stopped()) return false;
        const book = deps.readBook();
        const job = jobOf(book, jobId);
        if (!job || job.printerTimelapse) return false;
        const now = machineOf(book, machine && machine.id);
        if (!now || !now.printerApi || now.printerApi.type !== 'moonraker') return false;
        let found = null;
        try { found = await look(now, filename); } catch (_) { found = null; }
        if (found) return await write(jobId, now.id, found);
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      looking.delete(jobId);
    }
  }

  /** One answered poll of one printer: on the edge out of a finished job, start the look. */
  function noteEdge(machine, before, after) {
    const type = machine && machine.printerApi && machine.printerApi.type;
    if (type !== 'moonraker' || !machine.id) return null;
    if (FinishPhoto.outcome(before, after) !== 'finished') return null;
    const filename = String((after && after.filename) || (before && before.filename) || '');
    if (!filename) return null;
    const book = deps.readBook();
    const jobId = PrinterActuals.actualsJob(book && book.printLog, machine.id, filename);
    if (!jobId) return null;
    return lookAfter({ machine, jobId: String(jobId), filename });
  }

  /**
   * "Keep as proof": copy the job's video into its files.
   * → { ok: true, row }                    the window adds `row` to attachedFiles
   * → { ok: false, reason: 'over-budget' | 'size-unknown' | 'already' | 'none' | 'no-machine'
   *                       | 'unreachable' | 'cancelled' | 'busy', bytes?, maxBytes? }
   */
  async function keep(jobId, opts = {}) {
    const id = String(jobId || '');
    if (!id) return { ok: false, reason: 'none' };
    if (copying.has(id)) return { ok: false, reason: 'busy' };
    const book = deps.readBook();
    const order = jobOf(book, id);
    const rec = order && order.printerTimelapse;
    if (!rec) return { ok: false, reason: 'none' };
    const machine = machineOf(book, rec.machineId);
    if (!machine || !machine.printerApi || machine.printerApi.type !== 'moonraker') return { ok: false, reason: 'no-machine' };
    const plan = Attach.timelapseAttach(order, rec, { machineId: rec.machineId, stamp: Date.now().toString(36), maxBytes: opts.maxBytes });
    if (plan.action === 'already') return { ok: false, reason: 'already' };
    if (plan.action === 'link') return { ok: false, reason: plan.reason, bytes: plan.bytes, maxBytes: plan.maxBytes || Attach.MAX_BYTES };
    if (plan.action !== 'attach') return { ok: false, reason: 'none' };
    const cap = plan.maxBytes;
    const dest = path.join(deps.filesDir(), path.basename(plan.row.filename));
    const tmp = dest + '.part';
    const ctrl = new AbortController();
    copying.set(id, ctrl);
    let fd = null;
    try {
      let res;
      try { res = await deps.stream(machine, '/server/files/camera/' + encodeURIComponent(rec.video), ctrl.signal); }
      catch (e) { return { ok: false, reason: ctrl.signal.aborted ? 'cancelled' : 'unreachable' }; }
      if (!res || !res.ok || !res.body) return { ok: false, reason: 'unreachable' };
      const total = Number(rec.bytes) || null;
      fd = deps.fs.openSync(tmp, 'w');
      let got = 0;
      let lastTold = 0;
      for await (const chunk of res.body) {
        got += chunk.length;
        // The printer's claim is not a limit: what is READ is (#2611 review).
        if (got > cap) { ctrl.abort(); return { ok: false, reason: 'over-budget', bytes: got, maxBytes: cap }; }
        deps.fs.writeSync(fd, Buffer.from(chunk));
        if (got - lastTold > 512 * 1024) { lastTold = got; progress(id, got, total); }
      }
      deps.fs.closeSync(fd); fd = null;
      if (!got) return { ok: false, reason: 'unreachable' };
      deps.fs.renameSync(tmp, dest);
      progress(id, got, total);
      return { ok: true, row: { ...plan.row, size: got } };
    } catch (e) {
      return { ok: false, reason: ctrl.signal.aborted ? 'cancelled' : 'unreachable' };
    } finally {
      copying.delete(id);
      if (fd !== null) { try { deps.fs.closeSync(fd); } catch (_) { /* closed */ } }
      try { if (deps.fs.existsSync(tmp)) deps.fs.unlinkSync(tmp); } catch (_) { /* gone */ }
    }
  }

  function cancel(jobId) {
    const c = copying.get(String(jobId || ''));
    if (!c) return false;
    c.abort();
    return true;
  }

  return { noteEdge, lookAfter, look, write, keep, cancel, isCopying: (id) => copying.has(String(id || '')) };
}

module.exports = { createTimelapseKeep, TRIES_MS };
