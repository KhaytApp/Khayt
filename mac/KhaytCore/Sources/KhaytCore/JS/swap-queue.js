'use strict';
/**
 * Run one machine's waiting jobs in an order that changes spools less often
 * (KhaytSwapQueue).
 *
 * ── WHAT A "SWAP" IS HERE ─────────────────────────────────────────────────
 *
 * The shop's printer is a Snapmaker U1: four toolheads, one spool on each. It
 * has no purge tower, so the colour changes INSIDE a print (the file's own
 * `swapCount`) cost the same whichever order the jobs run in, and this module
 * does not count them. What the order DOES change is how often somebody has to
 * walk up and put a different spool on a head between two jobs. That is a
 * swap: one head, one spool out, one spool in. Filling an empty head counts
 * too — it is the same walk and the same load.
 *
 * So a machine is a small cache of spools (`heads` of them) and a queue is a
 * sequence of requests for colours. A job's swaps are the colours it needs
 * that are not on a head when it starts. Which head gives way is decided the
 * way the textbook says is best for a known sequence (furthest next use), for
 * the current order and the proposed one alike — so the two are compared on
 * the same footing and a saving is not an artefact of evicting badly in one
 * and well in the other.
 *
 * ── DEADLINES AND PRIORITY COME FIRST ─────────────────────────────────────
 *
 * Never make a job late to save a swap. Every job gets a latest finish:
 *   - its due date (the end of that day), when the current order meets it;
 *   - its finish in the CURRENT order, when that is already past the due date
 *     (it may not get any later; it may get earlier);
 *   - none, when it has no due date.
 * And a job with a higher priority never falls behind a lower-priority job it
 * was ahead of. The proposal is built one job at a time, and a job is only a
 * candidate when running it next still leaves an order — the rest of the
 * current one — in which every job keeps its latest finish. The current order
 * is always such an order to begin with, so the search can never paint itself
 * into a corner; and the finished proposal is checked once more against every
 * limit, and thrown away for the current order if it breaks one or saves
 * nothing.
 *
 * Swap time is counted in those finishes (at `swapMinutes` each) in both
 * orders, which is conservative: a proposal has to keep its promises with the
 * swaps it still needs, not with none.
 *
 * ── THE MINUTES ARE AN ESTIMATE ───────────────────────────────────────────
 *
 * `DEFAULT_SWAP_MINUTES` is three: unload, load and prime on a U1 head, with
 * somebody already standing at the machine. It does NOT count the wait for
 * that somebody to arrive, which is often longer — so the saving shown is a
 * floor, not a promise. A shop can set its own figure (`settings.swapMinutes`).
 *
 * Pure: no DOM, no I/O, no clock (`now` is passed in). Shared by the desktop
 * and, bundled, the Mac. Needs `color-mix` and `loaded-colours`.
 */
