'use strict';
/**
 * Reading an OctoPrint server's answer.
 *
 * Two endpoints, and which one is authoritative changes with the state of the
 * machine — which is the whole reason this is a module rather than four lines.
 *
 * `/api/printer` is guarded by `abort(409, "Printer is not operational")`, in
 * the 1.11 line and the 2.0 line alike (server/api/printer.py). That is not a
 * fault: it is OctoPrint running with the printer switched off or not
 * connected, which is most of any working day. `/api/job` has no such guard and
 * answers fine in exactly that state, and its `state` reads "Offline" straight
 * from the connection's own string.
 *
 * So the caller asks for the job unconditionally and the printer tolerantly,
 * and hands both here — `printer` as null when it answered 409. Any other
 * status is a fault and never reaches this.
 *
 * Lifted out of main.js so it can be driven with per-endpoint payloads. Its
 * only previous guard was a scan of main.js's source, which is the weakest kind
 * of test there is, and the 2026-08-27 audit found its defects in exactly this
 * shape of code.
 */
(function (global) {

  function status() {
    if (typeof require === 'function') {
      try { return require('./printer-status.js'); } catch (e) { /* renderer / JSC */ }
    }
    return global.KhaytPrinterStatus || null;
  }

  /**
   * @param {object|null} printer  `/api/printer`, or null when it answered 409
   * @param {object} job           `/api/job`
   */
  function readStatus(printer, job) {
    const S = status();
    const num = (v) => (S ? S.reading(v)
                          : (v === null || v === undefined || v === '' || !Number.isFinite(Number(v))
                             ? null : Number(v)));
    const j = job || {};
    return {
      // The connection's own word first; the job's `state` is the fallback that
      // says "Offline" when there is no printer attached to answer.
      state: (printer && printer.state && printer.state.text) || j.state || 'Unknown',
      progress: S ? S.normalizeProgress(j.progress && j.progress.completion) : 0,
      filename: (j.job && j.job.file && j.job.file.name) || '',
      // `S.reading`, not `|| null`: OctoPrint reports `printTimeLeft: 0` at
      // the instant a print finishes, and a nozzle or bed can genuinely be
      // at 0. See the note on `reading` in `printer-status.js`.
      timeRemaining: num(j.progress && j.progress.printTimeLeft),
      tempNozzle: num(printer && printer.temperature && printer.temperature.tool0
                      && printer.temperature.tool0.actual),
      tempBed: num(printer && printer.temperature && printer.temperature.bed
                   && printer.temperature.bed.actual),
      type: 'octoprint',
    };
  }

  const api = { readStatus };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOctoprint = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
