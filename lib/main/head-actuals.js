'use strict';
/**
 * Filament used per head, for a print a Snapmaker U1 (Moonraker) just
 * finished on a job the book names: the Windows/Linux side of the Mac's
 * HeadActuals.swift (#2624 U1 idea 4, and the colour stamp of a368a4462).
 *
 * The printer's history holds the slicer's grams per head and the measured
 * total. The shared rule (`lib/printer-actuals.js perHeadActuals`) splits the
 * measured total across the heads in proportion to their estimates and says
 * so (`basis: proportional`); `perHeadPatch` adds each head's colour and
 * material as they were at this print (`headColour`: the spool's RFID tag,
 * read with `lib/rfid-tray.js trays` from the U1's `filament_detect`, else
 * the machine's `loaded` list, else nothing). Main only reads the printer
 * (two GETs) and writes what the rule returns.
 *
 * ONE RECORD PER PRINT: the printer's own job id is the key
 * (`actualHeadsJobId`). A job that already holds a split is left alone,
 * whoever wrote it (this desktop, the Mac, a second look), and that is asked
 * again on the record as it is inside the write.
 *
 * Writes only `actualHeads`, `actualHeadsJobId` and `actualHeadsBasis`, and
 * only when the person signed in may edit orders. Best-effort and silent: a
 * printer whose history says nothing per head simply has none.
 *
 * Every effect is a parameter, so the test drives it with a fake printer and
 * a fake book.
 */
const PrinterActuals = require('../printer-actuals.js');
const RfidTray = require('../rfid-tray.js');
const FinishPhoto = require('../print-finish-photo.js');
const Rbac = require('../rbac.js');
const { activeRole } = require('./printer-permission.js');

/** When to look after a print finishes: history is written as it ends. */
const TRIES_MS = Object.freeze([20 * 1000, 90 * 1000]);
const HISTORY_LIMIT = 5;
/** How far the history row's end may be from when Khayt saw the print end.
 *  An older run of the same file is not this print. */
const WINDOW_MS = 20 * 60 * 1000;
/** The only keys a split writes. */
const KEYS = Object.freeze(['actualHeads', 'actualHeadsJobId', 'actualHeadsBasis']);

const HISTORY_PATH = `/server/history/list?limit=${HISTORY_LIMIT}`;
const DETECT_PATH = '/printer/objects/query?filament_detect';

/** May the person signed in edit orders? The P5 reading of the role
 *  (printer-permission activeRole): lock off, everyone; lock on and nobody
 *  main can name, nobody. */
function ordersEditAllowed(store) {
  const { lock, role } = activeRole(store);
  if (lock && !role) return false;
  return Rbac.can(role, 'orders', 'edit', { lockEnabled: lock });
}

/** The history row for the print that just ended under `filename`: the newest
 *  completed run of that file whose end is within WINDOW_MS of `endedAtMs`. */
function historyJob(answer, filename, endedAtMs) {
  const jobs = answer && answer.result && Array.isArray(answer.result.jobs) ? answer.result.jobs : [];
  return jobs.find((row) => row && typeof row === 'object'
    && row.filename === filename && row.status === 'completed'
    && typeof row.end_time === 'number' && Number.isFinite(row.end_time)
    && Math.abs(row.end_time * 1000 - endedAtMs) <= WINDOW_MS) || null;
}

/** `filament_detect` out of a `/printer/objects/query` answer, or null. */
function filamentDetect(answer) {
  const d = answer && answer.result && answer.result.status && answer.result.status.filament_detect;
  return d && typeof d === 'object' && !Array.isArray(d) ? d : null;
}

const recordId = (o) => (o && o.id != null ? String(o.id) : '');

/**
 * @param {object} deps
 * @param {(machine: object, path: string) => Promise<object>} deps.read  a GET on the printer, JSON back (throws on failure)
 * @param {() => object} deps.readBook   the book as main holds it
 * @param {(mutate: Function) => Promise<object>} deps.updateStoreOnDisk
 * @param {(jobId: string, fields: object) => void} deps.notify  tell the window
 * @param {(ms: number) => Promise<void>} [deps.sleep]
 * @param {number[]} [deps.tries]
 */
