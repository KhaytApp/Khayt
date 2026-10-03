'use strict';

/**
 * What one order is worth, and what is still owed on it, in the shop's own
 * currency.
 *
 * This is the single chokepoint for revenue in every reported figure — 53 call
 * sites — and it lived in `renderer/currency.js`, reaching for `global.settings`
 * and `global.clients`. That put it out of reach of anything that is not the
 * renderer, and the Mac app needed exactly these answers for its dashboard. The
 * alternative was a second implementation of "what counts as revenue", which is
 * how two apps come to disagree about a shop's year.
 *
 * So the bodies moved here and take their context as an argument.
 * `renderer/currency.js` keeps the same function names and passes its globals
 * in, so every one of those call sites is untouched.
 *
 * PURE: no globals of its own, no clock. `KhaytBusinessScope` is consulted the
 * way `currency.js` consulted it — through a `typeof` guard — because it is a
 * sibling `lib/` module present in both apps, and a build without it should
 * behave exactly as it did before.
 *
 * ── THE RULES, AND WHY EACH ONE IS HERE ────────────────────────────────────
 * A print marked "not business" earns nothing, everywhere at once — but still
 * wears the nozzle, which is why the flag stops at money.
 *
 * A parent order that was split into sub-orders has been replaced by them and
 * they carry its price between them; counting it too reports the job twice.
 *
 * Credit notes reduce a sale. Gift cards do NOT — a gift card is a tender, not
 * a discount, and netting it here would make it revenue nowhere at all. It pays
 * an order DOWN, so it appears in `owed` and not in `revenue`.
 */
