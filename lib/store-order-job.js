'use strict';
/**
 * A store order as a real job: its lines matched to catalogue products, and
 * the parts it has to print built from them.
 *
 * ── WHY THIS EXISTS ───────────────────────────────────────────────────────
 *
 * A Salla or Zid order webhook wrote a job with a title, a customer and a
 * price, and nothing else: no product, no parts, no grams, no hours. So the
 * job reserved no filament, carried no cost, and the person at the printer
 * had to look the product up by hand. Only the cloud-queue path built parts,
 * and only after somebody pressed Make job.
 *
 * ── THE MATCHING RULE ─────────────────────────────────────────────────────
 *
 * `lib/shelf-sale.js` `matcher` is the one rule, for every door an online
 * order comes through (the Mac's webhook, the desktop's webhook, the cloud
 * queue on both apps):
 *
 *   1. the line's SKU against each product's `sku` and its variants' SKUs;
 *   2. else the line's exact normalised name (English or Arabic);
 *   3. else UNMATCHED. Never a near match, never a guess.
 *
 * An unmatched line stays on the job (`storeLines`, with a "Not matched to a
 * product" note) and the shop picks the product later (`assignLine`).
 *
 * ── THE PARTS ─────────────────────────────────────────────────────────────
 *
 * Built the way a job taken from the catalogue by hand builds them
 * (`appendProductParts` in renderer/inventory.js): each product part at the
 * rates the catalogue costs it at (`KhaytPrintRates.withRates`), its material
 * from the spool it names, and `baseCost` as a LINE total
 * (`KhaytCalculatorCost.partTotalCost`). The product's part count is per ONE
 * piece, so it is multiplied by how many pieces the line prints. A part that
 * names a spool and grams reserves that filament the same way every open job
 * does (`lib/reorder.js committedByItem`): there is no separate reservation
 * record to write.
 *
 * Pure: the book and an id base in, records out. No clock, no randomness.
 */
