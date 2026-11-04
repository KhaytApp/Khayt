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
  /**
   * The money rules a deposit is judged by, however this file was loaded: as
   * globals in both apps, and by `require` under Node when nothing else
   * loaded them — so a test of this module alone reaches the same rule.
   */
  function sibling(name, file) {
    const g = typeof globalThis !== 'undefined' ? globalThis[name] : undefined;
    if (g) return g;
    if (typeof require !== 'function') return undefined;
    try { require(file); } catch (e) { return undefined; }
    return typeof globalThis !== 'undefined' ? globalThis[name] : undefined;
  }

  /**
   * What a deposit taken with a NEW order writes onto it.
   *
   * The deposit was written as `paidAmount` with a status from `deposit >=
   * price` — the PRE-TAX price. On a shop that adds tax on top, a 100 job at
   * 10% with a 100 deposit read `paid`, and because nothing said the payment
   * was judged against the gross, `settledBeforeTaxOnTop` grandfathered it as
   * settled: the 10 of tax was never billed. Now the deposit is clamped to
   * what the order is BILLED (price + tax there), stamped `paidGross: true`
   * the way `recordPayment` stamps every payment, and its status is
   * `KhaytOrderPayment.statusOf`'s — the one rule — with the shop's settings.
   */
  function depositFields(deposit, finalPrice, settings) {
    if (!(deposit > 0)) return { paymentStatus: 'unpaid', paidAmount: deposit };
    sibling('KhaytTax', './tax.js');
    const M = sibling('KhaytOrderMoney', './order-money.js');
    const P = sibling('KhaytOrderPayment', './order-payment.js');
    const ctx = { settings: settings || {} };
    const probe = { price: finalPrice, paidGross: true };
    const gross = (M && typeof M.orderGrossRaw === 'function') ? num(M.orderGrossRaw(probe, ctx), finalPrice) : finalPrice;
    const paid = +Math.min(deposit, Math.max(0, gross)).toFixed(2);
    probe.paidAmount = paid;
    const status = (P && typeof P.statusOf === 'function')
      ? P.statusOf(probe, ctx)
      : (paid >= gross ? 'paid' : 'partial');
    return { paymentStatus: status, paidAmount: paid, paidGross: true };
  }

  /** `YYYY-MM-DD` in the shop's own timezone — a due date is a local day. */
  function localDateStr(d) {
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  }

  function escapeRe(text) { return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

  /**
   * The highest sequence this book already shows for a series, or 0.
   *
   * WHY THE BOOK AND NOT ONLY THE COUNTER. The counters (`invNumNext`,
   * `quoteNumNext`) live in `settings`, and settings never travel through
   * cloud sync (lib/cloud-inbox.js says why). Two computers on one book
   * therefore each kept their own counter, and both handed out
   * INV-2026-0042. Reading the numbers already in the book means a number
   * the other computer issued — once its job has synced here — is never
   * issued again on this one. Two computers that are offline at the same
   * moment can still both reach for the same next number; the id no longer
   * depends on that number being unique (`mintOrderId`), so that costs a
   * duplicated label at worst, never a job.
   *
   * `patterns` are anchored regexes whose first group is the sequence.
   * Only 1–6 digits count, so a phone- or LAN-minted id
   * (`INV-2026-<13-digit ms>-<hex>`) never drags a counter into the
   * trillions. `sameYear`, when given, limits the scan to jobs dated in it —
   * for a format with no {year} in it, which still restarts every January.
   */
  function highestSeq(orders, patterns, fields, sameYear) {
    let max = 0;
    for (const o of arrayOf(orders)) {
      if (!o || typeof o !== 'object') continue;
      if (sameYear && !String(o.date || o.timestamp || '').startsWith(String(sameYear))) continue;
      for (const f of fields) {
        const v = o[f];
        if (typeof v !== 'string' || !v) continue;
        for (const re of patterns) {
          const m = re.exec(v);
          if (m) { const n = parseInt(m[1], 10); if (n > max) max = n; }
        }
      }
    }
    return max;
  }

  /** `{prefix}-{year}-{seq4}` as a regex capturing the sequence, or null. */
  function formatPattern(fmt, prefix, year) {
    const pieces = String(fmt).split(/(\{prefix\}|\{year\}|\{seq4\})/);
    if (pieces.indexOf('{seq4}') === -1) return null;
    let re = '^';
    for (const piece of pieces) {
      if (piece === '{prefix}') re += escapeRe(prefix);
      else if (piece === '{year}') re += escapeRe(year);
      else if (piece === '{seq4}') re += '(\\d{1,6})';
      else re += escapeRe(piece);
    }
    return new RegExp(re + '$');
  }

  /** An id or job number in a `${prefix}-${year}-${seq}` series, tagged or not. */
  function seriesPattern(prefix, year) {
    return new RegExp('^' + escapeRe(prefix) + '-' + escapeRe(year) + '-(\\d{1,6})(?:-[0-9a-z]{4})?$');
  }

  /**
   * The counter, moved past every number the book already holds this year.
   * Never moves it backwards: a shop that set its counter ahead keeps that.
   */
  function catchUpInvoiceCounter(settings, year, orders) {
    if (!orders) return;
    const prefix = settings.invNumPrefix || 'INV';
    const fmt = settings.invNumFormat || '{prefix}-{year}-{seq4}';
    const numbered = formatPattern(fmt, prefix, year);
    const yearless = fmt.indexOf('{year}') === -1 ? year : null;
    let seen = numbered ? highestSeq(orders, [numbered], ['invoiceNumber', 'invoiceNum'], yearless) : 0;
    // A plain job's id and job number carry the same sequence under the
    // shop's own prefix (`invPrefix`), which differs from `invNumPrefix` the
    // moment a shop changes one of them.
    seen = Math.max(seen, highestSeq(orders, [seriesPattern(settings.invPrefix || 'INV', year)], ['jobNumber', 'id']));
    if (seen >= (settings.invNumNext || 1)) settings.invNumNext = seen + 1;
  }

  /**
   * The next formal invoice number, advancing the counter — and its bare
   * four-digit sequence, which a new job's number is built from.
   */
  function allocateInvoice(settings, year, orders) {
    if ((settings.invNumYear || year) !== year) {
      settings.invNumYear = year;
      settings.invNumNext = 1;
    }
    catchUpInvoiceCounter(settings, year, orders);
    const prefix = settings.invNumPrefix || 'INV';
    const seq4 = String(settings.invNumNext || 1).padStart(4, '0');
    const fmt = settings.invNumFormat || '{prefix}-{year}-{seq4}';
    const number = fmt.replace('{prefix}', prefix).replace('{year}', year).replace('{seq4}', seq4);
    settings.invNumNext = (settings.invNumNext || 1) + 1;
    settings.invNumYear = year;
    return { number, seq4 };
  }

  /**
   * The next formal invoice number, advancing the counter.
   *
   * The counter resets on 1 January, which is what "{year}-0001" promises. A
   * shop that keeps its own format gets it honoured; the default is the one
   * every existing invoice already carries.
   *
   * `orders`, when given, is the book: the counter first moves past every
   * number already in it (see `highestSeq`), so a number another computer
   * issued is not issued twice. Every caller that has the book should pass it.
   */
  function allocateInvoiceNumber(settings, year, orders) {
    return allocateInvoice(settings, year, orders).number;
  }

  /**
   * A new job's id: its readable number plus a short random tag.
   *
   * THE BUG THIS EXISTS FOR. The id used to BE the readable number,
   * `INV-2026-0042`, drawn from a counter each computer keeps for itself. Two
   * computers on one book both created INV-2026-0042, and when they synced,
   * the merge (lib/sync.js `applyDeltas`) saw one id and kept one record — a
   * whole job, with its payments and parts, silently replaced by another.
   *
   * The id is the key every other record points at (payments, credit notes,
   * portal and tracking links, the phone, the LAN API), so it must be unique
   * on its own, without asking the other computer. Four characters from a
   * 32-letter alphabet is about a million to one per same-numbered pair, and
   * same-numbered pairs are already rare because the counter reads the book.
   *
   * The readable number is kept whole in front, so every screen that shows
   * the id still shows the number the shop knows, and it is also stored on
   * its own as `jobNumber` — which is what an invoice prints (see
   * lib/invoice-document.js `documentNumber`). Ids already in a book are
   * never touched: they are referenced from everywhere.
   *
   * `bytes` is the random source (`ctx.tokens.id`), for the same reason the
   * tracking token takes one; without it `Math.random` is used.
   */
  const ID_TAG_ALPHABET = '0123456789abcdefghjkmnpqrstvwxyz';
  function idTag(bytes) {
    let out = '';
    for (let k = 0; k < 4; k++) {
      const b = bytes && bytes.length > k ? (Number(bytes[k]) & 0xff) : Math.floor(Math.random() * 256);
      out += ID_TAG_ALPHABET[b & 31];
    }
    return out;
  }
  function mintOrderId(jobNumber, bytes) { return `${jobNumber}-${idTag(bytes)}`; }

  /**
   * The reference a person reads for a job: `jobNumber`, else the id. Every
   * screen, page, message and log line a person reads shows this; the id
   * stays the key. renderer/util.js `jobRef` and the Mac's `Order.reference`
   * are the same rule.
   */
  function jobRef(order) {
    if (!order || typeof order !== 'object') return '';
    return String((typeof order.jobNumber === 'string' && order.jobNumber) || order.id || '');
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
   * `invNumNext` would print one number on two invoices. `orders`, the book,
   * moves the counter past numbers already in it (`allocateInvoiceNumber`).
   */
  function ensureInvoiceNumber(order, settings, year, orders) {
    if (!invoiceNumberOwed(order, settings)) return null;
    const n = allocateInvoiceNumber(settings, year, orders);
    order.invoiceNum = n;
    order.invoiceNumber = n;
    return n;
  }

  /**
   * The next quote sequence.
   *
   * A separate counter, because a quote is not an invoice and must not use
   * up an invoice number. `orders`, the book, moves it past every quote
   * number already there, as `allocateInvoiceNumber` does.
   */
  function allocateQuoteSeq(settings, year, orders) {
    if ((settings.quoteNumYear || year) !== year) {
      settings.quoteNumYear = year;
      settings.quoteNumNext = 1;
    }
    if (orders) {
      const seen = highestSeq(orders, [seriesPattern(settings.quotePrefix || 'QUO', year)], ['jobNumber', 'id']);
      if (seen >= (settings.quoteNumNext || 1)) settings.quoteNumNext = seen + 1;
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
   * The currency a new job is billed in, and how to get there from the shop's.
   *
   * The calculator prices in the shop's own currency: every cost behind it
   * (spools, power, labour) is. The job used to be saved with that figure but
   * LABELLED with the quote's or the client's currency, so a 115 SAR job for a
   * EUR client invoiced as 115 EUR, and the books then counted it as 115 × the
   * EUR rate in SAR. Decided Nov 2 2026 (Turki): convert at save.
   *
   * - the job's currency is the one picked on the quote, else the client's,
   *   else the shop's;
   * - with a rate for it in Settings (`exchangeRates[code]` = shop currency per
   *   one unit, as `order-money.js` `convertToBase` reads it), every money
   *   figure is converted and the code is stamped on the job, so a later change
   *   of rate does not move what the customer was quoted;
   * - with NO rate the price cannot be converted, so the job is stamped with
   *   the shop's currency: an honest SAR price beats a SAR number wearing EUR.
   *
   * `fx` is shop currency per one unit of the job's currency (1 = no change).
   * `currency` is what goes on the record: undefined for an ordinary job in
   * the shop's currency with nothing picked, so its shape is unchanged.
   */
  function jobCurrency(i, settings, clients) {
    const base = settings.currency || 'SAR';
    let code = i.currency || '';
    if (!code && i.clientId) {
      const cl = arrayOf(clients).find((x) => x && x.id === i.clientId);
      code = (cl && cl.currency) || '';
    }
    if (!code || code === base) return { fx: 1, currency: i.currency || undefined };
    const rate = num((settings.exchangeRates || {})[code], 0);
    if (rate > 0) return { fx: rate, currency: code };
    return { fx: 1, currency: base };
  }

  /**
   * A saved job's money figures back in the SHOP's currency, for loading it
   * into the calculator again (a copy, a reprint). The calculator reads every
   * figure as the shop's, so a EUR job's 10 EUR shipping loaded as typed would
   * be read as 10 SAR and converted a second time on save. Uses today's rate;
   * a job in the shop's currency, or one with no rate, comes back unchanged.
   *
   * Returns `{ fx, shippingCost, extraLines, parts }` — only what the copy
   * paths reload.
   */
  function inShopCurrency(order, settings) {
    const o = ctxOf(order);
    const st = ctxOf(settings);
    const base = st.currency || 'SAR';
    const rate = o.currency && o.currency !== base ? num((st.exchangeRates || {})[o.currency], 0) : 0;
    const fx = rate > 0 ? rate : 1;
    const back = (v) => +(num(v, 0) * fx).toFixed(2);
    const P = pricing();
    return {
      fx,
      shippingCost: fx === 1 ? num(o.shippingCost, 0) : back(o.shippingCost),
      extraLines: arrayOf(o.extraLines).map((l) => (fx !== 1 && l && !(P && P.isPercentLine(l))
        ? Object.assign({}, l, { amount: back(l.amount) }) : Object.assign({}, l))),
      parts: arrayOf(o.parts).map((p) => (fx !== 1 && isAgreed(p)
        ? Object.assign({}, p, { agreedPrice: back(p.agreedPrice) }) : Object.assign({}, p))),
    };
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
   *   `priceOverride` a typed total, used as is — in the JOB's currency
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
   * Every other money input (costs, shipping, deposit, fixed extra lines,
   * overhead, agreed prices) is in the SHOP's currency, as the calculator
   * shows it, and is converted to the job's currency (`jobCurrency`). Costs
   * stay in the shop's currency on the record (`baseCost`, `componentsCost`,
   * `overheadCost`), as every report reads them.
   *
   * `ctx`: `{ settings, orders, now, tokens, consumables, clients }`. `tokens` is
   * `{ tracking, quoteApproval, id }`: the first two 16 bytes each, `id` at
   * least 4 — the random tag on the job's id (`mintOrderId`).
   */
  function newOrder(input, ctx) {
    const i = ctxOf(input);
    const c = ctxOf(ctx);
    const settings = c.settings || {};
    const orders = arrayOf(c.orders);
    const now = c.now instanceof Date ? c.now : new Date(typeof c.now === 'number' ? c.now : Date.now());
    const tokens = ctxOf(c.tokens);
    const asQuote = !!i.asQuote;
    const cur = jobCurrency(i, settings, c.clients);
    const fx = cur.fx;
    const toJob = (v) => (fx === 1 ? v : +(num(v, 0) / fx).toFixed(4));

    const parts = arrayOf(i.parts).map(p => Object.assign({}, p, {
      partStatus: p.partStatus || 'pending',
    }, fx !== 1 && isAgreed(p) ? { agreedPrice: +toJob(p.agreedPrice).toFixed(2) } : {}));
    const totalBaseCost = parts.reduce((s, p) => s + num(p.baseCost, 0), 0);
    const totalPrintTime = parts.reduce((s, p) => s + num(p.printTime, 0), 0);
    // A percentage line is a share of the bill whatever its currency; a fixed
    // line is an amount typed in the shop's currency.
    const extraLines = arrayOf(i.extraLines).map((l) => (fx !== 1 && l && !pricing().isPercentLine(l)
      ? Object.assign({}, l, { amount: +toJob(l.amount).toFixed(2) }) : l));

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
      baseCost: toJob(costedBase),
      agreedAmount,
      qty: 1,                    // the cart's parts already carry their own qty
      margin: positive(i.margin),
      priceTier: null,           // a tier never applies to a multi-line cart
      discountPct: Math.min(100, positive(i.discountPct)),
      rushEnabled,
      rushPct: rushEnabled ? num(settings.rushFeePct, 25) : 0,
      shippingCost: toJob(positive(i.shippingCost)),
      extraLines,
      priceRound: i.priceRound || null,
      priceOverride: i.priceOverride,
      overheadPerHour: toJob(positive(i.overheadPerHour)),
      printHours: overheadHours(parts, { productId: i.productId }),
      business: true,
    });

    const year = now.getFullYear();
    const prefix = asQuote ? (settings.quotePrefix || 'QUO') : (settings.invPrefix || 'INV');
    // Only the real invoice counter advances for an order; a quote is not an
    // invoice and must not consume a number the tax authority will ask about.
    const invoice = asQuote ? null : allocateInvoice(settings, year, orders);
    const invoiceNum = invoice ? invoice.number : null;
    const seq = asQuote ? allocateQuoteSeq(settings, year, orders) : invoice.seq4;
    const jobNumber = `${prefix}-${year}-${seq}`;

    const deposit = toJob(positive(i.depositAmount));
    const finalPrice = +quote.total.toFixed(2);
    const discountPct = Math.min(100, positive(i.discountPct));
    const shippingCost = toJob(positive(i.shippingCost));
    const rushFee = quote.rushFee > 0 ? +quote.rushFee.toFixed(2) : 0;

    return {
      // Unique across computers; `jobNumber` is the readable half (mintOrderId).
      id: mintOrderId(jobNumber, tokens.id),
      jobNumber,
      invoiceNum,
      invoiceNumber: invoiceNum,
      date: localDateStr(now),
      timestamp: now.toISOString(),
      project: i.project || '',
      clientId: i.clientId || null,
      productId: i.productId || null,
      currency: cur.currency,
      // The rate the price was converted at (shop currency per one unit of
      // `currency`), kept so a document that must state the amount in the
      // shop's currency — the ZATCA QR's total and VAT are riyals
      // (lib/zatca-qr.js qrAmounts) — uses the rate the customer was quoted
      // at, not whatever Settings holds on the day it is reprinted. Only on a
      // converted job, so an ordinary job's shape is unchanged.
      ...(cur.fx !== 1 ? { fxRate: cur.fx } : {}),
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
        ? P.resolveExtraLines(extraLines, quote.extrasBase, quote.feeBase)
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
      // The deposit as TAKEN — clamped to the bill like `paidAmount` below.
      // Stored as typed, a 200 deposit on a 115 bill read 200 here and 115
      // paid, and the deposit audit flagged the shop's own new order.
      depositAmount: depositFields(deposit, finalPrice, settings).paidAmount,
      // Derived here rather than taken, for the reason lib/order-payment.js
      // exists: a stored status that disagrees with the arithmetic is how an
      // order sits in receivables after it was settled.
      // and on a shop that adds tax on top, judged against price + tax — see
      // `depositFields`. `paidGross` is ABSENT on a job taken without one.
      ...depositFields(deposit, finalPrice, settings),
      paymentMethod: null,
      paidAt: null,
      // Empty for a job taken fresh. A COPY of a job (`lib/record-duplicate.js`)
      // carries what was written about the work; nothing else passes notes.
      notes: typeof i.notes === 'string' ? i.notes : '',
      internalNotes: typeof i.internalNotes === 'string' ? i.internalNotes : '',
      invoiceNotes: typeof i.invoiceNotes === 'string' ? i.invoiceNotes : '',
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
        ? { overheadCost: +(quote.overhead * fx).toFixed(2) } : {}),
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

  /**
   * Give a job whose printed number another job already carries the next
   * free one. The id never changes: payments, links and the phone point at it.
   *
   * Two computers offline at once can both reach for the same next invoice
   * number (the counter reads the book, but only once the other job has
   * synced). `KhaytInvoiceDocument.duplicateNumbers` finds the pairs; this is
   * the one fix offered, and it is the shop's to press — a number may already
   * be on a paper in a customer's hands, and only the shop knows which.
   *
   * What changes is whatever that job PRINTS (`documentNumber`):
   *   - a quote: its `jobNumber`, from the quote counter;
   *   - a job that began as a quote: its invoice number;
   *   - any other job: its invoice number and its `jobNumber` together, as a
   *     new job takes them. An older job whose id is its number gains a
   *     `jobNumber`, which is what prints from then on.
   * `renumberedFrom` keeps what it printed before. Returns the new number.
   *
   * IN THE GROUP'S OWN YEAR. `year` is the year of the duplicate pair, not
   * today's: a 2025 pair gets a free 2025 number — the highest that year holds
   * in the book, plus one. The shop's counter moves only when `year` is the
   * year it is counting; a past year's renumber leaves it exactly as it was,
   * so this January's sequence is not reset to 2025's. When it does move,
   * `settings` IS MUTATED, as by `newOrder`, and the caller writes both.
   */
  function renumber(order, settings, orders, year) {
    if (!order || typeof order !== 'object') return null;
    const live = settings || {};
    const quote = order.status === 'quote';
    const counting = quote ? live.quoteNumYear : live.invNumYear;
    // Another year's counter is a scratch copy started at 1: the book alone
    // (`highestSeq`) decides the number, and nothing is written back.
    const s = (!counting || counting === year)
      ? live
      : Object.assign({}, live, quote ? { quoteNumYear: year, quoteNumNext: 1 }
                                      : { invNumYear: year, invNumNext: 1 });
    const D = global.KhaytInvoiceDocument;
    const before = D && typeof D.documentNumber === 'function'
      ? D.documentNumber(order, s) : (order.invoiceNumber || order.jobNumber || order.id);
    let given;
    if (order.status === 'quote') {
      const seq = allocateQuoteSeq(s, year, orders);
      given = order.jobNumber = `${s.quotePrefix || 'QUO'}-${year}-${seq}`;
    } else if (beganAsQuote(order, s)) {
      given = allocateInvoiceNumber(s, year, orders);
      order.invoiceNum = given;
      order.invoiceNumber = given;
    } else {
      const inv = allocateInvoice(s, year, orders);
      order.invoiceNum = inv.number;
      order.invoiceNumber = inv.number;
      given = order.jobNumber = `${s.invPrefix || 'INV'}-${year}-${inv.seq4}`;
    }
    if (before && before !== given) order.renumberedFrom = before;
    return given;
  }

  /**
   * What `renumber` may change, taken BEFORE it runs, so a misclick can be
   * undone (`undoRenumber`). The job's number fields and the two counters.
   */
  const RENUMBER_FIELDS = ['jobNumber', 'invoiceNumber', 'invoiceNum', 'renumberedFrom'];
  const COUNTER_FIELDS = ['invNumNext', 'invNumYear', 'quoteNumNext', 'quoteNumYear'];
  function renumberSnapshot(order, settings) {
    const pick = (src, keys) => {
      const out = {};
      for (const k of keys) out[k] = (src && Object.prototype.hasOwnProperty.call(src, k)) ? src[k] : null;
      return out;
    };
    return { order: pick(order, RENUMBER_FIELDS), settings: pick(settings, COUNTER_FIELDS) };
  }

  /**
   * Put a renumbered job back as it was. `before` is the snapshot taken
   * before `renumber`, `after` the one taken after it. The job's fields come
   * back; a counter comes back only if nothing has moved it since — another
   * job given a number in between keeps its number, and the counter stays
   * past it. Mutates `order` and `settings`; the caller writes both.
   */
  function undoRenumber(order, settings, before, after) {
    if (!order || !before) return false;
    for (const k of RENUMBER_FIELDS) {
      const v = before.order ? before.order[k] : null;
      if (v === null || v === undefined) delete order[k]; else order[k] = v;
    }
    if (settings && before.settings && after && after.settings) {
      for (const k of COUNTER_FIELDS) {
        if (settings[k] === after.settings[k] && before.settings[k] !== null) settings[k] = before.settings[k];
      }
    }
    return true;
  }

  /** How many random bytes each token needs. */
  const TOKEN_BYTES = 16;

  const api = {
    TOKEN_BYTES,
    allocateInvoice, allocateInvoiceNumber, allocateQuoteSeq, mintOrderId, jobRef, renumber, renumberSnapshot, undoRenumber, avgDailyWorkingHours,
    estimateDueDate, newOrder, componentsCost, jobCurrency, inShopCurrency, overheadHours, isAgreed,
    invoiceNumberOwed, ensureInvoiceNumber, beganAsQuote, awaitingApproval,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderNew = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
