'use strict';

/**
 * What a shop spent keeping each machine running.
 *
 * Maintenance is recorded in the book's own `machMaintLog` — one flat list of
 * `{ id, machineId, date, note, cost }`, written by the machine screen and
 * carried by sync and backup like every other collection. The machine record
 * itself holds no log.
 *
 * "Maintenance Cost by Machine" on the Reports screen read `machine.machMaintLog`:
 * a per-machine property that nothing in Khayt has ever written. It was always
 * `undefined`, always became `[]`, and every machine therefore totalled zero
 * and was filtered out — so the chart printed "No data yet" no matter how many
 * services a shop had logged, while the machine screen listed those same
 * services correctly from the real list.
 *
 * The entries are also bucketed by year, and the original did that with
 * `new Date(entry.date).getFullYear()`. `"2026-01-01"` parses as midnight UTC,
 * and `getFullYear()` then answers in the reader's own timezone: west of UTC
 * that is the 31st of December, so a shop in New York would have seen its new
 * year's maintenance counted against the year before. Khayt compares dates as
 * strings everywhere else for exactly this reason (`lib/date-range.js`), and
 * so does this.
 *
 * Costs for a machine the shop has since deleted are kept rather than dropped,
 * labelled by the id the entry carries. The money left the shop; a chart of
 * what maintenance cost should not quietly shrink because a printer was sold.
 */
(function (global) {

  function num(v) {
    const n = +v;
    return Number.isFinite(n) ? n : 0;
  }

  /**
   * The year an entry falls in, read off the front of its date string.
   *
   * Returns `''` for anything that is not a `YYYY-MM-DD` date, which is what
   * keeps a malformed entry out of every year rather than filed into one by
   * accident — the same call `lib/date-range.js` makes.
   */
  function yearOf(dateStr) {
    const s = String(dateStr == null ? '' : dateStr);
    return /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 4) : '';
  }

  /**
   * Total maintenance cost per machine, biggest spender first.
   *
   * `machines` supplies the names; `entries` is the book's `machMaintLog`.
   * `opts.year` limits to one year (a number or a four-digit string) and is
   * how the Reports chart shows the current year; omit it for everything the
   * shop has ever logged.
   *
   * Machines with nothing spent on them are left out, because a bar chart of
   * zero-height bars is noise rather than information — the same filter the
   * original applied.
   */
  function byMachine(machines, entries, opts) {
    const options = opts || {};
    const year = options.year == null || options.year === ''
      ? null
      : String(options.year);

    const names = new Map();
    (machines || []).forEach(m => {
      if (!m || !m.id) return;
      names.set(m.id, m.name || m.model || m.id);
    });

    const totals = new Map();
    (entries || []).forEach(e => {
      if (!e || !e.machineId) return;
      if (year !== null && yearOf(e.date) !== year) return;
      const prev = totals.get(e.machineId) || 0;
      totals.set(e.machineId, prev + num(e.cost));
    });

    const rows = [];
    totals.forEach((total, machineId) => {
      if (!(total > 0)) return;
      rows.push({
        machineId,
        name: names.get(machineId) || machineId,
        /** True when the entry's machine is no longer in the book. */
        orphan: !names.has(machineId),
        total,
      });
    });

    // Biggest first, then by name so two machines that cost the same amount do
    // not swap places between renders.
    rows.sort((a, b) => (b.total - a.total) || a.name.localeCompare(b.name));
    return rows;
  }

  const api = { yearOf, byMachine };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytMaintenanceCost = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
