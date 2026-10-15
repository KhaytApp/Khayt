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
  const calculatorCost = () => (typeof globalThis !== 'undefined' ? globalThis.KhaytCalculatorCost : undefined);
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
   * Whether this job BEGAN AS A QUOTE, so its invoice is numbered by the
   * invoice counter rather than by its id.
   *
   * The markers are the customer's yes — `quoteAcceptedAt` (the shop pressed
   * Approve) or `clientApprovedAt` (the customer did, online) — or an id that
   * still wears the quote prefix. `hasQuote` is NOT one: a job held On hold
   * with a quote attached is a quote still waiting for its answer (the
   * approval page offers the Approve button for exactly that shape), and
   * counting it would number an invoice nobody has agreed to.
   *
   * A job that was never a quote is numbered by its id, which `newOrder`
   * builds from `settings.invPrefix` — the prefix the shop set — while the
   * invoice counter runs on `invNumPrefix`. The two differ the moment a shop
   * changes one, so a plain job must keep printing its id.
   */
  function beganAsQuote(order, settings) {
    if (!order || typeof order !== 'object') return false;
    if (order.quoteAcceptedAt || order.clientApprovedAt) return true;
    const prefix = ((settings && settings.quotePrefix) || 'QUO') + '-';
    return typeof order.id === 'string' && order.id.startsWith(prefix);
  }

  /**
   * A quote still waiting for the customer: in the quote column, or held On
   * hold with its quote attached and no yes recorded.
   */
  function awaitingApproval(order) {
    if (!order || typeof order !== 'object') return false;
    if (order.status === 'quote') return true;
    return order.status === 'on_hold' && !!order.hasQuote
      && !order.quoteAcceptedAt && !order.clientApprovedAt;
  }

  /**
   * Whether this job is owed an invoice number it does not have.
   *
   * A quote is created WITHOUT one (`newOrder` leaves `invoiceNum` null so a
   * quote never consumes a number the tax authority will ask about), and the
   * number is meant to arrive when the customer says yes. On the Mac nothing
   * gave it one — the approve paths stamped `quoteAcceptedAt` and moved on —
   * so an accepted quote was invoiced under its quote id, `QUO-…`.
   *
   * Owed when the job is not a quote still waiting for its answer
   * (`awaitingApproval`), was not cancelled, has neither spelling of the
   * number, and `beganAsQuote`. A job that was never a quote is left alone —
   * its id IS its invoice number.
   */
  function invoiceNumberOwed(order, settings) {
    if (!order || typeof order !== 'object') return false;
    if (order.status === 'cancelled' || awaitingApproval(order)) return false;
    if (order.invoiceNumber || order.invoiceNum) return false;
    return beganAsQuote(order, settings);
  }

  /**
   * Give an accepted quote its invoice number, once.
   *
   * Writes both spellings (`invoiceNum` and `invoiceNumber`, as `newOrder`
   * does) onto `order` and advances `settings`' counter, in place. Returns the
   * number given, or null when none was owed — so a second call, or a call on
   * a job that already has one, changes nothing.
   *
   * The caller must run this INSIDE the store's write, on the newest book: the
   * counter is a read-modify-write, and two approvals that each read the same
   * `invNumNext` would print one number on two invoices.
   */
  function ensureInvoiceNumber(order, settings, year) {
    if (!invoiceNumberOwed(order, settings)) return null;
    const n = allocateInvoiceNumber(settings, year);
    order.invoiceNum = n;
    order.invoiceNumber = n;
    return n;
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

  /**
   * The print hours the overhead line is charged on: each part's print time ×
   * its quantity (a part's `printTime` is per piece, exactly as its wear is),
   * over the parts priced at cost plus margin. A part the customer has agreed
   * a price for is charged that price and nothing else — its hours carry no
   * overhead, as they carry no margin. Nor does a part whose own price tier
   * applies at its quantity: the calculator stores it at the tier price backed
   * out to a cost, so the margin puts it back at exactly the tier price, and
   * overhead on top would sell it above the price the tier promised.
   *
   * And none at all on a job taken from a catalogue PRODUCT (`opts.productId`).
   * The product has one price — `lib/product-pricing.js`, the storefront feed
   * and a shelf sale all price it without the overhead line — and a job taken
   * from it that added the line sold the same product for two prices
   * (alpha.74 review). A shop that wants overhead in a product's price puts it
   * in the product.
   */
  function overheadHours(parts, opts) {
    if (opts && opts.productId) return 0;
    const P = pricing();
    let total = 0;
    for (const p of arrayOf(parts)) {
      if (!p || isAgreed(p)) continue;
      if (P && typeof P.activePriceTier === 'function' && P.activePriceTier(p.priceTiers, p.qty)) continue;
      total += positive(p.printTime) * Math.max(1, num(p.qty, 1));
    }
    return total;
  }

  /**
   * What a job's bought-in components cost: the catalogue's own figure for one
   * assembly (`computeComponentsCost`, the helper `lib/product-pricing.js`
   * prices a product with) times how many assemblies the job makes.
   *
   * The catalogue folds components into a product's cost before the margin;
   * a job taken from that product left them out, so it sold for less than the
   * catalogue said by exactly their cost plus margin. Times `assemblyQty`
   * because that is what the job DRAWS from the shelf
   * (`lib/order-deduction.js`: `qtyPerUnit × assemblyQty`) — one assembly is
   * the catalogue's figure exactly.
   *
   * `consumables` omitted reads the renderer's global shelf, as the helper
   * always has; the Mac passes its rows explicitly.
   */
  function componentsCost(components, assemblyQty, consumables) {
    const list = arrayOf(components).filter(x => x && x.consumableId);
    if (!list.length) return 0;
    const CC = calculatorCost();
    if (!CC || typeof CC.computeComponentsCost !== 'function') {
      throw new Error('KhaytOrderNew needs KhaytCalculatorCost to price components');
    }
    const each = +CC.computeComponentsCost(list, Array.isArray(consumables) ? consumables : undefined) || 0;
    const aq = num(assemblyQty, 0) > 0 ? num(assemblyQty, 1) : 1;
    return +(each * aq).toFixed(4);
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
   *   `overheadPerHour` the shop's fixed costs per print hour, as the screen
   *                  that took the job showed them (`lib/overhead-rate.js`
   *                  `perHour`) — absent or 0 unless the shop turned it on
   *
   * A part carrying `agreedPrice` (set by `lib/price-agreements.js` from the
   * customer's record) is priced at that figure per unit and NOT marked up;
   * the rest of the cart is cost plus margin. Each part's `baseCost` stays
   * the true cost of that part, agreed or not — it is what a margin is
   * measured against, and an agreed price that overwrote it would report the
   * part as sold at cost.
   *
   * Components are costed from `ctx.consumables` (see `componentsCost`) and
   * priced at cost plus margin with the rest of the cart, as the catalogue
   * prices them; their cost is frozen on the record as `componentsCost`.
   *
   * `ctx`: `{ settings, orders, now, tokens, consumables }`. `tokens` is
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
    // The components ride with the costed half: the catalogue prices them at
    // cost plus margin, and no customer agreement names them.
    const components = arrayOf(i.components).filter(x => x && x.consumableId).map(x => Object.assign({}, x));
    const assemblyQty = num(i.assemblyQty, 0) > 0 ? num(i.assemblyQty, 1) : 1;
    const compCost = componentsCost(components, assemblyQty, c.consumables);
    const costedBase = parts.reduce((s, p) => s + (isAgreed(p) ? 0 : num(p.baseCost, 0)), 0) + compCost;

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
      overheadPerHour: positive(i.overheadPerHour),
      printHours: overheadHours(parts, { productId: i.productId }),
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
      components,
      assemblyQty,
      // What the components cost when the job was taken, frozen like a part's
      // `baseCost` — the price above includes them, so the cost beside it has
      // to. ABSENT on a job with none, so every other record keeps its shape.
      ...(compCost > 0 ? { componentsCost: +compCost.toFixed(2) } : {}),
      // The share of the shop's fixed costs this job was priced to carry
      // (lib/overhead-rate.js). Beside the parts' cost, NEVER inside it: the
      // P&L and the break-even target count the fixed costs themselves, and a
      // part cost holding a slice of them would count them twice. Absent when
      // the line is off, so every other record keeps its shape.
      // Not when the price was TYPED (`priceOverride`): that figure is what the
      // customer pays whatever the cost lines say, so nothing of it was priced
      // to carry the overhead, and a record claiming it was would misreport.
      ...(quote.overhead > 0 && quote.priceSource !== 'override'
        ? { overheadCost: +quote.overhead.toFixed(2) } : {}),
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
    estimateDueDate, newOrder, componentsCost, overheadHours, isAgreed,
    invoiceNumberOwed, ensureInvoiceNumber, beganAsQuote, awaitingApproval,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderNew = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
