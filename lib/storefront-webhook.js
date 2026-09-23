'use strict';
/**
 * What a signed Salla or Zid order webhook does to the shop's book.
 *
 * ── WHY THIS IS A MODULE ──────────────────────────────────────────────────
 *
 * It lived inline in `lib/lan-server.js`, twice — once per platform, nearly
 * line for line — and `lan-server.js` cannot run on the Mac: it wants
 * `node:http`, `node:fs` and `node:crypto` at module scope. So the Mac app
 * could hand a storefront its webhook address and answer every delivery 404.
 *
 * What is a RULE moved here: the order a delivery becomes, whether the book
 * already holds it, and what it takes off the shelf. What is PLUMBING stayed
 * with each server: reading the body, the HMAC, the replay cache, the lockout
 * and the write chain. The two servers now differ only in plumbing.
 *
 * ── CALLED INSIDE THE WRITE ───────────────────────────────────────────────
 *
 * `record` is handed the book as it is inside the write and returns the book
 * as it should be. It has to be: the duplicate check and the shelf are both a
 * read-modify-write, and two deliveries arriving together outside the chain
 * would each read the same log and the same count.
 *
 * Pure: no clock, no randomness, no I/O. The id, the day and the moment are
 * the caller's, so both servers and a test can say exactly what they are.
 */
(function (global) {
  const StorefrontOrders = global.KhaytStorefrontOrders
    || (typeof require === 'function' ? require('./storefront-orders.js') : null);
  const ShelfSale = global.KhaytShelfSale
    || (typeof require === 'function' ? require('./shelf-sale.js') : null);

  /** The platforms this answers for, and the label an order's title carries. */
  const PLATFORMS = { salla: 'Salla', zid: 'Zid' };

  /**
   * An online order for something already printed comes OFF THE SHELF.
   *
   * `settings.storefront.stockQty` is the count of finished items the
   * storefront publishes and sells against, and until #1504 one screen in the
   * whole app wrote it: a person typing a number. Nothing took one off. So a
   * shop that printed twelve, listed twelve and sold four went on publishing
   * twelve — and the next publish put the four that were gone back on sale.
   *
   * Returns the store and the order, both possibly unchanged — a basket naming
   * nothing this shop sells is left exactly alone rather than half-recognised.
   */
  function takeOffTheShelf(source, parsed, cur, order, at) {
    const items = StorefrontOrders.orderObject(source, parsed).items;
    const basket = ShelfSale.itemLines(items);
    if (!basket.length) return { store: cur, order };
    const settings = { ...(cur.settings || {}) };
    const storefront = { ...(settings.storefront || {}) };
    const reading = ShelfSale.readLines(basket, {
      products: cur.products || [],
      stock: storefront.stockQty || {},
    });
    if (reading.fromShelf <= 0) return { store: cur, order };

    const stockQty = { ...(storefront.stockQty || {}) };
    const stockCountedAt = { ...(storefront.stockCountedAt || {}) };
    for (const effect of ShelfSale.effects(reading, at)) {
      if (effect.type !== 'deduct') continue;
      stockQty[effect.productId] = effect.to;
      // Re-dated even when the figure lands on what it already was: a count
      // carries the date it was taken, and this figure is current as of now.
      stockCountedAt[effect.productId] = effect.countedAt;
    }
    storefront.stockQty = stockQty;
    storefront.stockCountedAt = stockCountedAt;
    settings.storefront = storefront;

    const next = { ...order, shelfTaken: reading.fromShelf };
    if (reading.allFromShelf) {
      // Nothing about this waits on a machine. A shelf sale sitting under
      // Pending is a job somebody goes looking for a free printer to start —
      // the same reason the Mac's counter sale is written completed.
      next.fromStock = true;
      next.status = 'completed';
      next.completedAt = at;
      next.statusHistory = [{ status: 'completed', at }];
    }
    // Said in the notes as well as in a field, because the notes line is what a
    // shop reads in the queue and `shelfTaken` is what code reads.
    next.notes = `${order.notes}\n${reading.fromShelf} off the shelf`
      + (reading.toPrint > 0 ? `, ${reading.toPrint} to print` : '');
    return { store: { ...cur, settings }, order: next };
  }

  /**
   * The print-log row a delivery becomes, before the shelf has been read.
   *
   * `data.total` DOES NOT EXIST in a Salla webhook, and never did — the total
   * is `data.amounts.total.amount`, and reading the wrong one priced every
   * Salla order Khayt ever imported at zero. `StorefrontOrders.orderPriceFrom`
   * is the one reader of it. Unknown stays 0 here because the print log's price
   * is a number everywhere downstream; it is reached only when the platform
   * genuinely sent nothing.
   */
  function newOrder(source, parsed, ctx) {
    const ref = StorefrontOrders.sourceOrderIdFrom(source, parsed);
    const price = StorefrontOrders.orderPriceFrom(source, parsed);
    const order = {
      id: ctx.id,
      project: `${PLATFORMS[source]}: ${StorefrontOrders.orderTitleFrom(source, parsed)}`,
      client: StorefrontOrders.customerNameFrom(source, parsed),
      status: 'pending',
      date: ctx.day,
      price: price === null ? 0 : price,
      notes: StorefrontOrders.noteFor(source, ref),
      source,
    };
    // Structured rather than only quoted in `notes`, so the next delivery can
    // be recognised without parsing prose. Absent, not empty, when the
    // platform sent no id — as the Node server has always written it.
    if (ref) order.sourceOrderId = ref;
    return order;
  }

  /**
   * Whether the book already holds this delivery's order.
   *
   * The early answer, from the book as it was read before the write. The
   * servers ask it first so a provider's retry is answered 200 without a
   * write at all; `record` asks it again inside the write, because a retry
   * arriving while the first write is in flight passes the early check.
   */
  function alreadyRecorded(source, parsed, printLog) {
    const ref = StorefrontOrders.sourceOrderIdFrom(source, parsed);
    return StorefrontOrders.alreadyRecorded(printLog || [], source, ref);
  }

  /**
   * The book with this delivery in it.
   *
   * `ctx` is `{ id, day, at }`: the new row's id, the shop's calendar day
   * (`YYYY-MM-DD`, local — not UTC, which names the wrong day for three hours
   * of every Riyadh night) and the moment as ISO-8601.
   *
   * Returns `{ store, order, duplicate }`. A duplicate returns the store it was
   * given, untouched, and no order.
   */
  function record(source, parsed, cur, ctx) {
    if (!PLATFORMS[source]) throw new Error(`not a storefront this answers for: ${source}`);
    const log = [...((cur && cur.printLog) || [])];
    if (alreadyRecorded(source, parsed, log)) return { store: cur, order: null, duplicate: true };
    const taken = takeOffTheShelf(source, parsed, cur, newOrder(source, parsed, ctx), ctx.at);
    log.unshift(taken.order);
    return { store: { ...taken.store, printLog: log }, order: taken.order, duplicate: false };
  }

  const api = { PLATFORMS, takeOffTheShelf, newOrder, alreadyRecorded, record };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStorefrontWebhook = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
