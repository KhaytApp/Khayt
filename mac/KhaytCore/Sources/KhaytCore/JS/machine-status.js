'use strict';

/**
 * A printer that is in service, under service, or retired — and when one may
 * be deleted at all.
 *
 * ── THREE STATES, TWO FIELDS ───────────────────────────────────────────────
 *
 *   - UNDER SERVICE is `isOffline: true`, the flag the desktop's machine modal
 *     has always written and `lib/scheduling.js`, `attention.js` and
 *     `lead-time-publish.js` already honour. `offlineReason` and
 *     `offlineSince` say why and since when; both optional. Temporary: the
 *     printer still counts in the shop's overhead and keeps its history.
 *   - RETIRED (sold, scrapped, given away) is `status: 'retired'` with
 *     `retiredAt` (an ISO day). Kept in the book so every past job, cost and
 *     service still has a printer to belong to — its P&L, depreciation up to
 *     `retiredAt`, its maintenance log. Gone from everything day-to-day:
 *     scheduling, dispatch, pickers, polling, the board, the overhead rate.
 *   - IN SERVICE is neither.
 *
 * `status` stays a string. The iPhone decodes it as one, and a whole Machines
 * tab fails to decode on a value that is not.
 *
 * ── DELETE ONLY WHAT NOTHING REMEMBERS ────────────────────────────────────
 *
 * Deleting a printer that has history rewrites the past: its depreciation
 * vanishes from every earlier period, its jobs fall into "Unassigned", its
 * service costs are dropped from the machine P&L. So a printer may be deleted
 * only when no record in the book names it — a printer added by mistake.
 * Anything else is retired. `references` scans every array in the book, and
 * the parts, runs and setups inside a record, for `machineId`; a new
 * collection that names a machine is covered without being listed here.
 *
 * Pure: no clock, no I/O. Dates are handed in.
 */