(function (global) {
  /** Siblings, found at CALL time: the Mac loads modules in its own order. */
  function sibling(name, file) {
    const g = global[name];
    if (g) return g;
    if (typeof require !== 'function') return null;
    try { return require(file); } catch (e) { return null; }
  }

  const str = (v) => String(v == null ? '' : v);
  const num = (v, d) => {
    const n = +v;
    return Number.isFinite(n) ? n : d;
  };
  /** The most of one thing a line can ask for — `lib/shelf-sale.js MAX_QTY`. */
  const MAX_QTY = 100000;
  const count = (v) => Math.max(0, Math.min(MAX_QTY, Math.floor(num(v, 0))));

  /** The words a job carries for a line it could not place. In the book, so English, like the shelf note. */
  const NOT_MATCHED = 'Not matched to a product';

  function unmatchedNote(line) {
    const l = line || {};
    return `${NOT_MATCHED}: ${str(l.name)} × ${Math.max(1, count(l.qty))}`
      + (l.sku ? ` (SKU ${str(l.sku)})` : '');
  }

  /**
   * A product's parts for `units` pieces, as a hand-made job from the
   * catalogue has them. `book` is `{ settings, inventory, consumables }`;
   * `idBase` makes each part's id (`<idBase>-P1`, …) so the same delivery
   * always builds the same ids.
   */
  function productParts(product, units, book, idBase) {
    const PR = sibling('KhaytPrintRates', './print-rates.js');
    const CC = sibling('KhaytCalculatorCost', './calculator-cost.js');
    const b = book || {};
    const settings = b.settings || {};
    const inventory = Array.isArray(b.inventory) ? b.inventory : [];
    const consumables = Array.isArray(b.consumables) ? b.consumables : [];
    const n = Math.max(1, count(units));
    const out = [];
    const rows = product && Array.isArray(product.parts) ? product.parts : [];
    rows.forEach((part, i) => {
      if (!part || typeof part !== 'object') return;
      const rated = PR && typeof PR.withRates === 'function' ? PR.withRates(part, { settings }) : Object.assign({}, part);
      const copy = Object.assign({}, rated, { id: `${idBase}-P${i + 1}` });
      if (!copy.material && copy.filamentId) {
        const inv = inventory.find((x) => x && x.id === copy.filamentId);
        if (inv) copy.material = inv.material;
      }
      const perPiece = Math.max(1, count(part.qty) || 1);
      copy.qty = Math.min(MAX_QTY, perPiece * n);
      copy.partStatus = 'pending';
      copy.baseCost = CC && typeof CC.partTotalCost === 'function'
        ? +CC.partTotalCost(copy, { inventory, settings, consumables }) || 0
        : 0;
      out.push(copy);
    });
    return out;
  }

  /** `material` and `printTime` as `lib/order-new.js newOrder` sums them. */
  function summary(parts) {
    const list = Array.isArray(parts) ? parts : [];
    return {
      material: [...new Set(list.map((p) => p && p.material))].join(', '),
      printTime: +list.reduce((s, p) => s + num(p && p.printTime, 0), 0).toFixed(1),
    };
  }

  /** The product's components for `made` assembled pieces, and what they cost. */
  function componentFields(product, made, consumables) {
    const components = (Array.isArray(product.components) ? product.components : [])
      .filter((c) => c && c.consumableId).map((c) => Object.assign({}, c));
    const perOne = num(product.assemblyQty, 0) > 0 ? num(product.assemblyQty, 1) : 1;
    const assemblyQty = perOne * Math.max(1, count(made));
    const out = { components, assemblyQty };
    const N = sibling('KhaytOrderNew', './order-new.js');
    if (components.length && N && typeof N.componentsCost === 'function') {
      try {
        const cost = N.componentsCost(components, assemblyQty, consumables);
        if (cost > 0) out.componentsCost = +cost.toFixed(2);
      } catch (e) { /* no calculator here: the components still travel */ }
    }
    return out;
  }

  /**
   * The lines of a `lib/shelf-sale.js` reading as the job keeps them, and the
   * notes for the ones that matched nothing.
   */
  function linesOf(reading) {
    const storeLines = [];
    const notes = [];
    for (const line of (reading && Array.isArray(reading.lines)) ? reading.lines : []) {
      const row = {
        name: str(line.name),
        qty: Math.max(1, count(line.qty)),
        productId: line.productId ? str(line.productId) : null,
        matchedBy: line.productId ? (line.matchedBy || 'name') : null,
      };
      if (line.sku) row.sku = str(line.sku);
      storeLines.push(row);
      if (!row.productId) notes.push(unmatchedNote(row));
    }
    return { storeLines, notes };
  }

  /**
   * What a reading of an order becomes on its job.
   *
   * `reading` is `KhaytShelfSale.readLines`' answer, taken against the shelf
   * BEFORE this order came off it. Each matched line prints what the shelf
   * does not cover (`toPrint`); an order the shelf covers whole keeps parts for
   * every piece, because that job is recorded finished and its parts are what
   * the sale cost — the Mac's cloud-queue path (`printOnly`) does the same.
   *
   * `productId` (and the product's components) only when every matched line is
   * ONE product: a basket of two things is not either of them.
   */
  function build(reading, book, idBase) {
    const b = book || {};
    const byId = new Map((Array.isArray(b.products) ? b.products : [])
      .filter((p) => p && p.id).map((p) => [str(p.id), p]));
    const { storeLines, notes } = linesOf(reading);
    const all = !!(reading && reading.allFromShelf);
    const lines = (reading && Array.isArray(reading.lines)) ? reading.lines : [];
    const parts = [];
    const made = new Map();
    lines.forEach((line, i) => {
      const product = line.productId ? byId.get(str(line.productId)) : null;
      if (!product) {
        // An id the reading trusted but this book has not got: unmatched.
        if (storeLines[i].productId) {
          storeLines[i].productId = null;
          storeLines[i].matchedBy = null;
          notes.push(unmatchedNote(storeLines[i]));
        }
        return;
      }
      const units = all ? count(line.qty) : count(line.toPrint);
      made.set(str(product.id), (made.get(str(product.id)) || 0) + units);
      if (units > 0) parts.push(...productParts(product, units, b, `${idBase}-L${i + 1}`));
    });
    const out = { storeLines, notes, parts, productId: null };
    if (made.size === 1) {
      const [id, units] = [...made][0];
      out.productId = id;
      Object.assign(out, componentFields(byId.get(id), units, b.consumables));
    }
    return out;
  }

  /** The order with `build`'s answer on it. Nothing changes for an empty basket. */
  function apply(order, job) {
    if (!job || !job.storeLines.length) return order;
    const next = Object.assign({}, order, { storeLines: job.storeLines });
    if (job.parts.length) {
      next.parts = job.parts;
      Object.assign(next, summary(job.parts));
    }
    if (job.productId) {
      next.productId = job.productId;
      next.components = job.components;
      next.assemblyQty = job.assemblyQty;
      if (job.componentsCost > 0) next.componentsCost = job.componentsCost;
    }
    if (job.notes.length) {
      next.notes = [str(order.notes)].concat(job.notes).filter(Boolean).join('\n');
    }
    return next;
  }

  /**
   * The shop picked the product for a line nothing matched.
   *
   * Returns the order with that line placed, its parts added (for every piece
   * the line asked for — the shelf was read when the order arrived, and is not
   * read again here), the "Not matched" note for it removed, and `productId`
   * set when every placed line is now that one product. `book` is
   * `{ settings, inventory, consumables }`, for the parts' cost. Returns null when
   * there is nothing to do: no such line, a line already placed, no product.
   */
  function assignLine(order, index, product, book) {
    const o = order && typeof order === 'object' ? order : null;
    const lines = o && Array.isArray(o.storeLines) ? o.storeLines : [];
    const line = lines[index];
    if (!line || line.productId || !product || !product.id) return null;
    const next = Object.assign({}, o);
    next.storeLines = lines.map((l, i) => (i === index
      ? Object.assign({}, l, { productId: str(product.id), matchedBy: 'shop' }) : l));
    const added = productParts(product, Math.max(1, count(line.qty)), book, `${str(o.id)}-L${index + 1}`);
    // The Mac's cloud queue keeps an unmatched line as a bare part named after
    // it (no weight, no spool, no model). Placed now, that stand-in is replaced
    // rather than printed beside the real parts.
    const had = (Array.isArray(o.parts) ? o.parts : []).slice();
    const standIn = had.findIndex((p) => p && str(p.name) === str(line.name)
      && !(num(p.printWeight, 0) > 0) && !p.filamentId && !p.printFileId);
    if (standIn >= 0) had.splice(standIn, 1);
    next.parts = had.concat(added);
    Object.assign(next, summary(next.parts));
    const note = unmatchedNote(line);
    const kept = str(o.notes).split('\n');
    const at = kept.indexOf(note);
    if (at >= 0) kept.splice(at, 1);
    next.notes = kept.join('\n');
    const placed = new Set(next.storeLines.filter((l) => l.productId).map((l) => l.productId));
    if (placed.size === 1) {
      const units = next.storeLines.filter((l) => l.productId === str(product.id))
        .reduce((s, l) => s + Math.max(1, count(l.qty)), 0);
      if (!o.productId) {
        next.productId = str(product.id);
        Object.assign(next, componentFields(product, units, (book || {}).consumables));
      }
    } else if (placed.size > 1 && o.productId) {
      // Two products now: the job is not one of them. Its components stay —
      // they are still things the first product needs.
      next.productId = null;
    }
    return next;
  }

  /**
   * What the customer paid for this order, or null when the order carried no
   * price — `lib/webstore-order.js linePrices`, the rule the Mac's cloud queue
   * prices with (`onlinePricing`): each line at its own `unitPrice` when it
   * came with one, else the product's catalogue price; and when no line
   * carried a price, the payload's `paidTotal` if there is one. Null means the
   * caller falls back to costing the job (cost plus margin).
   *
   * Tax: a line's `unitPrice` is the catalogue's price, which is what the
   * book's `price` holds (pre-tax on a shop that adds tax on top), so it is
   * taken as it stands — the same as the Mac. A webhook order is not priced
   * here at all: its price is the platform's own total (`storefront-webhook`).
   */
  function orderPrice(reading, payload, book) {
    const W = sibling('KhaytWebstoreOrder', './webstore-order.js');
    const b = book || {};
    const lines = (reading && Array.isArray(reading.lines)) ? reading.lines : [];
    const anyPaid = lines.some((l) => l && typeof l.unitPrice === 'number');
    if (W && typeof W.linePrices === 'function' && anyPaid) {
      const r = W.linePrices(lines.map((l) => ({
        qty: l.qty, productId: l.productId || null,
        ...(typeof l.unitPrice === 'number' ? { unitPrice: l.unitPrice } : {}),
      })), { products: b.products || [], settings: b.settings || {} });
      if (r.priced) return r.total;
    }
    const said = num((payload || {}).paidTotal, NaN);
    return Number.isFinite(said) && said >= 0 ? +said.toFixed(2) : null;
  }

  /** The lines on a job that still want a product. */
  function unmatched(order) {
    const lines = order && Array.isArray(order.storeLines) ? order.storeLines : [];
    return lines.map((l, index) => ({ index, line: l })).filter((x) => x.line && !x.line.productId);
  }

  const api = { NOT_MATCHED, unmatchedNote, productParts, summary, linesOf, build, apply, assignLine, unmatched, orderPrice };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStoreOrderJob = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
