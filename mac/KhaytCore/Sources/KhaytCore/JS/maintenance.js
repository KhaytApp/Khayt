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

  let status = 'ok';
  let hoursRemaining = null;
  let daysRemaining = null;

  // --- Hours clock ---
  if (intervalHours > 0) {
    // Clamp so a backwards meter (deleted orders) never shows perpetually due.
    const usedHours = Math.max(0, num(machineHours, 0) - num(task.lastDoneHours, 0));
    hoursRemaining = intervalHours - usedHours;
    const hStatus = classify(usedHours, intervalHours);
    if (SEVERITY[hStatus] > SEVERITY[status]) status = hStatus;
  }

  // --- Date clock ---
  if (intervalDays > 0) {
    const lastMs = parseTime(task.lastDoneAt);
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

  return { status, hoursRemaining, daysRemaining };
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
function dueTasks(tasks, hoursByMachineId, now) {
  if (!Array.isArray(tasks)) return [];
  const byMachine = hoursByMachineId || {};
  const annotated = [];
  for (const task of tasks) {
    if (!task) continue;
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
    if (!job || job.machineId !== machineId || job.status !== 'completed') continue;
    hours += num(job.printTime, 0);
  }
  return Math.max(0, hours);
}

const api = {
  WARN_FRACTION,
  DUE_FRACTION,
  OVERDUE_FRACTION,
  taskStatus,
  dueTasks,
  markDone,
  hoursSinceService,
  hoursMeter,
};

// Dual export: CommonJS (node tests) + global (renderer <script>, like quote-followup).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytMaintenance = api;

})();
