'use strict';

/**
 * What a new job IS.
 *
 * Forty-five fields, an identifier allocated from a counter the shop owns, an
 * invoice number, a due date estimated from how much work is already queued,
 * and a deposit that decides the payment status. All of it was written inline
 * in `logPrint`, reading twenty form controls, which meant only the Electron
 * window could create a job at all — and the native Mac app cannot be a
 * replacement for a shop that still has to open Electron to take an order.
 *
 * So the RECORD moved here and takes its inputs as an argument. The form still
 * belongs to whoever is asking; what a job looks like once it exists does not.
 *
 * PURE, with two deliberate exceptions the caller has to know about:
 *
 *   `ctx.settings` IS MUTATED, on purpose. Allocating an invoice number and a
 *   quote sequence advances counters the shop owns, and an allocation that is
 *   not written down hands the same number to the next job. The caller must
 *   save settings with the order, in the same write.
 *
 *   `ctx.tokens` supplies the random bytes for the tracking and quote-approval
 *   tokens, because a random source is exactly what a pure module has not got.
 *
 * `KhaytPricing` and `KhaytCalculatorCost` are consulted through globals the way
 * every sibling module is: they are present in both apps, and a build without
 * them should fail loudly here rather than quietly price a job at zero.
 */
(function (global) {

  const ctxOf = (ctx) => (ctx && typeof ctx === 'object' ? ctx : {});
  const arrayOf = (v) => (Array.isArray(v) ? v : []);
  const num = (v, d) => {
    const n = +v;
    return Number.isFinite(n) ? n : d;
  };
  const positive = (v) => Math.max(0, num(v, 0));

  const pricing = () => (typeof globalThis !== 'undefined' ? globalThis.KhaytPricing : undefined);
  const workingWeek = () => (typeof globalThis !== 'undefined' ? globalThis.KhaytWorkingWeek : undefined);

  /** `YYYY-MM-DD` in the shop's own timezone — a due date is a local day. */
  function localDateStr(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  /**
   * The next formal invoice number, advancing the counter.
   *
   * The counter resets on 1 January, which is what "{year}-0001" promises. A
   * shop that keeps its own format gets it honoured; the default is the one
   * every existing invoice already carries.
   */
  function allocateInvoiceNumber(settings, year) {
    if ((settings.invNumYear || year) !== year) {
      settings.invNumYear = year;
      settings.invNumNext = 1;
    }
    const prefix = settings.invNumPrefix || 'INV';
    const seq4 = String(settings.invNumNext || 1).padStart(4, '0');
    const fmt = settings.invNumFormat || '{prefix}-{year}-{seq4}';
    const result = fmt.replace('{prefix}', prefix).replace('{year}', year).replace('{seq4}', seq4);
    settings.invNumNext = (settings.invNumNext || 1) + 1;
    settings.invNumYear = year;
    return result;
  }

  /**
   * The next quote sequence.
   *
   * A separate counter, because the id is the primary key and two quotes
   * sharing one is a record that overwrites another.
   */
  function allocateQuoteSeq(settings, year) {
    if ((settings.quoteNumYear || year) !== year) {
      settings.quoteNumYear = year;
      settings.quoteNumNext = 1;
    }
    const seq4 = String(settings.quoteNumNext || 1).padStart(4, '0');
    settings.quoteNumNext = (settings.quoteNumNext || 1) + 1;
    settings.quoteNumYear = year;
    return seq4;
  }

  /**
   * Hours a shop gets through in an average CALENDAR day.
   *
   * Divided by seven rather than by the number of open days, because this
   * estimates a delivery DATE and the customer's week has seven days in it.
   * Eight hours when the working week says nothing.
   */
  function avgDailyWorkingHours(settings) {
    const ww = workingWeek();
    if (!ww) return 8;
    const hours = Object.values(ww.workingHours(settings) || {});
    const weekly = hours.reduce((s, h) => s + (h > 0 ? h : 0), 0);
    return weekly > 0 ? weekly / 7 : 8;
  }

  /**
   * When this job can realistically be ready.
   *
   * Everything already queued, plus this job, divided by what a day gets
   * through. Quotes get no date: nothing is queued until somebody accepts.
   *
   * On hold is excluded because a held job is not consuming machine time, and
   * counting it would push every new due date out by work nobody is doing.
   */
  function estimateDueDate(orders, addedHours, settings, now) {
    const queued = arrayOf(orders)
      // A legacy `delivered` row is finished, not queued: counting it pushed
      // every new due date out by work that was handed over months ago.
      .filter(o => o && o.status !== 'completed' && o.status !== 'delivered' && o.status !== 'quote' && o.status !== 'on_hold')
      .reduce((s, o) => s + positive(o.printTime), 0);
    const total = queued + positive(addedHours);
    const daily = avgDailyWorkingHours(settings);
    if (daily <= 0 || total <= 0) return null;
    const d = new Date(now);
    d.setDate(d.getDate() + Math.ceil(total / daily));
    return localDateStr(d);
  }

  /** A part the customer has agreed a price for. Zero is a price; absent is not. */
  function isAgreed(p) {
    const v = p && p.agreedPrice;
    if (v === null || v === undefined || v === '') return false;
    const n = +v;
    return Number.isFinite(n) && n >= 0;
  }

  /** `srv`-style hex from the bytes the caller supplies. */
  function hex(bytes) {
    return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
  }

  /**
   * A new job, as the book records it.
   *
   * `input`:
   *   `parts`        the cart, each already carrying its own cost fields
   *   `project`      what the job is called
   *   `clientId`, `clientRef`, `productId`, `machineId`, `currency`
   *   `margin`, `discountPct`, `shippingCost`, `depositAmount`
   *   `rushEnabled`, `extraLines`, `components`, `assemblyQty`
   *   `priceRound`   `{ step, mode }` — round the total, as a product's price is
   *   `priceOverride` a typed total, used as is
   *   `asQuote`      a quote rather than an order
   *   `fromStock`    this piece came off the shelf; it was printed in a batch
   *                  weeks ago and is being SOLD now, not made now
   *
   * A part carrying `agreedPrice` (set by `lib/price-agreements.js` from the
   * customer's record) is priced at that figure per unit and NOT marked up;
   * the rest of the cart is cost plus margin. Each part's `baseCost` stays
   * the true cost of that part, agreed or not — it is what a margin is
   * measured against, and an agreed price that overwrote it would report the
   * part as sold at cost.
   *
   * `ctx`: `{ settings, orders, now, tokens }`. `tokens` is
   * `{ tracking, quoteApproval }`, each 16 bytes.
   */
  function newOrder(input, ctx) {
    const i = ctxOf(input);
    const c = ctxOf(ctx);
    const settings = c.settings || {};
    const orders = arrayOf(c.orders);
    const now = c.now instanceof Date ? c.now : new Date(typeof c.now === 'number' ? c.now : Date.now());
    const tokens = ctxOf(c.tokens);
    const asQuote = !!i.asQuote;

    const parts = arrayOf(i.parts).map(p => Object.assign({}, p, {
      partStatus: p.partStatus || 'pending',
    }));
    const totalBaseCost = parts.reduce((s, p) => s + num(p.baseCost, 0), 0);
    const totalPrintTime = parts.reduce((s, p) => s + num(p.printTime, 0), 0);
    const extraLines = arrayOf(i.extraLines);

    // The cart in two halves: what the customer has agreed a price for, and
    // what is priced at cost plus margin.
    const agreedAmount = parts.reduce((s, p) => s + (isAgreed(p)
      ? positive(p.agreedPrice) * Math.max(1, num(p.qty, 1)) : 0), 0);
    const costedBase = parts.reduce((s, p) => s + (isAgreed(p) ? 0 : num(p.baseCost, 0)), 0);

    const P = pricing();
    if (!P) throw new Error('KhaytOrderNew needs KhaytPricing');
    const rushEnabled = !!i.rushEnabled;
    const quote = P.quoteTotal({
      baseCost: costedBase,
      agreedAmount,
      qty: 1,                    // the cart's parts already carry their own qty
      margin: positive(i.margin),
      priceTier: null,           // a tier never applies to a multi-line cart
      discountPct: Math.min(100, positive(i.discountPct)),
      rushEnabled,
      rushPct: rushEnabled ? num(settings.rushFeePct, 25) : 0,
      shippingCost: positive(i.shippingCost),
      extraLines,
      priceRound: i.priceRound || null,
      priceOverride: i.priceOverride,
      business: true,
    });

    const year = now.getFullYear();
    const prefix = asQuote ? (settings.quotePrefix || 'QUO') : (settings.invPrefix || 'INV');
    // Only the real invoice counter advances for an order; a quote is not an
    // invoice and must not consume a number the tax authority will ask about.
    const invoiceNum = asQuote ? null : allocateInvoiceNumber(settings, year);
    const seq = asQuote ? allocateQuoteSeq(settings, year)
                        : String((settings.invNumNext || 2) - 1).padStart(4, '0');

    const deposit = positive(i.depositAmount);
    const finalPrice = +quote.total.toFixed(2);
    const discountPct = Math.min(100, positive(i.discountPct));
    const shippingCost = positive(i.shippingCost);
    const rushFee = quote.rushFee > 0 ? +quote.rushFee.toFixed(2) : 0;

    return {
      id: `${prefix}-${year}-${seq}`,
      invoiceNum,
      invoiceNumber: invoiceNum,
      date: localDateStr(now),
      timestamp: now.toISOString(),
      project: i.project || '',
      clientId: i.clientId || null,
      productId: i.productId || null,
      currency: i.currency || undefined,
      // NOT filtered for blanks. A part with no filament chosen contributes an
      // empty string, so a two-part job can read "PLA, " with a dangling comma.
      // That is what every record already in a shop's book carries, and a lift
      // whose job is to change nothing does not quietly tidy a display string.
      material: [...new Set(parts.map(p => p.material))].join(', '),
      printTime: +totalPrintTime.toFixed(1),
      price: finalPrice,
      discountPct: discountPct || 0,
      priceBeforeDiscount: discountPct > 0 ? +quote.priceBeforeDiscount.toFixed(2) : null,
      // How the price was reached, only when something other than the
      // arithmetic reached it — every record before this had none of these,
      // and a field that is always present is a field every reader must learn.
      ...(agreedAmount > 0 ? { agreedAmount: +agreedAmount.toFixed(2) } : {}),
      ...(quote.priceSource !== 'base' ? {
        computedPrice: +quote.computedTotal.toFixed(2),
        priceSource: quote.priceSource,
      } : {}),
      ...(quote.priceSource === 'rounded' ? { priceRound: { step: positive(i.priceRound.step), mode: i.priceRound.mode || 'nearest' } } : {}),
      ...(quote.priceSource === 'override' ? { priceOverride: finalPrice } : {}),
      shippingCost: shippingCost > 0 ? +shippingCost.toFixed(2) : 0,
      deliveredAt: null,
      carrier: null,
      trackingNumber: null,
      labelUrl: null,
      shippedAt: null,
      shippingStatus: null,
      shippingHistory: [],
      shippingService: null,
      shipmentMeta: null,
      attachedFiles: [],
      // `amount` is frozen at the resolved figure so an invoice never recomputes
      // a percentage against a base that has since changed. `pct` is kept beside
      // it so the row still reads as "6.5%" — pricing ignores `amount` on a
      // percentage line, so carrying both cannot double-charge.
      extraLines: extraLines.length > 0
        ? P.resolveExtraLines(extraLines, quote.extrasBase)
           .map((r, n) => Object.assign({}, extraLines[n], { label: r.label, amount: r.amount }))
        : undefined,
      // ── SOLD OFF THE SHELF, NOT MADE TO ORDER ────────────────────────
      //
      // A marker, never a calculation. The piece was printed in a batch weeks
      // ago and is being sold today, so its price, its cost AND its print
      // hours all land on the sale — which is the only combination that keeps
      // the existing figures true. Cost without hours would inflate revenue
      // per print-hour in `cost-trends.js`, which divides one by the other;
      // hours without cost would show a machine earning nothing.
      //
      // The KEY IS ABSENT on an ordinary job, rather than present and
      // undefined. `fromStock: undefined` reads the same through
      // `JSON.stringify` and is a different object — `Object.keys` sees it,
      // and so does the characterization test that pins this record against
      // the implementation it was lifted out of. A record shape that changes
      // for every job in every book was not what this field is for.
      ...(i.fromStock === true ? { fromStock: true } : {}),
      status: asQuote ? 'quote' : 'pending',
      statusHistory: [{ status: asQuote ? 'quote' : 'pending', at: now.toISOString() }],
      queuePos: orders.filter(o => o && o.status === 'pending').length + 1,
      machineId: i.machineId || null,
      materialDeducted: false,
      depositAmount: deposit,
      // Derived here rather than taken, for the reason lib/order-payment.js
      // exists: a stored status that disagrees with the arithmetic is how an
      // order sits in receivables after it was settled.
      paymentStatus: deposit <= 0 ? 'unpaid' : (deposit >= finalPrice ? 'paid' : 'partial'),
      paidAmount: deposit,
      paymentMethod: null,
      paidAt: null,
      notes: '',
      internalNotes: '',
      invoiceNotes: '',
      clientRef: i.clientRef || null,
      tags: [],
      dueDate: asQuote ? null : estimateDueDate(orders, totalPrintTime, settings, now),
      priority: false,
      printPhotos: [],
      parts,
      components: arrayOf(i.components).filter(x => x && x.consumableId).map(x => Object.assign({}, x)),
      assemblyQty: num(i.assemblyQty, 0) > 0 ? num(i.assemblyQty, 1) : 1,
      actualPrintTime: null,
      actualWeight: null,
      quoteSentAt: asQuote ? localDateStr(now) : null,
      rushFee: rushFee > 0 ? rushFee : undefined,
      rushFeeAmount: rushFee,
      quoteExpiresAt: asQuote
        ? localDateStr(new Date(now.getTime() + num(settings.quoteValidityDays, 7) * 86400000))
        : null,
      quoteApprovalToken: asQuote && tokens.quoteApproval ? hex(tokens.quoteApproval) : undefined,
      quoteAcceptedAt: null,
      quoteVersion: asQuote ? 1 : undefined,
      quoteRevisions: asQuote ? [] : undefined,
      trackingToken: tokens.tracking ? hex(tokens.tracking) : undefined,
    };
  }

  /** How many random bytes each token needs. */
  const TOKEN_BYTES = 16;

  const api = {
    TOKEN_BYTES,
    allocateInvoiceNumber, allocateQuoteSeq, avgDailyWorkingHours,
    estimateDueDate, newOrder,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderNew = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
