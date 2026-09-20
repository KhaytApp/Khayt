'use strict';
(function () {

/**
 * Marketplace fees, as quote lines.
 *
 * Asked for twice by the same shop (issue #364, item 1 and again in an earlier
 * email), which is the strongest signal in that thread:
 *
 *   "Etsy for instance charges two percentage based fees and a relisting fee of
 *    .20 for each item sold."
 *
 * Half of this already worked. Since v3.6.0-beta.14 a quote line can be either a
 * flat amount or a percentage, and lib/pricing.js resolves percentages against
 * the pre-extras subtotal — deliberately, because that is what a marketplace
 * actually charges against. What was missing is that a shop had to remember
 * Etsy's three numbers and type them by hand on every quote.
 *
 * So this holds the numbers and emits lines in the shape the calculator already
 * understands: `{ label, pct }` or `{ label, amount }`. Nothing downstream
 * changes — pricing, the invoice, and the totals all treat these as the extra
 * lines they already are.
 *
 * THE RATES ARE A STARTING POINT, NOT AN AUTHORITY. Marketplaces change them,
 * they vary by country and category, and a shop on a legacy plan pays different
 * ones. Every preset is editable and the shop's own edits win — see
 * platformFor(). Getting this wrong quietly is worse than not shipping it, so
 * the UI shows the resolved money before anything is added.
 *
 * Pure: no DOM, no settings object, no globals.
 */

/**
 * Default fee schedules, keyed by the storefront ids already used in
 * lib/integrations-registry.js so the two agree on what a platform is called.
 *
 * `pct` lines are percentages of the pre-extras subtotal; `amount` lines are
 * flat, in the shop's currency. Flat fees are inherently currency-specific and
 * are quoted here in USD, which is why they are the first thing a shop should
 * check.
 */
const PRESETS = Object.freeze({
  etsy: {
    name: 'Etsy',
    lines: [
      { key: 'transaction', label: 'Etsy transaction fee', pct: 6.5 },
      { key: 'processing', label: 'Etsy payment processing', pct: 3 },
      { key: 'listing', label: 'Etsy listing fee', amount: 0.20 },
    ],
  },
  shopify: {
    name: 'Shopify',
    lines: [{ key: 'processing', label: 'Shopify payment processing', pct: 2.9 },
            { key: 'per_order', label: 'Shopify per-transaction fee', amount: 0.30 }],
  },
  ebay: {
    name: 'eBay',
    lines: [{ key: 'final_value', label: 'eBay final value fee', pct: 13.25 },
            { key: 'per_order', label: 'eBay per-order fee', amount: 0.30 }],
  },
  amazon: {
    name: 'Amazon',
    lines: [{ key: 'referral', label: 'Amazon referral fee', pct: 15 }],
  },
  woocommerce: {
    name: 'WooCommerce',
    lines: [{ key: 'processing', label: 'Payment processing', pct: 2.9 },
            { key: 'per_order', label: 'Per-transaction fee', amount: 0.30 }],
  },
  salla: {
    name: 'Salla',
    lines: [{ key: 'processing', label: 'Salla payment processing', pct: 2.75 }],
  },
  zid: {
    name: 'Zid',
    lines: [{ key: 'processing', label: 'Zid payment processing', pct: 2.75 }],
  },
});

/** Platform ids a shop can pick, in a stable order for a dropdown. */
function platformIds() {
  return Object.keys(PRESETS);
}

/**
 * The fee schedule in force for a platform: the shop's saved edits when it has
 * any, otherwise the shipped defaults.
 *
 * A saved schedule REPLACES rather than merges. Merging would make a line the
 * shop deliberately deleted reappear on the next update, which is the worst
 * failure mode here — an invisible charge on a customer quote.
 */
function platformFor(id, settings) {
  const key = String(id || '');
  const preset = PRESETS[key];
  if (!preset) return null;
  const saved = settings && settings.platformFees && settings.platformFees[key];
  if (saved && Array.isArray(saved.lines)) {
    return { id: key, name: String(saved.name || preset.name), lines: normalizeLines(saved.lines) };
  }
  return { id: key, name: preset.name, lines: normalizeLines(preset.lines) };
}

/** Drop anything that would charge nothing or cannot be understood. */
function normalizeLines(lines) {
  return (Array.isArray(lines) ? lines : []).map((l, i) => {
    if (!l || typeof l !== 'object') return null;
    const label = String(l.label || '').trim();
    if (!label) return null;
    const pct = Number(l.pct);
    if (Number.isFinite(pct) && pct > 0) return { key: String(l.key || `p${i}`), label, pct };
    const amount = Number(l.amount);
    if (Number.isFinite(amount) && amount > 0) return { key: String(l.key || `a${i}`), label, amount };
    return null;
  }).filter(Boolean);
}

/**
 * Quote lines for a platform, in the shape renderer/build.js already appends.
 *
 * `id` is carried so the same platform cannot be added twice — the calculator
 * replaces its previous set rather than stacking a second copy, which is what a
 * shop would otherwise do by clicking twice and only notice on the invoice.
 */
function feeLinesFor(id, settings) {
  const p = platformFor(id, settings);
  if (!p) return [];
  return p.lines.map((l) => (l.pct != null
    ? { id: `PF-${p.id}-${l.key}`, platformId: p.id, label: l.label, pct: l.pct }
    : { id: `PF-${p.id}-${l.key}`, platformId: p.id, label: l.label, amount: l.amount }));
}

/**
 * What a platform's fees come to on a given subtotal — for showing the shop the
 * money BEFORE it is added to a customer's quote.
 *
 * Percentages resolve against `subtotal` (the pre-extras figure lib/pricing.js
 * uses), flat fees add as they are.
 */
function estimateFor(id, settings, subtotal) {
  const base = Number(subtotal);
  const s = Number.isFinite(base) && base > 0 ? base : 0;
  const lines = feeLinesFor(id, settings);
  const total = lines.reduce((sum, l) => sum + (l.pct != null ? s * l.pct / 100 : l.amount), 0);
  return { lines, total: Math.round((total + Number.EPSILON) * 100) / 100 };
}

/** True when these quote lines already carry this platform's fees. */
function hasPlatform(extraLines, id) {
  return (Array.isArray(extraLines) ? extraLines : []).some((l) => l && l.platformId === id);
}

/** Every line that is NOT a platform fee, preserving order. */
function withoutPlatformFees(extraLines) {
  return (Array.isArray(extraLines) ? extraLines : []).filter((l) => !(l && l.platformId));
}

const api = {
  PRESETS, platformIds, platformFor, feeLinesFor, estimateFor,
  hasPlatform, withoutPlatformFees, normalizeLines,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPlatformFees = api;

})();
