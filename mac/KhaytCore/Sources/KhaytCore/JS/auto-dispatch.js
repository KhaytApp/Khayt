'use strict';
/**
 * Which job goes on which printer next.
 *
 * Every print-farm tool worth the name answers this and Khayt did not: it could
 * upload a file and start a print, and it could tell you the queue and which
 * machines were idle — but choosing between them was a person standing in the
 * shop doing it in their head. With three machines that is fine. With twelve it
 * is where the idle hours come from.
 *
 * ── IT PROPOSES. IT DOES NOT PRESS THE BUTTON ────────────────────────────────
 *
 * THE BED IS THE WHOLE PROBLEM. None of the printers Khayt talks to can clear
 * their own plate. An "idle" printer is very often an idle printer with
 * yesterday's part still bolted to it, and starting a job onto that is not a
 * wasted print — it is a nozzle dragged through solid PLA at speed.
 *
 * So a machine is only ever offered when somebody has said the bed is clear
 * SINCE ITS LAST PRINT. `bedClearedAt` is that sentence, and a machine without
 * one is reported as waiting on a person rather than quietly skipped — a farm
 * tool that silently stops offering a printer is a farm tool nobody trusts.
 *
 * Everything here is a proposal with a reason attached. The host decides
 * whether a person accepts each one or whether the shop has turned that
 * confirmation off; this module never reaches a socket.
 *
 * Pure: no sockets, no clock — `now` is passed in.
 */
