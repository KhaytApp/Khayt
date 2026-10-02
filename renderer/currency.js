/**
 * Multi-currency catalogue and conversion (uses global settings, clients, fmtMoney).
 */
(function (global) {
  // The table is lib/currencies.js, because the invoice formats against it
  // and the Mac app prints the invoice with no renderer to read it from.
  const CURRENCIES = ((typeof globalThis !== 'undefined' && globalThis.KhaytCurrencies)
    || (() => { try { return require('../lib/currencies.js'); } catch (e) { return { CURRENCIES: {} }; } })()).CURRENCIES;

  const fmtMoney = (n) => global.fmtMoney(n);

  function fmtPrice(n) {
    const cur = CURRENCIES[global.settings?.currency] || CURRENCIES.SAR;
    const num = fmtMoney(n);
    return cur.pos === 'before' ? `${cur.symbol}\u202f${num}` : `${num}\u202f${cur.symbol}`;
  }

  function currencySymbol() {
    return (CURRENCIES[global.settings?.currency] || CURRENCIES.SAR).symbol;
  }

  function fmtMoneyIn(n, currencyCode) {
    const cur = CURRENCIES[currencyCode] || CURRENCIES[global.settings?.currency] || CURRENCIES.SAR;
    const val = fmtMoney(n);
    return cur.pos === 'before' ? `${cur.symbol} ${val}` : `${val} ${cur.symbol}`;
  }

  /* The rules moved to lib/order-money.js so the Mac app could use the same
   * ones — it needed "what did this order earn" for its dashboard, and the
   * alternative was a second implementation of revenue. These wrappers keep the
   * names and signatures every call site already uses, and supply the globals
   * that module deliberately does not reach for. */
  /* require() under Node and the test suite; the global under the renderer,
   * where lib/ modules arrive as <script> tags and order-money.js is loaded
   * first. Same shape as lib/nozzle-wear.js, and for the same reason: a file
   * that works in one runtime and throws in the other is not shared code. */
  let _money;
  const M = () => {
    if (_money) return _money;
    if (global.KhaytOrderMoney) { _money = global.KhaytOrderMoney; return _money; }
    try { _money = require('../lib/order-money.js'); } catch (e) { _money = null; }
    return _money;
  };
  const ctx = () => ({ settings: global.settings || {}, clients: global.clients || [] });

  function clientCurrency(clientId) {
    return M().clientCurrency(clientId, ctx());
  }

  /** Resolve an order's currency: an explicit per-order override wins, else the
   *  client's currency, else the shop base. Lets a single quote be priced in a
   *  currency that differs from the client default (or for a client-less quote). */
  function orderCurrency(o) {
    return M().orderCurrency(o, ctx(), CURRENCIES);
  }

  function convertToBase(amount, fromCurrency) {
    return M().convertToBase(amount, fromCurrency, ctx());
  }

  function orderRevenueBase(o) {
    return M().orderRevenueBase(o, ctx(), CURRENCIES);
  }

  /** Total credit notes issued against an order, in the ORDER's own currency. */
  function orderCreditedRaw(o) {
    return M().orderCreditedRaw(o);
  }

  /** Total credit notes issued against an order, in the shop's base currency. */
  function orderCreditedBase(o) {
    return M().orderCreditedBase(o, ctx(), CURRENCIES);
  }

  /**
   * Revenue actually EARNED on an order: the price less any credit notes.
   *
   * orderRevenueBase is the gross invoiced figure and is right for reproducing a
   * document (the invoice, a statement's charges line, a journal's invoice
   * entry). It is wrong for any question of the form "how much did the shop
   * earn", because a refund never touches price or paidAmount —
   * generateCreditNote records the credit only in creditNotes[], and sets
   * creditedAt only on a FULL credit. A PARTIAL refund therefore leaves a plain
   * completed order with no voidedAt and no other marker, so a status filter
   * books the full price as revenue and the full VAT with it.
   *
   * giftCardDiscount is deliberately NOT subtracted. Issuing a gift card does
   * not create an order (giftCards[] is its own collection), so redemption is
   * the only moment that money can be recognised as revenue — netting it here
   * would make it revenue nowhere at all. Every other path already treats it as
   * a tender, not a discount: payStatus adds it to cash paid, the client
   * statement totals it as its own settlement line, and the journal clears it
   * against the gift-card liability. Credit notes are the opposite: a genuine
   * reduction of the sale.
   */
  function orderNetRevenueBase(o) {
    return M().orderNetRevenueBase(o, ctx(), CURRENCIES);
  }

  /**
   * What is still outstanding, in the ORDER'S OWN currency.
   *
   * Same rules as orderOwedBase — credit notes, gift-card redemption and cash
   * all pay an order down — but without converting to base, because the caller
   * is writing amounts BACK onto the order. An instalment plan denominated in
   * the shop's base currency on an order priced in another is a second bug.
   *
   * The instalment generator passed the gross price, so a job with a deposit
   * already taken produced a schedule that billed the deposit a second time:
   * SAR 3,000 across three payments on a job with SAR 2,000 left to pay.
   */
  function orderOwedRaw(o) {
    // ctx() carries the shop's settings: a tax-added shop is owed the tax too.
    return M().orderOwedRaw(o, ctx());
  }

  /**
   * What an order EARNED the shop: its revenue in base currency, net of the
   * tax collected for the government (lib/order-money.js orderEarnedBase).
   * For profit and margin screens. Revenue and cash screens keep
   * orderNetRevenueBase, which is what the customer was charged.
   */
  function orderEarnedBase(o) {
    return M().orderEarnedBase(o, ctx(), CURRENCIES);
  }

  function orderOwedBase(o) {
    return M().orderOwedBase(o, ctx(), CURRENCIES);
  }

  function refreshCurrencyLabels() {
    const sym = currencySymbol();
    document.querySelectorAll('[data-i18n="common.currency"]').forEach((el) => {
      el.textContent = sym;
    });
  }

  const api = {
    CURRENCIES,
    fmtPrice,
    currencySymbol,
    fmtMoneyIn,
    clientCurrency,
    orderCurrency,
    convertToBase,
    orderRevenueBase,
    orderCreditedRaw,
    orderCreditedBase,
    orderNetRevenueBase,
    orderEarnedBase,
    orderOwedBase,
    orderOwedRaw,
    refreshCurrencyLabels,
  };

  global.CURRENCIES = CURRENCIES;
  Object.assign(global, api);
  global.refreshCurrencyLabels = refreshCurrencyLabels;
  global.KhaytCurrency = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
