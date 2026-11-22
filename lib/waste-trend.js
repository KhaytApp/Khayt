'use strict';

/**
 * What the shop threw away, month by month, and why.
 *
 * Lifted from `renderWasteTrendChart` in `renderer/analytics.js`, which drew
 * six months of wasted grams stacked by failure type — and named the types by
 * hand: `warping`, `adhesion`, `stringing`, everything else "other". The
 * waste log's own vocabulary (`lib/qc-failure.js`, and the words under
 * `waste.ft.*`) has no `adhesion`; it has `bed_adhesion`. So every failed
 * first layer a shop ever logged landed in "other", and a chart whose whole
 * point is "what keeps going wrong" could not say the commonest thing that
 * does. The three named types are chosen from the data now — the heaviest
 * three in the window — and the rest is "other", said as such.
 *
 * PURE. Grams, not money: a failed print's cost depends on which spool it came
 * off, and the log already carries `cost` per entry for the screens that want
 * it; what a trend of failure TYPES needs is the weight. A month with nothing
 * thrown away is a month with nothing thrown away — its total is 0, because
 * zero waste is a real and good answer, unlike "no hours printed".
 */
(function (global) {

  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };
  const listOf = (v) => (Array.isArray(v) ? v : []);

  function monthOf(day) {
    if (!day) return null;
    const s = String(day);
    if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 7);
    const d = new Date(s);
    if (Number.isNaN(d.getTime())) return null;
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  }

  function monthKeys(now, months) {
    const d = new Date(typeof now === 'number' ? now : (now instanceof Date ? now.getTime() : Date.now()));
    const out = [];
    for (let i = months - 1; i >= 0; i--) {
      const m = new Date(d.getFullYear(), d.getMonth() - i, 1);
      out.push(`${m.getFullYear()}-${String(m.getMonth() + 1).padStart(2, '0')}`);
    }
    return out;
  }

  /**
   * @param wasteLog  the book's `wasteLog`
   * @param opts      { now, months = 6, named = 3 }
   * @returns {{ types: string[], months: Array<{key, total, byType: {[type]: grams}, entries}>,
   *             total: number, entries: number, byType: {[type]: grams} }}
   *   `types` are the named failure types in the order the columns stack —
   *   heaviest first — with `'other'` last when anything fell outside them.
   */
  function wasteTrend(wasteLog, opts) {
    const o = opts || {};
    const months = o.months > 0 ? Math.floor(o.months) : 6;
    const named = o.named >= 0 ? Math.floor(o.named) : 3;
    const keys = monthKeys(o.now, months);
    const inWindow = new Set(keys);

    // First pass: which types matter in this window.
    const weightByType = {};
    const rows = [];
    for (const w of listOf(wasteLog)) {
      if (!w) continue;
      const k = monthOf(w.date);
      if (!k || !inWindow.has(k)) continue;
      const type = typeof w.failureType === 'string' && w.failureType ? w.failureType : 'other';
      const grams = Math.max(0, num(w.weight));
      weightByType[type] = (weightByType[type] || 0) + grams;
      rows.push({ k, type, grams });
    }
    const ranked = Object.entries(weightByType)
      .filter(([type]) => type !== 'other')
      .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
      .map(([type]) => type);
    const top = ranked.slice(0, named);
    const restWeight = ranked.slice(named).reduce((s, t) => s + weightByType[t], 0) + (weightByType.other || 0);
    const types = restWeight > 0 || rows.some((r) => r.type === 'other') ? [...top, 'other'] : top;

    const bucket = (t) => (top.includes(t) ? t : 'other');
    const byMonth = {};
    for (const k of keys) byMonth[k] = { key: k, total: 0, byType: {}, entries: 0 };
    for (const r of rows) {
      const b = byMonth[r.k];
      const t = bucket(r.type);
      b.byType[t] = round1((b.byType[t] || 0) + r.grams);
      b.total = round1(b.total + r.grams);
      b.entries += 1;
    }
    const byType = {};
    for (const r of rows) { const t = bucket(r.type); byType[t] = round1((byType[t] || 0) + r.grams); }
    return {
      types,
      months: keys.map((k) => byMonth[k]),
      total: round1(rows.reduce((s, r) => s + r.grams, 0)),
      entries: rows.length,
      byType,
    };
  }

  function round1(v) { return Math.round(v * 10) / 10; }

  const api = { wasteTrend, monthKeys };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytWasteTrend = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