function createHeadActuals(deps) {
  const read = deps.read;
  const readBook = deps.readBook;
  const updateStoreOnDisk = deps.updateStoreOnDisk;
  const notify = typeof deps.notify === 'function' ? deps.notify : () => {};
  const sleep = deps.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
  const tries = Array.isArray(deps.tries) ? deps.tries : TRIES_MS;
  const running = new Set();   // job ids a look is already under way for

  /** Put the rule's split on the job. False when nothing was written. */
  async function write({ historyRow, jobId, detect, machineId }) {
    const book = readBook();
    if (!book || !book.settings || !ordersEditAllowed(book)) return false;
    const order = (Array.isArray(book.printLog) ? book.printLog : []).find((o) => recordId(o) === jobId);
    if (!order) return false;
    const split = PrinterActuals.perHeadActuals(historyRow, {});
    if (!split) return false;
    const machine = (Array.isArray(book.machines) ? book.machines : []).find((m) => recordId(m) === String(machineId || ''));
    const at = {
      trays: detect ? RfidTray.trays(detect) : [],
      loaded: machine && Array.isArray(machine.loaded) ? machine.loaded : [],
    };
    const patch = PrinterActuals.perHeadPatch(order, split, at);
    if (!patch) return false;
    const fields = {};
    for (const k of KEYS) fields[k] = patch[k];
    let wrote = false;
    await updateStoreOnDisk((cur) => {
      const log = Array.isArray(cur.printLog) ? cur.printLog : [];
      const i = log.findIndex((o) => recordId(o) === jobId);
      // Asked again on the record as it is: the Mac or a second look may
      // have written this print's split since the rule was asked.
      if (i === -1 || log[i].actualHeadsJobId != null) return cur;
      const next = log.slice();
      next[i] = { ...log[i], ...fields };
      wrote = true;
      return { ...cur, printLog: next };
    });
    if (wrote) notify(jobId, fields);
    return wrote;
  }

  /** After a finished Moonraker print on job `jobId`: look, at most twice. */
  async function lookAfter({ machine, jobId, filename, endedAt }) {
    const type = machine && machine.printerApi && machine.printerApi.type;
    if (type !== 'moonraker' || !jobId || !filename || running.has(jobId)) return false;
    running.add(jobId);
    try {
      for (const wait of tries) {
        await sleep(wait);
        const book = readBook();
        if (!book || !book.settings || !ordersEditAllowed(book)) return false;
        const order = (Array.isArray(book.printLog) ? book.printLog : []).find((o) => recordId(o) === jobId);
        if (!order || order.actualHeadsJobId != null) return false;
        let row = null;
        try { row = historyJob(await read(machine, HISTORY_PATH), filename, endedAt); } catch (_) { row = null; }
        if (!row) continue;
        // What is in each head, for the colour stamp: one more read-only GET.
        // A printer that does not answer it leaves the machine's `loaded` list.
        let detect = null;
        try { detect = filamentDetect(await read(machine, DETECT_PATH)); } catch (_) { detect = null; }
        return await write({ historyRow: row, jobId, detect, machineId: machine.id });
      }
      return false;
    } catch (_) {
      return false;   // best-effort and silent
    } finally {
      running.delete(jobId);
    }
  }

  /**
   * One answered poll of one printer: `before` and `after` are its cache
   * entries. On the edge out of a FINISHED job (print-finish-photo `outcome`,
   * the Mac's FinishCamera edge) on a job the book names (`jobFor`), start
   * the look. Not awaited by the poll.
   */
  function noteEdge(machine, before, after, now) {
    const type = machine && machine.printerApi && machine.printerApi.type;
    if (type !== 'moonraker' || !machine.id) return null;
    if (FinishPhoto.outcome(before, after) !== 'finished') return null;
    const filename = String((after && after.filename) || (before && before.filename) || '');
    if (!filename) return null;
    const book = readBook();
    const jobId = FinishPhoto.jobFor(book && book.printLog, machine.id, filename);
    if (!jobId) return null;
    return lookAfter({ machine, jobId: String(jobId), filename, endedAt: Number.isFinite(now) ? now : Date.now() });
  }

  return { noteEdge, lookAfter, write };
}

module.exports = {
  createHeadActuals, ordersEditAllowed, historyJob, filamentDetect,
  TRIES_MS, HISTORY_LIMIT, WINDOW_MS, KEYS,
};
