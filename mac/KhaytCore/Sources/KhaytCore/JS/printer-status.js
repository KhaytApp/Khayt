/**
 * Normalisation shared by every printer adapter.
 *
 * Each firmware reports progress differently — OctoPrint gives 0-100, Moonraker
 * a 0-1 fraction, Duet a byte offset into the file, Repetier its own field — and
 * each adapter converted in its own way with no shared floor or ceiling. A
 * printer that reports something unexpected therefore reached the UI unchecked.
 *
 * The concrete bug this was written for: Duet computed
 *
 *     (job.filePosition || 0) / (job.file?.size || 1) * 100
 *
 * so when the file size was absent — which Duet does report during the pre-print
 * phase, before the job file is fully parsed — the divisor fell back to 1 and a
 * 500 KB offset rendered as 50,000,000%.
 */

/*
 * WRAPPED IN AN IIFE, like every other shared module.
 *
 * The Mac app polls the same printers as the Electron app, and it loads every
 * bundled module into ONE JavaScriptCore context — so a top-level `function`
 * here is a global there, and a name any other module also uses fails the whole
 * runtime with no symptom a shop can see: the app comes up with no words, no
 * tax and no writes. `lib/upgrade-backup.js` was the module that taught that.
 */
(function (global) {

  /**
   * A number a printer reported, or null when it reported nothing.
   *
   * ── ZERO IS A READING ─────────────────────────────────────────────────────
   *
   * Four adapters wrote `(obj && obj.field) || null`, which turns a genuine
   * **0** into "no reading" — because `0 || null` is `null`. What that costs:
   *
   * - OctoPrint reports `printTimeLeft: 0` at the instant a print finishes, so
   *   the one moment the app could say "done" it said "time unknown". The
   *   48-hour band then fell back to estimating from a percentage it already
   *   knew was 100.
   * - A nozzle or bed genuinely at 0 °C — a cold machine, or a disconnected
   *   thermistor, which Klipper publishes as 0 — read as "not reporting"
   *   rather than "reporting zero". Those are different machines to a person
   *   deciding whether a printer is alive.
   *
   * Moonraker's own nozzle line two lines away used `Number.isFinite` and was
   * right. The bed line beside it used `|| null` and was wrong. One helper, so
   * there is nowhere left for the two to disagree.
   *
   * An empty string is not a reading — some firmwares send `""` for a sensor
   * they have not read yet, and `Number('')` is 0, which would invent one.
   */
  function reading(value) {
    if (value === null || value === undefined || value === '') return null;
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }

  /** Clamp anything an adapter produces to a whole 0-100. Junk becomes 0. */
  function normalizeProgress(value) {
    const n = Number(value);
    if (!Number.isFinite(n)) return 0;
    return Math.min(100, Math.max(0, Math.round(n)));
  }

  /**
   * Percentage from a byte position within a file.
   *
   * Without a positive size this is not a percentage at all, so it reports 0
   * rather than inventing one — "unknown" reads better as no progress than as an
   * impossible number.
   */
  function fileProgressPct(position, size) {
    const p = Number(position);
    const s = Number(size);
    if (!Number.isFinite(p) || !Number.isFinite(s) || s <= 0) return 0;
    return normalizeProgress((p / s) * 100);
  }

  /**
   * Seconds remaining, extrapolated linearly from time spent so far.
   *
   * Returns null rather than a number whenever the estimate would be meaningless:
   * no elapsed time, no progress yet (dividing by ~0 gives an absurd ETA), or
   * already finished. A missing ETA is honest; a wild one is not, and the UI shows
   * it to someone deciding whether to wait.
   */
  function etaSeconds(elapsedSeconds, progressFraction) {
    const elapsed = Number(elapsedSeconds);
    const f = Number(progressFraction);
    if (!Number.isFinite(elapsed) || !Number.isFinite(f)) return null;
    if (elapsed <= 0) return null;
    if (f <= 0.01) return null;   // under 1% the extrapolation is noise
    if (f >= 1) return 0;
    return Math.max(0, Math.round((elapsed / f) * (1 - f)));
  }


  /**
   * Time left, using the slicer's own estimate for the file where it helps.
   *
   * ── WHY `etaSeconds` ALONE IS NOT ENOUGH ──────────────────────────────────
   *
   * `etaSeconds` extrapolates from what has happened: elapsed ÷ done. That is
   * a good answer once a print has run long enough to have a rate, and noise
   * before it — the first minutes are heating, a purge line and a slow first
   * layer, none of which run at the speed of the rest.
   *
   * Measured on the shop's own Snapmaker U1, 2026-09-10: two percent in,
   * twenty-seven minutes elapsed, on a file the slicer had named
   * `BLHT_PETG_4h24m.gcode`. The extrapolation said TWENTY-TWO AND A HALF
   * HOURS — five times over, on the dashboard, as the first thing the shop
   * sees. `moonrakerProgress` above records the same shape of mistake being
   * corrected for progress ("176 hours, on a five-hour print"); the ETA half
   * was left extrapolating.
   *
   * Every other adapter reads the printer's own figure — Bambu's
   * `mc_remaining_time`, OctoPrint's `progress.printTimeLeft`, Duet's
   * `timesLeft.file`, PrusaLink's `job.time_remaining`. Moonraker publishes no
   * such number, but it does publish the slicer's `estimated_time` per file.
   *
   * ── AND WHY THE SLICER ALONE IS NOT EITHER ────────────────────────────────
   *
   * The bench fixture in test/moonraker.test.js is the other end of it: the
   * same U1, 53 layers of 212 (25%), 7,291 seconds elapsed, on a file named
   * `3h58m`. A quarter of the print took HALF the estimate. Believing the
   * slicer there answers 1h56m for something running at a pace that says 6h04m,
   * and that is not a rounding difference — the slicer's estimate is a guess
   * about a machine it has never met, and by 53 layers this machine has
   * measured itself.
   *
   * ── SO: EACH ESTIMATOR WHERE IT IS ACTUALLY GOOD ──────────────────────────
   *
   *     from the slicer    estimated × (1 − f)     good at the start
   *     from the clock     elapsed × (1 − f) / f   good once there is a rate
   *
   * weighted by `w`, which ramps from 0 to 1 across f = 5%…25% — the clock has
   * said nothing worth hearing below the first, and has the floor by the
   * second. The band is a judgement and those two measurements are what it is
   * judged against; it is written as a constant so the next person with a third
   * measurement can move it deliberately.
   *
   * No floor on `f` is needed: at zero the answer is the whole estimate, so a
   * shop gets a usable figure from the first second instead of a blank for the
   * first percent.
   *
   * @param {number} estimatedTotalSeconds the slicer's estimate for the whole file
   * @param {number} elapsedSeconds        seconds actually printing
   * @param {number} progressFraction      0–1, layers preferred over bytes
   * @returns {number|null} seconds left, or null when there is no estimate to use
   */
  const ETA_CLOCK_FROM = 0.05;   // below this the elapsed time says nothing
  const ETA_CLOCK_FULL = 0.25;   // by this the machine has measured itself

  function etaWithEstimate(estimatedTotalSeconds, elapsedSeconds, progressFraction) {
    const total = Number(estimatedTotalSeconds);
    // No estimate is not an estimate of zero. The caller falls back to
    // `etaSeconds`, which is what it had before this existed.
    if (!Number.isFinite(total) || total <= 0) return null;
    const elapsed = Math.max(0, Number(elapsedSeconds) || 0);
    let f = Number(progressFraction);
    if (!Number.isFinite(f) || f < 0) f = 0;
    if (f >= 1) return 0;

    const fromSlicer = total * (1 - f);
    if (f <= ETA_CLOCK_FROM) return Math.max(0, Math.round(fromSlicer));

    const fromClock = (elapsed / f) * (1 - f);
    const w = Math.min(1, (f - ETA_CLOCK_FROM) / (ETA_CLOCK_FULL - ETA_CLOCK_FROM));
    return Math.max(0, Math.round((1 - w) * fromSlicer + w * fromClock));
  }

  /**
   * Percentage from layers printed.
   *
   * Klipper publishes `print_stats.info.{current_layer,total_layer}`. It is a
   * better signal than file position for anything whose G-code is unevenly
   * distributed through the file, which is most decorative work.
   */
  function layerProgressPct(info) {
    // Klipper reports EITHER field as null when the slicer has not set it —
    // print_stats.py stores `info_current_layer = None` until a
    // `SET_PRINT_STATS_INFO CURRENT_LAYER=` arrives. `Number(null)` is 0, and 0 is
    // finite, so a naive read turns "not set" into "layer zero": a slicer that
    // announces TOTAL_LAYER in its start g-code but never updates the current one
    // pinned this at 0% for the whole job and — because layers had "answered" —
    // never fell back to byte position, which would have said 44%. Absent has to
    // mean absent, so both fields are required to be actual numbers.
    const n = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
    const cur = n(info && info.current_layer);
    const total = n(info && info.total_layer);
    if (cur === null || total === null || total <= 0) return null;
    if (cur < 0) return null;
    return normalizeProgress((cur / total) * 100);
  }

  /**
   * How far through a Moonraker job we are, preferring layers over bytes.
   *
   * `virtual_sdcard.progress` is a BYTE position, and bytes are not work. Measured
   * against a real Snapmaker U1 printing a 31 MB relief, 2026-08-01:
   *
   *     actually done (elapsed vs the slicer's own estimate)   19.4%
   *     virtual_sdcard.progress (bytes)                         0.7%
   *     print_stats.info layers (5 of 28)                      17.9%
   *
   * The relief's detail lives in its upper layers, so almost all the G-code sits
   * at the end of the file and byte position barely moves for the first third of
   * the print. Khayt showed that 0.7% as the job's progress and extrapolated an
   * ETA from it — 176 hours, on a five-hour print.
   *
   * Layers are not perfect either (a tall layer takes longer than a short one),
   * so this returns which signal it used and the caller can say so.
   *
   * @returns {{percent: number, source: 'layers'|'bytes'}}
   */
  function moonrakerProgress(printStats, virtualSdcard) {
    const byLayer = layerProgressPct(printStats && printStats.info);
    if (byLayer !== null) return { percent: byLayer, source: 'layers' };
    const frac = Number(virtualSdcard && virtualSdcard.progress);
    return { percent: normalizeProgress(Number.isFinite(frac) ? frac * 100 : 0), source: 'bytes' };
  }

  /**
   * The sentence a shop sees when a printer's server refuses the poll.
   *
   * Every HTTP adapter threw `new Error('HTTP ' + status)`, and that string is
   * rendered verbatim on the dashboard card and in the machine dialog's "Test
   * connection". So the two most ordinary states a printer server reports —
   * "I am running, but no printer is connected to me" and "the key you sent is
   * wrong" — reached the owner as **HTTP 409** and **HTTP 403**.
   *
   * The comment above the dashboard's own render call already says why that is
   * wrong, about a different symptom: it is "the symptom in the vocabulary of a
   * socket", where what is needed is "the same fact in the vocabulary of the
   * person who has to fix it". The same lesson is written down again in
   * lib/makerrun-maintenance.js, about a 503 from the library. The printer poller
   * had not learned it.
   *
   * These statuses are not guesses. Each is in the vendor's own source:
   *
   *   OctoPrint   `abort(409, description="Printer is not operational")` guards
   *               GET /api/printer in both the 1.11 and 2.0 lines
   *               (server/api/printer.py). Note GET /api/job has no such guard —
   *               which is what makes the fallback in the adapter possible.
   *   OctoPrint   `@Permissions.STATUS.require(403)` — a wrong or missing API key
   *               is a 403 here, not a 401.
   *   Moonraker   `ServerError("Klippy Host not connected", 503)` and
   *               `ServerError("Klippy Disconnected", 503)`
   *               (moonraker/klippy_connection.py). This is what a shop sees while
   *               Klipper restarts, and after a config error stops it coming back.
   *   PrusaLink   401 for a wrong Password/API key — called "Password" on Buddy
   *               firmware 5.0+, under Settings → Network → PrusaLink.
   *
   * Returns null when there is nothing better to say than the status, so the
   * caller keeps its own message rather than being handed a worse one.
   */
  function explainPrinterHttp(type, status, body) {
    const code = Number(status);
    const kind = String(type || '').toLowerCase();
    const said = vendorMessage(body);
    const quoted = said ? ` The server said: “${said}”.` : '';

    if (kind === 'octoprint') {
      if (code === 409) return `OctoPrint is running, but it is not connected to a printer. Connect it in OctoPrint, or switch the printer on.${quoted}`;
      if (code === 403) return `OctoPrint refused the API key. Copy it again from OctoPrint → Settings → API.${quoted}`;
    }
    if (kind === 'moonraker') {
      if (code === 503) return `Klipper is not running yet. This is normal for a few seconds after a restart; if it stays, Klipper stopped — check its console for a config error.${quoted}`;
      if (code === 401) return `Moonraker refused the connection. Either add this computer to Moonraker's trusted_clients, or paste an API key into the machine's API key field.${quoted}`;
    }
    if (kind === 'prusalink') {
      if (code === 401) return `PrusaLink refused the password. On firmware 5.0 and later it is shown on the printer under Settings → Network → PrusaLink, and it goes in the API key field.${quoted}`;
    }
    return null;
  }

  /**
   * The vendor's own words out of an error body, when it left any.
   *
   * Moonraker answers `{"error":{"code":503,"message":"Klippy Host not
   * connected"}}` and OctoPrint `{"error":"Printer is not operational"}`, so the
   * shapes differ but both are worth quoting: the message names WHICH failure it
   * is, and a shop reading it can search for it. Capped and stripped of newlines
   * because this lands in a one-line status on a card, and the body is a remote
   * printer's — length is not something this end controls.
   */
  function vendorMessage(body) {
    if (!body) return '';
    let text = body;
    if (typeof body === 'string') {
      try { text = JSON.parse(body); } catch { /* not JSON: use the string */ }
    }
    if (text && typeof text === 'object') {
      const e = text.error;
      text = (e && typeof e === 'object' ? e.message : e) || text.message || text.reason || '';
    }
    const flat = String(text || '').replace(/\s+/g, ' ').trim();
    if (!flat || flat.length > 200) return flat ? `${flat.slice(0, 197)}…` : '';
    return flat;
  }

  // duetHeaterTemp used to live here and has moved to lib/duet.js, next to the
  // two transports that need it. This file is the CROSS-adapter normaliser —
  // progress, ETA, clamping — and a Duet heater-index rule was never that.
  const api = {
    reading, normalizeProgress, fileProgressPct, etaSeconds, etaWithEstimate, layerProgressPct, moonrakerProgress,
    explainPrinterHttp, vendorMessage,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrinterStatus = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
