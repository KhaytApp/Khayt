'use strict';
(function () {

/**
 * "What needs me now" — pure selector behind the dashboard attention bar.
 *
 * The dashboard's problem was never taste, it was ranking: a printer that had
 * gone offline and a "Feedback & Bug Reports" button competed on even terms.
 * This module decides the one thing the operator has to be told before anything
 * else, so the top of the screen can carry a count and a reason instead of a
 * wall of KPIs.
 *
 * Two rules govern what gets in, and both exist to keep the bar trustworthy:
 *
 *   1. A missed poll is not a fault. `machineState` returns 'reconnecting'
 *      until a printer has genuinely stopped answering (see printer-poll-cache),
 *      and 'reconnecting' is deliberately NOT an attention item. Prusa's
 *      most-reported Connect complaint is false "Attention needed" alerts — a
 *      panel that cries wolf gets muted, and then the real fault is missed.
 *
 *   2. Only conditions the operator must ACT on. Bambu's Farm Manager collapses
 *      paused, offline and abnormally-stopped into one "Attention Needed"
 *      bucket, grouped by what the operator must do rather than by what
 *      technically went wrong. Same grouping here.
 *
 * Side-effect free and clock-injected so it can be unit-tested in isolation and
 * reused by the dashboard, the themes, and any future notification surface.
 */

/**
 * How many consecutive missed polls before a printer is called offline rather
 * than reconnecting. A CORE One takes 20-30s to answer after a power cycle and
 * the poll interval is 30s, so anything below 3 fires on healthy hardware.
 * Display and alerting are free to pass their own tolerance.
 */
const OFFLINE_AFTER_MISSED_POLLS = 3;

const DAY_MS = 86400000;

/** Local midnight for a Date/timestamp — Khayt stores due dates as 'YYYY-MM-DD' day strings. */
function startOfDay(now) {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

/** Parse a 'YYYY-MM-DD' day string at local midnight. Returns null if unparseable. */
function parseDay(s) {
  if (!s || typeof s !== 'string') return null;
  const ms = new Date(s + 'T00:00:00').getTime();
  return Number.isFinite(ms) ? ms : null;
}

/**
 * Resolve what a machine is actually doing, from the manual offline flag plus
 * whatever the poller last saw.
 *
 * This is the single definition of machine state. It was previously re-derived
 * in six places (the default dashboard and each of the five themes), which is
 * how the display and the alerting layer came to disagree about "offline".
 *
 * @param {object} machine      machine record; `isOffline` is the manual flag
 * @param {object} [entry]      machineStatusCache[machine.id], if any
 * @param {object} [opts]
 * @param {number} [opts.offlineAfter=3]  consecutive misses before 'offline'
 * @returns {'offline'|'error'|'reconnecting'|'printing'|'idle'|'unknown'}
 */
function machineState(machine, entry, opts) {
  const offlineAfter = (opts && +opts.offlineAfter > 0)
    ? +opts.offlineAfter
    : OFFLINE_AFTER_MISSED_POLLS;

  // The operator ticked "offline" by hand. Nothing the poller says overrides that.
  if (machine && machine.isOffline) return 'offline';
  if (!entry) {
    /* No reading. That means two different things and they must not share a word.
     *
     * A machine with NO printer API configured is genuinely idle as far as the
     * app can know — the shop tracks it by orders and there is nothing to poll.
     *
     * A machine that HAS one and no reading is a machine nobody has heard from:
     * polling has not run yet, or stopped. Calling that 'idle' is the app
     * asserting a fact it does not have, and it reads identically to a printer
     * that is genuinely free — which is the answer an owner acts on when
     * deciding whether a bed is available.
     */
    const api = machine && machine.printerApi;
    const polled = !!(api && api.type && api.type !== 'none');
    return polled ? 'unknown' : 'idle';
  }

  if (entry.error) {
    return (entry.consecutiveFailures || 0) >= offlineAfter ? 'offline' : 'reconnecting';
  }

  const st = String(entry.state || '').toLowerCase();
  if (st.includes('error')) return 'error';
  if (st.includes('print')) return 'printing';
  // Progress without a recognisable state string still means work in flight.
  if (Math.round(+entry.progress || 0) > 0) return 'printing';
  return 'idle';
}

/** Is this order still live work? Completed, quoted and voided orders can't be overdue. */
function isOpenOrder(o) {
  return !!o
    && o.status !== 'completed'
    && o.status !== 'quote'
    && !o.voidedAt;
}

/**
 * Everything demanding the operator's attention, most severe first.
 *
 * @param {object} input
 * @param {object[]} [input.machines]     machine records (already location-scoped)
 * @param {object[]} [input.orders]       order records (already location-scoped)
 * @param {object}   [input.statusCache]  machineStatusCache, keyed by machine id
 * @param {number}   [input.now]          injected clock; defaults to Date.now()
 * @param {number}   [input.offlineAfter] consecutive misses before 'offline'
 * @returns {{count:number, items:Array<object>}}
 *   items carry { severity:'crit'|'warn', kind, id, name, state?, dueDate?, daysLate? }
 */
function selectAttention(input) {
  const inp = input || {};
  const machines = Array.isArray(inp.machines) ? inp.machines : [];
  const orders = Array.isArray(inp.orders) ? inp.orders : [];
  const cache = inp.statusCache || {};
  const now = Number.isFinite(inp.now) ? inp.now : Date.now();
  const today = startOfDay(now);

  const items = [];

  // ── Machines that have stopped working ──────────────────────────────
  // 'reconnecting' is excluded by design: see rule 1 in the module header.
  for (const m of machines) {
    if (!m) continue;
    const state = machineState(m, cache[m.id], { offlineAfter: inp.offlineAfter });
    if (state !== 'offline' && state !== 'error') continue;
    items.push({
      severity: 'crit',
      kind: 'machine',
      id: m.id,
      name: m.name || '',
      state,
    });
  }

  /* ── A nozzle past the point the shop set ────────────────────────────
   *
   * `warn`, not `crit`: an overdue nozzle does not stop the printer, it makes
   * the parts wrong — which is worse to discover late and still not a reason to
   * outrank a machine that has actually gone down.
   *
   * This lives here because the dashboard's own maintenance section is markup
   * that no shipped theme renders: every theme replaces renderDashboard with
   * its own, and none of them draws `.dash-section`. So the nozzle warning
   * existed on the machine card and NOWHERE on any dashboard, which is the one
   * screen a shop leaves open. The attention bar is what the themes do render.
   *
   * Gated on `nozzleWear` being passed in: this module is pure and must not
   * reach for a global. A caller that does not supply it gets today's behaviour.
   */
  if (typeof inp.nozzleWear === 'function') {
    for (const m of machines) {
      if (!m || !(m.nozzle && m.nozzle.installedAt)) continue;
      let r = null;
      try { r = inp.nozzleWear(m); } catch (e) { r = null; }
      if (!r || !r.over) continue;
      items.push({
        severity: 'warn',
        kind: 'nozzle',
        id: m.id,
        name: m.name || '',
        grams: Math.round(r.wear),
        threshold: r.threshold,
      });
    }
  }

  /* ── Filament about to run out ───────────────────────────────────────
   *
   * `warn`, like the nozzle and for the same reason: a low spool does not stop
   * a printer that is already running, it stops the NEXT job — which is worse
   * to discover at the moment you want to start one, and still not a reason to
   * outrank a machine that has actually gone down.
   *
   * This was the last thing on the shop floor with a rule, a screen and no
   * place on the dashboard. `isLowStock` has decided what "low" means since the
   * banner, the row badge and the reorder list stopped disagreeing about it;
   * the one screen a shop leaves open was still not asking.
   *
   * Gated on `inventory` being passed in, and on `lowStock` being handed over,
   * exactly as `nozzleWear` is: this module is pure and must not reach for a
   * global, and a caller that supplies neither gets today's behaviour rather
   * than an error.
   */
  if (Array.isArray(inp.inventory) && typeof inp.lowStock === 'function') {
    const low = [];
    for (const item of inp.inventory) {
      if (!item) continue;
      let isLow = false;
      try { isLow = !!inp.lowStock(item); } catch (e) { isLow = false; }
      if (!isLow) continue;
      low.push({
        severity: 'warn',
        kind: 'stock',
        id: String(item.id || ''),
        name: item.material || '',
        variant: item.colourVariant || '',
        grams: Math.max(0, +item.weight || 0),
      });
    }
    // Emptiest first: the spool closest to stopping a job leads.
    low.sort((a, b) => (a.grams - b.grams) || String(a.id).localeCompare(String(b.id)));
    items.push(...low);
  }

  // ── Work that has missed its promised date ──────────────────────────
  const overdue = [];
  for (const o of orders) {
    if (!isOpenOrder(o)) continue;
    const due = parseDay(o.dueDate);
    if (due === null || due >= today) continue;
    overdue.push({
      severity: 'warn',
      kind: 'order',
      id: o.id,
      name: o.project || '',
      dueDate: o.dueDate,
      daysLate: Math.round((today - due) / DAY_MS),
    });
  }
  // Latest-promised-first: the order that has been waiting longest leads.
  overdue.sort((a, b) => (b.daysLate - a.daysLate) || String(a.id).localeCompare(String(b.id)));
  items.push(...overdue);

  return { count: items.length, items };
}

const api = {
  OFFLINE_AFTER_MISSED_POLLS,
  machineState,
  selectAttention,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAttention = api;

})();
