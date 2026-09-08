'use strict';
/**
 * Turning a customer's uploaded model into a number they are allowed to see.
 *
 * This is the only place in Khayt where a price is computed for someone who is
 * not the shop, so it is deliberately the most reluctant. It refuses far more
 * often than it answers, and every refusal says why:
 *
 *   - The shop has not switched public pricing on.        → off
 *   - The shop has not said what to charge.               → not-configured
 *   - The file gave us nothing usable.                    → no-numbers
 *   - The arithmetic produced nothing sane.               → no-price
 *
 * A price of "0" shown to a customer is a promise of free work, and a price
 * derived from a spool cost nobody set is a number the shop never agreed to.
 * Both are worse outcomes than "we'll get back to you", which is what the intake
 * form already does perfectly well on its own.
 *
 * When it does answer, it carries `exact` through from lib/model-intake.js. A
 * geometric estimate can be far out on a sparse or heavily-supported part, so a
 * customer must never be shown one without being told which it is — and no
 * result from here is a binding quote. The shop confirms.
 *
 * Pure: no fs, no network, no store writes. Cost and price come from the same
 * two functions the calculator screen uses, so a public number and a shop's own
 * number for the same part cannot disagree.
 */

/** Shape of settings.lanApi.intakeQuote, with the defaults that mean "not set up". */
const DEFAULT_CONFIG = {
  enabled: false,
  presetId: '',        // a printer preset — supplies the machine cost params
  filamentId: '',      // an inventory item — supplies the real material price
  spoolCost: 0,        // …or a flat basis, when no inventory item is chosen
  spoolWeight: 1000,
  marginPct: 0,
  minPrice: 0,
  wastePct: 0,         // purge/brim slack added to the customer's weight
  hourlyLimit: 12,     // estimates per visitor per hour (the LAN server enforces this)
};

const num = (v, d = 0) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
};

function refuse(reason, extra = {}) {
  return Object.assign({ ok: false, reason, price: null, grams: null, hours: null, exact: false }, extra);
}

/**
 * Resolve the shop's configured material basis to a cost per spool and a spool
 * weight. An inventory item wins because it is the price the shop actually pays.
 */
function materialBasis(cfg, inventory, reclaimsTax) {
  const list = Array.isArray(inventory) ? inventory : [];
  if (cfg.filamentId) {
    const item = list.find((i) => i && i.id === cfg.filamentId);
    if (item) {
      // THE PRICE WITHOUT THE TAX, for a shop that gets the tax back. A spool
      // bought for 75 including 9.78 of tax costs a print 65.22 — charging the
      // tax to the job would understate every margin the shop quotes. A spool
      // with no tax recorded, or a shop that cannot reclaim, costs what it
      // cost. `KhaytSpoolEdit.netCost` is the one place that decides.
      const SE = (typeof globalThis !== 'undefined' && globalThis.KhaytSpoolEdit) || null;
      const cost = (SE && typeof SE.netCost === 'function' && (item.cost != null))
        ? SE.netCost(item, !!reclaimsTax)
        : num(item.unitCost ?? item.cost ?? item.price, 0);
      const weight = num(item.spoolWeight ?? item.unitWeight ?? item.weight, 1000);
      if (cost > 0 && weight > 0) return { spoolCost: cost, spoolWeight: weight, from: 'inventory' };
    }
    // A configured filament that no longer exists is a broken setup, not a
    // reason to silently fall back to a flat number the shop may have forgotten.
    return null;
  }
  const spoolCost = num(cfg.spoolCost, 0);
  const spoolWeight = num(cfg.spoolWeight, 0);
  if (spoolCost > 0 && spoolWeight > 0) return { spoolCost, spoolWeight, from: 'flat' };
  return null;
}

/**
 * @param {object} input
 * @param {object} input.intake     a lib/model-intake.js result
 * @param {object} input.store      the shop's store ({ settings, inventory, printers })
 * @param {object} input.deps       { computePartBaseCost, quoteTotal, estimate }
 * @param {number} [input.qty=1]
 * @returns {{
 *   ok: boolean, reason?: string,
 *   price: number|null, currency: string|null,
 *   grams: number|null, hours: number|null,
 *   exact: boolean, source: string|null, slicer: string|null,
 *   binding: false
 * }}
 */
