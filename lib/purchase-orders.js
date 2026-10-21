'use strict';
(function () {

/**
 * What a purchase order IS, and what receiving one does to the book.
 *
 * ── WHY THIS MODULE EXISTS ────────────────────────────────────────────────
 *
 * Both rules lived in `renderer/inventory.js` and `renderer/wire-events.js`,
 * which means they lived where the macOS app cannot reach them: that app has
 * no purchase orders at all, and could not grow them without writing a second
 * copy of arithmetic that has already been wrong twice in this file's history.
 *
 * Receiving goods touches FOUR records — the order, the spool or the
 * consumable, the usage history, and an expense — and the two faults it has
 * carried were both in that chain:
 *
 *   - a consumable order looked its item up in `inventory`, found nothing,
 *     restocked nothing, and still marked itself received: goods paid for and
 *     silently absent from stock;
 *   - the expense divided by 1000 for a per-KILO rate that no version of the
 *     app has ever written, so every filament receipt booked nothing at all —
 *     the spool was paid for and missing from the material spend that pricing
 *     and the per-kilo analytics are derived from.
 *
 * PURE. Nothing here mutates its arguments and nothing here saves: every
 * function returns the records as they SHOULD BECOME and the caller writes
 * them, together or not at all. A receive that restocked the shelf and failed
 * to book the expense would be the second fault above, arriving a different
 * way.
 */

/** A spool is measured in grams and a shop cannot hold more than this of one. */
const MAX_SPOOL_GRAMS = 99000;
/** How much of a spool's own history is kept. */
const MAX_USAGE_ROWS = 200;
/** What a filament order asks for when nothing says otherwise. */
const DEFAULT_FILAMENT_QTY = 1000;

const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const str = (v) => (typeof v === 'string' ? v : (v == null ? '' : String(v)));

/**
 * A consumable is counted in the shop's own unit, not in grams.
 *
 * `kind` is absent on every purchase order written before consumables could be
 * ordered, so ABSENT MUST READ AS FILAMENT — the receive path restocks a
 * different field depending on this answer, and reading an old order as a
 * consumable would look its spool up in the wrong collection and restock
 * nothing.
 */
function isConsumableOrder(po) {
  return !!(po && po.kind === 'consumable');
}

/**
 * Draft a purchase order for one item.
 *
 * @param {object} opts
 * @param {object} opts.item          the spool or consumable being ordered
 * @param {object} [opts.ask]         what the caller asked for: supplierId,
 *                                    supplierName, qty, unitPrice,
 *                                    estimatedDelivery, status, notes, kind
 * @param {string} opts.id            the id to mint it with
 * @param {string} opts.today         'YYYY-MM-DD' in the shop's own calendar
 * @param {string} [opts.supplierName] resolved name when the caller looked it up
 * @returns {object} the record to append
 */
function draft({ item, ask, id, today, supplierName } = {}) {
  const source = item || {};
  const wanted = ask || {};
  const consumable = wanted.kind === 'consumable';
  const supplierId = wanted.supplierId || source.supplierId || null;
  // What a SPOOL is counted in. A bottle of resin or a pack of ply sheets
  // sits in `inventory` beside the filament, and an order for one asked for
  // "1000" in grams: a thousand sheets, captioned as weight when it came in.
  const unit = consumable ? '' : shelfUnitOf(source);

  const po = {
    id: str(id),
    itemId: source.id,
    // A consumable is NAMED; a spool is described by what it is made of.
    itemName: consumable ? str(source.name) : str(source.material),
    supplierId,
    supplierName: str(wanted.supplierName || supplierName || ''),
    // 1,000 is a spool. It is not a sane default for a box of screws.
    qty: wanted.qty ? num(wanted.qty)
                    : (num(source.reorderQty) || defaultQty(source, consumable, unit)),
    unitPrice: wanted.unitPrice ? num(wanted.unitPrice) : undefined,
    estimatedDelivery: wanted.estimatedDelivery || null,
    status: wanted.status || 'ordered',
    orderedAt: str(today),
    receivedAt: null,
    notes: str(wanted.notes || ''),
  };
  if (consumable) {
    po.kind = 'consumable';
    po.unit = str(source.unit).trim();
  } else if (unit !== 'g') {
    // Grams stay unwritten, as on every order before other units existed.
    po.unit = unit;
  }
  return po;
}

/** A spool's unit, by `lib/inventory-units.js`'s reading: absent is grams. */
function shelfUnitOf(item) {
  const U = typeof globalThis !== 'undefined' ? globalThis.KhaytInventoryUnits : null;
  if (U && typeof U.unitOf === 'function') return U.unitOf(item);
  let units = null;
  try { units = require('./inventory-units.js'); } catch (e) { units = null; }
  return units ? units.unitOf(item) : 'g';
}

/**
 * How much to ask for when neither the caller nor the item says.
 *
 * 1,000 is a spool of filament and ONE is a consumable. A spool counted in
 * another unit asks for what it held when it arrived — one more bottle, one
 * more pack — and one of them when that was never recorded.
 */
function defaultQty(item, consumable, unit) {
  if (consumable) return 1;
  if (unit === 'g') return DEFAULT_FILAMENT_QTY;
  return num(item.spoolWeight) > 0 ? num(item.spoolWeight) : (unit === 'sheet' ? 1 : DEFAULT_FILAMENT_QTY);
}

/**
 * What arrives when goods are received against an order.
 *
 * The caller hands in the order and whichever record it restocks — a spool
 * from `inventory` for a filament order, a row from `consumables` otherwise —
 * and writes back everything that comes out. Nothing is mutated here.
 *
 * @param {object} opts
 * @param {object} opts.po            the purchase order
 * @param {object} [opts.item]        the spool, for a filament order
 * @param {object} [opts.consumable]  the consumable, for a consumable order
 * @param {number} opts.quantity      grams, or the shop's own unit
 * @param {string} [opts.notes]
 * @param {string} opts.today         'YYYY-MM-DD'
 * @param {string} [opts.expenseId]   the id to mint the expense with
 * @param {string} [opts.expenseLabel] what to call it in the note; the caller
 *                                    owns the language
 * @param {string} [opts.lot]         the manufacturer's lot printed on what
 *                                    arrived. Optional; see LOT below.
 * @param {string} [opts.newSpoolId]  the id to mint a new spool with, when the
 *                                    lot makes this delivery its own spool
 * @param {object[]} [opts.receivedSpools] the spools this order already
 *                                    received into (`po.receivedInto`), so a
 *                                    second delivery of the same new lot finds
 *                                    the spool the first one made
 * @returns {{ok: boolean, reason?: string, po?: object, item?: object,
 *            newItem?: object, consumable?: object, expense?: object,
 *            complete?: boolean}}
 *
 * ── LOT ──────────────────────────────────────────────────────────────────
 *
 * A recall names a lot, and grams from two lots poured into one spool record
 * can never be told apart again. So when a lot is given, it DIFFERS (trimmed,
 * ignoring case) from the spool's own, and the spool still holds filament,
 * the delivery becomes its OWN spool — `newItem`, cloned from the old one
 * (material, colour, brand, cost…) with the new lot, this order's id and only
 * what arrived — and `item` is not returned: the old spool is untouched. The
 * order keeps pointing at the spool it was raised for; the new spool's id is
 * recorded on it (`receivedInto`) so nothing is lost.
 *
 * Otherwise — no lot, the same lot, or an empty spool that is simply being
 * refilled — the grams go onto the spool exactly as before, and the spool
 * takes the lot (when one was given) and this order's id.
 *
 * A PART delivery of a new lot arrives more than once, and the order still
 * points at the old spool. So before splitting, the spools the order already
 * received into (`receivedSpools`) are searched for that lot, and a match is
 * topped up instead — returned as `item` carrying ITS OWN id, which the
 * caller must use to find the record it replaces. Without this, two 500 g
 * deliveries of lot B made two lot-B spools.
 */
function receive({ po, item, consumable, quantity, notes, today, expenseId,
                   expenseLabel, lot, newSpoolId, receivedSpools } = {}) {
  if (!po || typeof po !== 'object') return { ok: false, reason: 'no_order' };
  const amount = num(quantity);
  if (!(amount > 0)) return { ok: false, reason: 'no_quantity' };

  const forConsumable = isConsumableOrder(po);
  // The goods have to land SOMEWHERE. A spool or consumable deleted after the
  // order was raised used to come back ok: the expense was booked and the
  // order advanced while the grams went nowhere, so the shop paid for stock
  // the shelf never showed.
  const target = forConsumable ? consumable : item;
  if (!target || typeof target !== 'object') return { ok: false, reason: 'no_item' };
  const ordered = num(po.qty);
  const already = num(po.receivedSoFar);
  const received = round2(already + amount);
  // An order with no quantity on it cannot be measured against one, so it is
  // never completed by arithmetic — the shop closes it by hand.
  const complete = ordered > 0 && received >= ordered;

  const out = {
    ok: true,
    complete,
    po: {
      ...po,
      receivedSoFar: received,
      status: complete ? 'received' : 'partial',
      receivedAt: complete ? str(today) : (po.receivedAt || null),
    },
  };

  if (forConsumable) {
    // No 99,000 cap here: that is a spool's limit, not a box of gloves'.
    out.consumable = { ...consumable, stock: Math.max(0, round2(num(consumable.stock) + amount)) };
  } else {
    const newLot = str(lot).trim();
    const oldLot = str(item.lot).trim();
    // NEGATIVE `weightUsed`: the shelf's history is a list of what left it, so
    // an arrival is a use of minus that much. Read the other way round, every
    // receipt would count as consumption.
    const row = {
      type: 'received', orderId: po.id, weightUsed: -amount,
      date: str(today), notes: str(notes || ''),
    };
    if (newLot || oldLot) row.lot = newLot || oldLot;
    if (po.id) row.poId = str(po.id);

    let topUp = false;
    let split = newLot && num(item.weight) > 0
      && newLot.toLowerCase() !== oldLot.toLowerCase();
    if (split) {
      const into = Array.isArray(po.receivedInto) ? po.receivedInto.map(str) : [];
      const earlier = (Array.isArray(receivedSpools) ? receivedSpools : []).find((s) =>
        s && typeof s === 'object' && into.includes(str(s.id))
        && str(s.lot).trim().toLowerCase() === newLot.toLowerCase());
      if (earlier) { item = earlier; split = false; topUp = true; }
    }
    if (split) {
      const id = str(newSpoolId) || (str(item.id) + '-' + str(po.id) + '-' + Math.round(received));
      // The ROLL's own facts are not inherited: when it was opened, dried or
      // bought, what it weighed, its history, its drying log, its weigh-in
      // corrections and its price changes belong to the old roll — a copied
      // `dryingLog` would read the new roll as freshly dried. What KIND of filament it is — material, colour, brand,
      // cost, print settings, where it lives — is the same delivery's.
      const clone = { ...item };
      for (const k of ['usageHistory', 'priceHistory', 'openedAt', 'driedAt',
                       'dryingLog', 'adjustments', 'purchasedAt', 'spoolWeight',
                       'addedAt']) delete clone[k];
      // The PRICE is the delivery's, not the old roll's: `cost` is what the
      // whole roll cost, and copying 80 for 1000 g onto a 250 g roll made its
      // plastic four times dearer than the 20 the expense booked.
      const grams = Math.min(round2(amount), MAX_SPOOL_GRAMS);
      Object.assign(clone, pricedFor(item, grams, num(po.unitPrice)));
      out.newItem = {
        ...clone,
        id,
        weight: grams,
        spoolWeight: grams,
        purchasedAt: str(today),
        lot: newLot,
        poId: str(po.id),
        usageHistory: [{ ...row, lot: newLot }],
      };
      out.po.receivedInto = (Array.isArray(po.receivedInto) ? po.receivedInto.slice() : [])
        .filter((x) => x !== id).concat([id]);
    } else {
      const history = Array.isArray(item.usageHistory) ? item.usageHistory.slice() : [];
      history.unshift(row);
      out.item = {
        ...item,
        weight: Math.min(round2(num(item.weight) + amount), MAX_SPOOL_GRAMS),
        usageHistory: history.slice(0, MAX_USAGE_ROWS),
      };
      if (newLot) out.item.lot = newLot;
      if (po.id) out.item.poId = str(po.id);
      // A later part of a new lot tops up the roll the first part became.
      // That roll's `spoolWeight` and `cost` describe ONLY what has arrived
      // into it, so both grow with it — otherwise the second 250 g would be
      // priced against a 250 g roll at the first part's price.
      if (!(num(item.weight) > 0)) {
        // An EMPTY roll refilled is a new roll on the old record: what it
        // weighed and what it cost are this delivery's, as a split's are.
        // Kept, the old 1000 g for 80 priced a 250 g refill's plastic at a
        // quarter of what the expense booked.
        const grams = out.item.weight;
        Object.assign(out.item, pricedFor(item, grams, num(po.unitPrice)));
        out.item.spoolWeight = grams;
      } else if (topUp) {
        const before = num(item.spoolWeight);
        const grams = Math.min(round2(before + amount), MAX_SPOOL_GRAMS) - before;
        if (before > 0 && grams > 0) {
          const extra = pricedFor(item, grams, num(po.unitPrice));
          out.item.spoolWeight = round2(before + grams);
          if ('cost' in extra) out.item.cost = round2(num(item.cost) + extra.cost);
          if ('vatAmount' in extra) out.item.vatAmount = round2(num(item.vatAmount) + extra.vatAmount);
        }
      }
    }
  }

  // THE MONEY. `unitPrice` is per gram for filament and per unit of the shop's
  // own for a consumable, so both multiply out identically and there is NO
  // /1000 — the per-kilo rate that division assumed lived in `unitCost`, which
  // no version of the app has ever written.
  const unitPrice = num(po.unitPrice);
  if (unitPrice > 0) {
    const spend = round2(amount * unitPrice);
    if (spend > 0) {
      out.expense = {
        id: str(expenseId),
        date: str(today),
        amount: spend,
        // Glue and bags are not filament. Booking them there inflates the
        // material spend that feeds pricing and the per-kilo analytics. There
        // is no consumables category, so `other` — which is merely
        // unspecific, where `filament` would be wrong.
        category: forConsumable ? 'other' : 'filament',
        note: str(expenseLabel || 'PO receive') + ': ' + str(po.id)
              + (notes ? ' — ' + str(notes) : ''),
        orderId: null,
        poId: po.id,
      };
    }
  }
  return out;
}

/**
 * What `grams` of a roll like `item` cost: `{ cost, vatAmount }`, whichever
 * the roll carries.
 *
 * The order's own per-gram price is the truth when it has one — it is what the
 * expense books. Without it the roll's price is scaled by the share of the roll
 * those grams are (`spoolWeight`, what it weighed when it arrived). Tax scales
 * with the cost it was charged on.
 */
function pricedFor(item, grams, unitPrice) {
  const out = {};
  const oldCost = num(item && item.cost);
  // Never `weight`: that is what is LEFT, and dividing by it prices a
  // half-used roll's plastic double. A roll that predates `spoolWeight` reads
  // as the kilo every other price-per-gram rule here assumes (reorder.js,
  // po-audit.js).
  const bought = num(item && item.spoolWeight) > 0 ? num(item.spoolWeight) : 1000;
  const share = bought > 0 ? grams / bought : 0;
  let factor = share;
  if (unitPrice > 0) {
    out.cost = round2(grams * unitPrice);
    factor = oldCost > 0 ? out.cost / oldCost : share;
  } else if (item && 'cost' in item) {
    out.cost = round2(oldCost * share);
  }
  if (item && item.vatAmount != null && num(item.vatAmount) !== 0) {
    out.vatAmount = round2(num(item.vatAmount) * factor);
  }
  return out;
}

/** Close an order by hand: the goods are all in, whatever was counted. */
function close(po, today) {
  if (!po || typeof po !== 'object') return null;
  return { ...po, status: 'received', receivedAt: str(today) };
}

/** Money is rounded to 2dp; so are the quantities, which are typed by hand. */
function round2(n) {
  return Math.round((Number(n) || 0) * 100) / 100;
}

const api = {
  MAX_SPOOL_GRAMS, MAX_USAGE_ROWS, DEFAULT_FILAMENT_QTY,
  isConsumableOrder, draft, receive, close,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPurchaseOrders = api;

})();