(function (global) {
  const LC = () => (typeof require === 'function' ? require('./loaded-colours') : global.KhaytLoadedColours);
  const KC = () => (typeof require === 'function' ? require('./color-mix') : global.KhaytColor);

  /** Minutes one spool change is assumed to take. See the header. */
  const DEFAULT_SWAP_MINUTES = 3;
  /** A Snapmaker U1 has four toolheads. */
  const DEFAULT_HEADS = 4;
  /** The range a shop may set; anything outside is clamped into it. */
  const MIN_SWAP_MINUTES = 0;
  const MAX_SWAP_MINUTES = 60;

  const DAY_MS = 86400000;
  const HOUR_MS = 3600000;
  const PRIORITY_RANK = { urgent: 0, high: 1, normal: 2 };

  function num(v, fallback) {
    const n = Number(v);
    return Number.isFinite(n) ? n : fallback;
  }

  /** The shop's minutes per swap, clamped, or the default when unset. */
  function swapMinutesFrom(settings) {
    const raw = settings && settings.swapMinutes;
    if (raw == null || raw === '') return DEFAULT_SWAP_MINUTES;
    const n = Number(raw);
    if (!Number.isFinite(n)) return DEFAULT_SWAP_MINUTES;
    return Math.max(MIN_SWAP_MINUTES, Math.min(MAX_SWAP_MINUTES, n));
  }

  /** urgent 0 .. normal 2. The board's boolean `priority` counts as urgent. */
  function priorityRank(job) {
    const lvl = job && job.priorityLevel;
    const byLevel = Object.prototype.hasOwnProperty.call(PRIORITY_RANK, lvl) ? PRIORITY_RANK[lvl] : 2;
    return job && job.priority === true ? Math.min(byLevel, 0) : byLevel;
  }

  /** The end of the due day (local), in epoch ms, or Infinity. */
  function deadlineOf(job) {
    const due = job && job.dueDate;
    if (!due || typeof due !== 'string') return Infinity;
    const day = /^\d{4}-\d{2}-\d{2}$/.test(due) ? new Date(due + 'T00:00:00') : new Date(due);
    const t = day.getTime();
    if (!Number.isFinite(t)) return Infinity;
    return /^\d{4}-\d{2}-\d{2}$/.test(due) ? t + DAY_MS : t;
  }

  /** The colours a job needs, each with the job's material. */
  function needsOf(job, tolerance) {
    const material = String((job && job.material) || '').trim();
    const list = job && (Array.isArray(job.colors) ? job.colors : Array.isArray(job.colours) ? job.colours : []);
    const model = { colors: (list || []).map((c) => (typeof c === 'string' ? { hex: c } : c)) };
    return LC().needed(model, tolerance).map((hex) => ({ hex, material }));
  }

  /** Is this spool that colour? Perceptually, and by material family. */
  function same(a, b, tolerance) {
    if (KC().deltaE(a.hex, b.hex) > tolerance) return false;
    const fa = LC().family(a.material);
    const fb = LC().family(b.material);
    return !fa || !fb || fa === fb;
  }

  /**
   * Walk a sequence and count the swaps each job needs, with the finish time
   * of each and what is on the heads after each. `seq` is indexes into
   * `prepared`; spools are small integers (see `plan`), so the walk compares
   * numbers rather than recomputing colour distances.
   */
  function walk(seq, prepared, ctx) {
    let heads = ctx.loaded.slice(0, ctx.heads);
    let clock = ctx.startMs;
    const perJob = new Map();
    const headsAfter = [];
    let total = 0;
    for (let k = 0; k < seq.length; k++) {
      const job = prepared[seq[k]];
      let swaps = 0;
      if (job.known) {
        const taken = new Set();
        const missing = [];
        for (const n of job.needs) {
          const at = heads.findIndex((h, i) => !taken.has(i) && ctx.same(h, n));
          if (at >= 0) taken.add(at);
          else missing.push(n);
        }
        for (const n of missing) {
          swaps += 1;
          if (heads.length < ctx.heads) {
            heads = heads.concat([n]);
            taken.add(heads.length - 1);
            continue;
          }
          // Give up the spool whose next use is furthest away. A spool this
          // job is using is only given up when there is nothing else — a job
          // with more colours than heads swaps mid-print anyway.
          let victim = -1;
          let victimNext = -1;
          for (let i = 0; i < heads.length; i++) {
            if (taken.has(i)) continue;
            const next = nextUse(heads[i], seq, k + 1, prepared, ctx);
            if (next > victimNext) { victim = i; victimNext = next; }
          }
          if (victim < 0) victim = 0;
          heads = heads.slice();
          heads[victim] = n;
          taken.add(victim);
        }
      }
      total += swaps;
      clock += swaps * ctx.swapMinutes * 60000 + job.hours * HOUR_MS;
      perJob.set(job.id, { swaps, finish: clock });
      headsAfter.push(heads);
    }
    return { total, perJob, headsAfter };
  }

  function nextUse(spool, seq, from, prepared, ctx) {
    for (let j = from; j < seq.length; j++) {
      const job = prepared[seq[j]];
      if (job.known && job.needs.some((n) => ctx.same(spool, n))) return j;
    }
    return Infinity;
  }

  /** Could this job start on these heads without a swap? */
  function fitsOn(heads, job, ctx) {
    if (!job.known) return false;
    const taken = new Set();
    for (const n of job.needs) {
      const at = heads.findIndex((h, i) => !taken.has(i) && ctx.same(h, n));
      if (at < 0) return false;
      taken.add(at);
    }
    return true;
  }

  /** Does this sequence keep every job's latest finish? */
  function keepsPromises(result, prepared, limits) {
    for (const job of prepared) {
      const at = result.perJob.get(job.id);
      if (at && at.finish > limits.get(job.id) + 1e-6) return false;
    }
    return true;
  }

  /**
   * The proposal for one machine.
   *
   * @param {object[]} jobs  in the CURRENT order: `{ id, colors|colours: [{hex}|hex],
   *                         material?, printTime? (hours), dueDate?, priorityLevel?, priority? }`
   * @param {object} [opts]  `{ loaded: [{hex, material}], heads?, swapMinutes?, now (epoch ms),
   *                         startHours? (work already ahead of these on the machine), tolerance? }`
   * @returns {{ order: string[], changed: boolean, estimate: true, swapMinutes: number,
   *             heads: number, loadedKnown: boolean,
   *             current: {swaps, minutes}, proposed: {swaps, minutes}, saved: {swaps, minutes},
   *             jobs: Array<{ id, position, was, known, swapsNow, swapsPlanned,
   *                           minutesNow, minutesPlanned, delta, minutesDelta,
   *                           finishHoursNow, finishHours }> }}
   */
  function plan(jobs, opts) {
    const o = opts || {};
    const tolerance = Number.isFinite(o.tolerance) ? Number(o.tolerance) : LC().DEFAULT_TOLERANCE;
    const heads = Math.max(1, Math.round(num(o.heads, DEFAULT_HEADS)) || DEFAULT_HEADS);
    const swapMinutes = o.swapMinutes == null ? DEFAULT_SWAP_MINUTES
      : Math.max(MIN_SWAP_MINUTES, Math.min(MAX_SWAP_MINUTES, num(o.swapMinutes, DEFAULT_SWAP_MINUTES)));
    const now = num(o.now, 0);
    const startMs = now + Math.max(0, num(o.startHours, 0)) * HOUR_MS;

    // Every spool mentioned — loaded or needed — becomes a small integer once,
    // with a table of which are "the same filament". The search below walks
    // the queue many times, and CIEDE2000 on every step of every walk is what
    // would make it slow.
    const spools = [];
    function intern(spool) {
      const at = spools.findIndex((x) => x.hex === spool.hex && x.material === spool.material);
      if (at >= 0) return at;
      spools.push(spool);
      return spools.length - 1;
    }

    const loaded = [];
    for (const s of LC().normalizeLoaded(o.loaded)) loaded.push(intern({ hex: s.hex, material: s.material }));

    const seen = new Set();
    const prepared = (Array.isArray(jobs) ? jobs : [])
      .filter((j) => j && j.id != null && !seen.has(String(j.id)) && seen.add(String(j.id)))
      .map((j, index) => {
        const needs = needsOf(j, tolerance).map(intern);
        return {
          id: String(j.id),
          index,
          needs,
          known: needs.length > 0,
          hours: Math.max(0, num(j.printTime, 0)),
          rank: priorityRank(j),
          deadline: deadlineOf(j),
        };
      });

    const table = spools.map((a) => spools.map((b) => same(a, b, tolerance)));
    const sameSpool = (x, y) => x === y || table[x][y];

    // Near-duplicate spools on two heads count once: the second is a head
    // free for anything.
    const onHeads = [];
    for (const id of loaded) if (!onHeads.some((h) => sameSpool(h, id))) onHeads.push(id);

    const ctx = { loaded: onHeads, heads, swapMinutes, startMs, same: sameSpool };
    const currentSeq = prepared.map((_, i) => i);
    const current = walk(currentSeq, prepared, ctx);

    // Each job's latest finish. See the header.
    const limits = new Map();
    for (const job of prepared) {
      const was = current.perJob.get(job.id).finish;
      limits.set(job.id, job.deadline === Infinity ? Infinity : Math.max(job.deadline, was));
    }

    // Greedy: the fewest swaps next, among the jobs that may go next.
    const placed = [];
    const remaining = currentSeq.slice();
    while (remaining.length) {
      let best = null;
      for (const i of remaining) {
        const job = prepared[i];
        // Priority: nothing still waiting may outrank it from ahead of it.
        if (remaining.some((k) => k !== i && prepared[k].index < job.index && prepared[k].rank < job.rank)) continue;
        const rest = remaining.filter((k) => k !== i);
        const trial = walk(placed.concat([i], rest), prepared, ctx);
        if (!keepsPromises(trial, prepared, limits)) continue;
        const swapsHere = trial.perJob.get(job.id).swaps;
        // Then: the job after which the most of the others need nothing new.
        // That is what groups the jobs sharing a set of spools.
        const heads_ = trial.headsAfter[placed.length];
        const readyAfter = rest.filter((k) => fitsOn(heads_, prepared[k], ctx)).length;
        const score = [swapsHere, -readyAfter, job.index];
        if (!best || less(score, best.score)) best = { i, score };
      }
      // The first job still waiting in the current order is always allowed —
      // see the header — so `best` is never null. Guarded all the same.
      const pick = best ? best.i : remaining[0];
      placed.push(pick);
      remaining.splice(remaining.indexOf(pick), 1);
    }

    let proposedSeq = placed;
    let proposed = walk(proposedSeq, prepared, ctx);
    if (!keepsPromises(proposed, prepared, limits) || proposed.total >= current.total) {
      proposedSeq = currentSeq;
      proposed = current;
    }
    const changed = proposedSeq.some((i, k) => i !== currentSeq[k]);

    const jobsOut = proposedSeq.map((i, position) => {
      const job = prepared[i];
      const before = current.perJob.get(job.id).swaps;
      const after = proposed.perJob.get(job.id).swaps;
      return {
        id: job.id,
        position,
        was: job.index,
        known: job.known,
        swapsNow: before,
        swapsPlanned: after,
        minutesNow: before * swapMinutes,
        minutesPlanned: after * swapMinutes,
        delta: after - before,
        minutesDelta: (after - before) * swapMinutes,
        // Hours from `now` until it would come off, swap time included.
        finishHoursNow: (current.perJob.get(job.id).finish - now) / HOUR_MS,
        finishHours: (proposed.perJob.get(job.id).finish - now) / HOUR_MS,
      };
    });

    const saved = current.total - proposed.total;
    return {
      order: proposedSeq.map((i) => prepared[i].id),
      changed,
      estimate: true,
      swapMinutes,
      heads,
      loadedKnown: onHeads.length > 0,
      current: { swaps: current.total, minutes: current.total * swapMinutes },
      proposed: { swaps: proposed.total, minutes: proposed.total * swapMinutes },
      saved: { swaps: saved, minutes: saved * swapMinutes },
      jobs: jobsOut,
    };
  }

  function less(a, b) {
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) return a[i] < b[i];
    }
    return false;
  }

  const api = {
    DEFAULT_SWAP_MINUTES, DEFAULT_HEADS, MIN_SWAP_MINUTES, MAX_SWAP_MINUTES,
    plan, swapMinutesFrom, priorityRank, deadlineOf,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSwapQueue = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