function publicQuote(input) {
  const { intake, store, deps } = input || {};
  const qty = Math.max(1, Math.min(1000, num(input && input.qty, 1)));
  const settings = (store && store.settings) || {};
  const cfg = Object.assign({}, DEFAULT_CONFIG, (settings.lanApi && settings.lanApi.intakeQuote) || {});
  const currency = settings.currency || null;

  // Off unless the shop turned it on. Not a default anyone drifts into.
  if (!cfg.enabled) return refuse('off');
  if (!intake) return refuse('no-numbers');
  if (!deps || typeof deps.computePartBaseCost !== 'function' || typeof deps.quoteTotal !== 'function') {
    return refuse('no-price');
  }

  // --- what will it weigh, and for how long? --------------------------------
  let grams = null, hours = null;
  // Exact figures off a slicer are always trustworthy; only the geometric
  // estimate can fall outside the model's range.
  let reliable = true;
  const exact = !!(intake.exact && intake.printTimeMins > 0 && intake.filamentGrams > 0);
  if (exact) {
    grams = num(intake.filamentGrams, 0);
    hours = num(intake.printTimeMins, 0) / 60;
  } else if (intake.source === 'geometry' && intake.geometry && intake.geometry.volumeMm3 > 0
             && typeof deps.estimate === 'function') {
    // The shop's own estimator settings, not the module defaults. A customer's
    // quote must be built on the same assumptions the shop uses itself —
    // otherwise the number they are shown is not the number the shop would have
    // reached for the same part.
    const est = deps.estimate(intake.geometry, deps.estimatorOpts || {});
    grams = num(est.estWeightG, 0);
    hours = num(est.estPrintTimeH, 0);
    // Carried all the way out to the customer. A quote this shop would not
    // stand behind must not look like one it would — scored against a real
    // slicer, geometry in this range lands between +58% and -66%.
    reliable = est.reliable !== false;
  }
  if (!(grams > 0) || !(hours > 0)) return refuse('no-numbers');

  // Purge, brim and support slack the customer's file does not account for.
  const waste = Math.min(0.5, Math.max(0, num(cfg.wastePct, 0)));
  grams = grams * (1 + waste);

  // --- what does the shop charge? ------------------------------------------
  // Whether the shop reclaims the tax it pays decides what a spool costs a job.
  // Read through the tax rule so this agrees with the invoice and the P&L.
  const T = (typeof globalThis !== 'undefined' && globalThis.KhaytTax) || null;
  const reclaimsTax = !!(T && T.profileFromSettings
    && (T.profileFromSettings((store && store.settings) || {}).rates || []).length);
  const basis = materialBasis(cfg, store && store.inventory, reclaimsTax);
  if (!basis) return refuse('not-configured', { missing: 'material' });

  const presets = (store && store.printers) || [];
  const preset = cfg.presetId ? presets.find((p) => p && p.id === cfg.presetId) : null;
  if (cfg.presetId && !preset) return refuse('not-configured', { missing: 'printer' });
  if (!preset) return refuse('not-configured', { missing: 'printer' });

  const part = {
    qty,
    printWeight: grams,
    printTime: hours,
    spoolCost: basis.spoolCost,
    spoolWeight: basis.spoolWeight,
    wearRate: num(preset.wearRate, 0),
    powerDraw: num(preset.powerDraw, 0),
    elecRate: num(preset.elecRate, 0),
    laborRate: num(preset.laborRate, 0),
    failureRate: num(preset.failureRate, 0),
    prepTime: num(preset.prepTime, 0),
    postTime: num(preset.postTime, 0),
  };

  let unitCost;
  try {
    unitCost = deps.computePartBaseCost(part, {
      inventory: (store && store.inventory) || [],
      settings,
    });
  } catch (e) { return refuse('no-price'); }
  // Belt and braces: quoteTotal already clamps Infinity/NaN/negative to zero,
  // which the price check below then rejects. This only fails faster and says
  // where the problem was.
  if (!Number.isFinite(unitCost) || unitCost <= 0) return refuse('no-price');

  let total;
  try {
    total = deps.quoteTotal({
      baseCost: unitCost * qty,
      qty,
      margin: num(cfg.marginPct, 0),
      // No discount, no rush, no shipping: a public estimate quotes the part,
      // and anything else is a conversation the shop has not had yet.
      discountPct: 0,
      rushEnabled: false,
      shippingCost: 0,
      extraLines: [],
    });
  } catch (e) { return refuse('no-price'); }

  let price = num(total && total.total, 0);
  const floor = num(cfg.minPrice, 0);
  if (floor > 0 && price < floor) price = floor;
  // Round BEFORE the sanity check, not after. A cost of 4e-15 is greater than
  // zero and passes an unrounded test, then renders as "0.00" — a customer shown
  // a price of zero has been promised free work, which is the exact outcome this
  // module exists to prevent.
  price = Math.round(price * 100) / 100;
  if (!(price > 0)) return refuse('no-price');

  return {
    ok: true,
    price,
    currency,
    qty,
    grams: Math.round(grams * 10) / 10,
    hours: Math.round(hours * 100) / 100,
    exact,
    // false when the geometry is outside what the estimator can describe. The
    // caller MUST show this — a number the shop would not stand behind must not
    // arrive looking like one it would.
    reliable,
    source: intake.source || null,
    slicer: exact ? (intake.slicer || null) : null,
    // Carried through for the SHOP, not for the visitor — see the caller. A
    // customer gets a price; whether the model needs supports is the shop's
    // decision to make when they accept the job, and the endpoint that answers
    // strangers does not repeat it back to them.
    risk: intake.risk || null,
    // Never true. The shop confirms every price; this only starts the conversation.
    binding: false,
  };
}

module.exports = { publicQuote, DEFAULT_CONFIG };
