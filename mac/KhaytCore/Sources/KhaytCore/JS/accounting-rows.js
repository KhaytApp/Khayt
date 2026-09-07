'use strict';
/**
 * Orders → the row shape `accounting-export.js` turns into a CSV.
 *
 * ── WHY THIS IS ITS OWN MODULE ────────────────────────────────────────────
 *
 * `buildInvoiceCsv` is a formatter: give it rows with a rate and a tax mode on
 * them and it lays out columns. **Everything that decides what those rows say
 * lived in the renderer** — which quarter's worth of orders count, that a quote
 * is not an invoice, that an order with no price is not one either, what the
 * shop's VAT rate and pricing mode are, and which customer a `clientId` belongs
 * to.
 *
 * So a second app calling the formatter directly gets a file that looks right
 * and is wrong in four ways at once. Measured, on a real order of 1,150 at 15%
 * inclusive:
 *
 *     VAT        0.00   instead of 150.00
 *     Subtotal   1150   instead of 1000
 *     Customer   empty
 *     and a quote exported as though it were an invoice
 *
 * That is a file a shop hands an accountant, and two apps disagreeing about a
 * VAT figure is a disagreement an auditor finds. The decision belongs in one
 * place, so it is here.
 *
 * PURE. The parts that need the host — how an order's currency is chosen, and
 * how it converts to the shop's base — arrive as functions in `ctx`, the same
 * way `invoice-document.js` takes its `escapeHtml` and `fmtMoney`. A host that
 * passes neither gets the shop's own currency and empty base columns, which is
 * right for a single-currency book and honest for any other: an empty column is
 * a column an accountant asks about, and a wrong one is not.
 */
(function (global) {

  /** The shop's VAT rate and whether prices include it. */
  function taxOf(settings, KhaytTax) {
    if (!KhaytTax || typeof KhaytTax.profileFromSettings !== 'function') {
      return { rate: 0, mode: 'inclusive' };
    }
    const p = KhaytTax.profileFromSettings(settings || {});
    return {
      rate: (p.rates || []).reduce((sum, r) => sum + (+r.percent || 0), 0),
      mode: p.mode,
    };
  }

  /**
   * `orders` is the whole print log; the rows that come back are the ones that
   * are invoices.
   *
   * A QUOTE IS NOT AN INVOICE and an order with no price is not one either.
   * Both exclusions are here rather than at the call site because both are
   * facts about accounting, not about a screen.
   */
  function ordersToInvoiceRows(orders, ctx) {
    ctx = ctx || {};
    const settings = ctx.settings || {};
    const clients = Array.isArray(ctx.clients) ? ctx.clients : [];
    const tax = ctx.tax || taxOf(settings, ctx.KhaytTax || global.KhaytTax);
    const baseCurrency = settings.currency || 'SAR';
    const currencyOf = typeof ctx.currencyOf === 'function'
      ? ctx.currencyOf : (o) => (o && o.currency) || baseCurrency;
    // No converter means no base columns, rather than a base figure that is
    // silently the foreign one.
    const toBase = typeof ctx.toBase === 'function' ? ctx.toBase : null;
    const nameOf = typeof ctx.localName === 'function'
      ? ctx.localName : (c) => (c && c.name) || '';

    const out = [];
    for (const o of Array.isArray(orders) ? orders : []) {
      if (!o || o.status === 'quote' || !(+o.price > 0)) continue;
      const cur = currencyOf(o);
      const client = o.clientId ? clients.find((c) => c && c.id === o.clientId) : null;
      out.push({
        id: o.id,
        date: o.date || '',
        clientName: (client && nameOf(client)) || o.clientName || o.client || '',
        price: +o.price || 0,
        currency: cur,
        vatRate: tax.rate,
        taxMode: tax.mode,
        baseCurrency: toBase ? baseCurrency : '',
        baseAmount: toBase ? toBase(+o.price || 0, cur) : undefined,
        status: o.status,
      });
    }
    return out;
  }

  const api = { ordersToInvoiceRows, taxOf };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytAccountingRows = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
