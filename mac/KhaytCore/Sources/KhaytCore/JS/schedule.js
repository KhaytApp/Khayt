/**
 * Production scheduling — turn the active queue into per-machine timelines with
 * completion ETAs, so the schedule board can show "ready by <date>" per job and
 * flag jobs that will miss their due date. Pure (no DOM / no clock): the caller
 * passes the jobs, the working hours/day, and an explicit start date, so the
 * math is deterministic and unit-testable.
 *
 * Model: per machine, jobs run sequentially in the given order; cumulative print
 * hours convert to calendar days at `dailyHours` per day (ceil), giving each
 * job's ready date. Unassigned jobs share a virtual lane.
 */
(function (global) {
  const UNASSIGNED = '__unassigned__';

  function addDays(iso, days) {
    // Parse + advance in UTC so the result is timezone-independent (a local-time
    // Date round-tripped through toISOString() can slip a day in +UTC offsets).
    const d = new Date(iso + 'T00:00:00Z');
    if (Number.isNaN(d.getTime())) return iso;
    d.setUTCDate(d.getUTCDate() + days);
    return d.toISOString().slice(0, 10);
  }

  /**
   * @param {object} input
   * @param {Array<{id,machineId?,hours,dueDate?,project?,status?}>} input.jobs queue order preserved per machine
   * @param {number} input.dailyHours productive hours per day (clamped ≥1)
   * @param {string} input.startDate  YYYY-MM-DD the schedule starts from
   * @returns {{ machines: Array, generatedAt: string }}
   */
  function computeSchedule(input) {
    input = input || {};
    const jobs = Array.isArray(input.jobs) ? input.jobs : [];
    const daily = Math.max(1, +input.dailyHours || 8);
    const start = input.startDate || '1970-01-01';

    const byMachine = new Map();
    for (const j of jobs) {
      const mid = j.machineId || UNASSIGNED;
      if (!byMachine.has(mid)) byMachine.set(mid, []);
      byMachine.get(mid).push(j);
    }

    const machines = [];
    for (const [machineId, list] of byMachine) {
      let cumHours = 0;
      let lateCount = 0;
      const out = list.map((j) => {
        const hours = Math.max(0, +j.hours || 0);
        const startDay = Math.floor(cumHours / daily);
        cumHours += hours;
        // Days elapsed once this job finishes (a >0h job always lands on ≥ day 1).
        const endDay = hours > 0 ? Math.max(1, Math.ceil(cumHours / daily)) : Math.ceil(cumHours / daily);
        const etaDate = addDays(start, endDay);
        const late = !!(j.dueDate && etaDate > j.dueDate);
        if (late) lateCount++;
        return { id: j.id, project: j.project || '', status: j.status || '', hours, startDay, etaDate, dueDate: j.dueDate || '', late };
      });
      machines.push({
        machineId, unassigned: machineId === UNASSIGNED,
        jobs: out,
        totalHours: Math.round(cumHours * 10) / 10,
        days: Math.ceil(cumHours / daily),
        readyDate: out.length ? out[out.length - 1].etaDate : start,
        lateCount,
      });
    }
    // Busiest machine first; unassigned last.
    machines.sort((a, b) => (a.unassigned - b.unassigned) || (b.totalHours - a.totalHours));
    return { machines, generatedAt: start, dailyHours: daily };
  }

  const api = { computeSchedule, UNASSIGNED };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytSchedule = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
