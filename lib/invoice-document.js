'use strict';

/**
 * The document a customer is handed.
 *
 * Four hundred lines of template string that lived inside the renderer, so the
 * only thing in the world that could produce a Khayt invoice was the Electron
 * window. The native Mac app can take a job, price it and be paid for it, and
 * could not give anybody a receipt.
 *
 * It was already almost pure: one element written to at the end, and everything
 * else computed from the order, the shop's settings and the money figures its
 * caller had already worked out. So the body moved here unchanged and its
 * twenty renderer globals became an argument.
 *
 * RETURNS A STRING, and a flag. The Arabic-numeral pass is the one thing that
 * cannot be done in a string — it rewrites the text of elements after they are
 * laid out — so this says whether it is needed and which elements it applies
 * to, and each app does it on its own DOM.
 *
 * PURE: no globals, no clock beyond what the order carries. `KhaytTax` and
 * `KhaytInvoiceLanguage` are consulted the way every sibling module consults a
 * sibling: through the global they assign themselves to, present in both apps.
 */
(function (global) {

  /**
   * The date formatter, however this file happens to be loaded. Both hosts
   * assign `KhaytPrintDate` onto the global before this module runs; `require`
   * is the Node path, and there is no `require` under JavaScriptCore.
   */
  const dates = (typeof global.KhaytPrintDate !== 'undefined')
    ? global.KhaytPrintDate
    : (function () {
        try { return require('./print-date.js'); } catch (e) { return null; }
      })();
  const printDate = dates ? dates.printDate : ((d) => String(d || ''));
  const localeTagFor = dates ? dates.localeTagFor : (() => 'en-US');

  /**
   * `lib/order-new.js`, for the rule that says whether a job began as a quote.
   * Looked up when it is asked, not when this file loads: both apps load
   * order-new first, and Node takes the `require` path.
   */
  const orderNew = () => (typeof global.KhaytOrderNew !== 'undefined')
    ? global.KhaytOrderNew
    : (function () {
        try { return require('./order-new.js'); } catch (e) { return null; }
      })();

  /**
   * The number a document prints under "No.". `settings` is read only for
   * `quotePrefix`, and may be absent.
   *
   *   - a quote prints its id, `QUO-…`, and keeps it;
   *   - a job that BEGAN AS A QUOTE (`KhaytOrderNew.beganAsQuote`: accepted,
   *     approved by the customer, or still wearing the quote prefix — not
   *     `hasQuote` alone) prints its invoice number, `invoiceNumber`, else the
   *     older `invoiceNum`, else its id — because its id is still `QUO-…`, and
   *     that is no number for a tax invoice;
   *   - anything else prints its id, as it always has — or, for a job made
   *     since ids carry a random tag, its `jobNumber`, which is that id
   *     without the tag.
   *
   * The last is the one that matters most. A plain job's id is built from
   * `settings.invPrefix` (`newOrder`), the "Invoice prefix" the shop sets,
   * while its `invoiceNumber` comes off the counter's own `invNumPrefix`. A
   * shop whose prefix is `ATH` has a job `ATH-2026-0012` carrying
   * `INV-2026-0012`; printing the second would change the number on every
   * reprint of an invoice already in a customer's hands.
   *
   * Exported because every place that names an invoice — the payment QR's
   * reference, a credit note's "reversal of", the ZATCA XML — must name it the
   * same way the paper does.
   */
  function documentNumber(order, settings) {
    if (!order || typeof order !== 'object') return '';
    // A job made since ids became unique across computers carries its
    // readable number apart from its id (`KhaytOrderNew.mintOrderId`): the id
    // is `INV-2026-0042-k7qx`, the number `INV-2026-0042`. The number is what
    // the paper has always printed, so it stands in for the id below. Older
    // jobs have no `jobNumber` and their id IS the number, as before.
    const id = typeof order.jobNumber === 'string' && order.jobNumber
      ? order.jobNumber
      : (order.id == null ? '' : String(order.id));
    if (order.status === 'quote') return id;
    const O = orderNew();
    if (!O || typeof O.beganAsQuote !== 'function') {
      throw new Error('KhaytInvoiceDocument needs KhaytOrderNew to number a document');
    }
    if (!O.beganAsQuote(order, settings || {})) return id;
    return String(order.invoiceNumber || order.invoiceNum || id);
  }

  /**
   * Documents in the book that print the same number — the duplicates two
   * computers can still make while both are offline (see
   * `KhaytOrderNew.allocateInvoiceNumber`). No job is lost to it any more;
   * two papers carrying one number is what is left, and this names them.
   *
   * Grouped by what the paper prints (`documentNumber`), its kind (a quote
   * or an invoice — a quote's number and an invoice's never collide) and the
   * year of the job's date, since the counters restart each January. Each
   * group lists its jobs oldest first: the oldest is the one that most likely
   * went out first, so it is the one to keep.
   *
   * Returns `[{ number, kind, year, jobs: [{ id, ref, project, date }] }]`.
   */
  function duplicateNumbers(orders, settings) {
    const groups = new Map();
    for (const o of Array.isArray(orders) ? orders : []) {
      if (!o || typeof o !== 'object' || typeof o.id !== 'string') continue;
      const number = documentNumber(o, settings);
      if (!number) continue;
      const kind = o.status === 'quote' ? 'quote' : 'invoice';
      const year = String(o.date || o.timestamp || '').slice(0, 4);
      const key = kind + '|' + year + '|' + number;
      if (!groups.has(key)) groups.set(key, { number, kind, year, jobs: [] });
      groups.get(key).jobs.push(o);
    }
    const when = (o) => String(o.timestamp || o.date || '');
    const out = [];
    for (const g of groups.values()) {
      if (g.jobs.length < 2) continue;
      g.jobs.sort((a, b) => (when(a) < when(b) ? -1 : when(a) > when(b) ? 1 : (a.id < b.id ? -1 : 1)));
      g.jobs = g.jobs.map((o) => ({
        id: o.id,
        ref: String((typeof o.jobNumber === 'string' && o.jobNumber) || o.id),
        project: String(o.project || ''),
        date: String(o.date || ''),
      }));
      out.push(g);
    }
    return out.sort((a, b) => (a.number < b.number ? -1 : a.number > b.number ? 1 : 0));
  }

  /** The elements whose digits become Arabic-Indic when a shop asks for it. */
  const NUMERAL_SELECTOR = '.amount, .v, .qty, td.center, td.amount, .biz-meta, .meta';

/**
 * A phone number, an email, a registration — anything Latin inside an Arabic
 * document — kept in the order it was typed.
 *
 * ## The bug this exists for
 *
 * A Saudi shop's phone is `+966 50 000 0000`: Latin digits, spaces and a plus
 * sign, and NOT ONE character of it has a strong direction. Dropped into the
 * `dir="rtl"` invoice, the Unicode bidi algorithm gives those runs the
 * paragraph's direction, and the printed invoice read
 *
 *     0000 000 50 966+
 *
 * — the shop's own phone number, backwards, on a document a customer keeps.
 * The groups are not scrambled at random: they are laid out right to left,
 * which is exactly what the algorithm is specified to do with neutral runs.
 *
 * `<bdi>` is the element for this and it is all that is needed: "isolate this
 * text from the direction around it". Not `dir="ltr"`, which would also
 * left-ALIGN the value inside a right-aligned block.
 */
function isolate(text, escape) {
  return `<bdi>${escape(text)}</bdi>`;
}

/**
 * Phone and email, under the name a job is billed to.
 *
 * Both are optional and a customer with neither gets no line at all — an empty
 * strip under the name reads as a detail that failed to load.
 */
function contactLine(client, escape) {
  const bits = [client && client.phone, client && client.email]
    .filter(Boolean)
    .map((bit) => isolate(bit, escape))
    .join(' \u00b7 ');
  if (!bits) return '';
  return `<div class="name-sub">${bits}</div>`;
}

/**
 * The Saudi Riyal mark, drawn.
 *
 * ── WHY A PATH AND NOT THE CHARACTER ──────────────────────────────────────
 *
 * The app itself prints U+20C1 — it can ask CoreText at runtime whether the
 * face it is drawing in has the glyph and fall back to "SAR" when it does not.
 * **A document cannot ask.** An invoice is exported to PDF and opened on a
 * machine this app will never see, in a reader with fonts it cannot inspect,
 * and a price that renders as an empty box on a customer's invoice is worse
 * than one that says SAR. The codepoint arrived with the mark in 2025, so any
 * font older than that has nothing at that position.
 *
 * So the mark is geometry: `Saudi_Riyal_Symbol.svg` from Wikimedia Commons,
 * the same source and the same two paths the storefront uses. Geometry needs
 * no font.
 *
 * `currentColor` so it takes the colour of the text it sits in — the line
 * amounts wrap it in a muted span and the total does not. Sized from the
 * viewBox's own ratio in `invoice.css` so it cannot squash.
 *
 * The `<title>` is what a screen reader says. Note the trade-off taken here:
 * a drawn mark is not text, so a machine reading the PDF back gets the figure
 * without a currency beside it. That is the price of the glyph being certain,
 * and the ZATCA QR — which is the thing software actually parses — carries the
 * total and the tax as numbers regardless.
 */
const RIYAL_SVG =
  '<svg class="riyal" viewBox="0 0 1124.14 1256.39" role="img" aria-label="SAR" ' +
  'xmlns="http://www.w3.org/2000/svg" fill="currentColor" focusable="false">' +
  '<title>SAR</title>' +
  '<path d="M699.62,1113.02h0c-20.06,44.48-33.32,92.75-38.4,143.37l424.51-90.24c20.06-44.47,33.31-92.75,38.4-143.37l-424.51,90.24Z"/>' +
  '<path d="M1085.73,895.8c20.06-44.47,33.32-92.75,38.4-143.37l-330.68,70.33v-135.2l292.27-62.11c20.06-44.47,33.32-92.75,38.4-143.37l-330.68,70.27V66.13c-50.67,28.45-95.67,66.32-132.25,110.99v403.35l-132.25,28.11V0c-50.67,28.44-95.67,66.32-132.25,110.99v525.69l-295.91,62.88c-20.06,44.47-33.33,92.75-38.42,143.37l334.33-71.05v170.26l-358.3,76.14c-20.06,44.47-33.32,92.75-38.4,143.37l375.04-79.7c30.53-6.35,56.77-24.4,73.83-49.24l68.78-101.97v-.02c7.14-10.55,11.3-23.27,11.3-36.97v-149.98l132.25-28.11v270.4l424.53-90.28Z"/>' +
  '</svg>';

/**
 * How a currency is SHOWN on the document — the drawn mark for the riyal, the
 * escaped symbol or code for everything else.
 *
 * Display only. Nothing that is stored, totalled, or packed into the ZATCA QR
 * goes through here: `zatca-qr.js` builds its TLV from `String(total)` and the
 * VAT amount, so the mark cannot reach a scanner.
 */
function currencyMarkHtml(code, symbol, escapeHtml) {
  return String(code).toUpperCase() === 'SAR'
    ? RIYAL_SVG
    : escapeHtml(String(symbol == null ? '' : symbol));
}

/**
 * Print time as an invoice should say it.
 *
 * A slicer reports 8.745 hours and the line beside this one has always run
 * `Math.round` over the grams — so an invoice went to a customer reading
 * "PETG-CF · 8.745 hrs · 559 g". The weight was rounded and the hours next to
 * it were not, which is the whole bug: one figure was treated as something a
 * person reads and its neighbour was left as the machine's own number.
 *
 * One decimal. Three is a measurement nobody made — nothing in the shop knows
 * a print time to three and a half seconds, so printing it claims a precision
 * the figure does not have. A whole number would round 8.745 down to a flat 9
 * and lose the only part a customer might check against a quote.
 *
 * A trailing `.0` goes: "6 hrs" is what a person writes, "6.0 hrs" is what a
 * spreadsheet writes.
 */
/*
 * An attribute value, escaped HERE rather than through the host's
 * `escapeHtml`: that one is injected and defaults to the identity, and the
 * logo is a settings string — `safeBizLogo` checks only that it STARTS with
 * `data:image/`, so `data:image/png" onerror="…` passed it and closed the
 * attribute. A real data URL has none of these characters, so a good logo
 * comes out byte for byte.
 */
function attr(v) {
  return String(v == null ? '' : v)
    .replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/'/g, '&#39;')
    .replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function hoursForPrint(hours) {
  const n = Number(hours);
  if (!isFinite(n)) return String(hours);
  return String(Math.round(n * 10) / 10);
}

/**
 * The money lines under an invoice's table, as one rule both apps print.
 *
 * `order.price` already bundles rush, shipping and the extras
 * (`finalPrice = goods + rush + shipping + extras`), and the summary prints
 * Rush and Shipping as rows of their own under "Subtotal". So the Subtotal row
 * is the ITEMS — the price less rush and shipping, shown before the discount
 * when there is one — or the rows do not add up to the total under them. The
 * Mac printed the whole price there: a 280 job of 225 goods, 25 rush and 30
 * shipping read Subtotal 280, Rush 25, Shipping 30, Total 280.
 *
 *   itemsSubtotal − discount + rush + shipping = price
 *
 * in the price's own terms — tax-inclusive for an inclusive shop, pre-tax for
 * an exclusive one, whose `total` is the price plus `taxTotal` on a line of
 * its own (`addsTax`).
 *
 * @param {object} order
 * @param {object} profile from `KhaytTax.profileFromSettings`
 */
function invoiceSummary(order, profile) {
  const o = order || {};
  const r2 = (n) => Math.round(((+n || 0) + Number.EPSILON) * 100) / 100;
  const price = +o.price || 0;
  const T = (typeof globalThis !== 'undefined') ? globalThis.KhaytTax : undefined;
  const p = profile || {};
  const tax = (T && typeof T.computeTax === 'function')
    ? T.computeTax(price, p)
    : { subtotal: r2(price), taxTotal: 0, total: r2(price) };
  const shipping = +o.shippingCost || 0;
  const rush = +o.rushFeeAmount || 0;
  const discount = (+o.discountPct || 0) > 0
    ? Math.max(0, (+o.priceBeforeDiscount || 0) * (+o.discountPct || 0) / 100)
    : 0;
  const rates = Array.isArray(p.rates) ? p.rates.filter((r) => r && +r.percent > 0) : [];
  return {
    itemsSubtotal: r2(price - shipping - rush + discount),
    discount: r2(discount),
    rush: r2(rush),
    shipping: r2(shipping),
    subtotal: tax.subtotal,
    taxTotal: tax.taxTotal,
    total: tax.total,
    addsTax: p.mode === 'exclusive' && rates.length > 0,
  };
}

function invoiceHtml(order, ctx) {
  const {
    qrSvg, qrProblem = null, payQrSvg = '', total, vatAmount, subtotal,
    subtotalShown, vatRate, shipping = 0,
    // The shop, and the ways it says things. Every one of these was a renderer
    // global; naming them is what lets a second app produce the same document.
    settings = {}, clients = [], CURRENCIES = {}, i18n = { current: 'en' },
    t = (k) => k,
    escapeHtml = (s) => String(s == null ? '' : s),
    fmtMoney = (n) => String(n),
    // Defaulted to the shared formatter, for the same reason as the contact
    // line below: a host that forgets it prints an ISO timestamp on a document
    // a customer reads.
    formatPrintDate = (d) => printDate(d, localeTagFor(i18n && i18n.current)),
    shopField = () => '', safeBizLogo = () => '', safeCssColor = (v, f) => f,
    // Defaulted to the real thing, not to nothing. A host that forgets to pass
    // it gets an invoice with the customer's contact line missing and no sign
    // that anything is absent — which is how the Mac app printed six invoices
    // with a blank under the bill-to name.
    // THE CUSTOMER'S LOYALTY TIER, AS A RECORD.
    //
    // This was the one ingredient in this file that was never named. Every
    // other former renderer global is in this list; `getClientTier` was left
    // as a free variable, so it resolved to the renderer's global in Electron
    // and threw `ReferenceError: Can't find variable: getClientTier` in
    // JavaScriptCore — which meant the native Mac app could not build an
    // invoice AT ALL for any job with a customer, once loyalty was switched
    // on. The sheet said "This job's invoice could not be built" and no test
    // caught it, because no invoice test has ever enabled loyalty.
    //
    // Null is the honest default: the tier is the HOST's to look up, it needs
    // the whole print log to work out, and a document that quietly invented
    // one would be worse than one that prints no badge.
    clientTier = null,
    renderClientSub = (c) => contactLine(c, escapeHtml), BRAND_MARK_SVG = `<svg viewBox="300 110 424 760" xmlns="http://www.w3.org/2000/svg" fill="currentColor" aria-hidden="true"><rect x="497" y="130" width="30" height="60" rx="12"/><rect x="420" y="176" width="184" height="118" rx="26"/><rect x="452" y="294" width="120" height="22" rx="8"/><path d="M466 316H558L528 362H496Z"/><circle cx="512" cy="396" r="30"/><path d="M368 512C350 480 380 452 424 458C520 472 612 464 688 460C560 488 362 566 354 694C346 816 470 860 690 810" fill="none" stroke="currentColor" stroke-width="64" stroke-linecap="round"/></svg>`,
    orderCurrency = null, clientCurrency = () => '',
    payStatus = (o) => o.paymentStatus || 'unpaid',
    hijriDate = () => '', toArabicNumerals = (s) => String(s),
    // A PROFORMA: the job's paper as a request for payment, before the work is
    // invoiced. It is not a tax invoice, so it carries no ZATCA QR and no
    // invoice number — printing one must never use up a number or mark the
    // tax point (VAT is due on issued invoices). It prints the job's id,
    // the proforma title, and a watermark saying so.
    proforma = false,
    // ONE PART OF A JOB, asked for on its own: `{ label, percentage, amount,
    // total }`. Only meaningful with `proforma` — a milestone is a request for
    // part of the money, never a tax invoice, so the job's single real invoice
    // is untouched. With it the table is ONE line (the label and "N% of
    // total") priced at `amount`, shipping/rush/extras/discount are left off,
    // and the tax breakdown is worked out on `amount` by the same engine as
    // the whole job. Without it the document is byte for byte what it was.
    milestone = null,
  } = ctx || {};
  const ms = (proforma && milestone && typeof milestone === 'object') ? milestone : null;
  // THE DAY THE INVOICE WAS ISSUED (`KhaytPaymentTerms.invoiceDate`), the one
  // day the VAT summary, the accountant's CSV and the due date below all use.
  // An accepted quote is invoiced on its acceptance; its `date` is still the
  // quote's, and printing that put a 2 Oct invoice on paper as 28 Sep. When
  // the day is the job's own, `date` is printed exactly as before.
  const PTerms = (typeof global.KhaytPaymentTerms !== 'undefined')
    ? global.KhaytPaymentTerms
    : (function () { try { return require('./payment-terms.js'); } catch (e) { return null; } })();
  const issuedDay = (PTerms && typeof PTerms.invoiceDate === 'function') ? PTerms.invoiceDate(order) : '';
  const issuedMoved = !!issuedDay && issuedDay !== String(order.date || '').slice(0, 10);
  const issuedOn = issuedMoved ? issuedDay : order.date;
  const issuedDate = formatPrintDate(issuedOn);
  // The time beside it is the same moment's: the acceptance's own time when it
  // was stamped as an instant on that day, none when it was a bare day — the
  // quote's creation time under the acceptance's date would be a moment that
  // never happened.
  const acceptedStamp = String(order.quoteAcceptedAt || order.clientApprovedAt || '');
  const acceptedAt = /^\d{4}-\d{2}-\d{2}T/.test(acceptedStamp) ? new Date(acceptedStamp) : null;
  const issuedTime = !issuedMoved
    ? (order.timestamp ? new Date(order.timestamp).toTimeString().slice(0, 5) : '')
    : (acceptedStamp
      ? ((acceptedAt && !isNaN(acceptedAt.getTime())) ? acceptedAt.toTimeString().slice(0, 5) : '')
      : (order.timestamp ? new Date(order.timestamp).toTimeString().slice(0, 5) : ''));
  // Feature 1: use the order's currency (per-order override, else client, else base)
  const invCurrencyCode = (typeof orderCurrency === 'function') ? orderCurrency(order) : clientCurrency(order.clientId);
  const invCurObj = CURRENCIES[invCurrencyCode] || CURRENCIES[settings.currency] || CURRENCIES.SAR;
  // The drawn mark for SAR; the plain symbol for everything else. Named
  // `…Html` because it is markup now and must never be escaped again at a call
  // site, nor used anywhere a plain string is wanted.
  const invCurrSym = currencyMarkHtml(invCurrencyCode || settings.currency || 'SAR',
                                      invCurObj.symbol, escapeHtml);

  // Direction follows the current app language, and the primary label (larger,
  // bolder) matches it.
  //
  // Whether there is a SECOND label under it is a decision, not a constant. It
  // used to be unconditional, which meant the hardcoded Arabic half printed on
  // documents in all nine languages — a shop in the US sent customers quotes
  // captioned عرض سعر. lib/invoice-language.js owns the rule, including the part
  // that cannot be overridden: ZATCA Phase 1 requires Arabic on a Saudi tax
  // invoice, so bilingual stays forced there whatever the setting says.
  const isAr = i18n.current === 'ar';
  const docLang = KhaytInvoiceLanguage.resolveDocumentLanguage({
    mode: settings.invoiceBilingual,
    lang: i18n.current,
    secondary: settings.invoiceSecondLang,
    enableZatca: settings.enableZatca,
  });
  // `bi` gates every second-language element below: the hardcoded label halves
  // AND the shop's own secondary name/address/terms. Both answer the same
  // question — "is this a two-language document?" — and gating only the labels
  // would leave an English quote carrying an Arabic address.
  const bi = docLang.bilingual;
  // The shop's OWN second-language content — its name, address, tagline, terms
  // and footer — exists only as an English/Arabic pair in settings. There is no
  // bizFr. So a document whose second language is French can carry French
  // LABELS, which come from the locale files, but has no French shop name to
  // put beside them; printing the Arabic one there would pair French headings
  // with an Arabic address, which is how this looked before the gate existed.
  // Show that block only when the second language is the one those fields hold.
  const biContent = bi
    && docLang.secondary === KhaytInvoiceLanguage.defaultSecondaryFor(i18n.current);
  const dir = isAr ? 'rtl' : 'ltr';
  // Numeral formatting helper — only converts when in Arabic mode with the toggle on
  const num = (v) => (isAr && settings.useArabicNumerals) ? toArabicNumerals(v) : String(v);
  const isPaid = (payStatus(order) === 'paid');

  // Label pairs — (primary, secondary). Primary = working language.
  const isQuoteDoc = order.status === 'quote';
  // The number under "No." — see `documentNumber`. A proforma names the job,
  // never the invoice number a job may already have been given.
  const docNumber = proforma ? String(order.id == null ? '' : order.id) : documentNumber(order, settings);
  // Every printed label, as [primary, secondary].
  //
  // These used to be hardcoded English/Arabic literal pairs, which is why the
  // second language could only ever BE Arabic. They now come out of the locale
  // files like the rest of the app: the primary through t(), the secondary
  // through tIn() against whichever language the shop picked. That is the whole
  // reason for the doc.* vocabulary — a label the second language cannot be
  // looked up in is a label that language cannot print.
  const L2 = (key, vars) => [t(key, vars), bi ? i18n.tIn(docLang.secondary, key, vars) : ""];
  const rate = vatRate || 15;
  // A shop that adds tax on top prints it as a line ADDED to the subtotal, not
  // "(incl.)": the total is price + tax there (`invoiceSummary().addsTax`), and
  // "included" told the customer the opposite of the arithmetic beside it.
  const Tx = global.KhaytTax;
  const taxAdded = !!(Tx && typeof Tx.profileFromSettings === 'function'
    && invoiceSummary(order, Tx.profileFromSettings(settings || {})).addsTax);
  const L = {
    invoice:    L2(proforma ? "inv.proforma_title" : isQuoteDoc ? "doc.quotation" : "doc.invoice"),
    no:         L2("doc.no"),
    date:       L2("doc.date"),
    time:       L2("doc.time"),
    billTo:     L2("doc.bill_to"),
    description:L2("doc.description"),
    qty:        L2("doc.qty"),
    amount:     L2("doc.amount"),
    subtotal:   L2("doc.subtotal"),
    vat:        L2("doc.vat", { rate }),
    totalDue:   L2("doc.total_due"),
    qrLabel:    L2("doc.qr_label"),
    // A sentence, not a label — it is set once in the working language and has
    // no second-language twin on the page.
    legal:      settings.enableZatca
                  ? (isAr ? "فاتورة متوافقة مع المرحلة الأولى من هيئة الزكاة والضريبة والجمارك"
                           : "ZATCA Phase 1 compliant invoice with TLV-encoded QR code.")
                  : (isAr ? `صادرة بواسطة Khayt · ${t("inv.generated_by") || "Professional Invoice"}`
                           : `Generated by Khayt · ${t("inv.generated_by") || "Professional Invoice"}`),
  };

  // Pretty label: primary on top, smaller secondary underneath — or just the
  // primary on a single-language document.
  const pair = (k) => {
    const [p, s] = L[k];
    if (!bi) return escapeHtml(p);
    return `${escapeHtml(p)} <span class="sub${isAr ? ' ltr' : ' rtl'}">${escapeHtml(s)}</span>`;
  };
  /**
   * The secondary half of a label strip — empty on a single-language document.
   * Takes a locale KEY, not a literal: the second language is the shop's choice,
   * so the text has to be looked up rather than written inline.
   */
  const sub = (key) => (bi
    ? `<span class="sub ${isAr ? 'ltr' : 'ar'}">${escapeHtml(i18n.tIn(docLang.secondary, key))}</span>`
    : '');

  /* Bill-to: the CUSTOMER, and this used to be the job.
   *
   * The comment here said "real client name" and the code read `order.project`,
   * which is the free-text field the order editor labels "Description" and the
   * print log labels "Project / Client". So a job linked to a customer printed
   * BILLED TO: Turbine bracket, with that customer's phone and email underneath
   * — their contact details under somebody else's name, on a tax document.
   *
   * The fallback chain keeps every invoice that was already right, right:
   *
   *   1. the linked client's name, read through the content-language rule, so a
   *      shop writing Arabic bills in Arabic rather than in the stale English
   *      left over from setup. Same rule as `localName` in the renderer.
   *   2. `order.project`, which is what a shop that types its customer's name
   *      into that dual-purpose field has always relied on, and is unchanged
   *      for every order with no `clientId` at all.
   *   3. the walk-in label.
   *
   * Nine of the ten invoice fixtures did not move by a single byte.
   */
  const linkedClient = order.clientId ? clients.find(c => c.id === order.clientId) : null;
  const clientName = (linkedClient && typeof KhaytContentLanguages !== 'undefined')
    ? (KhaytContentLanguages.read(linkedClient, 'name', i18n.current, settings) || '').trim()
    : ((linkedClient && linkedClient.name) || '').trim();
  // PAYMENT TERMS (lib/payment-terms.js): a customer on net-30 is handed an
  // invoice that says so, and the day it falls due — counted from the date
  // printed above it, so the two can never disagree on the paper. Nothing is
  // printed for due-on-receipt (the default), nor on a quote, which is not
  // yet an invoice; every existing document stays byte for byte as it was.
  const PT = (typeof global.KhaytPaymentTerms !== 'undefined')
    ? global.KhaytPaymentTerms
    : (function () { try { return require('./payment-terms.js'); } catch (e) { return null; } })();
  const termsDays = (PT && !isQuoteDoc) ? PT.termsDays(linkedClient) : 0;
  const dueOn = termsDays > 0 ? PT.dueDate(order, linkedClient) : '';
  const project = (order.project || '').trim();
  const billToName = clientName || project || t('inv.walk_in');
  const billToSub  = billToName === t('inv.walk_in')
    ? `<div class="name-sub">${t("doc.no_specific_client")}</div>`
    : (linkedClient ? renderClientSub(linkedClient) : '');
  // The job's own name, when the bill-to is now the customer rather than it.
  // Dropping it would take the one line saying WHAT was made off a document
  // whose line items are individual parts.
  const projectRef = (clientName && project && project !== clientName) ? project : '';

  // Lines
  const orderExtraLines = ms ? [] : (order.extraLines || []);
  const orderExtraTotal = orderExtraLines.reduce((s, l) => s + (+l.amount || 0), 0);
  const lines = (order.parts && order.parts.length > 0)
    ? order.parts
    : [{ name: t('inv.services_default'), material: order.material, printTime: order.printTime, baseCost: order.price }];
  // Pool for parts = total price minus shipping minus extra lines (fixed fees)
  // PLUS the discount: the rows are at LIST price, as the Subtotal under them
  // is (`invoiceSummary`), and the Discount row then takes it off. Shared out
  // after the discount, the rows summed to less than the Subtotal printed
  // beneath them on every discounted job. The total, the tax and the QR are
  // all read from the price and do not move.
  const listDiscount = (+order.discountPct || 0) > 0
    ? Math.max(0, (+order.priceBeforeDiscount || 0) * (+order.discountPct || 0) / 100)
    : 0;
  const partsPool = +order.price - (+order.shippingCost || 0) - orderExtraTotal - (+order.rushFeeAmount || 0)
    + listDiscount;
  // A part the customer agreed a price for is billed at THAT figure — it is
  // the one line on the document they can check against what they were told.
  // The rest of the pool is shared among the other parts by cost, as it
  // always was; with no agreed part these two sums are the old ones exactly.
  const isAgreed = (p) => p.agreedPrice !== undefined && p.agreedPrice !== null && p.agreedPrice !== ''
    && Number.isFinite(+p.agreedPrice) && +p.agreedPrice >= 0;
  const agreedLine = (p) => +p.agreedPrice * Math.max(1, +p.qty || 1);
  const costedLines = lines.filter(p => !isAgreed(p));
  const totalBase = costedLines.reduce((s, p) => s + (+p.baseCost || 0), 0);
  const costedPool = partsPool - lines.reduce((s, p) => s + (isAgreed(p) ? agreedLine(p) : 0), 0);
  const msAmount = ms ? (+ms.amount || 0) : 0;
  const msTax = (() => {
    // The same engine, the same profile, applied to the milestone's amount —
    // which is in the job's tax mode, inclusive or exclusive, like its price.
    const T = global.KhaytTax;
    if (T && typeof T.computeTax === 'function' && typeof T.profileFromSettings === 'function') {
      return T.computeTax(msAmount, T.profileFromSettings(settings || {}));
    }
    return { subtotal: msAmount, taxTotal: 0, total: msAmount };
  })();
  const msMeta = ms ? num(t("doc.milestone_of", {
    pct: String(+ms.percentage || 0),
    total: `${fmtMoney(+ms.total || 0)} ${invCurrencyCode || settings.currency || ''}`.trim(),
  })) : '';
  const linesHtml = ms ? `
      <tr>
        <td>
          <div class="desc-en">${escapeHtml(ms.label || '')}</div>
          <div class="meta">${escapeHtml(msMeta)}</div>
        </td>
        <td class="center">${num('1')}</td>
        <td class="amount">${fmtMoney(msAmount)} <span style="color:var(--ink-mute); font-weight:500;">${invCurrSym}</span></td>
      </tr>` : lines.map(p => {
    const share = isAgreed(p) ? agreedLine(p)
      : totalBase > 0 ? (p.baseCost / totalBase) * costedPool : costedPool / costedLines.length;
    const meta = [
      p.material,
      p.printTime ? `${hoursForPrint(p.printTime)} hrs` : '',
      p.printWeight ? `${Math.round(p.printWeight)} g` : '',
      p.layerHeight ? `${p.layerHeight}mm` : '',
      p.infill ? `${p.infill}% infill` : '',
      p.profile || ''
    ].filter(Boolean).join(' · ');
    return `
      <tr>
        <td>
          <div class="desc-en">${escapeHtml(p.name)}</div>
          ${meta ? `<div class="meta">${escapeHtml(meta)}</div>` : ''}
        </td>
        <td class="center">${num(String(p.qty || 1))}</td>
        <td class="amount">${fmtMoney(share)} <span style="color:var(--ink-mute); font-weight:500;">${invCurrSym}</span></td>
      </tr>`;
  }).join('');
  // Extra charge lines
  const extraLinesHtml = orderExtraLines.map(l => `
      <tr>
        <td><div class="desc-en">${escapeHtml(l.label || t('calc.extra_label_ph'))}${
          // A percentage fee says so on the invoice. The money is the frozen
          // `amount` written when the order was logged — an invoice reports what
          // was charged, it does not recompute a percentage months later.
          (+l.pct > 0) ? ` <span style="color:var(--ink-mute);">(${escapeHtml(String(l.pct))}%)</span>` : ''
        }</div></td>
        <td class="center">1</td>
        <td class="amount">${fmtMoney(+l.amount || 0)} <span style="color:var(--ink-mute); font-weight:500;">${invCurrSym}</span></td>
      </tr>`).join('');

  // Compact contact line in the header. Each datum isolated — see `isolate`:
  // every one of these is Latin text with no direction of its own, and in the
  // Arabic document they came out back to front.
  const contactBits = [
    settings.phone, settings.email,
    settings.cr ? `CR ${settings.cr}` : '',
    settings.vat ? `VAT ${settings.vat}` : ''
  ].filter(Boolean).map((bit) => isolate(bit, escapeHtml)).join(' · ');

  /* The shop's own text, in the document's languages.
   *
   * This picked between an Arabic field and an English one and nothing else, so
   * a shop writing Turkish printed an invoice with a BLANK business name — the
   * labels were translated by resolveDocumentLanguage and the shop's own name
   * was not. The document already knows which two languages it is in; these now
   * ask for those.
   */
  const _p = docLang.lang;
  const _s = docLang.secondary;
  /* The second-language line, or nothing when it says what the first does.
   *
   * `shopField` falls back across languages: a shop that filled in only its
   * Arabic name gets that name as the English "primary" too. The secondary
   * line read the Arabic field directly, so the same name printed twice, one
   * under the other — and the same for the tagline, the address, the terms
   * and the footer. A line that repeats the one above it is not a translation. */
  const secondaryOf = (base, primary) => {
    if (!bi) return '';
    const text = settings[KhaytContentLanguages.fieldKey(base, _s)] || '';
    return String(text).trim() && String(text).trim() === String(primary || '').trim() ? '' : text;
  };
  const bizPrimary    = shopField('biz', _p);
  const bizSecondary  = secondaryOf('biz', bizPrimary);
  const addrPrimary   = shopField('addr', _p);
  const addrSecondary = secondaryOf('addr', addrPrimary);

  const taglinePrimary   = shopField('tagline', _p);
  const taglineSecondary = secondaryOf('tagline', taglinePrimary);

  // Brand color: amber for quotes, user-chosen (or default) for invoices
  const invBrand     = isQuoteDoc ? '#92400e' : (safeCssColor(settings.invAccentColor, '#5E2E14'));
  const invAccent    = isQuoteDoc ? '#d97706' : (safeCssColor(settings.invAccentColor, '#B8723D'));
  const invHighlight = isQuoteDoc ? '#fef3c7' : '#fcefdc';

  // Terms / conditions section
  const termsPrimary   = shopField('invTerms', _p);
  const termsSecondary = secondaryOf('invTerms', termsPrimary);
  const footerPrimary   = shopField('footer', _p);
  const footerSecondary = secondaryOf('footer', footerPrimary);
  const termsSectionHtml = termsPrimary.trim() ? `
    <div class="inv-terms">
      <div class="label-strip">
        <span>${escapeHtml(t("doc.terms"))}</span>
        ${sub("doc.terms")}
      </div>
      <p class="inv-terms-body">${escapeHtml(termsPrimary)}</p>
      ${biContent && termsSecondary ? `<p class="inv-terms-body sec">${escapeHtml(termsSecondary)}</p>` : ''}
    </div>` : '';

  // Hijri date — a second rendering of the issue date for an Arabic-reading
  // audience, which is the same job every other secondary element does, so it
  // follows the same gate. (The original note here already called it "always
  // bilingual when toggle is on"; `bi` is now what "bilingual" means.)
  //
  // This is why the toggle alone was not enough: `useHijri` shipped defaulting
  // to true for every shop in the world, so an English quote for a US customer
  // carried a Hijri date nobody had asked for and few would recognise. The
  // default is fixed for new setups, but existing stores already have `true`
  // written into them — gating the row is what actually reaches those shops.
  const hijri = (bi && settings.useHijri) ? hijriDate(issuedOn, 'short') : '';

  // Bank / payment info section — only render if at least one bank field is set
  const hasBank = (settings.bankName || settings.iban || settings.accountHolder);
  const bankSectionHtml = hasBank ? `
    <div class="bank-section">
      <div class="label-strip">
        <span>${escapeHtml(t("doc.payment_info"))}</span>
        ${sub("doc.payment_info")}
      </div>
      <div class="bank-grid">
        ${settings.bankName ? `<span class="k">${escapeHtml(t('inv.bank'))}</span><span class="v">${escapeHtml(settings.bankName)}</span>` : ''}
        ${settings.accountHolder ? `<span class="k">${escapeHtml(t('inv.account'))}</span><span class="v">${escapeHtml(settings.accountHolder)}</span>` : ''}
        ${settings.iban ? `<span class="k">${escapeHtml(t('inv.iban'))}</span><span class="v" style="letter-spacing:0.05em;">${escapeHtml(settings.iban.replace(/(.{4})/g, '$1 ').trim())}</span>` : ''}
      </div>
      ${(settings.acceptedPayments && settings.acceptedPayments.length > 0) ? `
        <div class="accepted-strip">
          <span class="label">${escapeHtml(t('inv.accepted'))}</span>
          <span class="methods">
            ${settings.acceptedPayments.map(m => `<span class="pm-pill ${m}">${escapeHtml(t('pay.method.' + m))}</span>`).join('')}
          </span>
        </div>` : ''}
      ${payQrSvg ? `
        <div class="pay-qr-row">
          <div class="pay-qr-code">${payQrSvg}</div>
          <div class="pay-qr-label">
            <span>${escapeHtml(t("doc.scan_to_pay"))}</span>
            ${sub("doc.scan_to_pay")}
          </div>
        </div>` : ''}
    </div>` : '';

  // "Paid" stamp overlay
  const paidStampHtml = isPaid ? `<div class="paid-stamp">${escapeHtml(t("doc.paid_stamp"))}</div>` : '';

  const invTmpl = ['classic', 'modern', 'minimal'].includes(settings.invTemplate) ? settings.invTemplate : 'classic';
  const html = `
    <div class="inv-wrap inv-tmpl-${invTmpl}">
    <div class="inv-top-bar" style="background:${invBrand};"></div>
    <div class="inv" dir="${dir}" lang="${i18n.current}" style="--brand:${invBrand}; --accent:${invAccent}; --highlight:${invHighlight};${proforma ? ' position:relative;' : ''}">${proforma ? `<div class="proforma-watermark" aria-hidden="true" style="position:absolute; inset:0; display:flex; align-items:center; justify-content:center; pointer-events:none; z-index:0; overflow:hidden;"><span style="transform:rotate(-30deg); font-size:64px; font-weight:800; letter-spacing:4px; color:rgba(0,0,0,0.07); white-space:nowrap;">${escapeHtml(L.invoice[0])}</span></div>` : ''}
      ${paidStampHtml}

      <div class="inv-header">
        <div class="biz">
          <div class="mark">${safeBizLogo() ? `<img src="${attr(safeBizLogo())}" style="max-height:80px; max-width:150px; object-fit:contain;" alt="logo">` : BRAND_MARK_SVG}</div>
          <div class="biz-name">
            <h1>${escapeHtml(bizPrimary || 'Khayt')}</h1>
            ${taglinePrimary ? `<div class="biz-tagline">${escapeHtml(taglinePrimary)}</div>` : ''}
            ${biContent && taglineSecondary ? `<div class="biz-tagline sec ${isAr ? 'ltr' : 'ar'}">${escapeHtml(taglineSecondary)}</div>` : ''}
            ${biContent && bizSecondary ? `<div class="biz-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(bizSecondary)}</div>` : ''}
            <div class="biz-meta">
              ${addrPrimary ? `<p>${escapeHtml(addrPrimary)}</p>` : ''}
              ${biContent && addrSecondary ? `<p class="${isAr ? 'ltr' : 'ar-line ar'}">${escapeHtml(addrSecondary)}</p>` : ''}
              ${contactBits ? `<p>${contactBits}</p>` : ''}
            </div>
          </div>
        </div>

        <div class="doc">
          <div class="title">${escapeHtml(L.invoice[0])}</div>
          ${bi ? `<div class="title-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(L.invoice[1])}</div>` : ''}
          <div class="meta">
            <div class="meta-row">
              <span class="k">${escapeHtml(L.no[0])}</span>
              <span class="v">${escapeHtml(num(docNumber))}</span>
            </div>
            <div class="meta-row">
              <span class="k">${escapeHtml(L.date[0])}</span>
              <span class="v">${escapeHtml(num(issuedDate))}</span>
            </div>${dueOn ? `
            <div class="meta-row">
              <span class="k">${escapeHtml(t("doc.payment_terms"))}</span>
              <span class="v">${escapeHtml(num(t("doc.net_days", { n: termsDays })))}</span>
            </div>
            <div class="meta-row">
              <span class="k">${escapeHtml(t("doc.due_date"))}</span>
              <span class="v">${escapeHtml(num(formatPrintDate(dueOn)))}</span>
            </div>` : ''}
            ${hijri ? `
            <div class="meta-row">
              <span class="k">${escapeHtml(t("doc.hijri"))}</span>
              <span class="v">${escapeHtml(num(hijri))}</span>
            </div>` : ''}
            ${issuedTime ? `
            <div class="meta-row">
              <span class="k">${escapeHtml(L.time[0])}</span>
              <span class="v">${escapeHtml(num(issuedTime))}</span>
            </div>` : ''}${projectRef ? `
            <div class="meta-row">
              <span class="k">${escapeHtml(t("doc.project"))}</span>
              <span class="v">${escapeHtml(projectRef)}</span>
            </div>` : ''}
            ${order.clientRef ? `
            <div class="meta-row">
              <span class="k">${escapeHtml(t("doc.client_ref"))}</span>
              <span class="v">${escapeHtml(order.clientRef)}</span>
            </div>` : ''}
          </div>
        </div>
      </div>

      <div class="bill-to">
        <div class="label">
          <span>${escapeHtml(L.billTo[0])}</span>
          ${sub(L.billTo[1])}
        </div>
        <div>
          <div class="name">${escapeHtml(billToName)}${(() => {
            if (!order.clientId || !settings.loyaltyEnabled) return '';
            const tierObj = clientTier;
            if (!tierObj || !tierObj.name) return '';
            return ` <span style="display:inline-block;background:#D88A3D;color:#fff;font-size:9px;font-weight:700;padding:1px 5px;border-radius:3px;vertical-align:middle;margin-inline-start:4px;">${escapeHtml(tierObj.name)}</span>`;
          })()}</div>
          ${billToSub}
        </div>
      </div>

      <table class="lines">
        <thead>
          <tr>
            <th>${pair('description')}</th>
            <th style="text-align:center; width: 60px;">${pair('qty')}</th>
            <th class="th-amount" style="width: 150px;">${pair('amount')}</th>
          </tr>
        </thead>
        <tbody>${linesHtml}${extraLinesHtml}</tbody>
      </table>

      <div class="totals">
        ${settings.enableZatca && !proforma ? `
        <div class="qr-box">
          <div class="qr-svg">${qrSvg || `<div style="font-size:11px;color:#b91c1c;padding:18px 8px;line-height:1.5;">
            <strong>${escapeHtml(t('inv.qr_not_compliant'))}</strong><br>${escapeHtml(qrProblem || t('inv.qr_failed'))}</div>`}</div>
          <div class="qr-label">
            <span>${escapeHtml(L.qrLabel[0])}</span>
            ${sub(L.qrLabel[1])}
          </div>
        </div>` : ''}
        <div class="summary">
          <div class="row">
            <span class="label-en">${escapeHtml(L.subtotal[0])}</span>
            <span class="v">${ms ? fmtMoney(msAmount) : subtotalShown} ${invCurrSym}</span>
          </div>
          ${!ms && order.discountPct > 0 ? `
          <div class="row" style="color:#22c55e;">
            <span class="label-en">${escapeHtml(isAr ? `خصم (${order.discountPct}%)` : `Discount (${order.discountPct}%)`)}</span>
            <span class="v">−${fmtMoney(Math.max(0, (+order.priceBeforeDiscount || 0) * (+order.discountPct || 0) / 100))} ${invCurrSym}</span>
          </div>` : ''}
          ${!ms && (+order.rushFeeAmount || 0) > 0 ? `
          <div class="row">
            <span class="label-en">${escapeHtml(t("doc.rush_fee"))}</span>
            <span class="v">${fmtMoney(+order.rushFeeAmount)} ${invCurrSym}</span>
          </div>` : ''}
          ${!ms && (+order.shippingCost || 0) > 0 ? `
          <div class="row">
            <span class="label-en">${escapeHtml(t("doc.shipping"))}</span>
            <span class="v">${fmtMoney(+order.shippingCost)} ${invCurrSym}</span>
          </div>` : ''}
          ${vatRate > 0 ? `
          <div class="row">
            <span class="label-en">${escapeHtml(L.vat[0])}${taxAdded ? '' : ` ${t("doc.incl")}`}</span>
            <span class="v">${ms ? fmtMoney(msTax.taxTotal) : vatAmount} ${invCurrSym}</span>
          </div>` : ''}
          <div class="row grand">
            <span>
              <span class="label-en">${escapeHtml(L.totalDue[0])}</span>
              ${bi ? `<span class="label-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(L.totalDue[1])}</span>` : ''}
            </span>
            <span class="v">${ms ? fmtMoney(msTax.total) : total}<span class="unit">${invCurrSym}</span></span>
          </div>
          ${(() => {
            const orderCur = invCurrencyCode;
            const baseCur = settings.currency || 'SAR';
            // The rate the job was SAVED at (lib/order-new.js `fxRate`), not
            // today's from Settings: a reprint must state the same amount the
            // customer was first invoiced. A job with no stored rate has no
            // honest figure in the shop's currency, so the line is left out.
            const xrate = +order.fxRate || 0;
            if (orderCur && orderCur !== baseCur && xrate && xrate > 0) {
              const convertedAmt = fmtMoney((ms ? msAmount : (+order.price || 0)) * xrate);
              const baseSym = currencyMarkHtml(baseCur,
                                (CURRENCIES[baseCur] || CURRENCIES.SAR).symbol, escapeHtml);
              return `<div class="row" style="opacity:0.65;font-size:11px;border-top:1px dashed rgba(0,0,0,0.1);padding-top:4px;margin-top:4px;">
                <span class="label-en">${escapeHtml(isAr ? `المبلغ بـ ${baseCur}` : `Amount in ${baseCur}`)}</span>
                <span class="v">${convertedAmt}<span class="unit">${escapeHtml(baseSym)}</span></span>
              </div>`;
            }
            return '';
          })()}
        </div>
      </div>

      ${bankSectionHtml}

      ${(!ms && order.instalments && order.instalments.length > 0) ? `
      <div class="inv-notes-section" style="margin-top:12px;">
        <div class="label-strip">
          <span>${escapeHtml(t("doc.payment_schedule"))}</span>
          ${sub("doc.payment_schedule")}
        </div>
        <table style="width:100%;border-collapse:collapse;font-size:11.5px;margin-top:4px;">
          <thead><tr style="color:var(--ink-mute);text-align:left;">
            <th style="padding:3px 6px;">#</th>
            <th style="padding:3px 6px;">${escapeHtml(t("doc.due_date"))}</th>
            <th style="padding:3px 6px;text-align:right;">${escapeHtml(t("doc.amount"))}</th>
            <th style="padding:3px 6px;text-align:center;">${escapeHtml(t("doc.status"))}</th>
          </tr></thead>
          <tbody>
            ${order.instalments.map((ins, i) => `
            <tr style="border-top:1px solid rgba(0,0,0,.06);">
              <td style="padding:3px 6px;">${i + 1}</td>
              <td style="padding:3px 6px;">${escapeHtml(ins.dueDate ? formatPrintDate(ins.dueDate) : '—')}</td>
              <td style="padding:3px 6px;text-align:right;">${fmtMoney(+ins.amount || 0)} ${invCurrSym}</td>
              <td style="padding:3px 6px;text-align:center;color:${ins.paid ? 'var(--ink-success,#15803d)' : 'var(--ink-mute)'}">${ins.paid ? (t("doc.paid_check")) : (t("doc.pending"))}</td>
            </tr>`).join('')}
          </tbody>
        </table>
      </div>` : ''}

      ${(order.invoiceNotes || '').trim() ? `
      <div class="inv-notes-section">
        <div class="label-strip">
          <span>${escapeHtml(t("doc.notes"))}</span>
          ${sub("doc.notes")}
        </div>
        <p class="inv-notes-body">${escapeHtml(order.invoiceNotes)}</p>
      </div>` : ''}

      ${termsSectionHtml}

      <div class="footer">
        <div class="thanks">${escapeHtml(footerPrimary || t('inv.thank_you'))}</div>
        ${biContent && footerSecondary ? `<div class="thanks-ar ${isAr ? 'ltr' : 'ar'}">${escapeHtml(footerSecondary)}</div>` : ''}
        <div class="legal">${escapeHtml(L.legal)}</div>
      </div>

    </div>
    </div>`;

  // The Arabic-numeral pass is the ONE thing a string cannot do: it rewrites
  // the text of elements after they are laid out. This says whether it is
  // needed and which elements it touches, and each app does it on its own DOM.
  return { html, arabicNumerals: !!(isAr && settings.useArabicNumerals),
           selector: NUMERAL_SELECTOR };
}
const api = { invoiceHtml, invoiceSummary, contactLine, isolate, documentNumber, duplicateNumbers, NUMERAL_SELECTOR };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytInvoiceDocument = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
