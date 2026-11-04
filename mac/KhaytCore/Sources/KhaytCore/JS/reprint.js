'use strict';
/**
 * A linked reprint: a NEW job made to replace one that failed, carrying the
 * link both ways.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * It lived in `renderer/order-flows.js` (`applyReprintMeta`), so only the
 * desktop could make one. With `settings.qc.enabled` on, the desktop marks a
 * job that failed inspection scrapped and offers Scrap or a linked reprint;
 * the Mac sent the same job back to Pending instead, so `lib/qc-metrics.js`
 * (first-pass yield collapses a `reprintChain`, RMA counts `reprintOf`) never
 * saw a single Mac reprint. The rule is here now and both apps run it.
 *
 * ── WHAT IT NEVER DOES ────────────────────────────────────────────────────
 *
 * It never touches the original's material accounting. The failed job's
 * filament is already gone — deducted at completion, booked in the waste log
 * by `lib/qc-failure.js`. The reprint is a fresh job that draws its own
 * filament when it is printed.
 *
 * `apply` and `markScrapped` change the records they are handed IN PLACE,
 * as the desktop's flow always has. `create` works on copies.
 */
(function (global) {
  function sibling(name, file) {
    const g = global[name];
    if (g) return g;
    if (typeof require !== 'function') return null;
    try { return require(file); } catch (e) { return null; }
  }
  const arrayOf = (v) => (Array.isArray(v) ? v : []);
  const num = (v, d) => {
    const n = +v;
    return Number.isFinite(n) ? n : d;
  };

  /** How much history a job keeps — the cap every status push uses. */
  const HISTORY_CAP = 200;

  /** The first job of a reprint chain. */
  function chainRoot(order) {
    if (!order) return null;
    return order.reprintChain || (order.reprintOf ? null : order.id) || order.id;
  }

  /**
   * The link a reprint of `original` carries. `reason` is `qc_fail`, `rma` or
   * `manual`; `cost` is `shop` (no charge — our defect) or `billable`.
   */
  function metaFor(original, reason, cost) {
    const o = original || {};
    return {
      of: o.id || null,
      reason: reason || 'manual',
      cost: cost === 'shop' ? 'shop' : 'billable',
      chain: o.reprintChain || o.id || null,
    };
  }

  /**
   * Stamp the link onto a freshly-created job and back-reference the original
   * in `log`. A shop-cost reprint carries no charge; a billable one keeps its
   * price.
   */
  function apply(newOrder, meta, log) {
    if (!newOrder || !meta) return newOrder;
    newOrder.reprintOf = meta.of || null;
    newOrder.reprintReason = meta.reason || 'manual';
    newOrder.reprintCost = meta.cost || 'billable';
    newOrder.reprintChain = meta.chain || meta.of || newOrder.id;
    if (meta.cost === 'shop') {
      newOrder.price = 0;
      newOrder.priceBeforeDiscount = null;
      newOrder.reprintNoCharge = true;
      newOrder.paymentStatus = 'paid';
      newOrder.paidAmount = 0;
    }
    const orig = arrayOf(log).find((o) => o && o.id === meta.of);
    if (orig) {
      if (!Array.isArray(orig.reprintedInto)) orig.reprintedInto = [];
      if (!orig.reprintedInto.includes(newOrder.id)) orig.reprintedInto.push(newOrder.id);
      // RMA reprint: link the warranty record to the replacement order.
      if (meta.reason === 'rma' && orig.rma && !orig.rma.reprintId) orig.rma.reprintId = newOrder.id;
    }
    return newOrder;
  }

  /**
   * A job that failed inspection with QC switched on: terminal, kept as a
   * scrapped record in the QC stage. Its filament is already booked as waste.
   */
  function markScrapped(order, at) {
    if (!order) return order;
    order.scrapped = true;
    if (!Array.isArray(order.statusHistory)) order.statusHistory = [];
    order.statusHistory.push({ status: 'qc', at, note: 'QC failed' });
    if (order.statusHistory.length > HISTORY_CAP) order.statusHistory = order.statusHistory.slice(-HISTORY_CAP);
    return order;
  }

  /**
   * What `lib/order-new.js newOrder` is handed to make the reprint: the
   * original's parts (fresh ids, `baseCost` as a line total — what the
   * desktop loads into the calculator), its customer, product, discount,
   * shipping and extra lines, all back in the shop's currency
   * (`inShopCurrency`), and the shop's default margin.
   *
   * `book` is `{ settings, inventory, consumables }`; `idBase` names the parts.
   */
  function input(original, book, idBase) {
    const o = original || {};
    const b = book || {};
    const settings = b.settings || {};
    const N = sibling('KhaytOrderNew', './order-new.js');
    const CC = sibling('KhaytCalculatorCost', './calculator-cost.js');
    const shop = N && typeof N.inShopCurrency === 'function'
      ? N.inShopCurrency(o, settings)
      : { shippingCost: o.shippingCost, extraLines: arrayOf(o.extraLines), parts: arrayOf(o.parts) };
    const ctx = { inventory: arrayOf(b.inventory), settings, consumables: arrayOf(b.consumables) };
    const parts = arrayOf(shop.parts).map((p, i) => {
      const copy = Object.assign({}, p, { id: `${idBase}-P${i + 1}`, partStatus: 'pending' });
      copy.baseCost = CC && typeof CC.partTotalCost === 'function' ? +CC.partTotalCost(copy, ctx) || 0 : num(p.baseCost, 0);
      return copy;
    });
    const margin = typeof settings.defaultMargin === 'number' && Number.isFinite(settings.defaultMargin)
      ? settings.defaultMargin : 30;
    const out = {
      parts,
      project: o.project || '',
      clientId: o.clientId || null,
      productId: o.productId || null,
      currency: o.currency || undefined,
      margin,
      discountPct: num(o.discountPct, 0),
      shippingCost: num(shop.shippingCost, 0),
      extraLines: arrayOf(shop.extraLines),
      clientRef: o.clientRef || null,
    };
    if (arrayOf(o.components).length) {
      out.components = arrayOf(o.components).map((c) => Object.assign({}, c));
      out.assemblyQty = num(o.assemblyQty, 1) > 0 ? num(o.assemblyQty, 1) : 1;
    }
    return out;
  }

  /**
   * Make the linked reprint of `originalId` in `printLog`, through the shared
   * `newOrder`. Returns `{ order, printLog, settings }` — the new job first in
   * the log, the original carrying `reprintedInto` — or null when the original
   * is not in the log.
   *
   * `ctx` is `newOrder`'s (`{ settings, now, tokens, consumables, clients }`)
   * plus `inventory`, `reason`, `cost` and `partIdBase`. `ctx.settings` is
   * advanced (the invoice counter), so the caller writes it back with the log.
   */
  function create(originalId, printLog, ctx) {
    const c = ctx || {};
    const N = sibling('KhaytOrderNew', './order-new.js');
    if (!N) throw new Error('KhaytReprint needs KhaytOrderNew');
    const log = arrayOf(printLog).map((o) => (o && typeof o === 'object' ? Object.assign({}, o) : o));
    const original = log.find((o) => o && o.id === originalId);
    if (!original) return null;
    const settings = Object.assign({}, c.settings || {});
    const made = N.newOrder(input(original, {
      settings, inventory: c.inventory, consumables: c.consumables,
    }, c.partIdBase || `${originalId}-R`), {
      settings, orders: log, now: c.now, tokens: c.tokens,
      consumables: c.consumables, clients: c.clients,
    });
    // The customer's name travels on the record, as every other job's does.
    if (original.client && !made.client) made.client = original.client;
    apply(made, metaFor(original, c.reason || 'qc_fail', c.cost), log);
    return { order: made, printLog: [made].concat(log), settings };
  }

  const api = { HISTORY_CAP, chainRoot, metaFor, apply, markScrapped, input, create };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytReprint = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
