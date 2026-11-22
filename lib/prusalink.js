'use strict';
/**
 * Reading a PrusaLink printer's answer.
 *
 * Two endpoints, because one of them does not carry what a shop needs.
 *
 * `/api/v1/status` has NO file information. Not "usually" — the job object
 * Prusa's Buddy firmware renders is exactly `{id, progress, time_remaining,
 * filament_change_in, time_printing}` (lib/WUI/nhttp/status_renderer.cpp) and
 * the OpenAPI spec's `StatusJob` agrees. `job.file` does not exist on that
 * endpoint at any firmware version; it lives on `/api/v1/job`, so the filename
 * was always the empty string until both were asked for.
 *
 * That second request is allowed to fail — it answers `204 No Content` when
 * nothing is printing — and a missing name must not cost the temperatures and
 * the progress the first request did return. The caller passes null for it.
 *
 * Lifted out of main.js so it can be driven with per-endpoint payloads rather
 * than guarded by a scan of main.js's source.
 */
(function (global) {

  function status() {
    if (typeof require === 'function') {
      try { return require('./printer-status.js'); } catch (e) { /* renderer / JSC */ }
    }
    return global.KhaytPrinterStatus || null;
  }

  /**
   * @param {object} data     `/api/v1/status`
   * @param {object|null} jobData  `/api/v1/job`, or null when it answered 204
   */
  function readStatus(data, jobData) {
    const S = status();
    const d = data || {};
    const job = d.job || {};
    const file = (jobData && jobData.file) || {};
    const p = d.printer || {};
    const num = (v) => (S ? S.reading(v)
                          : (v === null || v === undefined || v === '' || !Number.isFinite(Number(v))
                             ? null : Number(v)));
    return {
      state: (d.printer && d.printer.state) || 'Unknown',
      progress: S ? S.normalizeProgress(job.progress) : 0,
      // display_name is the long filename; `name` is the 8.3 short form, which
      // Prusa's own spec illustrates as "SPICE~1.gco". A shop looking at its
      // queue needs the one it saved the file under.
      filename: file.display_name || file.name || '',
      timeRemaining: job.time_remaining || null,
      tempNozzle: (d.printer && d.printer.temp_nozzle) || null,
      tempBed: (d.printer && d.printer.temp_bed) || null,
      // From the OpenAPI spec's `StatusPrinter` (prusa3d/Prusa-Link-Web,
      // spec/openapi.yaml): `target_nozzle`, `target_bed`, `speed` and `flow`
      // (integer percent, example 100 and 95). Through `reading` so a target
      // of 0 — heater off — survives as 0 and an absent one stays null: the
      // spec says "all values except state are optional".
      //
      // NOT `fan_print`: the spec gives it as an integer with the example 420,
      // which is an RPM, not a share of full speed. Drawn beside a Klipper
      // fan's 0-100 it would read as 420%.
      targetNozzle: num(p.target_nozzle),
      targetBed: num(p.target_bed),
      speedFactor: num(p.speed),
      flowFactor: num(p.flow),
      // `status_printer: {ok, message}` — the printer's own word, shown only
      // when it is not ok. "OK" is not news.
      message: p.status_printer && p.status_printer.ok === false
        && typeof p.status_printer.message === 'string' && p.status_printer.message.trim()
        ? p.status_printer.message.trim() : null,
      type: 'prusalink',
    };
  }

  const api = { readStatus };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrusalink = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
