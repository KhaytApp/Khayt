'use strict';
(function () {
/**
 * AI price assist — recommend a margin/price grounded in the shop's OWN
 * realized history. Like lib/ai-quote.js + lib/ai-assistant.js: pure +
 * transport-injected. buildComparables() is deterministic (so it's testable and
 * trustworthy on its own); the prompt builders feed those comparables to the
 * model via the owner's key so it can phrase a recommendation and weigh
 * outliers — never inventing numbers absent from the comparables.
 */

const DONE = new Set(['completed', 'delivered']);

const PRICE_SCHEMA = {
  type: 'object',
  required: ['suggestedMargin'],
  properties: {
    suggestedMargin: { type: 'number' },
    suggestedPrice: { type: 'number' },
    rationale: { type: 'string' },
  },
};

/** Reduce a free-text material ("PETG - Black (Brand)") to its family token. */
function materialFamily(s) {
  const m = String(s == null ? '' : s).toUpperCase().match(/[A-Z][A-Z0-9+]*/);
  return m ? m[0] : '';
}

function orderFamilies(o) {
  const fams = new Set();
  for (const p of (o.parts || [])) { const f = materialFamily(p && p.material); if (f) fams.add(f); }
  if (!fams.size && o.material) { const f = materialFamily(o.material); if (f) fams.add(f); }
  return fams;
}

/**
 * What a finished job actually made, as a percentage of what the shop KEPT.
 *
 * ── NET OF TAX, BECAUSE THE TAX WAS NEVER THE SHOP'S ──────────────────────
 *
 * `price` is what the customer paid. For an INCLUSIVE-VAT shop — which is Saudi
 * and most of the Gulf, and most of Europe — part of that is the tax
 * authority's and was never revenue. Margin against the gross therefore
 * overstates every comparable in this file, and this module exists to
 * recommend a margin FROM those comparables: a Riyadh shop at 15% was shown
 * 56.5% where it had actually made 50.0%, and pricing to the number it was
 * shown leaves it thinner than it thinks by exactly that much.
 *
 * `KhaytTax.netOfTax` is mode-aware and is already what `kpi-rows`,
 * `top-lists` and `pnl-report` use for revenue. Reached through the global and
 * guarded, the same way those three reach it — a shop with no profile, or a
 * host that has not loaded `tax`, gets the gross, which is what an unregistered
 * shop's price is anyway.
 */
function realizedMargin(o, profile) {
  const charged = +o.price || 0, cost = +o.costBasis || 0;
  if (charged <= 0 || cost <= 0) return null;
  const T = (typeof globalThis !== 'undefined' && globalThis.KhaytTax) || null;
  const price = (T && profile && typeof T.netOfTax === 'function')
    ? T.netOfTax(charged, profile)
    : charged;
  if (price <= 0) return null;
  return ((price - cost) / price) * 100;
}

function median(nums) {
  if (!nums.length) return 0;
  const a = nums.slice().sort((x, y) => x - y);
  const mid = Math.floor(a.length / 2);
  return a.length % 2 ? a[mid] : (a[mid - 1] + a[mid]) / 2;
}
const round1 = (n) => Math.round(n * 10) / 10;

/**
 * Comparable-order stats for a material, grounded in realized margins.
 * Prefers same-material history; falls back to all priced jobs when a material
 * has too few (<3) comparables. basis: 'material' | 'all' | 'none'.
 */
function buildComparables(printLog, opts) {
  opts = opts || {};
  const fam = materialFamily(opts.material);
  // The shop's own tax position, resolved ONCE for the whole history rather
  // than per order: it is a property of the shop, not of the job.
  const T = (typeof globalThis !== 'undefined' && globalThis.KhaytTax) || null;
  const profile = (T && opts.settings && typeof T.profileFromSettings === 'function')
    ? T.profileFromSettings(opts.settings)
    : null;
  const priced = (Array.isArray(printLog) ? printLog : [])
    .filter((o) => o && DONE.has(o.status) && realizedMargin(o, profile) != null)
    .map((o) => ({ o, margin: realizedMargin(o, profile), fams: orderFamilies(o) }));

  let basis = 'material';
  let rows = fam ? priced.filter((r) => r.fams.has(fam)) : [];
  if (rows.length < 3) { rows = priced; basis = priced.length ? 'all' : 'none'; }
  if (!rows.length) return { basis: 'none', material: fam, count: 0 };

  const margins = rows.map((r) => r.margin);
  const examples = rows.slice()
    .sort((a, b) => (Date.parse(b.o.date || b.o.completedAt || 0) || 0) - (Date.parse(a.o.date || a.o.completedAt || 0) || 0))
    .slice(0, 6)
    .map((r) => ({ project: String(r.o.project || r.o.id || ''), price: Math.round(+r.o.price || 0), marginPct: round1(r.margin) }));

  const avg = margins.reduce((s, m) => s + m, 0) / margins.length;
  const med = median(margins);
  return {
    basis, material: fam, count: rows.length,
    avgMarginPct: round1(avg),
    medianMarginPct: round1(med),
    minMarginPct: round1(Math.min(...margins)),
    maxMarginPct: round1(Math.max(...margins)),
    suggestedMargin: round1(med),   // median is robust to outliers
    examples,
  };
}

function buildPriceSystem(opts) {
  opts = opts || {};
  const lang = opts.lang === 'ar' ? 'Arabic' : 'English';
  return [
    `You price jobs for ${opts.shopName || 'a 3D-printing shop'}.`,
    `Write the rationale in ${lang}.`,
    'Recommend a target profit margin (%) and the resulting price for the new job,',
    'grounded ONLY in the comparable realized margins provided — do not invent figures.',
    'Favor the median of comparables; nudge for outliers or thin samples and say why in one short sentence.',
    'suggestedPrice must equal cost / (1 - suggestedMargin/100), rounded sensibly.',
  ].join(' ');
}

function buildPriceRequest(comparables, job) {
  job = job || {};
  return 'Comparable history (JSON):\n' + JSON.stringify(comparables)
    + '\n\nNew job:\n' + JSON.stringify({
      material: job.material || '', grams: job.grams || 0, hours: job.hours || 0,
      cost: job.cost || 0, currency: job.currency || '',
    })
    + '\n\nRecommend suggestedMargin (%), suggestedPrice, and a one-line rationale.';
}

function pickPrice(result, fallback) {
  const r = result || {};
  const margin = Number(r.suggestedMargin);
  if (!Number.isFinite(margin)) return fallback || null;
  return {
    suggestedMargin: Math.max(0, round1(margin)),
    suggestedPrice: Number.isFinite(+r.suggestedPrice) ? Math.round(+r.suggestedPrice * 100) / 100 : null,
    rationale: String(r.rationale || '').trim(),
  };
}

const api = { PRICE_SCHEMA, materialFamily, buildComparables, buildPriceSystem, buildPriceRequest, pickPrice };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiPrice = api;

})();
