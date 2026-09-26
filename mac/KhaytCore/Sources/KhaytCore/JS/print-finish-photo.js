'use strict';
/**
 * The printer's own photo, taken the moment a print finishes.
 *
 * A shop's portfolio and its product listings both want the same thing — a
 * photograph of what actually came off the bed — and the printer is pointing a
 * camera at it at exactly the right moment. This module decides the three
 * things that are rules rather than plumbing:
 *
 *   1. WHEN: the edge out of a job, once per print, and only for a print that
 *      FINISHED. A cancelled or failed print is a picture of a failure, and
 *      putting it on the job's record (and from there on a storefront) would
 *      be a lie told with the shop's own camera.
 *   2. WHICH JOB the picture belongs to, from what the book knows about the
 *      machine and the file it was printing.
 *   3. (In `lib/product-images.js`) how it becomes a product picture of kind
 *      `print`.
 *
 * Pure: no fetch, no fs. The caller owns the camera and the book.
 */
(function (global) {

  // The same vocabulary `printer-poll-cache` uses for "mid-job", so a finish
  // this module sees is a finish the completion cache saw too. Paused is still
  // mid-job: leaving `printing` for `paused` is not an end.
  const IN_JOB = /^(printing|busy|running|working|paus)/i;
  // What a printer says after a job somebody stopped. Moonraker:
  // `cancelled`. PrusaLink: `STOPPED`. OctoPrint: `Cancelling`.
  const CANCELLED = /(cancel|abort|stop)/i;
  // …and after a job that went wrong. Moonraker and PrusaLink: `error`.
  // Bambu: `FAILED`. OctoPrint: `Error`, `Offline after error`.
  const FAILED = /(error|fail)/i;
  // What a printer says after a job it did complete. Moonraker: `complete`.
  // PrusaLink: `FINISHED`. Bambu: `FINISH`.
  const DONE = /^(complete|finish|done|success)/i;
  // A firmware that goes straight back to idle (OctoPrint's `Operational`,
  // Moonraker when something clears the job) says nothing about HOW the job
  // ended. The last progress it reported does: a print that reached the end
  // finished, one abandoned at 40% did not.
  const DONE_PROGRESS = 99;

  const inJob = (s) => IN_JOB.test(String(s || ''));
  const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);

  /**
   * How a job ended, given the state before and the reading after.
   *
   * 'finished' | 'failed' | 'cancelled' when there IS an edge out of a job,
   * and null when there is none. Only 'finished' earns a photo. An idle
   * printer that did not say how it ended, at a progress short of the end, is
   * 'cancelled': that is the shape a cancel takes on firmwares that do not
   * name one (OctoPrint goes straight back to `Operational`).
   */
  function outcome(prev, next) {
    const p = prev || {};
    const n = next || {};
    if (!inJob(p.state) || inJob(n.state)) return null;
    const state = String(n.state || '');
    if (FAILED.test(state)) return 'failed';
    if (CANCELLED.test(state)) return 'cancelled';
    if (DONE.test(state)) return 'finished';
    const reached = Math.max(num(p.progress), num(n.progress));
    return reached >= DONE_PROGRESS ? 'finished' : 'cancelled';
  }

  /**
   * Fold one answered poll into the memory, and say whether to take the photo.
   *
   * `memo` is `{ [machineId]: { state, progress, filename } }`, handed back
   * each time and never read by anyone else. A poll that FAILED is simply not
   * passed in, so a Wi-Fi blip between `printing` and `complete` leaves the
   * last good state standing and the finish is still seen — once.
   *
   * ONCE PER PRINT falls out of the shape: the memo moves on to the new state
   * in the same breath as the decision, so a printer that sits on `complete`
   * for an hour is asked about every ten seconds and answers "no edge" every
   * time. The next print sets `printing` again, and its own finish is a new
   * edge.
   *
   * `durationS` is how long the job ran by the printer's own counter
   * (`actuals.durationS`), from the finished reading or — for a printer that
   * clears it the instant the job ends — the last reading during it. Null
   * when the printer never said.
   *
   * @returns {{ memo: object, capture: boolean, outcome: string|null,
   *             filename: string, durationS: number|null }}
   */
  function track(memo, machineId, status) {
    const all = memo && typeof memo === 'object' ? memo : {};
    const id = String(machineId || '');
    const prev = all[id] || {};
    const s = status || {};
    const result = outcome(prev, s);
    // The file that was printing: what the printer says now, or — for a
    // firmware that forgets it the instant the job ends — what it said last.
    const filename = String(s.filename || prev.filename || '');
    const ran = (a) => (a && Number(a.durationS) > 0 ? Number(a.durationS) : null);
    const durationS = ran(s.actuals) || (Number(prev.durationS) > 0 ? Number(prev.durationS) : null);
    const nextMemo = Object.assign({}, all, {
      [id]: {
        state: String(s.state || ''),
        progress: num(s.progress),
        filename: inJob(s.state) ? String(s.filename || prev.filename || '') : String(s.filename || ''),
        durationS: inJob(s.state) ? (ran(s.actuals) || prev.durationS || null) : null,
      },
    });
    return {
      memo: nextMemo, capture: result === 'finished', outcome: result, filename,
      durationS: result ? durationS : null,
    };
  }

  /** The last path component, lower-cased: how a printer and a job agree on a file. */
  function fileKey(name) {
    const s = String(name || '').trim().toLowerCase();
    const leaf = s.split(/[\\/]/).pop() || '';
    return leaf;
  }

  function partsOf(job) {
    return Array.isArray(job && job.parts) ? job.parts : [];
  }

  function namesFile(job, key) {
    if (!key) return false;
    return partsOf(job).some((part) => part && fileKey(part.fileRef) === key);
  }

  /**
   * The job a finished print belongs to, or null.
   *
   * In order of how sure it is:
   *   1. a job on this machine, still `printing`, with a part whose `fileRef`
   *      is the file that just finished — the only link a printer and the book
   *      share, and the one `renderer/order-flows.js` matches on too;
   *   2. the ONLY job on this machine still marked `printing`;
   *   3. a job on this machine the shop already moved on (`post`, `qc`,
   *      `completed`) that names the file — somebody quick with the board.
   *
   * Two printing jobs on one machine and no file to tell them apart is null,
   * not a guess: a photo on the wrong job is worse than no photo, and the shop
   * can still add one by hand.
   */
  function jobFor(printLog, machineId, filename) {
    const jobs = Array.isArray(printLog) ? printLog.filter((j) => j && typeof j === 'object') : [];
    const id = String(machineId || '');
    if (!id) return null;
    const mine = jobs.filter((j) => String(j.machineId || '') === id);
    const key = fileKey(filename);
    const printing = mine.filter((j) => j.status === 'printing');

    const byFile = printing.find((j) => namesFile(j, key));
    if (byFile) return byFile.id || null;
    if (printing.length === 1) return printing[0].id || null;
    const movedOn = mine.find((j) => ['post', 'qc', 'completed'].includes(j.status) && namesFile(j, key));
    return movedOn ? (movedOn.id || null) : null;
  }

  const api = { outcome, track, jobFor, fileKey, DONE_PROGRESS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrintFinishPhoto = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
