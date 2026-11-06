'use strict';
(function () {

/**
 * Preventive-maintenance scheduler core. See docs/KHAYT-3.0-MAINTENANCE-SPEC.md.
 *
 * Pure, side-effect-free logic for recurring per-machine maintenance tasks with
 * hours-based and/or date-based intervals. It generalizes the single
 * serviceInterval/lastServiceHours pair in renderer/machines.js into N named
 * tasks, reusing the same 0.9 warn-threshold pattern as machineServiceStatus().
 *
 * Run-hours are NEVER stored on the task; callers pass the current
 * machineHoursMeter value in. Date logic takes `now` as a parameter so the
 * module stays deterministic and testable (no fs, no clock, no renderer deps).
 *
 *   MaintTask = {
 *     id,            // task identifier
 *     machineId,     // FK -> machine
 *     name,          // label, e.g. "Replace nozzle"
 *     intervalHours, // > 0 -> hours-driven; 0/undefined -> not hours-driven
 *     intervalDays,  // > 0 -> date-driven; 0/undefined -> not date-driven
 *     lastDoneHours, // machineHoursMeter snapshot at last completion (default 0)
 *     lastDoneAt,    // ISO date/time of last completion (date clock)
 *     // Optional, all added by care plans (lib/care-plans.js); older records
 *     // and the other app's writers leave them out and nothing changes:
 *     careTaskId,    // catalogue task id ('nozzle', 'wiper', ...)
 *     carePlanId,    // the plan it came from ('bambu-p1', ...)
 *     parts,         // [{ id, qty }] parts the task consumes (care-plans PARTS ids)
 *     inspectedAt,   // ISO: inspected and found NOT NEEDED (see deferTask)
 *     inspectedHours,// meter at that inspection
 *     deferUntilHours, // meter reading the task is pushed out to
 *     deferUntilAt,  // ISO date the task is pushed out to
 *   }
 *
 * Thresholds (fraction of the active interval the elapsed amount has reached):
 *   ok      : used <  0.9 * interval
 *   warning : used >= 0.9 * interval
 *   due     : used >= 1.0 * interval
 *   overdue : used >= 1.5 * interval
 * These mirror machineServiceStatus()'s due/warning split, extended with an
 * "overdue" tier for tasks left long past their interval.
 */

const WARN_FRACTION = 0.9;
const DUE_FRACTION = 1.0;
const OVERDUE_FRACTION = 1.5;

const MS_PER_DAY = 24 * 60 * 60 * 1000;

// Status ordering, most-urgent first, for comparison and sorting.
const SEVERITY = { overdue: 3, due: 2, warning: 1, ok: 0 };

/** Classify a used/interval ratio into a status tier. */
function classify(used, interval) {
  if (!(interval > 0)) return 'ok';
  if (used >= OVERDUE_FRACTION * interval) return 'overdue';
  if (used >= DUE_FRACTION * interval) return 'due';
  if (used >= WARN_FRACTION * interval) return 'warning';
  return 'ok';
}

/** Coerce a value to a finite number, or fall back. */
function num(v, fallback = 0) {
  const n = +v;
  return Number.isFinite(n) ? n : fallback;
}

/** Parse an ISO date/time to epoch ms, or null if unparseable/missing. */
function parseTime(iso) {
  if (!iso) return null;
  const t = new Date(iso).getTime();
  return Number.isFinite(t) ? t : null;
}

/**
 * Compute the status of a single maintenance task.
 *
 * @param {object} task - MaintTask (see module docs).
 * @param {number} machineHours - current machineHoursMeter for task.machineId.
 * @param {string|number|Date} [now] - reference time for the date clock.
 * @returns {{ status: 'ok'|'warning'|'due'|'overdue',
 *             hoursRemaining: number|null, daysRemaining: number|null }}
 *   hoursRemaining/daysRemaining are null when that clock is inactive; they may
 *   go negative once the interval has been exceeded.
 *   When both clocks are active the MORE-urgent status wins.
 */
function taskStatus(task, machineHours, now) {
  task = task || {};
  const intervalHours = num(task.intervalHours, 0);
  const intervalDays = num(task.intervalDays, 0);
  const deferral = activeDeferral(task);

  let status = 'ok';
  let hoursRemaining = null;
  let daysRemaining = null;

  // --- Hours clock ---
  if (intervalHours > 0) {
    // A deferral moves the baseline so the task falls due at `deferUntilHours`
    // and never earlier than the interval already said.
    let baseHours = num(task.lastDoneHours, 0);
    if (deferral && deferral.untilHours != null) {
      baseHours = Math.max(baseHours, deferral.untilHours - intervalHours);
    }
    // Clamp so a backwards meter (deleted orders) never shows perpetually due.
    const usedHours = Math.max(0, num(machineHours, 0) - baseHours);
    hoursRemaining = intervalHours - usedHours;
    const hStatus = classify(usedHours, intervalHours);
    if (SEVERITY[hStatus] > SEVERITY[status]) status = hStatus;
  }

  // --- Date clock ---
  if (intervalDays > 0) {
    let lastMs = parseTime(task.lastDoneAt);
    if (deferral && deferral.untilMs != null) {
      const moved = deferral.untilMs - intervalDays * MS_PER_DAY;
      lastMs = lastMs == null ? moved : Math.max(lastMs, moved);
    }
    const nowMs = parseTime(now) ?? (now instanceof Date ? now.getTime() : Date.now());
    if (lastMs != null && Number.isFinite(nowMs)) {
      const usedDays = Math.max(0, (nowMs - lastMs) / MS_PER_DAY);
      daysRemaining = intervalDays - usedDays;
      const dStatus = classify(usedDays, intervalDays);
      if (SEVERITY[dStatus] > SEVERITY[status]) status = dStatus;
    } else {
      // No baseline date yet: report the full interval remaining, stay ok.
      daysRemaining = intervalDays;
    }
  }

  return { status, hoursRemaining, daysRemaining, deferred: !!deferral };
}

/**
 * The deferral a task carries, if it still applies.
 *
 * "Inspected, not needed" is recorded on the task as `inspectedAt` (when the
 * shop looked), `inspectedHours` (the meter then), and how far the task was
 * pushed: `deferUntilHours` (meter reading) and/or `deferUntilAt` (ISO date).
 * A later completion supersedes it — `markDone` writes a `lastDoneAt` after
 * `inspectedAt`, and this then returns null — so markDone needs no new fields.
 *
 * @returns {{ untilHours: number|null, untilMs: number|null }|null}
 */
function activeDeferral(task) {
  if (!task) return null;
  const inspected = parseTime(task.inspectedAt);
  if (inspected == null) return null;
  const done = parseTime(task.lastDoneAt);
  if (done != null && done >= inspected) return null;
  const h = task.deferUntilHours;
  const untilHours = h != null && h !== '' && Number.isFinite(+h) ? +h : null;
  const untilMs = parseTime(task.deferUntilAt);
  if (untilHours == null && untilMs == null) return null;
  return { untilHours, untilMs };
}

/** Default push for "Not needed": half an interval, counted from the inspection. */
const DEFER_FRACTION = 0.5;

/**
 * Build the patch for "inspected — not needed": the shop looked at the part
 * and pushed the task out without replacing anything. Does NOT mutate the
 * task, and writes none of markDone's fields: the work was not done, and the
 * service log is not written either.
 *
 * The push is measured from the inspection (`machineHours`, `nowIso`):
 * `opts.hours` / `opts.days` when given, otherwise `opts.fraction` (default
 * 0.5, capped at 1) of each active interval. It never pulls a task EARLIER
 * than it was already due.
 *
 * @param {object} task
 * @param {number} machineHours - meter now
 * @param {string} nowIso
 * @param {{ fraction?: number, hours?: number, days?: number }} [opts]
 * @returns {{ inspectedAt: string, inspectedHours: number,
 *             deferUntilHours: number|null, deferUntilAt: string|null }}
 */
function deferTask(task, machineHours, nowIso, opts) {
  task = task || {};
  opts = opts || {};
  const meter = Math.max(0, num(machineHours, 0));
  const fraction = Math.min(1, Math.max(0, num(opts.fraction, DEFER_FRACTION)));
  const intervalHours = num(task.intervalHours, 0);
  const intervalDays = num(task.intervalDays, 0);
  const nowMs = parseTime(nowIso);
  const st = taskStatus(task, meter, nowIso);

  let deferUntilHours = null;
  if (intervalHours > 0) {
    const push = opts.hours != null ? Math.min(intervalHours, Math.max(0, num(opts.hours, 0)))
      : fraction * intervalHours;
    const wasDueAt = meter + num(st.hoursRemaining, 0);
    deferUntilHours = Math.max(meter + push, wasDueAt);
  }
  let deferUntilAt = null;
  if (intervalDays > 0 && nowMs != null) {
    const push = opts.days != null ? Math.min(intervalDays, Math.max(0, num(opts.days, 0)))
      : fraction * intervalDays;
    const wasDueMs = nowMs + num(st.daysRemaining, 0) * MS_PER_DAY;
    deferUntilAt = new Date(Math.max(nowMs + push * MS_PER_DAY, wasDueMs)).toISOString();
  }
  return { inspectedAt: nowIso, inspectedHours: meter, deferUntilHours, deferUntilAt };
}

/**
 * Average print-hours per day on one machine, from the completed jobs that
 * finished inside the window ending at `now`. The same jobs `hoursMeter`
 * counts (completed or delivered); dated by `completedAt`, else `date`.
 *
 * A machine whose first finished job is newer than the window is averaged
 * over the days since that job (at least one), so a printer bought last week
 * is not read as idle for the other three.
 *
 * @param {object[]} jobs
 * @param {string} machineId
 * @param {string|number|Date} now
 * @param {number} [windowDays=30]
 * @returns {number} hours per day, never negative
 */
function hoursPerDay(jobs, machineId, now, windowDays) {
  if (!Array.isArray(jobs)) return 0;
  const win = num(windowDays, 30) > 0 ? num(windowDays, 30) : 30;
  const nowMs = parseTime(now) ?? (now instanceof Date ? now.getTime() : null);
  if (nowMs == null) return 0;
  const start = nowMs - win * MS_PER_DAY;
  let hours = 0;
  let first = null;
  for (const job of jobs) {
    if (!job || job.machineId !== machineId || (job.status !== 'completed' && job.status !== 'delivered')) continue;
    const at = parseTime(job.completedAt || job.date);
    if (at == null || at > nowMs) continue;
    if (first == null || at < first) first = at;
    if (at > start) hours += Math.max(0, num(job.printTime, 0));
  }
  if (first == null) return 0;
  const days = first > start ? Math.max(1, (nowMs - first) / MS_PER_DAY) : win;
  return hours / days;
}

/**
 * When a task is projected to fall due, from the real meter and the rate the
 * machine has been running at. Whichever clock comes first wins.
 *
 * @param {object} task
 * @param {number} meter - hoursMeter for the task's machine
 * @param {number} rate - hoursPerDay for the machine
 * @param {string|number|Date} now
 * @returns {{ dueAt: string|null, dueMs: number|null, clock: 'hours'|'days'|null,
 *             status: string, deferred: boolean }}
 *   dueAt is null when nothing can be projected: an hours-only task on a
 *   machine with no recent jobs. A task already due projects to `now`.
 */
function projectDue(task, meter, rate, now) {
  const nowMs = parseTime(now) ?? (now instanceof Date ? now.getTime() : Date.now());
  const st = taskStatus(task, meter, nowMs);
  let dueMs = null;
  let clock = null;
  if (st.hoursRemaining != null) {
    if (st.hoursRemaining <= 0) { dueMs = nowMs; clock = 'hours'; }
    else if (num(rate, 0) > 0) { dueMs = nowMs + (st.hoursRemaining / rate) * MS_PER_DAY; clock = 'hours'; }
  }
  if (st.daysRemaining != null) {
    const d = nowMs + Math.max(0, st.daysRemaining) * MS_PER_DAY;
    if (dueMs == null || d < dueMs) { dueMs = d; clock = 'days'; }
  }
  return {
    dueAt: dueMs == null ? null : new Date(dueMs).toISOString(),
    dueMs, clock, status: st.status, deferred: st.deferred,
  };
}

/**
 * Filter tasks to those needing attention (warning/due/overdue), annotate each
 * with its computed status fields, and sort most-urgent first.
 *
 * @param {object[]} tasks - array of MaintTask.
 * @param {Object<string, number>} hoursByMachineId - meter value per machine.
 * @param {string|number|Date} [now] - reference time for the date clock.
 * @returns {object[]} shallow copies of the qualifying tasks, each extended with
 *   { status, hoursRemaining, daysRemaining }, ordered overdue -> due -> warning.
 */
function dueTasks(tasks, hoursByMachineId, now, machines) {
  if (!Array.isArray(tasks)) return [];
  const byMachine = hoursByMachineId || {};
  // With the machine list: a task for a retired printer, or one deleted, is
  // never due again — a day-interval clean would otherwise come due forever.
  const live = Array.isArray(machines)
    ? new Set(machines.filter((m) => m && m.id != null && m.status !== 'retired'
        && !(m.retiredAt && String(m.retiredAt).trim())).map((m) => String(m.id)))
    : null;
  const annotated = [];
  for (const task of tasks) {
    if (!task) continue;
    if (live && task.machineId != null && !live.has(String(task.machineId))) continue;
    const hours = num(byMachine[task.machineId], 0);
    const st = taskStatus(task, hours, now);
    if (st.status === 'ok') continue;
    annotated.push({ ...task, ...st });
  }
  annotated.sort((a, b) => {
    const sev = SEVERITY[b.status] - SEVERITY[a.status];
    if (sev !== 0) return sev;
    // Tie-break: smaller remaining (more past-due) first, ignoring inactive clocks.
    return remainingFraction(a) - remainingFraction(b);
  });
  return annotated;
}

/** Most-overdue clock's remaining fraction, for stable urgency tie-breaking. */
function remainingFraction(t) {
  const vals = [];
  if (t.hoursRemaining != null && t.intervalHours > 0) vals.push(t.hoursRemaining / t.intervalHours);
  if (t.daysRemaining != null && t.intervalDays > 0) vals.push(t.daysRemaining / t.intervalDays);
  return vals.length ? Math.min(...vals) : 0;
}

/**
 * Build the patch applied to a task when it is marked done. Does NOT mutate the
 * input; the caller merges the patch and writes a machMaintLog entry separately.
 *
 * @param {object} task - the task being completed (read only).
 * @param {number} machineHours - current machineHoursMeter snapshot to record.
 * @param {string} nowIso - ISO timestamp of completion.
 * @returns {{ lastDoneHours: number, lastDoneAt: string }}
 */
function markDone(task, machineHours, nowIso) {
  return {
    lastDoneHours: num(machineHours, 0),
    lastDoneAt: nowIso,
  };
}

/**
 * Hours run since a machine was last serviced.
 *
 * The two numbers this used to subtract are not on the same scale. The machine editor
 * labels its field "Hours at last service", so an owner adding a printer that arrived
 * with 200 hours on it types 200 — a reading off the PRINTER's own clock. `totalHours`
 * is what this app has logged, and that starts at zero on the day the printer is added.
 *
 * `totalHours - lastServiceHours` therefore went negative, and the machine card read
 * "-200.0h since service". Worse than ugly: the figure never climbed to the interval, so
 * the service reminder for that printer could never fire at all.
 *
 * When the app recorded the service itself it also knows WHEN, and that is the reliable
 * answer — hours run since that moment, summed from the jobs finished after it, on
 * whatever scale the owner's field happens to be. Falling back to the difference is only
 * for machines whose figure was typed in and never serviced through the app, and it is
 * floored at zero: an owner saying the clock read more than this app has ever logged is
 * telling us nothing has run since.
 *
 * @param {{ totalHours?: number, lastServiceHours?: number, lastServiceAt?: string|null,
 *           jobs?: Array<{ printTime?: number, completedAt?: string, date?: string }> }} input
 * @returns {number} hours since the last service, never negative
 */
function hoursSinceService(input = {}) {
  const totalHours = num(input.totalHours, 0);
  const lastServiceAt = input.lastServiceAt ? Date.parse(input.lastServiceAt) : NaN;

  if (Number.isFinite(lastServiceAt)) {
    const jobs = Array.isArray(input.jobs) ? input.jobs : [];
    let hours = 0;
    for (const job of jobs) {
      if (!job) continue;
      // completedAt is when the job actually finished; `date` is the day it was logged,
      // and is all an older record carries.
      const at = Date.parse(job.completedAt || job.date || '');
      if (Number.isFinite(at) && at >= lastServiceAt) hours += num(job.printTime, 0);
    }
    return hours;
  }

  return Math.max(0, totalHours - num(input.lastServiceHours, 0));
}

/**
 * Hours a machine has run, as this app has logged them.
 *
 * Every maintenance figure is measured against this number, so it cannot live
 * in one host's renderer while another host guesses at it. It was defined
 * inline in `renderer/machines.js`; the Mac app needed the same answer, and a
 * second implementation of "which jobs count" is a second answer to when a
 * nozzle is due.
 *
 * Only completed jobs count. A cancelled print consumed some hours in reality,
 * but the log has no honest figure for how many, and counting its full
 * estimate would bring services forward on the machines that fail most.
 *
 * @param {Array<{machineId?: string, status?: string, printTime?: number}>} jobs
 * @param {string} machineId
 * @returns {number} hours, never negative
 */
function hoursMeter(jobs, machineId) {
  if (!Array.isArray(jobs)) return 0;
  let hours = 0;
  for (const job of jobs) {
    // Finished by either spelling: a legacy `delivered` job ran the machine too.
    if (!job || job.machineId !== machineId || (job.status !== 'completed' && job.status !== 'delivered')) continue;
    hours += num(job.printTime, 0);
  }
  return Math.max(0, hours);
}

/**
 * Tasks a new shop can start from instead of a blank form (PrintTender ships 58;
 * these are the dozen nearly every shop needs). Ids, not words: each app names
 * them in the shop's language (the Mac as `mac.mt_t_<id>`). The intervals are
 * STARTING POINTS a shop is told to adjust to its manufacturer's manual — a
 * maker's number always beats this list.
 *
 * `kinds` is the machine kind it applies to (lib/machine-kinds.js).
 */
const STARTER_TASKS = Object.freeze([
  { id: 'plate',     kinds: ['fdm'],   intervalHours: 50,   intervalDays: 0 },
  { id: 'belts',     kinds: ['fdm'],   intervalHours: 200,  intervalDays: 30 },
  { id: 'rods',      kinds: ['fdm'],   intervalHours: 200,  intervalDays: 90 },
  { id: 'leadscrew', kinds: ['fdm'],   intervalHours: 300,  intervalDays: 90 },
  { id: 'extruder',  kinds: ['fdm'],   intervalHours: 200,  intervalDays: 0 },
  { id: 'nozzle',    kinds: ['fdm'],   intervalHours: 500,  intervalDays: 0 },
  { id: 'ptfe',      kinds: ['fdm'],   intervalHours: 1000, intervalDays: 180 },
  { id: 'fans',      kinds: ['fdm'],   intervalHours: 300,  intervalDays: 90 },
  { id: 'wiring',    kinds: ['fdm', 'resin'], intervalHours: 0, intervalDays: 90 },
  { id: 'filter',    kinds: ['fdm', 'resin'], intervalHours: 0, intervalDays: 180 },
  { id: 'fep',       kinds: ['resin'], intervalHours: 100,  intervalDays: 0 },
  { id: 'vat',       kinds: ['resin'], intervalHours: 0,    intervalDays: 7 },
  { id: 'ipa',       kinds: ['resin'], intervalHours: 0,    intervalDays: 14 },
]);

/** The starter tasks for a machine of `kind` (unknown kinds read as fdm). */
function starterTasks(kind) {
  const k = String(kind || 'fdm').trim().toLowerCase() || 'fdm';
  return STARTER_TASKS.filter((t) => t.kinds.includes(k)).map((t) => ({
    id: t.id, intervalHours: t.intervalHours, intervalDays: t.intervalDays,
  }));
}

const api = {
  STARTER_TASKS,
  starterTasks,
  WARN_FRACTION,
  DUE_FRACTION,
  OVERDUE_FRACTION,
  taskStatus,
  dueTasks,
  markDone,
  deferTask,
  activeDeferral,
  DEFER_FRACTION,
  hoursPerDay,
  projectDue,
  hoursSinceService,
  hoursMeter,
};

// Dual export: CommonJS (node tests) + global (renderer <script>, like quote-followup).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytMaintenance = api;

})();
