/**
 * Advance the wall clock, so a fixture with an expiry date on it fails HERE
 * rather than on an unrelated PR one morning.
 *
 * On 2026-08-14 the QC smoke's RMA fixture aged out: it delivered an order on a
 * hardcoded `2026-07-15` under a 30-day warranty and asserted the RMA modal
 * auto-detects it as in-warranty. Thirty days later that flipped, and because
 * `E2E smoke (Electron)` is a REQUIRED check with no bypass actors, **nothing in
 * the repository could merge**. The bug was not in the app and not in the PR it
 * appeared on.
 *
 * Grep cannot find the next one. There are ~465 date literals under `test/` and
 * `scripts/`, and nearly all are inert labels — `date`, `timestamp`,
 * `statusHistory[].at`. A literal is only dangerous when something compares it to
 * the real clock, which is a property of the code, not of the string. Running the
 * suite in the future asks the question directly.
 *
 * Loaded via `--require` (see scripts/test-future.mjs), never by the app.
 *
 * WHAT IT SHIFTS, AND WHAT IT MUST NOT
 *
 * Only the two forms that mean "now": `new Date()` with no arguments, and
 * `Date.now()`. Every explicit form — a timestamp, an ISO string, y/m/d parts —
 * is a fixed point the caller named on purpose. Moving those would invent
 * failures in tests that are perfectly correct, and the noise would bury the one
 * real finding.
 */
'use strict';

const SHIFT_DAYS = Number(process.env.CLOCK_SHIFT_DAYS || 0);

if (SHIFT_DAYS) {
  const ms = SHIFT_DAYS * 86400000;
  const RealDate = Date;

  class ShiftedDate extends RealDate {
    constructor(...args) {
      if (args.length === 0) super(RealDate.now() + ms);
      else super(...args);
    }
    static now() { return RealDate.now() + ms; }
  }
  // Subclassing carries the prototype methods; these two are static and are not
  // inherited in a way that keeps the real implementations, so pass them through.
  ShiftedDate.parse = RealDate.parse;
  ShiftedDate.UTC = RealDate.UTC;

  globalThis.Date = ShiftedDate;
}
