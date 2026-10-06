'use strict';
/**
 * The kiosk: what each machine is doing, for a screen across the shop
 * (KhaytKiosk).
 *
 * One card per machine — its name, the job on it, how far along that job is
 * and when it will be done. Lifted out of `renderer/views.js`
 * `renderKioskView`, where the rule lived inside the HTML, so the Mac can draw
 * the same cards from the same answer.
 *
 * ── WHAT THE ORIGINAL GOT WRONG ────────────────────────────────────────────
 *
 * Kept here so nobody puts them back:
 *
 * 1. A CANCELLED job, a SPLIT parent, a VOIDED order and an ARCHIVED one were
 *    all "active": the filter was only `!isFinished && status !== 'quote'`.
 *    A machine whose last job was cancelled showed that job, forever, on the
 *    one screen meant to be read from across the room.
 * 2. The bar ran for jobs that were not printing. `printingStartedAt` is the
 *    FIRST start and survives a pause (lib/order-status.js), so a job put on
 *    hold kept "advancing" on the kiosk while the machine sat still, and a job
 *    in post-processing read 100% "Done" for as long as it sat there.
 * 3. "1h 60m". The minutes were rounded after the hours were floored, so 1.999
 *    hours left came out as one hour and sixty minutes. Minutes are rounded
 *    first here, then split.
 * 4. Past its estimate a print read "Done" while it was still printing — the
 *    clamp that kept the bar inside its track also threw away the one fact a
 *    shop wants from it. The bar is clamped; `overrunMinutes` is not.
 * 5. "~Nh total", for a job with an estimate and no start, was built and then
 *    never drawn: it only rendered inside the `pct > 0` branch, and such a job
 *    has `pct` 0. `totalHours` carries it now.
 * 6. A machine with a model and no name printed its model twice — once as the
 *    name it fell back to, once as the model line under it.
 *
 * ── THE PRINTER IS THE BETTER WITNESS ──────────────────────────────────────
 *
 * `live` is optional, and the same shape `lib/machine-band.js` reads:
 * `{ [machineId]: { progress, timeRemaining } }` (progress 0–100, time in
 * seconds), or `{ error }` for a printer that is not answering. A host that
 * polls its printers (the Mac does) passes what they said, and the card then
 * shows the printer's own progress rather than a guess from the clock. A host
 * that does not passes nothing and gets the estimate, as before.
 *
 * Pure; no DOM, no I/O. Shared by the desktop and, bundled, the Mac.
 */
