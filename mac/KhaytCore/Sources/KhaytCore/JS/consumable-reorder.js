'use strict';
(function () {

/**
 * Reorder suggestions for consumables — glue, IPA, bags, screws, nozzles.
 *
 * Asked for by a user: running out of a consumable stops production exactly the
 * way running out of filament does, but only filament reached the reorder list.
 * A consumable that ran low announced it in a toast that vanished, and nothing
 * downstream ever heard about it.
 *
 * This is deliberately a SIBLING of lib/reorder.js rather than a widening of it.
 * The two collections agree on almost nothing:
 *
 *              filament (inventory)        consumable (consumables)
 *   on hand    `weight`, always grams      `stock`, in the shop's own `unit`
 *   threshold  `reorderPoint`              `minStock`
 *   usage      grams per part printed      three unrelated deduction paths
 *   name       `material`                  `name`
 *
 * Sharing one function would mean a per-collection branch at every one of those
 * lines, and the failure when a branch is missed is silent: `weight` on a
 * consumable is `undefined`, `+undefined` is `NaN`, and `NaN <= threshold` is
 * `false` — so an empty shelf reads as "not low" and simply never appears.
 *
 * Pure and injected (`now`, `windowDays`), like reorder.js, so the forecast is
 * testable without clocks or globals.
 */

const RE = (typeof require === 'function') ? require('./reorder.js') : globalThis.KhaytReorder;

const DAY_MS = 86400000;

/**
 * A real number, or null when there is nothing to read.
 *
 * `+null`, `+''` and `+false` are all 0, which would turn "no threshold was ever
 * set" into "the threshold is zero" — a different claim, and the one that
 * decides whether an item can ever be called low.
 */
function num(v) {
  if (v === null || v === undefined || v === '' || typeof v === 'boolean') return null;
  const n = +v;
  return Number.isFinite(n) ? n : null;
}

/** On-hand count. Absent stock is zero — an item nobody has counted is not stock. */
const stockOf = (c) => Math.max(0, num(c && c.stock) || 0);

/**
 * Is this consumable low?
 *
 * The app had TWO answers to this and they disagreed. The table drew its badge
 * with `minStock > 0 && stock <= minStock`, while the three deduction paths
 * toasted on `stock <= (minStock || 0)` — which, with no threshold set, fires
 * only at exactly zero. So an item with no minStock was "low" to the toast the
 * moment it emptied and never low to the table.
 *
 * Both are reasonable halves of the same rule, so this is the whole rule: below
 * a threshold the shop set, or empty regardless. Empty has to count, or the
 * items nobody bothered to set a minimum for — which is most of them — can never
 * be reordered.
 */
function isLow(c) {
  if (!c) return false;
  const min = num(c.minStock);
  const stock = stockOf(c);
  if (stock <= 0) return true;
  return min !== null && min > 0 && stock <= min;
}

/**
 * Per-day consumption for each consumable, over the trailing window.
 *
 * Rebuilt from the same three paths that actually deduct stock, because a rate
 * derived any other way would drift away from what the shelf does:
 *
 *   1. hourly   `usagePerHour × order.printTime`   (deductMaterial)
 *   2. packaging one unit per completed order      (deductPackagingConsumables)
 *   3. BOM      `qtyPerUnit × assemblyQty`         (order.components)
 *
 * Each source is counted only for orders that actually ran it, by reading the
 * same `materialDeducted` / `packagingDeducted` flags the deduction guards on.
 * Orders completed before a path existed never touched stock, and charging their
 * consumption to it would invent usage that never happened — inflating the rate
 * and, through it, the amount suggested.
 *
 * @returns {{[id: string]: number}} units per day
 */
function consumptionByConsumable(consumables, orders, opts) {
  opts = opts || {};
  const windowDays = opts.windowDays > 0 ? opts.windowDays : 30;
  const now = opts.now || 0;
  const since = now - windowDays * DAY_MS;
  const completionMs = (RE && RE.completionMs) || (() => null);

  const byId = new Map();
  for (const c of (Array.isArray(consumables) ? consumables : [])) {
    if (c && c.id) byId.set(c.id, c);
  }
  const totals = {};
  const add = (id, qty) => {
    if (!id || !byId.has(id) || !(qty > 0)) return;
    totals[id] = (totals[id] || 0) + qty;
  };

  for (const order of (Array.isArray(orders) ? orders : [])) {
    if (!order) continue;
    const done = completionMs(order);
    if (done == null || done < since || done > now) continue;

    if (order.materialDeducted) {
      const hrs = num(order.printTime) || 0;
      if (hrs > 0) {
        for (const c of byId.values()) {
          const per = num(c.usagePerHour);
          if (per !== null && per > 0) add(c.id, per * hrs);
        }
      }
      const aq = Math.max(1, num(order.assemblyQty) || 1);
      for (const comp of (Array.isArray(order.components) ? order.components : [])) {
        if (!comp || !comp.consumableId) continue;
        add(comp.consumableId, (num(comp.qtyPerUnit) || 0) * aq);
      }
    }

    if (order.packagingDeducted) {
      for (const c of byId.values()) if (c.isPackaging) add(c.id, 1);
    }
  }

  const rates = {};
  for (const id of Object.keys(totals)) rates[id] = totals[id] / windowDays;
  return rates;
}

/**
 * Consumables that are low, or forecast to run out inside the lead time.
 *
 * Mirrors reorderSuggestions()'s shape so a caller can render both lists the
 * same way — but every quantity here is in the item's own `unit`, and there is
 * no `suggestG`. Naming it grams is how "4 boxes" becomes "4 g" on a supplier's
 * order form.
 *
 * @returns {Array<{item,id,label,unit,stock,minStock,perDay,daysLeft,low,suggestQty}>}
 */
function consumableSuggestions(consumables, orders, opts) {
  opts = opts || {};
  const leadDays = opts.leadDays > 0 ? opts.leadDays : 14;
  const targetDays = opts.targetDays > 0 ? opts.targetDays : 45;
  const rates = consumptionByConsumable(consumables, orders, opts);
  const out = [];

  for (const c of (Array.isArray(consumables) ? consumables : [])) {
    if (!c || !c.id) continue;
    const stock = stockOf(c);
    const min = num(c.minStock);
    const perDay = num(rates[c.id]) || 0;
    const low = isLow(c);
    // An empty shelf has nought days left, not an unknown number of them. Without
    // this an item at zero stock and no measurable rate sorts as "unknown", which
    // puts the single most urgent state in the shop BELOW an item with a fortnight
    // of cover. It is empty now; the rate does not come into it.
    const daysLeft = stock <= 0 ? 0 : (perDay > 0 ? stock / perDay : Infinity);

    if (!low && daysLeft > leadDays) continue;

    // With a rate, cover the horizon. Without one, the only defensible number is
    // the shop's own minimum — and when there is no minimum either, say nothing
    // rather than invent a quantity. A zero here renders as "restock", which is
    // the honest answer for an item whose usage nobody can measure.
    let suggestQty = 0;
    if (perDay > 0) {
      suggestQty = Math.max(0, Math.ceil(perDay * targetDays - stock));
    } else if (min !== null && min > 0 && stock < min) {
      suggestQty = Math.ceil(min - stock);
    }

    out.push({
      item: c,
      id: c.id,
      label: c.name || c.id,
      unit: (c.unit == null ? '' : String(c.unit)).trim(),
      category: (c.category == null ? '' : String(c.category)).trim(),
      stock,
      minStock: min,
      perDay: Math.round(perDay * 100) / 100,
      daysLeft: daysLeft === Infinity ? null : Math.round(daysLeft),
      low,
      suggestQty,
    });
  }

  out.sort((a, b) => {
    const da = a.daysLeft == null ? Infinity : a.daysLeft;
    const db = b.daysLeft == null ? Infinity : b.daysLeft;
    if (da !== db) return da - db;
    return (b.low ? 1 : 0) - (a.low ? 1 : 0);
  });
  return out;
}

/** "4 pcs", or just "4" when the shop never named a unit. Never "4 g". */
function qtyLabel(qty, unit) {
  const n = num(qty);
  if (n === null) return '';
  const u = (unit == null ? '' : String(unit)).trim();
  return u ? `${n} ${u}` : String(n);
}

/** A plain-text consumable reorder list to paste to a supplier. */
function consumableReorderText(suggestions, opts) {
  opts = opts || {};
  const header = opts.header || 'Consumables to reorder:';
  const restock = opts.restockLabel || 'restock';
  const lines = (Array.isArray(suggestions) ? suggestions : []).map((s) => {
    if (!s) return '';
    const name = s.label || s.id;
    if (s.suggestQty > 0) return `- ${name}: ~${qtyLabel(s.suggestQty, s.unit)}`;
    if (s.low) return `- ${name}: ${restock}`;
    return `- ${name}`;
  }).filter(Boolean);
  return lines.length ? header + '\n' + lines.join('\n') : '';
}

/**
 * Which suggestions should become new draft POs.
 *
 * Deliberately NOT reorder.js's itemsNeedingDraftPo. That one dedupes on
 * `po.itemId` alone, and a purchase order carries no record of which collection
 * its itemId came from. Consumable ids and spool ids are minted by the same
 * uid() and live in different arrays, so nothing stops one matching the other —
 * and the failure is silent in the worst direction: an open consumable PO would
 * suppress the filament PO for a spool that is genuinely empty.
 *
 * So consumable POs are marked `kind: 'consumable'` and matched only against
 * their own kind. A PO written before this existed has no `kind` and is filament
 * by definition, which is why the absent case reads as filament rather than as
 * "unknown".
 */
function consumablesNeedingDraftPo(suggestions, purchaseOrders) {
  const open = new Set();
  for (const po of (Array.isArray(purchaseOrders) ? purchaseOrders : [])) {
    if (!po || po.kind !== 'consumable' || !po.itemId) continue;
    if (po.status !== 'received' && po.status !== 'cancelled') open.add(po.itemId);
  }
  return (Array.isArray(suggestions) ? suggestions : [])
    .filter((s) => s && s.suggestQty > 0 && s.item && !open.has(s.item.id));
}

const api = {
  DAY_MS,
  isLow,
  stockOf,
  consumptionByConsumable,
  consumableSuggestions,
  consumableReorderText,
  consumablesNeedingDraftPo,
  qtyLabel,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytConsumableReorder = api;

})();
