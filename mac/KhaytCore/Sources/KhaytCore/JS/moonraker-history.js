'use strict';
/**
 * What the printer itself remembers.
 *
 * Khayt's print log is a BUSINESS record: orders a shop took, with a client and
 * a price. A printer's own history is a different and more literal thing — every
 * job it ran, including test prints, reprints, calibration and the ones nobody
 * paid for. Moonraker keeps it, Klipper machines expose it at
 * `/server/history/list`, and Khayt had never asked.
 *
 * That gap had a visible cost. The nozzle-wear counter reads completed ORDERS,
 * so a machine that has extruded three and a half kilos while only nineteen of
 * its jobs were customer orders reports a fraction of its real wear — and the
 * replacement warning fires late, in the direction that ruins parts.
 *
 * WHERE THIS IS AUTHORITATIVE AND WHERE IT IS NOT. For "how much filament has
 * gone through this nozzle", the printer is the ground truth and the order log is
 * a sample of it. For "what did we sell", the order log is the record and this
 * knows nothing. So an imported history REPLACES the order log for wear
 * specifically, and is ignored everywhere else. Mixing the two would double-count
 * every job that is both an order and a print.
 *
 * Pure: no network, no fs, no Electron. main.js does the fetching.
 */
(function (global) {

  const num = (v) => {
    const n = Number(v);
    return Number.isFinite(n) ? n : 0;
  };

  /**
   * The material a job ran, from metadata that is per-TOOL on a toolchanger.
   *
   * A four-toolhead U1 reports `filament_type` as "PETG;PETG;PETG;PETG" — one
   * entry per tool, whether or not that tool was used. Storing that verbatim
   * would make every multi-tool job look like a material nobody stocks, and the
   * abrasiveness match in lib/nozzle-wear.js would miss it entirely.
   */
  function materialOf(meta) {
    const raw = String((meta && (meta.filament_name || meta.filament_type)) || '');
    const parts = [...new Set(raw
      // The slicer writes the list ALREADY QUOTED, so the real value is
      //   Generic PLA";"Generic PLA Silk";"Generic PLA
      // and a plain split on ';' leaves a stray quote glued to every entry.
      // That reaches the abrasiveness patterns as `Generic PLA" + "Generic PLA`,
      // which matches nothing it should and is unreadable on a machine card.
      .split(';')
      .map((x) => x.replace(/^["'\s]+|["'\s]+$/g, ''))
      .filter(Boolean))];
    return parts.join(' + ');
  }

  /** Seconds → hours, to four places, which is what a part stores. */
  const hours = (s) => Math.round((num(s) / 3600) * 10000) / 10000;

  /**
   * Normalise Moonraker's job list into the shape Khayt keeps on a machine.
   *
   * Deliberately drops `thumbnails` and the slicer's per-object data: this is
   * stored inside the shop's store file, which is pushed to the cloud encrypted
   * on every sync, and a hundred base64 previews would multiply that for
   * information the wear model does not use.
   */
  function mapJobs(raw) {
    const list = Array.isArray(raw) ? raw : (raw && Array.isArray(raw.jobs) ? raw.jobs : []);
    return list.map((j) => {
      // Half a guard is not a guard: `j && j.metadata` was checked and then
      // `j.job_id` was read straight off it, so a null entry in the array threw
      // and took the whole import down. A printer on the LAN answering oddly
      // must not be able to do that.
      if (!j || typeof j !== 'object') return null;
      const meta = j.metadata || {};
      return {
        jobId: String(j.job_id || ''),
        filename: String(j.filename || ''),
        status: String(j.status || ''),
        // Moonraker keeps unix seconds; the store keeps ISO, like every other date.
        startedAt: j.start_time ? new Date(j.start_time * 1000).toISOString() : '',
        endedAt: j.end_time ? new Date(j.end_time * 1000).toISOString() : '',
        hours: hours(j.print_duration),
        // filament_weight_total is what the slicer computed for the whole plate.
        // filament_used is LENGTH in mm and is not interchangeable with it — a
        // number in the wrong unit here would read as a plausible weight.
        grams: Math.round(num(meta.filament_weight_total) * 100) / 100,
        material: materialOf(meta),
        layerHeightMm: num(meta.layer_height) || null,
        nozzleMm: num(meta.nozzle_diameter) || null,
      };
    }).filter((j) => j && j.filename);
  }

  /** Only the jobs that actually finished. Cancelled work still wore the nozzle,
   *  but Moonraker reports no weight for it, so counting it would add zeros. */
  const completed = (jobs) => (jobs || []).filter((j) => j.status === 'completed');

  /**
   * Grams and hours through this machine since a date, from its own history.
   *
   * `since` is an ISO day (the nozzle install date). A job with no start time
   * is excluded rather than credited to the current nozzle — the same direction
   * the order-log counter takes, and the safe one.
   */
  function totalsSince(jobs, since) {
    const from = String(since || '');
    let grams = 0;
    let hrs = 0;
    const byMaterial = new Map();
    for (const j of completed(jobs)) {
      if (from && (!j.startedAt || j.startedAt.slice(0, 10) < from.slice(0, 10))) continue;
      grams += j.grams;
      hrs += j.hours;
      const key = j.material || '(unspecified)';
      byMaterial.set(key, (byMaterial.get(key) || 0) + j.grams);
    }
    return {
      grams: Math.round(grams * 100) / 100,
      hours: Math.round(hrs * 100) / 100,
      jobs: completed(jobs).filter((j) => !from || (j.startedAt && j.startedAt.slice(0, 10) >= from.slice(0, 10))).length,
      byMaterial: [...byMaterial.entries()].map(([material, g]) => ({ material, grams: Math.round(g * 100) / 100 }))
        .sort((a, b) => b.grams - a.grams),
    };
  }

  /**
   * Merge a fresh pull into what is already stored, keyed on the printer's own
   * job id, so re-importing is idempotent rather than doubling everything.
   */
  function merge(existing, incoming) {
    const byId = new Map();
    for (const j of existing || []) if (j && j.jobId) byId.set(j.jobId, j);
    for (const j of incoming || []) if (j && j.jobId) byId.set(j.jobId, j);
    return [...byId.values()].sort((a, b) => String(b.startedAt).localeCompare(String(a.startedAt)));
  }

  const api = { mapJobs, completed, totalsSince, merge, materialOf };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytMoonrakerHistory = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
