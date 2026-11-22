'use strict';
/**
 * The multicolour print planner's rules — which spool each colour of a print
 * file starts on, what each colour costs, and how the spools load into a
 * four-slot AMS. Pure: no DOM, no fetch, no `require` at load time.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * The planner lived inside renderer/color-planner.js, so the only app that
 * could plan colours was the one with that modal. The native Mac plans the
 * same file from the same book, and a second copy of "nearest spool unless
 * the shop already chose one" written in Swift would agree today and drift by
 * the third fix. Both apps call these now; the renderer keeps only its DOM.
 *
 * Loaded three ways: required in Node (tests), a plain <script> in
 * renderer/index.html and renderer/bedready.html, and JavaScriptCore on the
 * Mac. JavaScriptCore has no `require`, so the colour maths is read off
 * `KhaytColor` (lib/color-mix.js, loaded first) and only required in Node.
 *
 * Field names are the book's: a plan row is `{hex, filamentId, grams}` and is
 * stored as `rec.colorPlan`; an inventory row's colour is `color`, its price
 * `cost` and its size `weight`.
 */
(function (global) {
  function KC() {
    if (global && global.KhaytColor) return global.KhaytColor;
    if (typeof require === 'function') return require('./color-mix');
    return null;
  }

  /** How many filaments one AMS (or MMU, or the U1's heads) holds at once. */
  const AMS_SLOTS = 4;

  /** The colours a print-file record carries that can be planned. */
  function plannableColours(rec) {
    return (rec && Array.isArray(rec.colors)) ? rec.colors.filter((c) => c && c.hex) : [];
  }

  /** Inventory rows with a colour the maths can read. */
  function colouredFilaments(inventory) {
    const kc = KC();
    const list = Array.isArray(inventory) ? inventory : [];
    return kc ? list.filter((it) => it && kc.hexToRgb(it.color)) : [];
  }

  /** What one gram of this spool costs: its price over its size, never over zero. */
  const costPerGram = (it) => (it ? (+it.cost || 0) / Math.max(1, +it.weight || 1) : 0);

  /**
   * The plan the planner opens on. Each colour keeps the spool the shop chose
   * last time (`saved`, matched by hex, ignoring case) while that spool is still
   * a candidate; otherwise it starts on the nearest colour on the shelf
   * (CIEDE2000), and failing that on the first candidate.
   *
   * @param {{hex:string, label?:string, grams?:number}[]} colours  rec.colors
   * @param {{hex:string, filamentId:string, grams?:number}[]} saved  rec.colorPlan
   * @param {object[]} cands  colouredFilaments(inventory)
   * @returns {{hex:string, label:string, grams:number, filamentId:string}[]}
   */
  function initialPlan(colours, saved, cands) {
    const kc = KC();
    const list = (Array.isArray(colours) ? colours : []).filter((c) => c && c.hex);
    const prevs = Array.isArray(saved) ? saved : [];
    const pool = Array.isArray(cands) ? cands : [];
    return list.map((c, i) => {
      const prev = prevs.find((s) => s && String(s.hex).toLowerCase() === String(c.hex).toLowerCase());
      const near = kc ? kc.nearest(c.hex, pool, { limit: 1 })[0] : null;
      const fid = prev && pool.some((x) => x.id === prev.filamentId)
        ? prev.filamentId
        : (near ? near.id : (pool[0] && pool[0].id) || '');
      return {
        hex: c.hex,
        label: c.label || `#${i + 1}`,
        grams: +(prev && prev.grams != null ? prev.grams : c.grams) || 0,
        filamentId: fid,
      };
    });
  }

  /**
   * What the plan comes to: each row's cost and colour distance, the totals,
   * and the slot map — one slot per DISTINCT spool with grams to print,
   * in the order the colours list them (colours sharing a spool share a slot).
   *
   * `deltaE` is null when the row has no spool. `overflow` is how many spools
   * do not fit in one AMS set and have to be swapped by hand.
   */
  function summarise(plan, cands) {
    const kc = KC();
    const pool = Array.isArray(cands) ? cands : [];
    const rows = (Array.isArray(plan) ? plan : []).map((p) => {
      const it = pool.find((x) => x.id === p.filamentId) || null;
      const grams = +p.grams || 0;
      const de = it && kc ? kc.deltaE(p.hex, it.color) : Infinity;
      return {
        hex: p.hex,
        filamentId: p.filamentId || '',
        grams,
        cost: it ? costPerGram(it) * grams : null,
        deltaE: isFinite(de) ? de : null,
      };
    });
    let totalGrams = 0, totalCost = 0;
    rows.forEach((r) => { totalGrams += r.grams || 0; totalCost += r.cost || 0; });
    const slots = [];
    (Array.isArray(plan) ? plan : []).forEach((p) => {
      if (p.filamentId && (+p.grams || 0) > 0 && slots.indexOf(p.filamentId) === -1) slots.push(p.filamentId);
    });
    return {
      rows,
      totalGrams,
      totalCost,
      slots,
      overflow: Math.max(0, slots.length - AMS_SLOTS),
    };
  }

  /** How close a match reads: under 5 is good, under 12 passable, else far. */
  function closeness(deltaE) {
    if (deltaE == null || !isFinite(deltaE)) return '';
    return deltaE < 5 ? 'good' : deltaE < 12 ? 'ok' : 'far';
  }

  /** The plan as the book stores it on the record (`rec.colorPlan`). */
  function toSaved(plan) {
    return (Array.isArray(plan) ? plan : []).map((p) => ({ hex: p.hex, filamentId: p.filamentId, grams: p.grams }));
  }

  /** The rows with a spool and grams — the ones a calculator part is made of. */
  function assigned(plan) {
    return (Array.isArray(plan) ? plan : []).filter((p) => p.filamentId && p.grams > 0);
  }

  const api = {
    AMS_SLOTS, plannableColours, colouredFilaments, costPerGram,
    initialPlan, summarise, closeness, toSaved, assigned,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.KhaytColorPlan = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
