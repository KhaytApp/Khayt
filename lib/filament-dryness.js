'use strict';
/*
 * Filament dryness model — how long a spool stays print-ready after drying, by material and storage.
 *
 * 3D-print filaments are hygroscopic: they reabsorb atmospheric moisture and then print wet (stringing,
 * popping, brittle parts). How fast depends on the polymer and how it's stored. These intervals are
 * conservative community rules of thumb (drying temps below each material's glass transition), used only
 * to nudge "dry me again soon" — they're guidance, not a spec.
 *
 * Shared, no DOM — unit-tested in Node, consumed by renderer/bedready-drylog.js.
 */
(function (global) {
  // openDays  = re-dry interval spooled in open room air.
  // sealedDays = interval in a sealed box/bag WITH active desiccant (a "drybox").
  // dryTempC / dryHours = a safe default drying recipe for the add form.
  const MATERIALS = {
    PLA:   { openDays: 14, sealedDays: 90,  dryTempC: 45, dryHours: 6 },
    PETG:  { openDays: 10, sealedDays: 75,  dryTempC: 65, dryHours: 6 },
    TPU:   { openDays: 3,  sealedDays: 30,  dryTempC: 50, dryHours: 8 },
    NYLON: { openDays: 1,  sealedDays: 20,  dryTempC: 70, dryHours: 12 },
    PA:    { openDays: 1,  sealedDays: 20,  dryTempC: 70, dryHours: 12 },
    ABS:   { openDays: 20, sealedDays: 120, dryTempC: 65, dryHours: 4 },
    ASA:   { openDays: 20, sealedDays: 120, dryTempC: 65, dryHours: 4 },
    PC:    { openDays: 4,  sealedDays: 30,  dryTempC: 80, dryHours: 8 },
    PVA:   { openDays: 1,  sealedDays: 14,  dryTempC: 45, dryHours: 8 },
  };
  const DEFAULT = { openDays: 10, sealedDays: 60, dryTempC: 55, dryHours: 6 };
  const DAY_MS = 86400000;

  /** Normalise a free-text material to a MATERIALS key (e.g. "PLA Matte" → PLA, "PA6-CF" → PA). */
  function materialKey(material) {
    const s = String(material || '').toUpperCase();
    if (/NYLON|\bPA\d*\b|\bPA-|\bPA\b/.test(s)) return 'PA';
    for (const k of ['PETG', 'PLA', 'TPU', 'ABS', 'ASA', 'PVA', 'PC']) {
      if (s.indexOf(k) >= 0) return k;
    }
    return null;
  }

  function materialSpec(material) {
    const k = materialKey(material);
    return k && MATERIALS[k] ? MATERIALS[k] : DEFAULT;
  }

  /** Storage kinds that keep filament dry (long interval). 'open' = room air (short interval). */
  function isSealed(storage) { return storage === 'drybox' || storage === 'sealed'; }

  /**
   * Current dryness status of a tracked spool.
   * @param {{material?:string, storage?:string, driedAt?:string|number}} rec
   * @param {number} [nowMs] current epoch ms (injectable for tests)
   * @returns {{ state:'good'|'due'|'overdue'|'unknown', daysSince:number|null, intervalDays:number, pct:number }}
   */
  function dryStatus(rec, nowMs) {
    const spec = materialSpec(rec && rec.material);
    const intervalDays = isSealed(rec && rec.storage) ? spec.sealedDays : spec.openDays;
    const now = typeof nowMs === 'number' ? nowMs : Date.now();
    const dried = rec && rec.driedAt ? new Date(rec.driedAt).getTime() : NaN;
    if (!isFinite(dried)) return { state: 'unknown', daysSince: null, intervalDays, pct: 0 };
    const daysSince = Math.max(0, (now - dried) / DAY_MS);
    const pct = intervalDays > 0 ? daysSince / intervalDays : 1;
    const state = pct < 0.75 ? 'good' : pct < 1 ? 'due' : 'overdue';
    return { state, daysSince, intervalDays, pct };
  }

  /**
   * A drying, written down: the log entry AND the date the verdict reads.
   *
   * ── THE TWO HALVES WERE NOT JOINED ──────────────────────────────────────
   *
   * `dryStatus` above reads `driedAt` and nothing else. The other app's drying
   * log appended to `dryingLog` and never touched it, so a shop that recorded
   * a drying there would still have been told the spool was overdue — by the
   * same app, on the same screen. Nothing had gone wrong yet only because no
   * book has a `dryingLog` in it.
   *
   * Returns both fields so a caller merges rather than replaces; the newest
   * date wins, because a shop correcting a forgotten entry types an older one
   * and that must not move the verdict backwards.
   */
  function recordDrying(rec, entry) {
    const e = entry || {};
    const log = Array.isArray(rec && rec.dryingLog) ? rec.dryingLog.slice() : [];
    const date = String(e.date || '').slice(0, 10);
    if (date) log.unshift(Object.assign({}, e, { date }));
    const newest = log.reduce(
      (best, row) => (row && row.date > best ? row.date : best),
      String((rec && rec.driedAt) || '').slice(0, 10));
    return { dryingLog: log, driedAt: newest || undefined };
  }

  const api = { MATERIALS, DEFAULT, materialKey, materialSpec, isSealed, dryStatus,
                recordDrying };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytFilamentDryness = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
