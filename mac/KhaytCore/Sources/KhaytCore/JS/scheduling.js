'use strict';
(function () {

/**
 * Print-farm scheduling core (Khayt 3.0). See
 * docs/KHAYT-3.0-SCHEDULING-SPEC.md.
 *
 * A pure, deterministic, *assistive* scheduler: given a set of machines and
 * orders it PROPOSES which machine prints which job and in what queue order.
 * It computes a proposal only — nothing is written, nothing moves. The caller
 * (renderer) presents the proposal and applies it only on an explicit operator
 * action.
 *
 * Design rules (mirrors lib/sync-crypto.js style):
 *   - No `fs`, no requiring renderer files, no global state.
 *   - No `Date.now()` in the logic: the current time is injected as
 *     `opts.now` (epoch ms) so overdue/urgency is fully reproducible in tests.
 *   - Data in -> data out. Same inputs always yield the same proposal (stable
 *     sort, deterministic tie-breaks on machine/order id).
 *
 * Field shapes are reused (not imported) from the renderer:
 *   machine: { id, name, compatMaterials?[], nozzleDiameter?, isOffline?,
 *              targetHoursPerDay? }
 *   order:   { id, material?, dueDate?, priorityLevel?, printTime?, machineId?,
 *              status? }
 */

const PRIORITY_RANK = { urgent: 0, high: 1, normal: 2 };
const SCHEDULABLE_STATUSES = new Set(['pending', 'queued']);
const DAY_MS = 86400000;

/** Numeric print time in (fractional) hours; non-numeric/absent -> 0. */
function printTimeOf(order) {
  const n = +(order && order.printTime);
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** Priority rank for tie-breaking (urgent=0 .. normal=2; unknown -> normal). */
function priorityRank(order) {
  const lvl = order && order.priorityLevel;
  return Object.prototype.hasOwnProperty.call(PRIORITY_RANK, lvl)
    ? PRIORITY_RANK[lvl]
    : PRIORITY_RANK.normal;
}

/**
 * Urgency score, reproducing renderer/kanban.js `kanbanUrgencyScore`: overdue
 * is the most negative (most urgent), then days-to-due, with printTime a minor
 * tiebreak; missing dueDate falls into a large positive bucket. `now` is epoch
 * ms (start-of-day is derived from it) so the result is deterministic.
 *
 * @param {object} order
 * @param {number} now epoch ms representing "today"
 * @returns {number} lower = more urgent
 */
function urgencyScore(order, now) {
  const printT = printTimeOf(order);
  if (!order || !order.dueDate) return 10000 + printT;
  const today0 = new Date(now);
  today0.setHours(0, 0, 0, 0);
  const due = new Date(order.dueDate + 'T00:00:00');
  const diff = Math.round((due.getTime() - today0.getTime()) / DAY_MS);
  if (diff < 0) return diff - 1000;       // overdue: most negative = most urgent
  if (diff === 0) return 0;
  if (diff <= 3) return diff;
  return diff + printT * 0.01;
}

/**
 * Material-compatibility check. Reuses the renderer rule
 * (order-flows.js compat warning): a machine accepts a material when one of its
 * `compatMaterials` entries is a case-insensitive substring of the order
 * material. An empty/absent `compatMaterials` means "accepts anything"
 * (back-compat). An order with no material is accepted by any machine.
 *
 * @param {object} machine
 * @param {string} [material]
 * @returns {boolean}
 */
function machineAcceptsMaterial(machine, material) {
  const list = machine && machine.compatMaterials;
  if (!Array.isArray(list) || list.length === 0) return true;
  if (!material) return true;
  const m = String(material).toLowerCase();
  return list.some(c => c != null && m.includes(String(c).toLowerCase()));
}

/**
 * Nozzle compatibility (soft per spec): only excludes when the order declares a
 * required nozzle and the machine declares a different one. Absent on either
 * side -> compatible. Returns true when the pairing is acceptable.
 */
function nozzleOk(machine, order) {
  const required = order && +order.requiredNozzleMm;
  if (!Number.isFinite(required) || required <= 0) return true;
  const have = machine && +machine.nozzleDiameter;
  if (!Number.isFinite(have) || have <= 0) return true; // machine unconstrained
  return Math.abs(have - required) < 1e-9;
}

/**
 * Sum of printTime (hours) for orders already assigned to a machine. An order
 * counts as assigned when its `machineId` equals the machine id.
 *
 * @param {object} machine
 * @param {object[]} orders
 * @returns {number} total hours
 */
function machineLoadMins(machine, orders) {
  if (!machine || !Array.isArray(orders)) return 0;
  return orders.reduce(
    (sum, o) => (o && o.machineId === machine.id ? sum + printTimeOf(o) : sum),
    0
  );
}

/**
 * Hours a machine is booked OUT of action, from `now` forward.
 *
 * ── RECORDED SINCE 3.0 AND NEVER CONSULTED HERE ───────────────────────────
 *
 * `machine.downtimeBlocks` was read by a badge and a chart and by nothing that
 * plans work — so this scheduler would put a job on a printer the shop had
 * already booked out for a belt change, and say it was the earliest finish.
 *
 * ── WHY LOAD, AND NOT A CALENDAR ──────────────────────────────────────────
 *
 * This scheduler does not work in wall-clock times; it balances MINUTES OF
 * LOAD and picks the machine with the least. So a maintenance window is
 * expressed the way everything else here is expressed: as minutes that machine
 * cannot print in. A printer booked out for six hours looks six hours busier
 * and the work goes elsewhere, which is the behaviour a shop is asking for
 * when it records one.
 *
 * That is deliberately weaker than the band, which knows real times and can
 * say a job STARTS after a window. Making this calendar-aware is a different
 * scheduler; making it stop ignoring downtime is this.
 *
 * `horizonDays` bounds it, because a window booked for next year is not a
 * reason to avoid a machine today.
 *
 * ── HOURS, WHATEVER THE FIELD NAMES SAY ───────────────────────────────────
 *
 * `machineLoadMins` sums `printTimeOf`, which is documented as HOURS, and
 * `projectedFinishMins` is hours too — `test/scheduling.test.js` asserts it
 * comes to 2 for two one-hour jobs. Both names are wrong and are left alone;
 * they are a public shape other code reads. What matters here is that a figure
 * added to that load must be in the same unit, and returning minutes would
 * have made every maintenance window count SIXTY TIMES over.
 */
function downtimeHours(machine, now, horizonDays) {
  const blocks = Array.isArray(machine && machine.downtimeBlocks) ? machine.downtimeBlocks : [];
  if (!blocks.length) return 0;
  const from = Number.isFinite(now) ? now : Date.now();
  const to = from + Math.max(1, horizonDays) * DAY_MS;
  let total = 0;
  for (const b of blocks) {
    if (!b || !b.from || !b.to) continue;
    const bFrom = new Date(b.from).getTime();
    const bTo = new Date(b.to).getTime();
    if (!Number.isFinite(bFrom) || !Number.isFinite(bTo) || bTo <= bFrom) continue;
    const start = Math.max(from, bFrom);
    const end = Math.min(to, bTo);
    if (end > start) total += (end - start) / 3600000;
  }
  return total;
}

/** True when the order is an un-printed, schedulable job. */
function isSchedulable(order, includeAssigned) {
  if (!order) return false;
  const status = order.status == null ? 'pending' : order.status;
  if (!SCHEDULABLE_STATUSES.has(status)) return false;
  if (!includeAssigned && order.machineId) return false;
  return true;
}

/**
 * Propose machine assignments for un-printed orders. Pure and deterministic.
 *
 * Algorithm:
 *  (1) Consider only schedulable orders (status pending/queued; no machineId
 *      unless `opts.includeAssigned`).
 *  (2) Candidate machines per order = not offline AND material-compatible AND
 *      nozzle-ok.
 *  (3) Sort orders by urgency (overdue/sooner dueDate first), then priority,
 *      then order id (stable deterministic tiebreak).
 *  (4) Greedy load-balance: place each order on the candidate machine with the
 *      lowest projected cumulative finish time, seeded from machines'
 *      already-assigned printTime sums; append to that machine's queue.
 *  (5) Same-material batching: among candidates within a small tolerance of the
 *      best projected finish, prefer one already queued (in this proposal or by
 *      seed) with the same material, so identical-material jobs cluster without
 *      pushing past the lowest-finish tier.
 *
 * Orders with no candidate machine -> `unassignable` with a reason
 * ('all printers offline' when offline machines existed but none qualified,
 * else 'no compatible printer').
 *
 * @param {object[]} machines
 * @param {object[]} orders
 * @param {object} [opts] { now?: number (epoch ms), includeAssigned?: boolean,
 *                          batchToleranceMins?: number }
 * @returns {{ assignments: Array<{orderId,machineId,position,projectedFinishMins,reason}>,
 *             unassignable: Array<{orderId,reason}> }}
 */
function proposeSchedule(machines, orders, opts) {
  const options = opts || {};
  const now = Number.isFinite(options.now) ? options.now : 0;
  const includeAssigned = !!options.includeAssigned;
  // Tolerance (hours) within which batching may override pure load-balancing.
  /// How far ahead a maintenance window still counts against a machine. A
  /// window booked for next year is not a reason to avoid a printer today.
  const downtimeHorizonDays = Number.isFinite(options.downtimeHorizonDays)
    ? Math.max(1, options.downtimeHorizonDays) : 14;
  const batchTol = Number.isFinite(options.batchToleranceMins)
    ? options.batchToleranceMins
    : 0;

  const machineList = Array.isArray(machines) ? machines.filter(Boolean) : [];
  const orderList = Array.isArray(orders) ? orders.filter(Boolean) : [];

  const assignments = [];
  const unassignable = [];

  // Per-machine running state. Load is seeded with already-assigned printTime so
  // the proposal accounts for in-flight/queued work. `lastMaterial` tracks the
  // material at the tail of each machine's (seed + proposed) queue for batching.
  const state = new Map();
  for (const m of machineList) {
    // Work already on it, PLUS the hours it is booked out for. Both are hours
    // this machine cannot take new work in, and the pick below is "least
    // loaded" — so a printer down for a belt change stops being the obvious
    // answer, which is the entire point of recording one.
    const seedLoad = machineLoadMins(m, orderList)
      + downtimeHours(m, now, downtimeHorizonDays);
    let seedTailMaterial = null;
    if (seedLoad > 0) {
      // Last assigned order on this machine (input order = queue order seed).
      for (const o of orderList) {
        if (o.machineId === m.id && o.material) seedTailMaterial = o.material;
      }
    }
    state.set(m.id, { load: seedLoad, depth: 0, lastMaterial: seedTailMaterial });
  }

  // Step 1: schedulable set.
  const schedulable = orderList.filter(o => isSchedulable(o, includeAssigned));

  // Step 3: deterministic order — urgency, then priority, then id.
  const ordered = schedulable
    .map((o, i) => ({ o, i }))
    .sort((a, b) => {
      const ua = urgencyScore(a.o, now);
      const ub = urgencyScore(b.o, now);
      if (ua !== ub) return ua - ub;
      const pa = priorityRank(a.o);
      const pb = priorityRank(b.o);
      if (pa !== pb) return pa - pb;
      const ia = String(a.o.id);
      const ib = String(b.o.id);
      if (ia !== ib) return ia < ib ? -1 : 1;
      return a.i - b.i;
    })
    .map(x => x.o);

  // Step 4 + 5: greedy placement with same-material batching.
  for (const order of ordered) {
    // Step 2: candidate machines.
    const offlineExisted = machineList.some(m => m.isOffline);
    const candidates = machineList.filter(
      m => !m.isOffline
        && machineAcceptsMaterial(m, order.material)
        && nozzleOk(m, order)
    );

    if (candidates.length === 0) {
      const reason = offlineExisted && machineList.every(
        m => m.isOffline || machineAcceptsMaterial(m, order.material) && nozzleOk(m, order)
      )
        ? 'all printers offline'
        : 'no compatible printer';
      unassignable.push({ orderId: order.id, reason });
      continue;
    }

    // Lowest projected finish (current seeded/proposed load on that machine).
    // Deterministic tiebreak by machine id.
    let best = null;
    for (const m of candidates) {
      const st = state.get(m.id);
      if (
        best === null
        || st.load < best.load
        || (st.load === best.load && String(m.id) < String(best.machine.id))
      ) {
        best = { machine: m, load: st.load };
      }
    }

    // Step 5: same-material batching. Among candidates whose projected finish is
    // within `batchTol` of the best, prefer one whose queue tail is the same
    // material (clusters spool-identical jobs without crossing a deadline tier).
    let chosen = best;
    if (order.material) {
      let batchPick = null;
      for (const m of candidates) {
        const st = state.get(m.id);
        if (st.load > best.load + batchTol) continue;
        if (st.lastMaterial && st.lastMaterial === order.material) {
          if (
            batchPick === null
            || st.load < batchPick.load
            || (st.load === batchPick.load
              && String(m.id) < String(batchPick.machine.id))
          ) {
            batchPick = { machine: m, load: st.load };
          }
        }
      }
      if (batchPick) chosen = batchPick;
    }

    const st = state.get(chosen.machine.id);
    const position = st.depth;
    const projectedFinishMins = st.load + printTimeOf(order);

    let reason = 'lowest projected finish';
    if (chosen !== best) reason = 'batched with same material';
    else if (candidates.length === 1) reason = 'only compatible printer';

    assignments.push({
      orderId: order.id,
      machineId: chosen.machine.id,
      position,
      projectedFinishMins,
      reason,
    });

    // Advance that machine's running state.
    st.load = projectedFinishMins;
    st.depth = position + 1;
    if (order.material) st.lastMaterial = order.material;
  }

  return { assignments, unassignable };
}

const api = {
  proposeSchedule,
  machineLoadMins,
  downtimeHours,
  // exposed for reuse / tests
  urgencyScore,
  machineAcceptsMaterial,
  nozzleOk,
};

// Dual export: CommonJS (node tests) + global (renderer <script>, like quote-followup).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytScheduling = api;

})();
