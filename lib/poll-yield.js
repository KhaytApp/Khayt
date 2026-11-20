'use strict';
(function (global) {

/**
 * The background poll steps aside while a PERSON's command is on its way to
 * a printer (C6, batch 2 of ~/Khayt-proposals/prusa-ideas-plan.md).
 *
 * The poller asks every printer every 30 s (desktop) or 10 s (Mac). A press
 * of Pause sent while a poll of the same printer is in flight raced it: the
 * poll's answer, read a moment before the pause landed, came back after the
 * press and drew "Printing" again, so the shop pressed Pause twice. And a
 * Bambu or SDCP printer shares one connection between the poll and the
 * command. So while a command is in flight, that printer is not polled; the
 * command's own reply (or the next poll after it) says what happened.
 *
 * Never for ever: a command that hangs releases its printer after `maxMs`,
 * so a lost reply cannot freeze a card. Commands to the same printer nest
 * (two presses, two replies). Other printers are polled as usual.
 *
 *   const y = createPollYield({ maxMs })
 *   y.begin(id, now)      a command to this printer is sent
 *   y.end(id, now)        its reply came (or it failed)
 *   y.yielding(id, now)   true while the poll should leave this printer alone
 *   y.justSettled(id, now)  true for `settleMs` after the last reply: poll it
 *                          NOW rather than waiting out the interval
 *
 * Pure: the clock is handed in. One instance per app.
 */

const MAX_MS = 20000;
const SETTLE_MS = 3000;

function createPollYield(opts = {}) {
  const maxMs = Number(opts.maxMs) > 0 ? Number(opts.maxMs) : MAX_MS;
  const settleMs = Number(opts.settleMs) >= 0 && opts.settleMs != null ? Number(opts.settleMs) : SETTLE_MS;
  const by = new Map();   // id → { n, since, settledAt }
  const key = (id) => String(id == null ? '' : id);

  function begin(id, now) {
    const k = key(id);
    if (!k) return;
    const e = by.get(k) || { n: 0, since: now, settledAt: null };
    if (e.n === 0) e.since = now;
    e.n += 1;
    e.settledAt = null;
    by.set(k, e);
  }

  function end(id, now) {
    const e = by.get(key(id));
    if (!e || e.n === 0) return;
    e.n -= 1;
    if (e.n === 0) e.settledAt = now;
  }

  function yielding(id, now) {
    const e = by.get(key(id));
    if (!e || e.n === 0) return false;
    if (now - e.since >= maxMs) { e.n = 0; e.settledAt = now; return false; }   // a reply that never came
    return true;
  }

  function justSettled(id, now) {
    const e = by.get(key(id));
    return !!(e && e.n === 0 && e.settledAt != null && now - e.settledAt <= settleMs);
  }

  /** Run `fn` as a command to `id`: yields around it, ends even when it throws. */
  async function around(id, fn, clock) {
    const now = typeof clock === 'function' ? clock : () => Date.now();
    begin(id, now());
    try { return await fn(); } finally { end(id, now()); }
  }

  return { begin, end, yielding, justSettled, around };
}

const api = { MAX_MS, SETTLE_MS, createPollYield };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytPollYield = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
