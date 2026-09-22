'use strict';
/**
 * An online order for something already printed is a SALE, not a job.
 *
 * ── WHAT WAS ACTUALLY HAPPENING ───────────────────────────────────────────
 *
 * Three doors let an online order into Khayt and not one of them looked at the
 * shelf:
 *
 *   1. `lib/lan-server.js` takes a signed Salla or Zid webhook and writes the
 *      order into the print log as `pending` — work to make.
 *   2. khayt-cloud's `/v1/shops/{id}/import/{platform}` files the order in the
 *      intake queue, and the desktop's Order requests screen turns it into a
 *      **quote priced at zero**.
 *   3. The Mac app could hand a storefront the webhook address and then never
 *      showed it a single order that arrived at it.
 *
 * Meanwhile `settings.storefront.stockQty` — the count of finished items on the
 * shelf, which is what the storefront publishes and sells against — is written
 * by one screen in the whole app: a person typing a number. Nothing has ever
 * taken one off. So a shop that printed twelve dragons, listed twelve and sold
 * four went on advertising twelve, and the first sign of it was a customer
 * buying the thirteenth.
 *
 * ── WHAT THIS DECIDES, AND WHAT IT REFUSES TO ─────────────────────────────
 *
 * Given an incoming order and the shop's catalogue, this says line by line how
 * many can come off the shelf and how many have to be printed. It is the only
 * place that arithmetic is done, so the desktop, the LAN server and the Mac
 * agree about a number a customer can see.
 *
 * It **refuses to guess**. A line whose name is not a product this shop sells
 * comes back unmatched, and an unmatched line is never quietly turned into a
 * deduction or into a print job with a made-up product. Unknown is not a yes —
 * the same rule the library's "what may I sell" answer is built on.
 *
 * Pure: an order and a book in, an ordered effects list out. No clock, no disk.
 */
