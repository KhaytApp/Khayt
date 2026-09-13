'use strict';
(function () {

/**
 * Which documents travel with an order.
 *
 * Requested in issue #364 item 4 — "add other files to a part (PDF for assembly
 * instructions, or safety sheets), printed when the part is made and added to
 * the package when shipped".
 *
 * They are stored against the PRODUCT rather than the part, because that is what
 * they describe: a safety sheet belongs to the thing being made, and filing it
 * against one order's line item would mean re-attaching it for every order of
 * the same product.
 *
 * Two audiences, two lists:
 *   - the WORK ORDER is read by whoever makes it, so it lists everything;
 *   - the DELIVERY NOTE goes to the customer, so it lists only what the shop
 *     marked to ship. A machine setup sheet is not something to put in the box.
 *
 * Pure: takes an order and the product list, returns rows.
 */

/** Every document attached to the product this order is for. */
function docsForOrder(order, products) {
  const id = order && order.productId;
  if (!id) return [];
  const product = (Array.isArray(products) ? products : []).find((p) => p && p.id === id);
  if (!product || !Array.isArray(product.docs)) return [];
  return product.docs
    .filter((d) => d && (d.originalName || d.filename))
    .map((d) => ({
      filename: String(d.filename || ''),
      name: String(d.originalName || d.filename || ''),
      // Absent means yes: a document attached before this flag existed was
      // attached to travel, and defaulting it to "no" would silently stop
      // shipping papers that used to go out.
      packWithOrder: d.packWithOrder !== false,
    }));
}

/** The subset the customer should receive with the goods. */
function packableDocsForOrder(order, products) {
  return docsForOrder(order, products).filter((d) => d.packWithOrder);
}

const api = { docsForOrder, packableDocsForOrder };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytProductDocs = api;

})();
