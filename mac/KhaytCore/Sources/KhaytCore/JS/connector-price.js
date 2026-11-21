'use strict';
(function (global) {

/**
 * The shop's price for a plate sliced in OrcaSlicer (the Khayt tab), from the
 * slice facts the plugin captured (lib/connector-slice.js field names) and a
 * quantity. Pure; no DOM, no I/O. The Mac's `POST /api/connectors/price`
 * calls it and seals the answer; the plugin does no arithmetic (plan:
 * ~/Khayt-proposals/orca-tab-price-plan.md, approved by Turki, Nov 19).
 *
 * ── NO NEW FORMULA ────────────────────────────────────────────────────────
 *
 * The facts become ONE hand-part, exactly as the calculator would hold it,
 * and the existing code prices it:
 *   material   the shop's spool by type (KhaytLoadedColours.family), then
 *              nearest colour (KhaytSpoolMatch.colorDistance), the cheapest
 *              per gram in stock. A type the shop has no spool of is
 *              no price. Only a slice with NO type falls back to the quote
 *              sheet's material (settings.lanApi.intakeQuote, never a
 *              resin). The shop's currency must be set. Several
 *              filaments are one blended `colours` part, as the colour
 *              planner makes one (spoolCost / spoolWeight pre-summed).
 *   time       printTime = timeSec / 3600, per piece.
 *   rates      KhaytPrintRates.withRates: the shop preset whose name is the
 *              slicer's printer preset, else the shop's defaults.
 *   labour     a NEW part: `labourPerLine: true`, prep once for the line and
 *              post per piece (KhaytOrderMoney.lineLabour, #2586).
 *   cost       KhaytCalculatorCost.computePartBaseCost (packaging and the
 *              failure buffer included, as for any hand part).
 *   price      KhaytPricing.quoteTotal: cost + the shop's overhead by the
 *              print hour (ctx.overheadPerHour, as the public quote passes
 *              it), the shop's default margin, then the rounding the shop
 *              chose for slicer prices (ctx.round {step, mode}), if any. A
 *              sliced plate is a new part with no price tiers of its own.
 *
 * Returns { currency, qty, cost: {unit, total} (overhead included), unit,
 * total, rounded, basis, margin: {pct of the price, pctOnCost (absent when the cost is 0), amount}, round: {step} only when rounded } or { unpriced: 'bad-facts' | 'no-material' | 'no-currency' }. The route
 * decides which keys a device may see (price only, or price and cost).
 * `basis` is 'measured' when the rates came from a shop preset matched by the
 * slicer's printer preset, 'assumed' when they are the shop's defaults.
 */

const MAX_QTY = 999;
const MAX_FILAMENTS = 16;
const MAX_GRAMS = 100000;
const MAX_TIME_SEC = 60 * 60 * 24 * 60;   // 60 days of printing

function lib(name, file) {
  if (global && global[name]) return global[name];
  if (typeof require === 'function') { try { return require(file); } catch (_) { return null; } }
  return null;
}

const finite = (v, lo, hi) => typeof v === 'number' && Number.isFinite(v) && v >= lo && v <= hi;
const r2 = (v) => Math.round(v * 100) / 100;
const r4 = (v) => Math.round(v * 10000) / 10000;

/** The facts the price needs, checked; null when they cannot be priced. */
function readFacts(facts) {
  const f = facts && typeof facts === 'object' ? facts : null;
  if (!f) return null;
  const qty = f.qty === undefined ? 1 : f.qty;
  if (!Number.isInteger(qty) || qty < 1 || qty > MAX_QTY) return null;
  if (!finite(f.timeSec, 0, MAX_TIME_SEC)) return null;
  const rows = Array.isArray(f.filaments) ? f.filaments : [];
  if (rows.length < 1 || rows.length > MAX_FILAMENTS) return null;
  const filaments = [];
  for (const row of rows) {
    if (!row || typeof row !== 'object' || !finite(row.grams, 0, MAX_GRAMS)) return null;
    filaments.push({
      type: typeof row.type === 'string' ? row.type : '',
      colour: typeof row.colour === 'string' ? row.colour : '',
      grams: row.grams,
    });
  }
  // Nothing to print (no grams, or no time) is not a plate to price.
  if (!(f.timeSec > 0) || !(filaments.reduce((t, x) => t + x.grams, 0) > 0)) return null;
  const preset = f.printer && typeof f.printer.preset === 'string' ? f.printer.preset.trim() : '';
  return { qty, hours: f.timeSec / 3600, filaments, preset };
}

/** Whether the shop gets the tax on a spool back (it is then not a cost). */
function reclaims(settings) {
  const T = lib('KhaytTax', './tax.js');
  if (!T || typeof T.profileFromSettings !== 'function') return false;
  const p = T.profileFromSettings(settings || {});
  return !!(p && p.rates && p.rates.length);
}

/** A spool's cost per gram: what it cost (net of reclaimed tax) over its SIZE, not what is left. */
function perGram(item, settings) {
  const SE = lib('KhaytSpoolEdit', './spool-edit.js');
  const cost = SE && typeof SE.netCost === 'function' ? SE.netCost(item, reclaims(settings)) : Math.max(0, +item.cost || 0);
  const size = Math.max(1, +item.spoolWeight || 1000);
  return cost > 0 ? cost / size : 0;
}

/**
 * The spool one filament is costed off: same family, in stock, priced; the
 * nearest colours (within KhaytSpoolMatch.GOOD_MATCH of the slicer's colour)
 * when there are any; the cheapest of those per gram. Null when none.
 */
function spoolFor(filament, inventory, settings) {
  const LC = lib('KhaytLoadedColours', './loaded-colours.js');
  const SM = lib('KhaytSpoolMatch', './spool-match.js');
  const fam = LC && typeof LC.family === 'function' ? LC.family(filament.type) : String(filament.type || '').toUpperCase();
  if (!fam) return null;
  const pool = (Array.isArray(inventory) ? inventory : []).filter((i) => i && i.id
    && i.materialType !== 'resin' && (+i.weight > 0)
    && (LC && typeof LC.family === 'function' ? LC.family(i.material) : String(i.material || '').toUpperCase()) === fam
    && perGram(i, settings) > 0);
  if (!pool.length) return null;
  let near = pool;
  if (filament.colour && SM && typeof SM.colorDistance === 'function') {
    const close = pool.filter((i) => i.color && SM.colorDistance(filament.colour, i.color) < SM.GOOD_MATCH);
    if (close.length) near = close;
  }
  return near.slice().sort((a, b) => (perGram(a, settings) - perGram(b, settings)) || String(a.id).localeCompare(String(b.id)))[0];
}

/** The quote sheet's material (settings.lanApi.intakeQuote), per gram, or 0. */
function defaultPerGram(settings, inventory) {
  const cfg = (settings && settings.lanApi && settings.lanApi.intakeQuote) || {};
  if (cfg.filamentId) {
    const item = (Array.isArray(inventory) ? inventory : []).find((i) => i && i.id === cfg.filamentId);
    // A resin bottle is costed per ml by the calculator's resin branch, never
    // per gram of filament: it is no default for a sliced FDM plate (#2588
    // review: grams were multiplied twice).
    if (!item || item.materialType === 'resin') return null;
    return { perGram: perGram(item, settings), id: item.id, material: item.material || '' };
  }
  const cost = +cfg.spoolCost, size = +cfg.spoolWeight;
  return cost > 0 && size > 0 ? { perGram: cost / size, id: '', material: '' } : null;
}

/** The facts as one hand-part, before rates; null when a filament has no material. */
function partFrom(f, ctx) {
  const settings = ctx.settings || {};
  const inventory = ctx.inventory || [];
  const fallback = defaultPerGram(settings, inventory);
  const lines = [];
  for (const fil of f.filaments) {
    const spool = spoolFor(fil, inventory, settings);
    // The quote sheet's material stands in ONLY when the slicer did not say a
    // type. A type the shop has no spool of (PEEK in a PLA shop) is not priced
    // like the shop's cheap default (#2588 review, MED).
    const typed = String(fil.type || '').trim() !== '';
    const pg = spool ? perGram(spool, settings) : (!typed && fallback ? fallback.perGram : 0);
    if (!(pg > 0)) return null;
    lines.push({ filamentId: spool ? spool.id : (fallback.id || ''), material: spool ? (spool.material || '') : (fallback.material || fil.type),
      hex: fil.colour || '', grams: fil.grams, cost: pg * fil.grams });
  }
  const grams = lines.reduce((s, l) => s + l.grams, 0);
  const part = { name: 'Sliced plate', qty: f.qty, printWeight: grams, supportWeight: 0, printTime: f.hours,
    extraMaterials: [], priceTiers: [], labourPerLine: true };
  if (lines.length === 1) {
    // One filament: that spool's own ratio, as the calculator holds a part.
    const l = lines[0];
    Object.assign(part, { filamentId: l.filamentId, material: l.material, spoolCost: l.grams > 0 ? l.cost : 0, spoolWeight: Math.max(1, l.grams) });
    if (!(l.grams > 0)) { part.spoolCost = 0; part.spoolWeight = 1000; }
  } else {
    // Several: one blended part (colour planner shape): the costs pre-summed.
    const dominant = lines.slice().sort((a, b) => b.grams - a.grams)[0];
    Object.assign(part, { filamentId: dominant.filamentId, material: dominant.material,
      spoolCost: lines.reduce((s, l) => s + l.cost, 0), spoolWeight: Math.max(1, grams),
      colours: lines.map((l) => ({ filamentId: l.filamentId, hex: l.hex, grams: l.grams, cost: l.cost })) });
  }
  return part;
}

/**
 * @param {object} facts  { qty, timeSec, filaments: [{type, colour, grams}], printer: {preset} }
 * @param {object} ctx    { settings, inventory, printers (shop presets), overheadPerHour?, round? }
 */
function priceSlice(facts, ctx) {
  const c = ctx || {};
  const f = readFacts(facts);
  if (!f) return { unpriced: 'bad-facts' };
  const PR = lib('KhaytPrintRates', './print-rates.js');
  const CC = lib('KhaytCalculatorCost', './calculator-cost.js');
  const P = lib('KhaytPricing', './pricing.js');
  if (!PR || !CC || !P) throw new Error('connector-price: KhaytPrintRates, KhaytCalculatorCost and KhaytPricing must be loaded');
  const settings = c.settings || {};

  // A shop that has not said its currency gets no figure, not one in SAR.
  const currency = typeof settings.currency === 'string' && /^[A-Z]{3}$/.test(settings.currency) ? settings.currency : '';
  if (!currency) return { unpriced: 'no-currency' };
  const raw = partFrom(f, c);
  if (!raw) return { unpriced: 'no-material' };
  const want = f.preset.toLowerCase();
  const preset = want ? (Array.isArray(c.printers) ? c.printers : []).find((p) => p && typeof p.name === 'string' && p.name.trim().toLowerCase() === want) : null;
  const part = PR.withRates(raw, { settings, preset: preset || undefined });

  const unitCost = CC.computePartBaseCost(part, { inventory: c.inventory || [], settings });
  if (!Number.isFinite(unitCost) || unitCost < 0) return { unpriced: 'bad-facts' };
  const overheadPerHour = Math.max(0, +c.overheadPerHour || 0);
  const margin = typeof settings.defaultMargin === 'number' && Number.isFinite(settings.defaultMargin) ? Math.max(0, settings.defaultMargin) : 30;
  const round = c.round && +c.round.step > 0 ? { step: +c.round.step, mode: c.round.mode } : null;
  const q = P.quoteTotal({
    baseCost: unitCost * f.qty, qty: f.qty, margin,
    overheadPerHour, printHours: f.hours * f.qty,
    discountPct: 0, rushEnabled: false, shippingCost: 0, extraLines: [], business: true,
    ...(round ? { priceRound: round } : {}),
  });
  const total = r2(+(q && q.total) || 0);
  const rounded = !!(q && q.priceSource === 'rounded');
  // What it costs the shop: the part, and its overhead by the print hour
  // (a cost, as quoteTotal counts it), so the margin shown is the real one.
  const unitAll = unitCost + overheadPerHour * f.hours;
  const costTotal = unitAll * f.qty;
  return {
    currency,
    qty: f.qty,
    unit: r2(total / f.qty),
    total,
    rounded,
    basis: preset ? 'measured' : 'assumed',
    cost: { unit: r4(unitAll), total: r2(costTotal) },
    // The margin three ways, for a device the shop lets see the cost: of the
    // price (pct), on the cost (pctOnCost, a markup) and in money (amount).
    margin: {
      pct: total > 0 ? r2((total - costTotal) / total * 100) : 0,
      // No cost, no markup to state: left out, never a misleading 0%.
      ...(costTotal > 0 ? { pctOnCost: r2((total - costTotal) / costTotal * 100) } : {}),
      amount: r2(total - costTotal),
    },
    // The step the price was rounded to, only when it was: a tab can say
    // "rounded to the nearest 5". Never the mode, and nothing when unrounded.
    ...(rounded && round ? { round: { step: round.step } } : {}),
  };
}

const api = { priceSlice, MAX_QTY, MAX_FILAMENTS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytConnectorPrice = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
