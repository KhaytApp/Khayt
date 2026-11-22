'use strict';

/**
 * How long a machine is actually out of action.
 *
 * A machine record carries `downtimeBlocks`: `[{ from, to, reason }]`, windows
 * a shop books the printer out for. Nothing stops two of them overlapping, and
 * overlapping is the natural way to record what happens — "down for a belt
 * change, Monday to Wednesday", then "waiting for the part, Tuesday to
 * Thursday". Both are true and both get written.
 *
 * Three separate places then added the windows up one by one:
 *
 *   - `lib/scheduling.js`, where the total is added to a machine's load and
 *     decides which printer the next job goes on;
 *   - `lib/lead-time-publish.js`, which publishes it to customers as the
 *     reason a date has moved;
 *   - the Reports downtime chart.
 *
 * Those two windows are 72 hours of downtime. All three reported **96**, and
 * the error grows with every overlap a shop records. The scheduler pushed work
 * off a machine that was freer than it looked, customers were told a longer
 * wait than the shop faced, and the chart could report more downtime in a month
 * than the month has hours in it.
 *
 * Elapsed time is the union of the windows, not the sum of their lengths. That
 * is the whole rule, and it lives here so the three cannot disagree about one
 * machine.
 *
 * Deliberately NOT here: merging the windows a shop has *stored*. Those are its
 * own records, with its own reasons written on them, and rewriting "belt
 * change" and "waiting for the part" into one nameless window would take away
 * the note that makes the record worth keeping. The merge happens when the
 * hours are counted, never on the way to disk.
 *
 * `lib/machine-band.js` is a fourth reader and is correct already: it walks the
 * windows rather than summing them, re-checking from the top after each push,
 * so an overlap costs it nothing. It is left alone.
 */
(function (global) {

  const HOUR_MS = 3600000;

  /**
   * A machine's downtime windows as epoch milliseconds, sorted, with the
   * unusable ones dropped.
   *
   * A window missing either end, running backwards, or carrying a date nothing
   * can parse is skipped rather than guessed at — the same judgement the
   * readers this replaces each made separately.
   */
  function windows(machine) {
    const blocks = Array.isArray(machine && machine.downtimeBlocks)
      ? machine.downtimeBlocks
      : [];
    const out = [];
    for (const b of blocks) {
      if (!b || !b.from || !b.to) continue;
      const startsAt = new Date(b.from).getTime();
      const endsAt = new Date(b.to).getTime();
      if (!Number.isFinite(startsAt) || !Number.isFinite(endsAt)) continue;
      if (endsAt <= startsAt) continue;
      out.push({ startsAt, endsAt, note: String((b.reason || b.note) || '') });
    }
    return out.sort((a, b) => a.startsAt - b.startsAt);
  }

  /**
   * The union of a sorted list of windows.
   *
   * Windows that merely touch — one ending exactly when the next begins — are
   * joined too. They are one stretch of time the machine was unavailable, and
   * counting the boundary twice is the same mistake in miniature.
   *
   * Notes are joined with " · " so the reason survives the merge for a caller
   * that shows one. A caller that only wants hours ignores it.
   */
  function merge(sorted) {
    const out = [];
    for (const w of sorted || []) {
      const last = out[out.length - 1];
      if (last && w.startsAt <= last.endsAt) {
        if (w.endsAt > last.endsAt) last.endsAt = w.endsAt;
        if (w.note && last.note.indexOf(w.note) === -1) {
          last.note = last.note ? last.note + ' · ' + w.note : w.note;
        }
        continue;
      }
      out.push({ startsAt: w.startsAt, endsAt: w.endsAt, note: w.note || '' });
    }
    return out;
  }

  /** A machine's downtime with overlaps resolved: what it is actually out for. */
  function mergedWindows(machine) {
    return merge(windows(machine));
  }

  /**
   * Hours the machine is out of action between `from` and `to`, epoch ms.
   *
   * Merged first, then clipped, which is the order that matters: clipping two
   * overlapping windows and adding them gives the wrong answer however
   * carefully each one is clipped.
   */
  function hoursBetween(machine, from, to) {
    const start = +from;
    const end = +to;
    if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return 0;
    let total = 0;
    for (const w of mergedWindows(machine)) {
      const a = w.startsAt > start ? w.startsAt : start;
      const z = w.endsAt < end ? w.endsAt : end;
      if (z > a) total += (z - a) / HOUR_MS;
    }
    return total;
  }

  /**
   * Hours out of action in each of several periods.
   *
   * `periods` is `[{ from, to }]` in epoch ms; the answer is an array of hours
   * in the same order, which is what a chart drawing a bar per month needs.
   */
  function hoursByPeriod(machine, periods) {
    const merged = mergedWindows(machine);
    return (periods || []).map((p) => {
      const start = +(p && p.from);
      const end = +(p && p.to);
      if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) return 0;
      let total = 0;
      for (const w of merged) {
        const a = w.startsAt > start ? w.startsAt : start;
        const z = w.endsAt < end ? w.endsAt : end;
        if (z > a) total += (z - a) / HOUR_MS;
      }
      return total;
    });
  }

  const api = { HOUR_MS, windows, merge, mergedWindows, hoursBetween, hoursByPeriod };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytDowntime = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