(function (global) {
  const str = (v) => String(v == null ? '' : v);
  const int = (v) => {
    const n = Math.floor(Number(v));
    return Number.isFinite(n) ? n : 0;
  };

  /**
   * One name, as a thing to compare rather than a thing to read.
   *
   * Arabic-Indic digits fold to ASCII because a storefront and a catalogue can
   * spell the same "×2" differently; tatweel and the combining marks go because
   * they are decoration a shop adds inconsistently; case and run-together
   * spaces go for the obvious reason. What does NOT happen here is any kind of
   * near-match — see `matchLine`.
   */
  function key(name) {
    return str(name)
      .normalize('NFKC')
      // Arabic-Indic (U+0660–0669) and Eastern Arabic-Indic (U+06F0–06F9).
      .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
      .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06F0))
      // Tatweel, the Arabic diacritics, and the zero-width characters that
      // arrive invisibly from a web form.
      .replace(/[ـً-ْٰ​-‏﻿]/g, '')
      .replace(/\s+/g, ' ')
      .trim()
      .toLowerCase();
  }

  /**
   * The lines of an order, out of the description khayt-cloud writes.
   *
   * `mapPlatformOrder` flattens every platform's basket into one string — each
   * line `• Name × 2`, the shop's own note appended after a blank line. That is
   * lossy and this is not the place to fix it: the cloud is a different
   * repository on a different release cycle, and until it carries the basket
   * through, the bullet block IS the wire format. It is a format Khayt writes
   * itself, so reading it back is parsing our own output, not guessing at a
   * third party's.
   *
   * A description with no bullets is ONE line named by the order's title, with
   * the order's total quantity — which is what a hand-typed customer request
   * looks like, and it still deserves to be checked against the shelf.
   */
  function lines(payload) {
    const p = payload || {};
    const out = [];
    for (const raw of str(p.description).split('\n')) {
      const m = /^\s*[•\-*]\s*(.+?)(?:\s*[×x*]\s*(\d+))?\s*$/.exec(raw);
      if (!m) continue;
      const name = str(m[1]).trim();
      if (!name) continue;
      out.push({ name, qty: m[2] ? Math.max(1, int(m[2])) : 1 });
    }
    if (out.length) return out;
    const title = str(p.title).trim();
    if (!title) return [];
    return [{ name: title, qty: Math.max(1, int(p.qty) || 1) }];
  }

  /**
   * Which product a line names, or none.
   *
   * EXACT on the normalised name, in either language, and nothing else. A
   * near-match here would deduct the wrong shelf — and a deduction is invisible
   * once made, because the number it produces looks exactly like a number
   * somebody counted. A line this cannot place is handed back unplaced and the
   * shop decides.
   *
   * An inactive product still matches: a shop that stopped listing something it
   * still has boxes of would otherwise be told its own order is unrecognisable.
   */
  function matchLine(name, products) {
    const want = key(name);
    if (!want) return null;
    for (const p of Array.isArray(products) ? products : []) {
      if (!p || !p.id) continue;
      if (key(p.nameEn) === want || key(p.nameAr) === want) return str(p.id);
    }
    return null;
  }

  /**
   * How much of this order the shelf can answer.
   *
   * `stock` is `settings.storefront.stockQty` — product id to count.
   *
   * ── THE ONE THAT NEEDS THE TEST ───────────────────────────────────────
   *
   * A basket can name the same product on two lines (a storefront splits by
   * variant, or the customer added it twice). Reading each line against the
   * shelf independently lets both see the SAME four items and promise eight,
   * so the count is taken sequentially and each line only sees what the lines
   * before it left.
   */
  function read(payload, book) {
    return readLines(lines(payload), book, payload);
  }

  /**
   * The same, from a basket somebody already has in hand.
   *
   * `lib/lan-server.js` takes Salla and Zid straight from the platform, so it
   * holds the real `items` array and has no flattened description to read back.
   * Handing it `lines(payload)` would mean writing the bullet string only to
   * parse it again.
   */
  function readLines(basket, book, payload) {
    const products = (book && book.products) || [];
    const stock = (book && book.stock) || {};
    const left = {};
    const rows = (Array.isArray(basket) ? basket : []).map((line) => {
      const productId = matchLine(line.name, products);
      if (!productId) {
        return { name: line.name, qty: line.qty, productId: null,
                 onShelf: 0, fromShelf: 0, toPrint: line.qty };
      }
      if (!(productId in left)) left[productId] = Math.max(0, int(stock[productId]));
      const onShelf = left[productId];
      const fromShelf = Math.min(line.qty, onShelf);
      left[productId] = onShelf - fromShelf;
      return { name: line.name, qty: line.qty, productId,
               onShelf, fromShelf, toPrint: line.qty - fromShelf };
    });
    const sum = (k) => rows.reduce((a, r) => a + r[k], 0);
    return {
      source: str((payload || {}).source),
      ref: str((payload || {}).ref),
      lines: rows,
      fromShelf: sum('fromShelf'),
      toPrint: sum('toPrint'),
      unmatched: rows.filter((r) => !r.productId).length,
      // Everything this order asked for is already made. The shop packs it;
      // nothing goes in the queue.
      allFromShelf: rows.length > 0 && rows.every((r) => r.toPrint === 0),
    };
  }

  /**
   * What to do about it, in order.
   *
   * An effects list rather than a mutation, because three hosts apply it and
   * two of them are not JavaScript. `countedAt` is the caller's clock: a count
   * carries the date it was taken, and a sale moves that date for the same
   * reason a re-count does — the figure is current as of now.
   *
   * Deductions are merged per product, so a basket naming one product twice
   * produces ONE write of the final figure rather than two writes that race.
   */
  function effects(reading, at) {
    const by = new Map();
    for (const line of (reading && reading.lines) || []) {
      if (!line.productId || line.fromShelf <= 0) continue;
      by.set(line.productId, (by.get(line.productId) || 0) + line.fromShelf);
    }
    const out = [];
    for (const [productId, taken] of by) {
      const start = (reading.lines.find((l) => l.productId === productId) || {}).onShelf || 0;
      out.push({ type: 'deduct', productId, taken, to: Math.max(0, start - taken),
                 countedAt: str(at) });
    }
    if (reading && reading.toPrint > 0) {
      out.push({ type: 'queue',
                 lines: reading.lines.filter((l) => l.toPrint > 0)
                   .map((l) => ({ name: l.name, qty: l.toPrint, productId: l.productId })) });
    }
    return out;
  }

  /**
   * A basket out of a platform's own `items` array.
   *
   * Every storefront Khayt imports names the line one of these four ways, and
   * only one of them is ever present, so this cannot pick the wrong one out of
   * two that both exist.
   */
  function itemLines(items) {
    const out = [];
    for (const it of Array.isArray(items) ? items : []) {
      if (!it) continue;
      const name = str(it.name || it.title || it.product_title || it.label).trim();
      if (!name) continue;
      const qty = int(it.quantity != null ? it.quantity : it.qty);
      out.push({ name, qty: qty > 0 ? qty : 1 });
    }
    return out;
  }

  const api = { key, lines, itemLines, matchLine, read, readLines, effects };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytShelfSale = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
