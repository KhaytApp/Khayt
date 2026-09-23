'use strict';
/**
 * The shop's pricing inputs, published so a storefront can quote an upload
 * with Khayt's own calculator — and the store rebuilt from them.
 *
 * ── WHY ───────────────────────────────────────────────────────────────────
 *
 * athartuwaiq3d.com wants an instant price when a customer uploads a model,
 * and the shop asked that it be Khayt's price, not a second calculator's. The
 * storefront vendors `public-quote.js` and its four dependencies byte for byte
 * and runs `publicQuote()` server side. What it lacks is the shop's inputs,
 * which only the book holds — the same shape of problem as the delivery
 * promise, and the same answer: the Mac publishes them.
 *
 * ── ONE MODULE, BOTH ENDS ─────────────────────────────────────────────────
 *
 * `build(store)` is what the Mac publishes. `toStore(sheet)` is what the
 * storefront rebuilds `publicQuote`'s store from. They live together so the
 * pair can be tested as a pair: a price reached from the shop's real book and
 * a price reached from `toStore(build(book))` must be the SAME number, for any
 * part (test/quote-sheet.test.js). If either end drifts, that test says so.
 *
 * ── WHAT IS IN IT, AND WHAT IS NOT ────────────────────────────────────────
 *
 * Only what the price is computed FROM: the intake-quote config, the material
 * as a cost and a weight (already net of any tax the shop reclaims — the
 * storefront knows nothing of the shop's tax), one printer preset, the
 * packaging cost, the currency, and the estimator the shop's own quotes use,
 * calibration included. Not the inventory, not the queue, not a customer.
 * It is still the shop's cost base and margin, so the cloud serves it only to
 * a holder of the shop's token — never on a public URL.
 *
 * Pure: the clock and the resolved estimator are the caller's.
 */
(function (global) {
  const PQ = global.KhaytPublicQuote
    || (typeof require === 'function' ? require('./public-quote.js') : null);
  const Tax = global.KhaytTax
    || (typeof require === 'function' ? (() => { try { return require('./tax.js'); } catch (_) { return null; } })() : null);

  const num = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };
  const PRINTER_FIELDS = ['wearRate', 'powerDraw', 'elecRate', 'laborRate', 'failureRate', 'prepTime', 'postTime'];

  /**
   * The sheet this book would publish, or null when there is nothing to
   * publish — public pricing is off, or the shop has not said what to charge
   * (no material, no printer). Null is how the Mac WITHDRAWS a sheet.
   *
   * `ctx`: `{ now: Date, staleAfterHours, estimatorOpts }` — the estimator
   * exactly as the Mac's own quote resolves it (`KhaytStl.fromSettings` plus
   * the book's calibration), so the web and the LAN price one part alike.
   */
  function build(store, ctx) {
    const c = ctx || {};
    const s = (store && store.settings) || {};
    const cfg = (s.lanApi && s.lanApi.intakeQuote) || {};
    if (!cfg.enabled) return null;
    const reclaims = !!(Tax && Tax.profileFromSettings && (Tax.profileFromSettings(s).rates || []).length);
    const basis = PQ.materialBasis(cfg, store && store.inventory, reclaims);
    if (!basis) return null;
    const preset = cfg.presetId ? ((store && store.printers) || []).find((p) => p && p.id === cfg.presetId) : null;
    if (!preset) return null;

    let name = '', materialType = 'fdm';
    if (cfg.filamentId) {
      const item = ((store && store.inventory) || []).find((i) => i && i.id === cfg.filamentId);
      if (item) { name = String(item.material || ''); materialType = String(item.materialType || 'fdm'); }
    }
    const printer = {};
    for (const k of PRINTER_FIELDS) printer[k] = num(preset[k]);
    const estimator = {};
    for (const [k, v] of Object.entries(c.estimatorOpts || {})) {
      if (typeof v === 'number' && Number.isFinite(v)) estimator[k] = v;
    }
    return {
      v: 1,
      computedAt: (c.now instanceof Date ? c.now : new Date()).toISOString(),
      staleAfterHours: num(c.staleAfterHours) || 168,
      currency: String(s.currency || ''),
      marginPct: num(cfg.marginPct),
      minPrice: num(cfg.minPrice),
      wastePct: num(cfg.wastePct),
      packagingCost: num(s.defaultPackagingCost),
      material: { spoolCost: basis.spoolCost, spoolWeight: basis.spoolWeight, name, materialType },
      printer,
      estimator,
    };
  }

  /**
   * The store `publicQuote` needs, rebuilt from a sheet: public pricing on, a
   * flat material basis (already net), one preset, nothing else. Pass
   * `sheet.estimator` as `deps.estimatorOpts` beside it.
   */
  function toStore(sheet) {
    const q = sheet || {};
    const m = q.material || {};
    return {
      settings: {
        currency: q.currency || '',
        defaultPackagingCost: num(q.packagingCost),
        lanApi: { intakeQuote: {
          enabled: true, presetId: 'sheet',
          spoolCost: num(m.spoolCost), spoolWeight: num(m.spoolWeight),
          marginPct: num(q.marginPct), minPrice: num(q.minPrice), wastePct: num(q.wastePct),
        } },
      },
      printers: [Object.assign({ id: 'sheet' }, q.printer || {})],
      inventory: [],
      printLog: [],
    };
  }

  /** Whether a sheet is too old to quote from, by its own `staleAfterHours`. */
  function stale(sheet, now) {
    const at = Date.parse(sheet && sheet.computedAt);
    if (!Number.isFinite(at)) return true;
    const hours = num(sheet.staleAfterHours) || 168;
    return ((now instanceof Date ? now.getTime() : Date.now()) - at) > hours * 3600 * 1000;
  }

  const api = { build, toStore, stale, PRINTER_FIELDS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytQuoteSheet = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
