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

  /**
   * Write on each of a customer's jobs the currency it is in today, BEFORE
   * that customer's currency changes.
   *
   * A job in the shop's own currency carries no `currency` and is read in its
   * customer's. So giving a customer with ten finished SAR jobs the currency
   * EUR turned every one of them into EUR: a paid 1,000 became 4,100 of
   * revenue. Call this with the clients AS THEY WERE; it stamps the jobs that
   * have none and returns the ones it changed. A job that already says its
   * currency is left alone.
   */
  function pinCurrenciesOf(orders, clientId, ctx) {
    const changed = [];
    if (clientId == null || clientId === '') return changed;
    for (const o of Array.isArray(orders) ? orders : []) {
      if (!o || typeof o !== 'object' || o.currency) continue;
      if (String(o.clientId) !== String(clientId)) continue;
      o.currency = orderCurrency(o, ctx);
      changed.push(o);
    }
    return changed;
  }

  /**
   * One of an ORDER's own amounts, into the shop's base currency — at the rate
   * the order was SAVED at when it carries one, today's otherwise.
   *
   * Since a job is converted into the client's currency when it is saved, the
   * rate it was converted at is kept on it (`fxRate`, lib/order-new.js:
   * shop currency per one unit of `currency`). Every report reads an order's
   * money through here, so the dashboard, the P&L, a client's totals, the
   * board and the Mac all count a EUR job at the rate it was quoted at, and
   * none of them moves when Settings does.
   *
   * A job saved before rates were kept (no `fxRate`) falls back to today's
   * rate from Settings, as every report always did — and, with no rate at
   * all, to the amount unconverted (`convertToBase`).
   *
   * The stored rate belongs to the stored code: it is used only when the
   * order's own `currency` is the one being converted.
   */
  function orderToBase(amount, o, ctx, known) {
    const cur = orderCurrency(o, ctx, known);
    const base = settingsOf(ctx).currency || 'SAR';
    if (!cur || cur === base) return +amount || 0;
    const saved = Number(o && o.fxRate);
    if (o && o.currency === cur && Number.isFinite(saved) && saved > 0) return (+amount || 0) * saved;
    return convertToBase(amount, cur, ctx);
  }

  /** The gross invoiced figure. Right for a document, wrong for "what did we earn". */
  function orderRevenueBase(o, ctx, known) {
    return orderToBase(+((o && o.price)) || 0, o, ctx, known);
  }

  function orderCreditedRaw(o) {
    return ((o && o.creditNotes) || []).reduce((s, cn) => s + (+((cn && cn.amount)) || 0), 0);
  }

  function orderCreditedBase(o, ctx, known) {
    return orderToBase(orderCreditedRaw(o), o, ctx, known);
  }

  /** What the shop actually earned: the price, less credit notes. */
  function orderNetRevenueBase(o, ctx, known) {
    if (!earns(o)) return 0;
    return Math.max(0, orderRevenueBase(o, ctx, known) - orderCreditedBase(o, ctx, known));
  }

  /**
   * What a set of jobs earned, in the shop's currency — `orderNetRevenueBase`
   * summed, so a board column is the same figure the reports give: each job
   * at its saved rate, a job saved before rates were kept at today's
   * (`orderToBase`). To the halala.
   */
  function earnedTotalBase(orders, ctx, known) {
    let total = 0;
    for (const o of Array.isArray(orders) ? orders : []) total += orderNetRevenueBase(o, ctx, known);
    return Math.round(total * 100) / 100;
  }

  /**
   * What is still outstanding, in the order's OWN currency.
   *
   * `ctx` is optional and carries the settings: given them, an exclusive shop
   * is owed price + tax (see `orderGrossRaw`), and its credit notes are grossed
   * up the same way (`orderCreditedDueRaw`). Without them the price is what is
   * due, as it always was.
   */
  function orderOwedRaw(o, ctx) {
    if (!earns(o)) return 0;
    if (!owesAtAll(o)) return 0;
    return Math.max(
      0,
      orderDueRaw(o, ctx) - (+((o && o.paidAmount)) || 0)
        - (+((o && o.giftCardDiscount)) || 0) - orderCreditedDueRaw(o, ctx),
    );
  }

  /** What is still outstanding, in the shop's base currency. */
  function orderOwedBase(o, ctx, known) {
    if (!earns(o)) return 0;
    if (!owesAtAll(o)) return 0;
    const toBase = (amount) => orderToBase(amount, o, ctx, known);
    return Math.max(
      0,
      toBase(orderDueRaw(o, ctx))
        - toBase(+((o && o.paidAmount)) || 0)
        - toBase(+((o && o.giftCardDiscount)) || 0)
        - toBase(orderCreditedDueRaw(o, ctx)),
    );
  }

  /**
   * Can this order owe the shop anything at all?
   *
   * A QUOTE has not been agreed, a CANCELLED job was called off, a VOIDED
   * invoice is not an invoice and one CREDITED IN FULL (`creditedAt`, stamped
   * by `generateCreditNote`) was handed back. None of them is a debt, whatever
   * their price and paid fields say — and receivables, the masthead total, the
   * Mac's title bar and widget all read owed through here.
   * `lib/payment-reminder.js` already refused quotes and voided orders; this is
   * that rule at the chokepoint, so every reader inherits it.
   */
  function owesAtAll(o) {
    if (!o || typeof o !== 'object') return false;
    if (o.status === 'quote' || o.status === 'cancelled') return false;
    if (o.voidedAt || o.creditedAt) return false;
    return earns(o);
  }

  /**
   * The credit notes in the same terms as what is DUE, in the order's own
   * currency.
   *
   * A credit note is taken against the PRICE (the dialog caps it there). On a
   * shop that adds tax on top the price is pre-tax while what is due is
   * price + tax, so subtracting the bare credit from the gross left the tax on
   * the credited part still owed: 100 at 10% with 50 credited read 60 owed
   * instead of 55. Scaled by due / price — exactly 1 on every inclusive or
   * unregistered shop, and on an order settled before tax on top (whose due is
   * its price, see `orderDueRaw`).
   */
  function orderCreditedDueRaw(o, ctx) {
    const credited = orderCreditedRaw(o);
    if (credited <= 0) return credited;
    const price = +((o && o.price)) || 0;
    if (price <= 0) return credited;
    const due = orderDueRaw(o, ctx);
    if (!(due > price)) return credited;
    return Math.round(credited * (due / price) * 100) / 100;
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

  /**
   * A job's costs that are not its parts, in the SHOP's currency, as stored:
   * componentsCost, overheadCost, and a product's labourCost and packagingCost
   * (order-level since Nov 19). `opts`: { components, overhead, labour,
   * packaging } — each true unless false, so a reader keeps exactly the costs
   * it always summed (the Orders Log leaves overhead out; the dashboard's cost
   * of goods leaves components out). The ONE place these fields are read
   * (test/job-cost-ratchet.test.js).
   */
  /**
   * The labour of ONE LINE of work, before any failure buffer: prep ONCE for
   * the line, post-processing / assembly PER PIECE (Turki, Nov 19):
   *   (prepTime + postTime × qty) × laborRate.
   * A line is a part (its own qty), or a product (qty = how many of it, the
   * product's own hours; its parts' qty do not multiply post: assembly is per
   * finished product), or a store order's line of N products. The ONE rule:
   * the calculator's part cost (lib/calculator-cost.js), a product's labour
   * (lib/product-pricing.js) and store orders (lib/store-order-job.js) all
   * call it, and so do the Mac and the phone. It used to be (prep + post) ×
   * rate per PIECE, so prep was charged qty times: +24.75 a piece by default.
   */
  /**
   * How many boxes a line of `qty` pieces ships in (Turki, Nov 19: "depends
   * on size"): `perBox` is how many fit one box. A whole number >= 1 gives
   * ceil(qty / perBox); unsaid (or not a usable number) is ONE box for the
   * line, a hand part's packaging as it always was. A product passes its own
   * perBox, 1 by default (a box each, as before).
   */
  function lineBoxes(qty, perBox) {
    const q = Math.max(1, Math.floor(+qty || 1));
    const b = Math.floor(+perBox);
    if (!(perBox !== undefined && perBox !== null && perBox !== '' && b >= 1)) return 1;
    return Math.ceil(q / b);
  }

  function lineLabour(line) {
    const l = line || {};
    const pos = (v) => Math.max(0, +v || 0);
    const qty = Math.max(1, +l.qty || 1);
    // ONLY a line marked `labourPerLine: true` is costed the new way. An
    // unmarked line is the OLD sum, prep and post on every piece, so every
    // record written before this (a stored job's parts, a product without
    // rates) and every path that does not know the mark costs exactly what
    // it did (money review of #2586, HIGH 1 and 2): stored jobs stay frozen
    // and a product keeps its catalogue figure until "Use the new cost"
    // (Turki, Nov 19, option ii). New parts are marked where they are made:
    // the calculator, the job sheet, a quote, a product with its own rates.
    if (l.labourPerLine !== true) return (pos(l.prepTime) + pos(l.postTime)) * qty * pos(l.laborRate);
    return (pos(l.prepTime) + pos(l.postTime) * qty) * pos(l.laborRate);
  }

  function jobFixedCost(order, opts) {
    const o = order || {};
    const x = opts || {};
    const pos = (v) => Math.max(0, +v || 0);
    return (x.components === false ? 0 : pos(o.componentsCost))
      + (x.overhead === false ? 0 : pos(o.overheadCost))
      + (x.labour === false ? 0 : pos(o.labourCost))
      + (x.packaging === false ? 0 : pos(o.packagingCost));
  }

  /**
   * A job's cost, shop currency: its parts' `baseCost` plus jobFixedCost(opts).
   * A job without labourCost / packagingCost (every job before Nov 19) costs
   * exactly what each reader summed before (test/job-cost-sample-book.test.js).
   */
  /**
   * Whether a part added BY HAND to an existing job carries `orderLevelCosts`
   * (costed without labour and packaging, which the order carries once). THE
   * rule, in one place, for the desktop's job sheet and calculator and the
   * Mac's partsForSave. A product's parts (productJobParts), and parts edited
   * from them, keep their mark whatever this says.
   *
   * Turki, Nov 19: a hand-added part gets its OWN labour, so false.
   * `api.HAND_PARTS_SHARE_ONCE` is the switch: read at call time, so a test
   * can flip it and see both settings price alike.
   */
  function addedPartMark(order) {
    if (api.HAND_PARTS_SHARE_ONCE !== true) return false;
    return jobFixedCost(order, { components: false, overhead: false }) > 0;
  }

  function jobCost(order, opts) {
    const parts = (order && Array.isArray(order.parts) ? order.parts : []);
    return parts.reduce((s, p) => s + Math.max(0, +(p && p.baseCost) || 0), 0) + jobFixedCost(order, opts);
  }

  const api = {
    lineLabour,
    lineBoxes,
    HAND_PARTS_SHARE_ONCE: false,   // Turki, Nov 19 (see addedPartMark)
    addedPartMark,
    jobCost, jobFixedCost,
    convertToBase, clientCurrency, orderCurrency, pinCurrenciesOf,
    orderRevenueBase, orderCreditedRaw, orderCreditedBase,
    orderNetRevenueBase, orderOwedRaw, orderOwedBase,
    orderGrossRaw, orderDueRaw, settledBeforeTaxOnTop, orderEarnedBase,
    owesAtAll, orderCreditedDueRaw, orderToBase, earnedTotalBase,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderMoney = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
