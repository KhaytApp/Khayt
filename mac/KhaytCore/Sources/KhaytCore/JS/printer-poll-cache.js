/**
 * How a printer's cached status survives a missed poll.
 *
 * The poller used to replace the whole cache entry with `{ error, lastUpdated }`
 * on any failure, which threw away the last known job and progress. A single
 * blip — a Wi-Fi hiccup, or a CORE One taking its usual 20-30s to answer after a
 * power cycle — flipped a card from "printing 61%" to a red "offline" and back.
 *
 * Vendors hit this too and fixed it the same way: Bambu shipped a distinct
 * "Connecting" status specifically so short reconnects stop reading as Offline,
 * and Prusa's most-reported Connect complaint is false "Attention" alerts. A
 * panel that cries wolf gets ignored, and then the real fault is missed — so the
 * cache keeps the last good reading and counts misses, letting the UI decide
 * when a machine is actually gone.
 */

(function (global) {
  /**
   * Is this machine mid-job? Matched on the state strings the pollers actually
   * return across OctoPrint, Moonraker, PrusaLink, Duet and Repetier.
   */
  const PRINTING = /^(printing|busy|running|working)/i;
  const isPrintingState = (s) => PRINTING.test(String(s || ''));

  /**
   * Paused is not printing, but it is not finished either.
   *
   * `captureCompletion` fires on the edge out of printing, and pause is such an
   * edge — so pausing a job recorded its mid-print filament and duration as if the
   * job had ended. With one completion slot that was invisible: the real
   * completion overwrote it minutes or hours later. Keeping a history would have
   * preserved both and started handing out the wrong one, so the edge has to mean
   * "the job is over" before anything remembers more than the last of them.
   */
  const PAUSED = /^(paus)/i;
  const isInJob = (s) => isPrintingState(s) || PAUSED.test(String(s || ''));

  /** How many finished jobs a machine remembers. */
  const COMPLETIONS_KEPT = 8;

  /**
   * Freeze what a finished job actually used.
   *
   * A printer's filament and duration counters are per-job and reset when the next
   * one starts, so "read them when the shop gets round to marking the order done"
   * is not a plan — by then the machine may be two jobs further on. The moment
   * they are true is the transition out of printing, so that is when they are kept.
   *
   * The finished reading is preferred over the last mid-print one because
   * Moonraker and OctoPrint both retain a completed job's stats until the next
   * print begins, and the last poll before the end can be several percent short.
   * The previous reading is the fallback for a printer that clears them instantly.
   */
  function captureCompletion(prev, status, now) {
    const p = prev || {};
    const was = isInJob(p.state);
    const is = isInJob(status && status.state);
    if (!was || is) return p.lastCompleted || null;

    const usable = (a) => !!(a && (a.filamentGrams > 0 || a.durationS > 0));
    const finished = status && status.actuals;
    const during = p.actuals;
    const actuals = usable(finished) ? finished : (usable(during) ? during : null);
    if (!actuals) return p.lastCompleted || null;

    return {
      at: now,
      // The job these figures belong to, so the shop is not offered last week's
      // numbers for today's order.
      filename: (status && status.filename) || p.filename || '',
      actuals,
    };
  }

  /**
   * The finished jobs this machine still remembers, newest first.
   *
   * One slot was not enough. A shop with two printers, or one printer running
   * overnight, finishes a second job before anyone opens the first job's dialog —
   * and the only record of what the first one cost was gone, silently, with the
   * UI still offering a confident "Measured" figure belonging to the wrong print.
   *
   * `lastCompleted` remains the head of this list, so every existing reader keeps
   * working unchanged; the list is what stops the older ones being destroyed.
   */
  function pushCompletion(prevList, entry) {
    const list = Array.isArray(prevList) ? prevList : [];
    if (!entry) return list;
    // A completion is captured once, on the edge — but a caller that re-merges the
    // same poll must not grow the list. Same job at the same instant is the same
    // event, not a second one.
    if (list.some((c) => c && c.at === entry.at && c.filename === entry.filename)) return list;
    return [entry, ...list].slice(0, COMPLETIONS_KEPT);
  }

  /** A poll that answered. Fresh object — a previous `error` must not survive. */
  function mergePollSuccess(prev, status, now) {
    const p = prev || {};
    const lastCompleted = captureCompletion(prev, status, now);
    // captureCompletion hands back the PREVIOUS completion when nothing finished,
    // so an identity change is exactly "a job just ended".
    const isNew = lastCompleted && lastCompleted !== p.lastCompleted;
    const completions = isNew
      ? pushCompletion(p.completions, lastCompleted)
      : (Array.isArray(p.completions) ? p.completions : []);

    return {
      ...(status || {}),
      ...(lastCompleted ? { lastCompleted } : {}),
      ...(completions.length ? { completions } : {}),
      consecutiveFailures: 0,
      lastOkAt: now,
      lastUpdated: now,
    };
  }

  /**
   * The remembered completion that belongs to a given job, or the most recent.
   *
   * Matching on the printer's filename is the only honest link between an order
   * and a set of figures. When the caller knows it, the right job's numbers are
   * returned even if three more have finished since. When it does not, this
   * returns the newest — the previous behaviour, unchanged.
   *
   * @param {object} entry     a machine's poll-cache entry
   * @param {{filename?: string}} [want]
   */
  function findCompletion(entry, want = {}) {
    const e = entry || {};
    const list = Array.isArray(e.completions) && e.completions.length
      ? e.completions
      : (e.lastCompleted ? [e.lastCompleted] : []);
    if (!list.length) return null;

    const wanted = String(want.filename || '').trim().toLowerCase();
    if (wanted) {
      const hit = list.find((c) => String((c && c.filename) || '').trim().toLowerCase() === wanted);
      if (hit) return hit;
    }
    return list[0];
  }

  /** A poll that threw. Keep the telemetry, count the miss. */
  function mergePollFailure(prev, message, now) {
    const p = prev || {};
    return {
      ...p,
      error: message,
      consecutiveFailures: (p.consecutiveFailures || 0) + 1,
      // Only stamp lastOkAt from lastUpdated on the FIRST failure — after that
      // lastUpdated is itself a failure timestamp and would falsely advance it.
      lastOkAt: p.error ? (p.lastOkAt || null) : (p.lastUpdated || null),
      lastUpdated: now,
    };
  }

  /**
   * Has this machine missed enough polls to be called offline rather than
   * reconnecting? Threshold is the caller's, since display and alerting use
   * different tolerances.
   */
  function isOffline(entry, threshold) {
    if (!entry || !entry.error) return false;
    return (entry.consecutiveFailures || 0) >= threshold;
  }

  /* ── Surviving a restart ─────────────────────────────────────────────────
   *
   * captureCompletion exists because "read the figures when the shop gets round
   * to marking the order done" is not a plan — the printer's counters reset when
   * the next job starts. So the numbers are frozen on the edge out of printing.
   *
   * They were frozen into MEMORY. Nothing wrote them anywhere, so the window in
   * which a measurement survives was not the 24 hours prefillActuals offers it
   * for — it was "until Khayt is next quit". Finish an overnight print, close the
   * app in the morning, open it and mark the order done: the job is offered an
   * ESTIMATE, correctly labelled as one, and the measurement it actually took is
   * gone. Same shape as a printer polled at a stale address — not a number
   * displayed wrongly, a number that stops existing.
   *
   * Only the completions are worth keeping. A saved STATUS would come back as a
   * confident "Printing · 47%" for a machine that has been off all night, which
   * is the exact failure the dashboard's freshness check was added to prevent —
   * so this deliberately cannot carry one.
   */

  /** The part of the cache worth writing to disk: finished jobs, nothing live. */
  function completionsToPersist(cache) {
    const out = {};
    for (const [machineId, entry] of Object.entries(cache || {})) {
      const list = Array.isArray(entry && entry.completions) ? entry.completions
        : (entry && entry.lastCompleted ? [entry.lastCompleted] : []);
      const clean = list.filter((c) => c && c.at && c.actuals).slice(0, COMPLETIONS_KEPT);
      if (clean.length) out[machineId] = clean;
    }
    return out;
  }

  /**
   * Rebuild a cache from what was saved — completions ONLY.
   *
   * Every entry comes back with no `state`, no `progress` and no `lastUpdated`,
   * so a restored machine reads as "not polled yet" rather than as whatever it
   * was doing when the app last closed. The first real poll fills the rest in.
   */
  function restoreCompletions(saved) {
    const cache = {};
    for (const [machineId, list] of Object.entries(saved || {})) {
      const clean = (Array.isArray(list) ? list : [])
        .filter((c) => c && c.at && c.actuals)
        .slice(0, COMPLETIONS_KEPT);
      if (!clean.length) continue;
      cache[machineId] = { completions: clean, lastCompleted: clean[0] };
    }
    return cache;
  }

  /** Did this merge just capture a job that was not there before? */
  function completionIsNew(before, after) {
    const b = before && before.lastCompleted;
    const a = after && after.lastCompleted;
    return !!a && a !== b;
  }

  const api = {
    mergePollSuccess, mergePollFailure, isOffline, captureCompletion,
    isPrintingState, isInJob, findCompletion, COMPLETIONS_KEPT,
    completionsToPersist, restoreCompletions, completionIsNew,
  };

  // Dual export. This runs in main.js as a CommonJS module AND as a plain <script>
  // in the renderer, where every module shares one global scope — hence the IIFE,
  // without which PRINTING, captureCompletion and friends would all be globals.
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPollCache = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
