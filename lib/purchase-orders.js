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

  const po = {
    id: str(id),
    itemId: source.id,
    // A consumable is NAMED; a spool is described by what it is made of.
    itemName: consumable ? str(source.name) : str(source.material),
    supplierId,
    supplierName: str(wanted.supplierName || supplierName || ''),
    // 1,000 is a spool. It is not a sane default for a box of screws.
    qty: wanted.qty ? num(wanted.qty)
                    : (num(source.reorderQty) || (consumable ? 1 : DEFAULT_FILAMENT_QTY)),
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
  }
  return po;
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
 */
function receive({ po, item, consumable, quantity, notes, today, expenseId,
                   expenseLabel, lot, newSpoolId } = {}) {
  if (!po || typeof po !== 'object') return { ok: false, reason: 'no_order' };
  const amount = num(quantity);
  if (!(amount > 0)) return { ok: false, reason: 'no_quantity' };

  const forConsumable = isConsumableOrder(po);
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
    if (consumable && typeof consumable === 'object') {
      out.consumable = { ...consumable, stock: Math.max(0, round2(num(consumable.stock) + amount)) };
    }
  } else if (item && typeof item === 'object') {
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

    const split = newLot && num(item.weight) > 0
      && newLot.toLowerCase() !== oldLot.toLowerCase();
    if (split) {
      const id = str(newSpoolId) || (str(item.id) + '-' + str(po.id) + '-' + Math.round(received));
      // The ROLL's own facts are not inherited: when it was opened, dried or
      // bought, what it weighed, its history and its price changes belong to
      // the old roll. What KIND of filament it is — material, colour, brand,
      // cost, print settings, where it lives — is the same delivery's.
      const clone = { ...item };
      for (const k of ['usageHistory', 'priceHistory', 'openedAt', 'driedAt',
                       'purchasedAt', 'spoolWeight', 'addedAt']) delete clone[k];
      out.newItem = {
        ...clone,
        id,
        weight: Math.min(round2(amount), MAX_SPOOL_GRAMS),
        spoolWeight: Math.min(round2(amount), MAX_SPOOL_GRAMS),
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
