'use strict';
/**
 * How far along an order is, for the page a CUSTOMER sees.
 *
 * `exportOrderStatusPage` and `autoExportStatusPage` each carried their own
 * copy of this list:
 *
 *     ['quote', 'pending', 'on_hold', 'printing', 'post', 'completed']
 *
 * `qc` and `delivered` were missing from both. `indexOf` returns -1 for a status
 * that is not there, every step then compares `-1 >= stepIndex` and comes out
 * false, so the tracker showed NOTHING as reached:
 *
 *     order is qc         1 2 3 4 5   (0/5 steps reached)
 *     order is delivered  1 2 3 4 5   (0/5 steps reached)
 *
 * A customer who had already RECEIVED their print opened the page and saw a
 * tracker saying the job had not started.
 *
 * One list, in one place, because two copies of an enumeration drift and this is
 * what that costs. Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  /**
   * The stages a customer is shown, in order.
   *
   * `on_hold` and `qc` are NOT here: they are real states an order sits in, but
   * they are not stages of their own on a customer's tracker — a job on hold has
   * still reached whatever it reached, and QC is part of finishing. They map to
   * the stage they belong to instead, via PROGRESS_OF.
   */
  const STEPS = ['quote', 'pending', 'printing', 'post', 'completed'];

  /**
   * Which step each status counts as having reached.
   *
   * Every status the app can ASSIGN is here. A status missing from this map is
   * the bug this file exists to prevent, so `progressIndex` treats an unknown
   * one as "at least started" rather than as "nothing has happened" — failing
   * forward, because a tracker that under-reports is the one that makes a
   * customer think their order was lost.
   */
  const PROGRESS_OF = {
    quote: 0,
    pending: 1,
    on_hold: 1,      // held, but it got as far as it got
    queued: 1,
    printing: 2,
    post: 3,
    qc: 3,           // checking the finished print is part of finishing it
    completed: 4,
    delivered: 4,    // completed and handed over
    split: 1,        // the parent is superseded; its children carry the work
  };

  /**
   * How many steps this order has reached, as an index into STEPS.
   * @returns {number} 0..STEPS.length-1
   */
  function progressIndex(status) {
    const s = String(status || '');
    if (Object.prototype.hasOwnProperty.call(PROGRESS_OF, s)) return PROGRESS_OF[s];
    // Unknown: something assigned a status this file has not been told about.
    // Show it as started rather than as nothing.
    return 1;
  }

  /** Is `step` (an index into STEPS) reached by an order at `status`? */
  function stepReached(status, step) {
    return progressIndex(status) >= step;
  }

  const api = { STEPS, PROGRESS_OF, progressIndex, stepReached };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderProgress = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