(function (global) {

  /** Printer states that mean "not printing, and not in trouble". */
  const IDLE_STATES = ['idle', 'ready', 'standby', 'operational', 'finished', 'complete', 'cancelled'];

  /** A job Khayt would dispatch: agreed, not started, not stopped. */
  const DISPATCHABLE = ['pending'];

  function text(v) { return v == null ? '' : String(v); }
  function lower(v) { return text(v).trim().toLowerCase(); }

  /**
   * Why a machine cannot take work right now, or null when it can.
   *
   * The reasons are KEYS, not sentences: this module is loaded by three hosts
   * in nine languages, and a rule that returns English is a rule that has
   * decided what language the shop reads.
   */
  function machineBlocked(machine, live, options = {}) {
    const api = machine && machine.printerApi;
    if (!api || !api.type || api.type === 'none') return 'ad.no_printer';
    const status = live || {};
    if (status.error) return 'ad.printer_error';
    const state = lower(status.state);
    // Nothing heard from it at all. Not an error, and not something to start a
    // print on either — a machine that has never answered may not be on.
    if (!state) return 'ad.no_reading';
    if (!IDLE_STATES.includes(state)) return 'ad.busy';
    if (options.paused && options.paused[machine.id]) return 'ad.held';

    // ── THE BED ──────────────────────────────────────────────────────────
    //
    // Idle is not empty. A finished print sits on the plate until somebody
    // takes it off, and no printer here can do that for itself.
    const cleared = Date.parse(text(machine.bedClearedAt));
    const finished = Date.parse(text(status.lastFinishedAt || machine.lastFinishedAt));
    if (!Number.isFinite(cleared)) return 'ad.bed_unknown';
    if (Number.isFinite(finished) && cleared < finished) return 'ad.bed_not_clear';
    return null;
  }

  /** Every material a job needs, lower-cased and deduplicated. */
  function materialsOf(order) {
    const parts = Array.isArray(order && order.parts) ? order.parts : [];
    const out = new Set();
    for (const part of parts) {
      const m = lower(part && part.material);
      if (m) out.add(m);
    }
    const own = lower(order && order.material);
    if (own) out.add(own);
    return [...out];
  }

  /** How many distinct colours the job asks for. */
  function coloursOf(order) {
    const parts = Array.isArray(order && order.parts) ? order.parts : [];
    const out = new Set();
    for (const part of parts) {
      const c = lower(part && part.colour);
      if (c) out.add(c);
    }
    return out.size || 1;
  }

  /**
   * Why this machine cannot take this job, or null.
   *
   * A machine that lists no compatible materials is NOT refused. That field is
   * frequently empty on a shop's own records, and refusing every such machine
   * would make the whole feature do nothing on a real book — which is how a
   * correct rule gets switched off. Unknown is carried out as a caveat instead.
   */
  function jobBlocked(order, machine) {
    const needs = materialsOf(order);
    const can = Array.isArray(machine && machine.compatMaterials)
      ? machine.compatMaterials.map(lower).filter(Boolean) : [];
    if (can.length && needs.length && !needs.every((m) => can.includes(m))) {
      return 'ad.material';
    }
    // The colours a machine HAS, which since the catalog fix is what it prints
    // as sold rather than what it could reach with an accessory.
    const colours = Number(machine && machine.maxColors) || 1;
    if (coloursOf(order) > colours) return 'ad.colours';
    return null;
  }

  /**
   * The order work is taken in. The board's order, deliberately: a shop that
   * sees one sequence on screen and another in the dispatcher has two queues.
   */
  function queueOrder(a, b) {
    if (!!a.priority !== !!b.priority) return a.priority ? -1 : 1;
    const da = Date.parse(text(a.dueDate)), db = Date.parse(text(b.dueDate));
    const hasA = Number.isFinite(da), hasB = Number.isFinite(db);
    if (hasA && hasB && da !== db) return da - db;
    if (hasA !== hasB) return hasA ? -1 : 1;
    const ca = Date.parse(text(a.date)), cb = Date.parse(text(b.date));
    if (Number.isFinite(ca) && Number.isFinite(cb) && ca !== cb) return ca - cb;
    return text(a.id).localeCompare(text(b.id));
  }

  /**
   * Prefer the machine that last printed this material.
   *
   * 3DPrintOps names minimising changeovers as one of the five things a farm
   * tool is for, and a changeover is a person unloading a spool. Khayt does not
   * record what is loaded in a machine right now — so the best available signal
   * is what it printed last, which is very often still in it.
   *
   * @returns {number} lower sorts first
   */
  function changeoverCost(machine, order, lastMaterialByMachine) {
    const needs = materialsOf(order);
    if (!needs.length) return 1;
    const loaded = lower(lastMaterialByMachine && lastMaterialByMachine[machine.id]);
    if (!loaded) return 1;                      // unknown: neither reward nor punish
    return needs.length === 1 && needs[0] === loaded ? 0 : 2;
  }

  /**
   * What to run next, and where.
   *
   * @param {object} input
   *   orders    every order; the dispatchable ones are chosen here
   *   machines  the fleet
   *   live      `{ [machineId]: status }` from the host's poller
   *   lastMaterialByMachine  `{ [machineId]: material }`, for changeovers
   *   paused    `{ [machineId]: true }` for machines the shop has held back
   * @returns {{proposals: Array, idle: Array, waiting: Array}}
   *   proposals `{ orderId, machineId, reason, caveats }` — one per machine
   *   idle      machines that could take work and were given none
   *   waiting   `{ machineId, blocked }` — why a machine was not offered, so a
   *             screen can say "bed not clear" rather than showing nothing
   */
  function plan(input) {
    const orders = Array.isArray(input && input.orders) ? input.orders : [];
    const machines = Array.isArray(input && input.machines) ? input.machines : [];
    const live = (input && input.live) || {};
    const lastMaterial = (input && input.lastMaterialByMachine) || {};

    const waiting = [];
    const free = [];
    for (const machine of machines) {
      const blocked = machineBlocked(machine, live[machine.id], input || {});
      if (blocked) waiting.push({ machineId: machine.id, blocked });
      else free.push(machine);
    }

    const queue = orders
      .filter((o) => o && DISPATCHABLE.includes(lower(o.status)))
      // Work already sent somewhere is not waiting for a machine.
      .filter((o) => !text(o.machineId))
      .sort(queueOrder);

    const proposals = [];
    const takenMachines = new Set();
    for (const order of queue) {
      let best = null;
      for (const machine of free) {
        if (takenMachines.has(machine.id)) continue;
        const blocked = jobBlocked(order, machine);
        if (blocked) continue;
        const cost = changeoverCost(machine, order, lastMaterial);
        if (!best || cost < best.cost) best = { machine, cost };
      }
      if (!best) continue;
      takenMachines.add(best.machine.id);
      const caveats = [];
      if (!Array.isArray(best.machine.compatMaterials) || !best.machine.compatMaterials.length) {
        caveats.push('ad.materials_unknown');
      }
      proposals.push({
        orderId: order.id,
        machineId: best.machine.id,
        reason: best.cost === 0 ? 'ad.same_material' : 'ad.next_in_queue',
        caveats,
      });
      if (takenMachines.size >= free.length) break;
    }

    return {
      proposals,
      idle: free.filter((m) => !takenMachines.has(m.id)).map((m) => m.id),
      waiting,
    };
  }

  const api = {
    plan, machineBlocked, jobBlocked, materialsOf, coloursOf, queueOrder,
    changeoverCost, IDLE_STATES, DISPATCHABLE,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytAutoDispatch = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