(function (global) {
  const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
  const str = (v) => String(v == null ? '' : v).trim();
  const arrayOf = (v) => (Array.isArray(v) ? v : []);
  const Status = global.KhaytOrderStatus
    || (typeof require === 'function' ? require('./order-status.js') : null);

  /** Sold, scrapped or given away: kept for its history, out of the way. */
  function isRetired(m) {
    return isObj(m) && (str(m.status) === 'retired' || !!str(m.retiredAt));
  }

  /** Temporarily out: being repaired, waiting for a part. */
  function isUnderService(m) {
    return isObj(m) && !isRetired(m) && (m.isOffline === true || str(m.status) === 'offline');
  }

  /** May be given work today. */
  function inService(m) {
    return isObj(m) && !isRetired(m) && !isUnderService(m);
  }

  /** `'retired'`, `'service'` or `'active'`. */
  function stateOf(m) {
    if (isRetired(m)) return 'retired';
    if (isUnderService(m)) return 'service';
    return 'active';
  }

  // Nested lists inside a record that can name a machine of their own.
  const NESTED = ['parts', 'printRuns', 'setups', 'runs', 'attempts'];

  function names(rec, id) {
    if (!isObj(rec)) return false;
    if (str(rec.machineId) === id) return true;
    for (const k of NESTED) {
      for (const inner of arrayOf(rec[k])) if (isObj(inner) && str(inner.machineId) === id) return true;
    }
    return false;
  }

  /**
   * How many records in each collection name the machine: `{ total, by:
   * { printLog: 4, machMaintLog: 2, … } }`. `machines` itself is skipped, and
   * so are tombstones. The finished-print cache keyed by machine id
   * (`printerCompletions`) counts too — at the book's TOP LEVEL, where both
   * apps write it (main.js `COMPLETIONS_KEY`, the Mac's `persistCompletions`);
   * under `settings` only in books from before that, so both are asked and a
   * machine in either counts once.
   */
  function references(book, machineId) {
    const id = str(machineId);
    const by = {};
    let total = 0;
    if (!id || !isObj(book)) return { total, by };
    for (const [coll, rows] of Object.entries(book)) {
      if (coll === 'machines' || coll === 'tombstones' || !Array.isArray(rows)) continue;
      let n = 0;
      for (const r of rows) if (names(r, id)) n++;
      if (n) { by[coll] = n; total += n; }
    }
    const s = isObj(book.settings) ? book.settings : {};
    for (const key of ['printerCompletions']) {
      const kept = (o) => isObj(o) && o[id] != null;
      if (kept(book[key]) || kept(s[key])) { by[key] = 1; total += 1; }
    }
    return { total, by };
  }

  /**
   * `{ ok, reason, total, by }`; reason is `missing`, `has_history` or null.
   */
  function canDelete(book, machineId) {
    const id = str(machineId);
    const m = arrayOf(isObj(book) && book.machines).find((x) => isObj(x) && str(x.id) === id);
    if (!m) return { ok: false, reason: 'missing', total: 0, by: {} };
    const refs = references(book, id);
    if (refs.total > 0) return Object.assign({ ok: false, reason: 'has_history' }, refs);
    return Object.assign({ ok: true, reason: null }, refs);
  }

  /** Remove the machine when `canDelete` allows. Changes `book` in place. */
  function remove(book, machineId) {
    const verdict = canDelete(book, machineId);
    if (!verdict.ok) return Object.assign({ removed: null }, verdict);
    const index = book.machines.findIndex((x) => isObj(x) && str(x.id) === str(machineId));
    const removed = book.machines.splice(index, 1)[0];
    return Object.assign({ removed, index }, verdict);
  }

  function finished(order) {
    if (!isObj(order)) return true;
    if (Status && typeof Status.isFinished === 'function' && Status.isFinished(order)) return true;
    return ['completed', 'delivered', 'cancelled', 'quote', 'split'].includes(str(order.status));
  }

  /**
   * Under service, or back in it. `opts`: `{ on, reason, since }` — `since`
   * an ISO day, handed in. Returns the new machine record; the input is left
   * alone. Turning it off clears the reason and date with it.
   */
  function setUnderService(machine, opts) {
    const o = isObj(opts) ? opts : {};
    const out = Object.assign({}, machine);
    if (o.on) {
      out.isOffline = true;
      const reason = str(o.reason).slice(0, 200);
      if (reason) out.offlineReason = reason; else delete out.offlineReason;
      if (str(o.since)) out.offlineSince = str(o.since);
    } else {
      out.isOffline = false;
      delete out.offlineReason;
      delete out.offlineSince;
      if (str(out.status) === 'offline') delete out.status;
    }
    return out;
  }

  /**
   * Retire the machine, and take it off every job that has not finished: a
   * queued job left on a sold printer is never moved by anything, because
   * every rule that places work only places jobs with no machine.
   *
   * `book`: `{ machines, printLog }`, changed in place. `opts`: `{ at, reason }`.
   * Returns `{ ok, reason, machine, unassigned: [jobId…] }`.
   */
  function retire(book, machineId, opts) {
    const o = isObj(opts) ? opts : {};
    const id = str(machineId);
    const machines = arrayOf(isObj(book) && book.machines);
    const index = machines.findIndex((x) => isObj(x) && str(x.id) === id);
    if (index < 0) return { ok: false, reason: 'missing', machine: null, unassigned: [] };
    const at = str(o.at);
    if (!/^\d{4}-\d{2}-\d{2}/.test(at)) return { ok: false, reason: 'no_date', machine: null, unassigned: [] };
    const m = Object.assign({}, machines[index], { status: 'retired', retiredAt: at.slice(0, 10) });
    const why = str(o.reason).slice(0, 200);
    if (why) m.retiredReason = why; else delete m.retiredReason;
    // Not "under service" as well: retired says it all, and a flag left on
    // would bring it back as offline if it were ever returned to service.
    m.isOffline = false;
    delete m.offlineReason;
    delete m.offlineSince;
    machines[index] = m;
    const unassigned = [];
    for (const job of arrayOf(book.printLog)) {
      if (!isObj(job) || str(job.machineId) !== id || finished(job)) continue;
      job.machineId = null;
      unassigned.push(str(job.id));
    }
    return { ok: true, reason: null, machine: m, unassigned };
  }

  /** Back in service: the retirement undone, its history untouched. */
  function unretire(machine) {
    const out = Object.assign({}, machine);
    if (str(out.status) === 'retired') delete out.status;
    delete out.retiredAt;
    delete out.retiredReason;
    return out;
  }

  /**
   * Is the machine retired on `day` (ISO)? Its depreciation, utilisation and
   * capacity stop the day after `retiredAt`. A retired machine with no date
   * (written by hand) is treated as retired always.
   */
  function retiredOn(m, day) {
    if (!isRetired(m)) return false;
    const at = str(m.retiredAt).slice(0, 10);
    if (!at) return true;
    return str(day).slice(0, 10) > at;
  }

  const api = {
    isRetired, isUnderService, inService, stateOf, retiredOn,
    references, canDelete, remove, setUnderService, retire, unretire,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytMachineStatus = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