(function (global) {

  const ctxOf = (ctx) => (ctx && typeof ctx === 'object' ? ctx : {});
  const settingsOf = (ctx) => ctxOf(ctx).settings || {};
  const clientsOf = (ctx) => {
    const c = ctxOf(ctx).clients;
    return Array.isArray(c) ? c : [];
  };

  const scope = () => (typeof globalThis !== 'undefined' ? globalThis.KhaytBusinessScope : undefined);

  /** Does this order count towards the shop's money at all? */
  function earns(o) {
    const S = scope();
    if (!S) return true;
    return S.countsForBusiness(o) && !S.isSuperseded(o);
  }

  /**
   * Into the shop's base currency.
   *
   * An unknown or non-positive rate returns the amount UNCONVERTED rather than
   * zero. Reporting a foreign order as worth nothing because a rate is missing
   * is the worse of the two wrong answers: it hides revenue instead of
   * misvaluing it, and a shop notices a wrong total sooner than a missing one.
   */
  function convertToBase(amount, fromCurrency, ctx) {
    const settings = settingsOf(ctx);
    const base = settings.currency || 'SAR';
    if (!fromCurrency || fromCurrency === base) return +amount || 0;
    const rate = (settings.exchangeRates || {})[fromCurrency];
    if (!rate || rate <= 0) return +amount || 0;
    return (+amount || 0) * rate;
  }

  function clientCurrency(clientId, ctx) {
    const settings = settingsOf(ctx);
    if (!clientId) return settings.currency || 'SAR';
    const c = clientsOf(ctx).find((x) => x && x.id === clientId);
    return (c && c.currency) ? c.currency : (settings.currency || 'SAR');
  }

  /**
   * An explicit per-order currency wins, then the client's, then the shop's.
   *
   * `known` is the caller's currency catalogue — `currency.js` passes CURRENCIES
   * so an order carrying a code the app does not support falls through to the
   * client rather than being trusted. Omitted, any non-empty code is accepted.
   */
  function orderCurrency(o, ctx, known) {
    const code = o && o.currency;
    if (code && (!known || known[code])) return code;
    return clientCurrency(o && o.clientId, ctx);
  }

  /** The gross invoiced figure. Right for a document, wrong for "what did we earn". */
  function orderRevenueBase(o, ctx, known) {
    return convertToBase(+((o && o.price)) || 0, orderCurrency(o, ctx, known), ctx);
  }

  function orderCreditedRaw(o) {
    return ((o && o.creditNotes) || []).reduce((s, cn) => s + (+((cn && cn.amount)) || 0), 0);
  }

  function orderCreditedBase(o, ctx, known) {
    return convertToBase(orderCreditedRaw(o), orderCurrency(o, ctx, known), ctx);
  }

  /** What the shop actually earned: the price, less credit notes. */
  function orderNetRevenueBase(o, ctx, known) {
    if (!earns(o)) return 0;
    return Math.max(0, orderRevenueBase(o, ctx, known) - orderCreditedBase(o, ctx, known));
  }

  /**
   * What is still outstanding, in the order's OWN currency.
   *
   * `ctx` is optional and carries the settings: given them, an exclusive shop
   * is owed price + tax (see `orderGrossRaw`). Without them the price is what
   * is due, as it always was.
   */
  function orderOwedRaw(o, ctx) {
    if (!earns(o)) return 0;
    return Math.max(
      0,
      orderDueRaw(o, ctx) - (+((o && o.paidAmount)) || 0)
        - (+((o && o.giftCardDiscount)) || 0) - orderCreditedRaw(o),
    );
  }

  /** What is still outstanding, in the shop's base currency. */
  function orderOwedBase(o, ctx, known) {
    if (!earns(o)) return 0;
    const cur = orderCurrency(o, ctx, known);
    return Math.max(
      0,
      convertToBase(orderDueRaw(o, ctx), cur, ctx)
        - convertToBase(+((o && o.paidAmount)) || 0, cur, ctx)
        - convertToBase(+((o && o.giftCardDiscount)) || 0, cur, ctx)
        - orderCreditedBase(o, ctx, known),
    );
  }

  /**
   * The shop's tax profile, from the settings in `ctx` — or null when there is
   * no tax module, or no settings were given at all. Null means "the price is
   * what is due", which is what every caller got before tax mode existed.
   */
  function taxProfileOf(ctx) {
    const T = (typeof globalThis !== 'undefined') ? globalThis.KhaytTax : undefined;
    if (!T || typeof T.profileFromSettings !== 'function') return null;
    if (!ctx || typeof ctx !== 'object' || !ctx.settings) return null;
    return T.profileFromSettings(ctx.settings);
  }

  /**
   * What the customer is asked to pay for this order, in its OWN currency.
   *
   * MODE-AWARE. An inclusive shop's price already holds the tax, so the price is
   * the bill. An EXCLUSIVE shop's price is the pre-tax figure and the tax is
   * added on top — a $100 job at 8.25% is a $108.25 bill, and the invoice has
   * always said so (`renderer/invoicing.js` prints `computeTax(...).total`).
   * Owed, paid and settled were all judged against the bare $100, so the $8.25
   * a customer paid could not be recorded and the order read settled short.
   *
   * Without settings in `ctx` the price is returned — the old answer, which is
   * the right one for every inclusive and every unregistered shop.
   */
  function orderGrossRaw(o, ctx) {
    const price = +((o && o.price)) || 0;
    const profile = taxProfileOf(ctx);
    if (!profile || profile.mode !== 'exclusive' || !(profile.rates || []).length) return price;
    return globalThis.KhaytTax.computeTax(price, profile).total;
  }

  /**
   * Was this order SETTLED before tax added on top was owed on it?
   *
   * Until alpha.58 `recordPayment` capped a payment at the PRICE — so on a shop
   * that adds tax on top, every order it ever settled reads `paidAmount` equal
   * to the pre-tax price, `paymentStatus: 'paid'`. Judged by the rule that
   * replaced it (owed = price + tax) each of those moved into receivables
   * owing the tax: the portal showed a balance, the reminders would chase it,
   * the KPI's outstanding grew. They were settled, and they stay settled.
   *
   * THE MARKER IS EXPLICIT. `recordPayment` now stamps `paidGross: true` on
   * every payment it records — the payment was judged against price + tax —
   * so an order carrying it is never grandfathered. Without the stamp, an
   * order counts as settled-before only when its STORED status says 'paid'
   * (what the old rule wrote) and its tenders — cash, gift card and credit
   * notes — cover the price. A status written by the new rule says 'partial'
   * for the same figures, so nothing recorded from now on slips through.
   */
  function settledBeforeTaxOnTop(o) {
    if (!o || typeof o !== 'object' || o.paidGross === true) return false;
    if (o.paymentStatus !== 'paid') return false;
    const price = +o.price || 0;
    if (price <= 0) return false;
    const tendered = (+o.paidAmount || 0) + (+o.giftCardDiscount || 0) + orderCreditedRaw(o);
    return tendered + 0.005 >= price;
  }

  /**
   * What the customer still has to COVER for this order to be settled, in its
   * OWN currency: `orderGrossRaw`, except for an order settled before tax on
   * top was owed (`settledBeforeTaxOnTop`), which was settled at its price.
   *
   * The figure owed, status and cash-due are judged against. Not a document
   * figure: what was billed is still `orderGrossRaw`.
   */
  function orderDueRaw(o, ctx) {
    const gross = orderGrossRaw(o, ctx);
    const price = +((o && o.price)) || 0;
    if (gross <= price) return gross;
    return settledBeforeTaxOnTop(o) ? price : gross;
  }

  /**
   * What the shop EARNED from this order: the price, less credit notes, in the
   * shop's currency, NET OF TAX.
   *
   * The one answer to "revenue" for a profit screen. `orderNetRevenueBase` is
   * the figure the customer was charged, and an inclusive-VAT shop that sums it
   * reads its own VAT as profit: a job charged 115 that cost 80 showed a
   * profit of 35 (30.4%) on the machine, product and per-hour screens while the
   * P&L — which has always taken the tax out — said 20 (20%). The P&L,
   * `kpi-rows` and `top-lists` each did this step inline; this is the step,
   * named, so the next screen asks for it instead of forgetting it.
   *
   * `netOfTax` is mode-aware: an exclusive shop's price IS the net figure and
   * comes back unchanged, and an unregistered shop has nothing to take out.
   */
  function orderEarnedBase(o, ctx, known) {
    const charged = orderNetRevenueBase(o, ctx, known);
    const profile = taxProfileOf({ settings: settingsOf(ctx) });
    if (!profile) return charged;
    return globalThis.KhaytTax.netOfTax(charged, profile);
  }

  const api = {
    convertToBase, clientCurrency, orderCurrency,
    orderRevenueBase, orderCreditedRaw, orderCreditedBase,
    orderNetRevenueBase, orderOwedRaw, orderOwedBase,
    orderGrossRaw, orderDueRaw, settledBeforeTaxOnTop, orderEarnedBase,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderMoney = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