(function (global) {
  /** Which job a machine shows when it has several: the one furthest along. */
  const RANK = { printing: 0, post: 1, qc: 2, pending: 3, on_hold: 4 };
  const OTHER_RANK = 5;

  /** Not work on a machine, whatever `isFinished` says about them. */
  const NOT_WORK = { quote: 1, cancelled: 1, split: 1 };

  function num(v) {
    if (v === null || v === undefined || v === '') return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  function isFinished(o) {
    const S = global.KhaytOrderStatus;
    if (S && typeof S.isFinished === 'function') return S.isFinished(o);
    const s = o && o.status;
    return s === 'completed' || s === 'delivered';
  }

  function showsBusiness(mode) {
    const T = global.KhaytTiers;
    if (T && typeof T.showsBusiness === 'function') return T.showsBusiness(mode);
    return mode !== 'enthusiast';
  }

  /** Is this order work that is still on a machine? */
  function isActive(o) {
    if (!o || typeof o !== 'object') return false;
    if (isFinished(o)) return false;
    if (NOT_WORK[o.status]) return false;
    if (o.voidedAt || o.archived) return false;
    return true;
  }

  function rankOf(status) {
    return Object.prototype.hasOwnProperty.call(RANK, status) ? RANK[status] : OTHER_RANK;
  }

  /** The job a machine shows, or null. Ties keep the book's order. */
  function jobFor(machineId, orders) {
    const mine = orders.filter(o => isActive(o) && o.machineId === machineId);
    mine.sort((a, b) => rankOf(a.status) - rankOf(b.status));
    return mine[0] || null;
  }

  /** A whole number of minutes, never negative; null when there is no answer. */
  function minutes(hours) {
    return hours === null ? null : Math.max(0, Math.round(hours * 60));
  }

  /**
   * How far along a PRINTING job is.
   *
   * The printer's own word first — `timeRemaining`, then `progress` against
   * the estimate — and the clock against the estimate only when the printer
   * said nothing. `pct` is for the bar and is clamped to 0–100; the overrun is
   * reported beside it, never folded into it.
   */
  function progressOf(job, reading, now) {
    const printHrs = num(job.printTime) > 0 ? num(job.printTime) : 0;
    const live = reading && !reading.error ? reading : null;
    const livePct = live ? num(live.progress) : null;
    const liveLeft = live ? num(live.timeRemaining) : null;

    if (liveLeft !== null && liveLeft >= 0 || livePct !== null && livePct >= 0) {
      let pct = livePct !== null ? livePct : null;
      let leftHrs = liveLeft !== null && liveLeft >= 0 ? liveLeft / 3600 : null;
      if (leftHrs === null && pct !== null && pct < 100 && printHrs > 0) {
        leftHrs = printHrs * (1 - pct / 100);
      }
      if (pct === null && leftHrs !== null && printHrs > 0) {
        pct = 100 * (1 - leftHrs / printHrs);
      }
      return {
        source: 'printer',
        pct: pct === null ? null : Math.max(0, Math.min(100, Math.round(pct))),
        remainingMinutes: minutes(leftHrs),
        overrunMinutes: 0,
        totalHours: printHrs || null,
      };
    }

    const startedAt = job.printingStartedAt ? new Date(job.printingStartedAt).getTime() : NaN;
    if (printHrs > 0 && Number.isFinite(startedAt)) {
      const elapsed = Math.max(0, (now - startedAt) / 3600000);
      return {
        source: 'estimate',
        pct: Math.min(100, Math.round((elapsed / printHrs) * 100)),
        remainingMinutes: minutes(Math.max(0, printHrs - elapsed)),
        overrunMinutes: elapsed > printHrs ? minutes(elapsed - printHrs) : 0,
        totalHours: printHrs,
      };
    }
    return {
      source: 'none', pct: null, remainingMinutes: null, overrunMinutes: 0,
      totalHours: printHrs || null,
    };
  }

  /**
   * The cards.
   *
   * @param {object} input
   *   machines  [{ id, name, model, deleted }]
   *   orders    the print log
   *   live      optional, see the header
   *   mode      the shop's mode — an enthusiast has no customers to name
   *   now       epoch ms
   * @returns {Array<object>} one card per machine still in the shop
   */
  function cards(input) {
    const inp = input || {};
    const machines = Array.isArray(inp.machines) ? inp.machines : [];
    const orders = Array.isArray(inp.orders) ? inp.orders : [];
    const live = inp.live && typeof inp.live === 'object' ? inp.live : {};
    const now = num(inp.now) !== null ? num(inp.now) : Date.now();
    const business = showsBusiness(inp.mode);

    return machines.filter(m => m && !m.deleted).map(m => {
      const name = String(m.name || m.model || m.id || '');
      const model = m.model && String(m.model) !== name ? String(m.model) : '';
      const reading = live[m.id] || null;
      const job = jobFor(m.id, orders);
      const offline = !!(reading && reading.error);
      const card = {
        machineId: String(m.id || ''), name, model,
        state: job ? String(job.status || '') : 'idle',
        offline,
        orderId: '', project: '', clientId: '', clientLabel: '',
        dueDate: '',
        source: 'none', pct: null, remainingMinutes: null, overrunMinutes: 0,
        totalHours: null,
      };
      if (job) {
        card.orderId = String(job.id || '');
        card.project = String(job.project || '');
        if (business) {
          card.clientId = String(job.clientId || '');
          card.clientLabel = String(job.client || '');
        }
        card.dueDate = String(job.dueDate || '');
        if (job.status === 'printing') {
          Object.assign(card, progressOf(job, reading, now));
        } else {
          const printHrs = num(job.printTime);
          card.totalHours = printHrs > 0 ? printHrs : null;
        }
      } else if (reading && !offline) {
        // Printing something the book has no job for. Say the machine is
        // busy, and for how long if it says, rather than "Idle" over a bed
        // with plastic coming out of it.
        const p = progressOf({}, reading, now);
        if (p.source === 'printer') {
          card.state = 'busy';
          Object.assign(card, p);
        }
      }
      return card;
    });
  }

  /** "2h 05m" / "45m" — minutes split AFTER rounding, so never "1h 60m". */
  function duration(totalMinutes) {
    const n = num(totalMinutes);
    if (n === null) return '';
    const m = Math.max(0, Math.round(n));
    const h = Math.floor(m / 60);
    const r = m % 60;
    return h > 0 ? `${h}h ${r}m` : `${r}m`;
  }

  const api = { cards, duration, isActive, RANK };
  global.KhaytKiosk = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
