'use strict';
(function () {

/**
 * Reorder suggestions — consumption-aware restocking.
 *
 * Beyond the existing "low stock" badge (weight ≤ reorder point), this estimates
 * how fast each spool is consumed from completed-order history, projects
 * days-until-empty, and suggests how much to reorder to cover a target horizon.
 *
 * Pure + injected: the caller passes `partGrams` (the app's partGramsConsumed,
 * which mirrors the real deduction) and `isLow` (isLowStock), plus `now`, so the
 * whole thing is unit-testable with no globals.
 */

const DAY_MS = 86400000;

/** Best-effort completion timestamp (ms) for an order, or null. */
function completionMs(order) {
  const cand = order && (order.completedAt || order.deliveredAt);
  if (cand) { const t = Date.parse(cand); if (!Number.isNaN(t)) return t; }
  const hist = order && Array.isArray(order.statusHistory) ? order.statusHistory : [];
  for (let i = hist.length - 1; i >= 0; i--) {
    const h = hist[i];
    if (h && (h.status === 'completed' || h.status === 'delivered') && h.at) {
      const t = Date.parse(h.at); if (!Number.isNaN(t)) return t;
    }
  }
  return null;
}

/** Grams consumed per spool id over the window → { [spoolId]: gramsPerDay }. */
function consumptionByItem(orders, opts) {
  opts = opts || {};
  const partGrams = typeof opts.partGrams === 'function' ? opts.partGrams : (p) => (+(p && p.grams) || 0);
  const windowDays = opts.windowDays > 0 ? opts.windowDays : 30;
  const now = opts.now || 0;
  const since = now - windowDays * DAY_MS;
  const totals = {};
  for (const order of (orders || [])) {
    if (!order) continue;
    const done = completionMs(order);
    if (done == null || done < since || done > now) continue;
    const parts = Array.isArray(order.parts) ? order.parts : [];
    for (const p of parts) {
      const key = p && (p.spoolId || p.filamentId);
      if (!key) continue;
      totals[key] = (totals[key] || 0) + (+partGrams(p) || 0);
    }
  }
  const rates = {};
  for (const key of Object.keys(totals)) rates[key] = totals[key] / windowDays;
  return rates;
}

/** Open (not yet consumed) orders whose parts commit grams against a spool. */
const OPEN_STATUSES = new Set(['pending', 'queued', 'printing', 'post', 'qc', 'on_hold']);

/** Grams already committed by OPEN orders per spool id → { [spoolId]: grams }. */
function committedByItem(orders, opts) {
  opts = opts || {};
  const partGrams = typeof opts.partGrams === 'function' ? opts.partGrams : (p) => (+(p && p.grams) || 0);
  const totals = {};
  for (const order of (orders || [])) {
    if (!order || !OPEN_STATUSES.has(order.status)) continue;
    for (const p of (Array.isArray(order.parts) ? order.parts : [])) {
      const key = p && (p.spoolId || p.filamentId);
      if (!key) continue;
      totals[key] = (totals[key] || 0) + (+partGrams(p) || 0);
    }
  }
  return totals;
}

/**
 * How long one item lasts at the rate it is being used.
 *
 * The arithmetic `reorderSuggestions` has always done, lifted out so the shelf
 * can ask the same question about EVERY spool without the reorder list's
 * filter. Two callers, one sum: a shelf saying "empty in 9 days" beside a
 * reorder list that thinks it is 14 would be worse than neither.
 *
 * `daysLeft` is null for "cannot say" — nothing used in the window, so there is
 * no rate to project. That is not "lasts forever": a spool nobody has printed
 * with this month has an unknown future, not an infinite one, and a screen that
 * writes ∞ over it is lying with more confidence than a blank.
 *
 * `emptyAt` is `now` plus that many days, and is an ESTIMATE from a trailing
 * 30-day average — fine for "order more this week", not for a promise to a
 * customer. Callers that show a date should round it to the day.
 */
function runway(item, gramsPerDay, committedG, now) {
  const weight = +(item && item.weight) || 0;
  const committed = +committedG || 0;
  // Headroom after work already in the queue, which is what is actually
  // available to a new job.
  const available = Math.max(0, weight - committed);
  const rate = +gramsPerDay || 0;
  let daysLeft = null;
  if (rate > 0) daysLeft = available / rate;
  else if (committed > weight) daysLeft = 0;   // already oversold, rate unknown
  return {
    weight,
    committedG: committed,
    available,
    gramsPerDay: rate,
    daysLeft,
    emptyAt: daysLeft === null || !now ? null : now + daysLeft * DAY_MS,
  };
}

/**
 * The runway for every item on the shelf, urgent or not.
 *
 * Unfiltered on purpose — `reorderSuggestions` answers "what should I buy",
 * and this answers "how long has this one got", which a shelf asks of a spool
 * that is in no trouble at all.
 *
 * @returns {Object<string, ReturnType<typeof runway>>} keyed by item id
 */
function runwayByItem(inventory, orders, opts) {
  opts = opts || {};
  const rates = consumptionByItem(orders, opts);
  const committed = committedByItem(orders, opts);
  const out = {};
  for (const item of (inventory || [])) {
    if (!item || !item.id) continue;
    out[item.id] = runway(item, rates[item.id], committed[item.id], opts.now || 0);
  }
  return out;
}

/**
 * Suggest reorders. Returns items that are low OR projected to deplete within
 * `leadDays`, each with { item, weight, committedG, available, gramsPerDay,
 * daysLeft, low, suggestG }, sorted most-urgent first. Open orders' committed
 * grams are subtracted from on-hand stock, so the forecast accounts for work
 * already in the queue (not just past usage velocity).
 */
function reorderSuggestions(inventory, orders, opts) {
  opts = opts || {};
  const isLow = typeof opts.isLow === 'function' ? opts.isLow : () => false;
  const leadDays = opts.leadDays > 0 ? opts.leadDays : 14;
  const targetDays = opts.targetDays > 0 ? opts.targetDays : 45;
  const rates = consumptionByItem(orders, opts);
  const committed = committedByItem(orders, opts);
  const out = [];
  for (const item of (inventory || [])) {
    if (!item || !item.id) continue;
    // One arithmetic, shared with the shelf — see `runway`.
    const r = runway(item, rates[item.id], committed[item.id], opts.now || 0);
    const { weight, committedG, available, gramsPerDay } = r;
    // This function has always treated "no rate" as infinite runway for the
    // purpose of NOT listing the item; `runway` reports it as null, which is
    // the more honest answer for a screen. Same decision, different word.
    const daysLeft = r.daysLeft === null ? Infinity : r.daysLeft;
    const low = !!isLow(item);
    // Surface if low, projected to deplete within leadDays, OR open orders already
    // exceed stock.
    if (!low && daysLeft > leadDays && committedG <= weight) continue;
    // Cover targetDays of usage beyond what's available, plus any shortfall now.
    const needG = gramsPerDay > 0
      ? Math.max(0, Math.ceil(gramsPerDay * targetDays - available))
      : Math.max(0, Math.ceil(committedG - weight));
    out.push({
      item,
      id: item.id,
      label: item.name || item.material || item.id,
      weight,
      committedG: Math.round(committedG),
      available: Math.round(available),
      gramsPerDay: Math.round(gramsPerDay * 10) / 10,
      daysLeft: daysLeft === Infinity ? null : Math.round(daysLeft),
      low,
      suggestG: needG,
    });
  }
  // Urgency: lowest daysLeft first (null/unknown last but still listed because low).
  out.sort((a, b) => {
    const da = a.daysLeft == null ? Infinity : a.daysLeft;
    const db = b.daysLeft == null ? Infinity : b.daysLeft;
    if (da !== db) return da - db;
    return (b.low ? 1 : 0) - (a.low ? 1 : 0);
  });
  return out;
}

/** Build a plain-text reorder list to paste/send to a supplier. */
function reorderText(suggestions, opts) {
  opts = opts || {};
  const header = opts.header || 'Reorder list:';
  const lines = (suggestions || []).map((s) => {
    const name = s.label || s.id;
    if (s.suggestG > 0) return `- ${name}: ~${Math.round(s.suggestG)} g`;
    if (s.low) return `- ${name}: restock`;
    return `- ${name}`;
  });
  return lines.length ? header + '\n' + lines.join('\n') : '';
}

/**
 * Pick which reorder suggestions should become *new* draft POs: only items with
 * a positive suggested quantity that don't already have an open (draft/ordered,
 * not-yet-received) purchase order — so auto-drafting never piles up duplicates.
 * Pure: caller passes suggestions + the current purchaseOrders list.
 */
function itemsNeedingDraftPo(suggestions, purchaseOrders) {
  const openByItem = new Set();
  for (const po of (purchaseOrders || [])) {
    if (po && po.itemId && po.status !== 'received' && po.status !== 'cancelled') openByItem.add(po.itemId);
  }
  return (suggestions || []).filter((s) => s && s.suggestG > 0 && s.item && !openByItem.has(s.item.id));
}

/** Leading material-family token, e.g. "PETG Black" → "PETG". */
function famToken(s) {
  const m = String(s == null ? '' : s).toUpperCase().match(/[A-Z][A-Z0-9+]*/);
  return m ? m[0] : '';
}

/**
 * Find the cheapest supplier price-list entry matching a material, across all
 * suppliers. An entry matches by family token (PLA == "PLA Black") or by a
 * loose name containment. Returns { supplierId, supplierName, pricePerKg } or
 * null. Pure: caller passes the suppliers array.
 */
function supplierPriceFor(suppliers, material) {
  const fam = famToken(material);
  const ml = String(material == null ? '' : material).toLowerCase().trim();
  let best = null;
  for (const s of (suppliers || [])) {
    for (const e of (s && s.priceList) || []) {
      const pk = +(e && e.pricePerKg) || 0;
      if (!(pk > 0)) continue;
      const em = String((e && e.material) || '').toLowerCase().trim();
      if (!em) continue;
      const matches = (fam && famToken(em) === fam) || ml.includes(em) || em.includes(ml);
      if (!matches) continue;
      if (!best || pk < best.pricePerKg) best = { supplierId: s.id, supplierName: s.name || '', pricePerKg: pk };
    }
  }
  return best;
}

const api = { DAY_MS, completionMs, runway, runwayByItem, consumptionByItem, committedByItem, reorderSuggestions, reorderText, itemsNeedingDraftPo, supplierPriceFor, famToken };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytReorder = api;

})();
