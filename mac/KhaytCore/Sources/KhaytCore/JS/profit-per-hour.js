'use strict';
(function (global) {
/**
 * Which catalogue products earn the most for each hour on the printer.
 *
 * A shop with one printer does not run out of money or shelf space first. It
 * runs out of MACHINE HOURS. Two products that each make 40 profit are not
 * equal if one takes two hours and the other twenty: the first earns 20 an
 * hour and the second 2. Ranking the catalogue by profit per sale hides that,
 * and the product it hides is the one that fills the week.
 *
 *   profit per hour = (price − cost) / print hours
 *
 * ── TWO FIGURES, AND THEY ARE KEPT APART ──────────────────────────────────
 *
 *   planned  from the catalogue record: the price the shop charges
 *            (`product-price.finalPrice` over the stored base price), the cost
 *            `product-pricing` wrote beside it, and the machine hours
 *            `product-specs` sums from its parts. Every product has one, even
 *            one never sold.
 *
 *   actual   from finished jobs that carry the product's id, through
 *            `product-profit` — real revenue, real part cost, linked expenses
 *            and, where the printer or the shop recorded it, the hours the job
 *            actually took (`actualPrintTime`), not the estimate. Only products
 *            that have been made have one.
 *
 * They are not blended. A planned figure that says 30 an hour beside an actual
 * one that says 18 is the finding, and averaging them would hide it.
 *
 * ── NOT-BUSINESS JOBS ARE LEFT OUT ────────────────────────────────────────
 *
 * `business-scope.countsForBusiness`: a calibration print or a gift is not a
 * sale and must not make a product look like it earns nothing.
 *
 * ── NO HOURS, NO PRICE ───────────────────────────────────────────────────
 *
 * A product with no hours has no rate — null, never a division by zero into an
 * Infinity that sorts to the top. A product with no price has no profit, and a
 * zero would read as "breaks even". Both still appear, last, with the reason.
 *
 * Pure: no DOM, no fs, no Electron. Its neighbours are reached through globals,
 * the way every module in this folder reaches another, and each can be
 * injected for a test.
 */

const FINISHED = ['completed', 'delivered'];

function num(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
const pos = (v) => { const n = num(v); return n !== null && n > 0 ? n : 0; };
const money = (v) => Math.round(v * 100) / 100;

function g(name) {
  return (typeof global !== 'undefined' && global[name]) || null;
}

/** Machine hours for one product: `product-specs`, or its rule if not loaded. */
function defaultHoursOf(product) {
  const PS = g('KhaytProductSpecs');
  if (PS && typeof PS.productSpecs === 'function') return PS.productSpecs(product).printHours;
  const parts = (product && Array.isArray(product.parts)) ? product.parts : [];
  const h = parts.reduce((s, p) => s + pos(p && p.printTime) * (pos(p && p.qty) || 1), 0);
  return h > 0 ? h : null;
}

/**
 * Hours a finished JOB occupied the machine: what it actually took when that
 * was recorded, the estimate otherwise. `machine-pl`'s rule — a typed actual is
 * still the shop's best account of the time.
 */
function jobHours(order) {
  const actual = pos(order && order.actualPrintTime);
  if (actual > 0) return actual;
  return estimatedJobHours(order);
}

function estimatedJobHours(order) {
  const parts = (order && Array.isArray(order.parts)) ? order.parts : [];
  const fromParts = parts.reduce((s, p) => s + pos(p && p.printTime) * (pos(p && p.qty) || 1), 0);
  return fromParts > 0 ? fromParts : pos(order && order.printTime);
}

/** Was this job's time reported by a printer, rather than typed or confirmed? */
function timeWasMeasured(order) {
  const src = order && order.actualsSource;
  return !!(src && src.time && src.time !== 'manual');
}

/**
 * @param {object} input
 *   products     catalogue records
 *   orders       every order (which ones are finished and business is decided here)
 *   expenses     expenses, linked to a job by `orderId`
 *   inventory, settings, consumables
 *                only to cost a product whose record carries no `baseCost`
 *   minForAverage  how many ranked products before "the shop's average" means
 *                anything (default 3 — with two, one is always "below average")
 *   underFraction  a product earning under this share of the average per hour
 *                is flagged underpriced (default 0.6)
 * @param {object} deps  every one optional
 *   priceOf(product)   => { price: number|null, cost: number|null }
 *   hoursOf(product)   => machine hours for one, or null
 *   nameOf(product)    => what to call it
 *   revenueOf(order), partCostOf(part), countsForBusiness(order)
 *                      passed through to `product-profit` for the actual side
 *   productProfit, compare, median, confidenceFor
 *                      the neighbouring modules, for a test to replace
 * @returns {{rows: Array, totals: object}}
 */
function productRates(input, deps) {
  const i = input || {};
  const d = deps || {};
  const products = (Array.isArray(i.products) ? i.products : []).filter((p) => p && p.id);
  const minForAverage = Number.isFinite(i.minForAverage) ? i.minForAverage : 3;
  const underFraction = Number.isFinite(i.underFraction) ? i.underFraction : 0.6;

  const PP = g('KhaytProductPrice');
  const PR = g('KhaytProductPricing');
  const priceOf = typeof d.priceOf === 'function' ? d.priceOf : (p) => {
    const override = num(p.priceOverride);
    const base = num(p.basePrice);
    // Never priced: no calculated price and no typed one. A typed 0 IS a
    // price (a giveaway), so the test is "is there a number", not truthiness.
    if (base === null && override === null && num(p.price) === null) return { price: null, cost: null };
    const fp = PP && typeof PP.finalPrice === 'function'
      ? PP.finalPrice(p, base !== null ? base : (num(p.price) || 0))
      : { final: override !== null ? override : (base !== null ? base : num(p.price)), source: 'base' };
    if (!(fp.final > 0) && fp.source !== 'override') return { price: null, cost: null };
    // The cost `product-pricing` wrote beside the price. Worked out afresh only
    // for a record that has none — an older one, or one typed elsewhere.
    let cost = num(p.baseCost);
    if (cost === null && PR && typeof PR.priceProduct === 'function') {
      cost = PR.priceProduct(p, { inventory: i.inventory, settings: i.settings,
                                  consumables: i.consumables }).cost;
    }
    return { price: fp.final, cost: cost === null ? 0 : cost };
  };
  const hoursOf = typeof d.hoursOf === 'function' ? d.hoursOf : defaultHoursOf;
  const nameOf = typeof d.nameOf === 'function' ? d.nameOf : (p) => String((p && p.name) || '');
  const BS = g('KhaytBusinessScope');
  const countsForBusiness = typeof d.countsForBusiness === 'function' ? d.countsForBusiness
    : (o) => (BS ? BS.countsForBusiness(o) : !!o && o.nonBusiness !== true);

  // ── ACTUAL: what the finished work earned, per product ──────────────────
  const profitFn = typeof d.productProfit === 'function' ? d.productProfit
    : (g('KhaytProductProfit') && g('KhaytProductProfit').productProfit);
  const actualById = new Map();
  if (typeof profitFn === 'function') {
    const report = profitFn(
      { orders: i.orders, products, expenses: i.expenses, untagged: '' },
      { revenueOf: d.revenueOf, partCostOf: d.partCostOf, hoursOf: jobHours,
        nameOf, countsForBusiness });
    for (const r of (report && report.rows) || []) actualById.set(String(r.productId), r);
  }

  // How far the real hours ran from the estimate, per product, from printer
  // MEASURED jobs only: a typed actual is usually the estimate confirmed, and
  // would report a drift of zero (see estimate-variance.js).
  const PA = g('KhaytPrinterActuals');
  const EV = g('KhaytEstimateVariance');
  const compare = typeof d.compare === 'function' ? d.compare : (PA && PA.compareToEstimate);
  const median = typeof d.median === 'function' ? d.median : (EV && EV.median);
  const confidenceFor = typeof d.confidenceFor === 'function' ? d.confidenceFor
    : (EV && EV.confidenceFor) || ((n) => (n >= 5 ? 'good' : n >= 3 ? 'fair' : 'thin'));
  const drifts = new Map();
  if (typeof compare === 'function') {
    for (const o of (Array.isArray(i.orders) ? i.orders : [])) {
      if (!o || o.voidedAt || !o.productId) continue;
      if (!FINISHED.includes(String(o.status || ''))) continue;
      if (!countsForBusiness(o) || !timeWasMeasured(o)) continue;
      const est = estimatedJobHours(o);
      const act = pos(o.actualPrintTime);
      if (!est || !act) continue;
      const c = compare({ printTime: est }, { durationS: act * 3600 });
      if (!c || c.hoursDeltaPct === null || c.hoursDeltaPct === undefined) continue;
      const key = String(o.productId);
      if (!drifts.has(key)) drifts.set(key, []);
      drifts.get(key).push(c.hoursDeltaPct);
    }
  }

  // ── PLANNED: every product, from its own record ─────────────────────────
  const rows = products.map((p) => {
    const id = String(p.id);
    const priced = priceOf(p) || {};
    const price = num(priced.price);
    const cost = num(priced.cost);
    const h = num(hoursOf(p));
    const hours = h !== null && h > 0 ? h : null;
    const profit = price !== null ? money(price - (cost || 0)) : null;
    const perHour = profit !== null && hours !== null ? money(profit / hours) : null;

    let actual = null;
    const a = actualById.get(id);
    if (a && a.jobs > 0) {
      const found = drifts.get(id) || [];
      actual = {
        jobs: a.jobs,
        revenue: money(a.revenue),
        cost: money(a.cost),
        hours: Math.round(a.hours * 100) / 100,
        profit: money(a.profit),
        perHour: a.profitPerHour === null || a.profitPerHour === undefined
          ? null : money(a.profitPerHour),
        measured: found.length,
        hoursDriftPct: found.length && typeof median === 'function' ? median(found) : null,
        confidence: found.length ? confidenceFor(found.length) : null,
      };
    }

    return {
      productId: id,
      name: nameOf(p),
      price, cost: cost === null ? null : money(cost), hours, profit, perHour,
      // Why a product has no rate, so a screen can say so instead of a blank.
      missing: price === null ? 'price' : hours === null ? 'hours' : null,
      actual,
      underpriced: false,
      suggestedPrice: null,
      priceRound: p.priceRound || null,
    };
  });

  // ── THE RANK ────────────────────────────────────────────────────────────
  // Planned rate first: it is the only figure every product has, so it is the
  // only one that compares like with like. The actual breaks a tie. Products
  // with no rate go last, by name — they are not the worst earners, they are
  // unknown.
  const ranked = rows.filter((r) => r.perHour !== null);
  const unranked = rows.filter((r) => r.perHour === null);
  const actualRate = (r) => (r.actual && r.actual.perHour !== null ? r.actual.perHour : -Infinity);
  ranked.sort((a, b) => b.perHour - a.perHour || actualRate(b) - actualRate(a)
                        || a.name.localeCompare(b.name));
  unranked.sort((a, b) => a.name.localeCompare(b.name));

  // ── THE SHOP'S OWN AVERAGE ──────────────────────────────────────────────
  // Hours-weighted — total profit over total hours, "one of each" — rather than
  // the mean of the rates, which a single five-minute keyring at 200 an hour
  // would drag up past everything the printer actually spends its week on.
  const sumProfit = ranked.reduce((s, r) => s + r.profit, 0);
  const sumHours = ranked.reduce((s, r) => s + r.hours, 0);
  const averagePerHour = ranked.length >= minForAverage && sumHours > 0
    ? money(sumProfit / sumHours) : null;

  if (averagePerHour !== null && averagePerHour > 0) {
    for (const r of ranked) {
      if (r.perHour >= averagePerHour * underFraction) continue;
      r.underpriced = true;
      // The price that would earn the shop's average for the hours it takes,
      // rounded UP to the shop's own step so the suggestion is never below it.
      let s = (r.cost || 0) + averagePerHour * r.hours;
      const step = r.priceRound && num(r.priceRound.step);
      if (PP && typeof PP.roundToStep === 'function' && step && step > 0) {
        s = PP.roundToStep(s, step, 'up');
      }
      r.suggestedPrice = money(s);
    }
  }
  for (const r of rows) delete r.priceRound;

  const withActual = rows.filter((r) => r.actual && r.actual.perHour !== null);
  const actHours = withActual.reduce((s, r) => s + r.actual.hours, 0);
  const actProfit = withActual.reduce((s, r) => s + r.actual.profit, 0);

  return {
    rows: ranked.concat(unranked),
    totals: {
      ranked: ranked.length,
      noHours: rows.filter((r) => r.missing === 'hours').length,
      noPrice: rows.filter((r) => r.missing === 'price').length,
      averagePerHour,
      actualPerHour: actHours > 0 ? money(actProfit / actHours) : null,
      best: ranked.length ? ranked[0].productId : null,
      underpriced: ranked.filter((r) => r.underpriced).length,
    },
  };
}

/**
 * Gentle suggestions for the products a web store lists.
 *
 * @param {object} result  what `productRates` returned
 * @param {string[]} listedIds  the products the store lists
 * @param {{top?: number}} [opts]
 * @returns {{best: Array, underpriced: Array}} rows from `result`, best first
 */
function storeHints(result, listedIds, opts) {
  const top = opts && Number.isFinite(opts.top) ? opts.top : 3;
  const listed = new Set((Array.isArray(listedIds) ? listedIds : []).map(String));
  const rows = ((result && result.rows) || []).filter((r) => listed.has(r.productId));
  const earning = rows.filter((r) => r.perHour !== null && r.perHour > 0);
  // Only worth saying when there is a choice to make: one listed product is
  // trivially the best one.
  const best = earning.length >= 2 ? earning.slice(0, top) : [];
  const underpriced = rows.filter((r) => r.underpriced);
  return { best, underpriced };
}

const api = { productRates, storeHints, jobHours, FINISHED };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytProfitPerHour = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
