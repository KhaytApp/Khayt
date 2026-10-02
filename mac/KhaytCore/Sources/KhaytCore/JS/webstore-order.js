'use strict';
/**
 * A web-store order, both ways: in as a job, and back out as where it has got to.
 *
 * ── THE LOOP THIS CLOSES ──────────────────────────────────────────────────
 *
 * The shop sells on a storefront (athartuwaiq3d.com, a Medusa store). Each
 * placed order is POSTed to khayt-cloud's `/import/{platform}` and filed in the
 * shop's intake queue. Until this, a person had to open Online orders and press
 * a button for every one — and nothing ever went back: the customer who paid
 * online was told nothing by the store about printing, the parcel or the
 * tracking number, because the store never heard.
 *
 * This module is the RULE for both halves. The Mac (and any other host) owns
 * the network and the write chain; what is decided here is:
 *
 *   - `decide`       — may this queue item become a job without anyone asking?
 *   - `paidState`    — has the customer paid?
 *   - `customerFor`  — which customer in the book is this, or who to create.
 *   - `statusFor`    — what the store should be told about a job, if anything.
 *   - `pending`      — which of those have not been told yet.
 *   - `linePrices`   — what each line of the order sells for, and the total.
 *   - `paidTotal`    — what the platform says the customer paid, if it said.
 *
 * Pure: no clock, no randomness, no I/O. The caller hands in the book and the
 * memory of what it already sent.
 */
(function (global) {
  const Carriers = global.KhaytCarriers
    || (typeof require === 'function' ? require('./carriers.js') : null);

  const str = (v) => String(v == null ? '' : v).trim();
  const lower = (v) => str(v).toLowerCase();

  /**
   * The storefronts khayt-cloud's `mapPlatformOrder` has a branch for — the
   * `source` it files an import under. `generic` is left out on purpose: a
   * generic POST can be anybody's form, and a form is a request, not a sale.
   */
  const PLATFORMS = ['shopify', 'woocommerce', 'etsy', 'salla', 'zid', 'medusa',
    'shopware', 'prestashop', 'base'];

  /**
   * Platforms whose order only EXISTS once the customer has paid.
   *
   * Medusa emits `order.placed` when a cart is completed, and a cart completes
   * only after its payment session is authorised — the subscriber Khayt hands a
   * shop (`lib/medusa-subscriber.js`) listens to exactly that event. The Athar
   * Tuwaiq store takes cards through Tap and nothing else, so an order that
   * reaches the queue from it has been paid for.
   *
   * Salla and Zid are NOT here: both take cash on delivery, and their order
   * webhook fires for an order nobody has paid for yet.
   */
  const PAID_WHEN_PLACED = ['medusa'];

  /** Payment words, as the platforms spell them, that mean the money is in. */
  const PAID = new Set(['paid', 'captured', 'authorized', 'authorised', 'completed',
    'succeeded', 'success']);
  /** …and the ones that mean it is not, or has gone back. */
  const UNPAID = new Set(['unpaid', 'not_paid', 'awaiting', 'pending', 'requires_action',
    'failed', 'canceled', 'cancelled', 'voided', 'refunded', 'partially_refunded']);

  /** Which storefront a queue item came from, or ''. */
  function platformOf(payload) {
    const p = payload || {};
    const source = lower(p.source);
    if (PLATFORMS.includes(source)) return source;
    // The cloud scopes a reference by platform (`medusa:#1042`), so an item
    // whose `source` was lost still says where it came from.
    const scoped = /^([a-z]+):/.exec(str(p.ref));
    return scoped && PLATFORMS.includes(scoped[1]) ? scoped[1] : '';
  }

  /**
   * Has the customer paid? `'paid'`, `'unpaid'` or `'unknown'`.
   *
   * An explicit answer in the payload wins: `paid` as a boolean, or the
   * platform's own `paymentStatus`. Only when the payload says nothing does
   * the platform decide — and only a platform that cannot place an unpaid
   * order (see PAID_WHEN_PLACED) turns "nothing said" into "paid".
   */
  function paidState(payload) {
    const p = payload || {};
    if (typeof p.paid === 'boolean') return p.paid ? 'paid' : 'unpaid';
    const said = lower(p.paymentStatus || p.payment_status);
    if (PAID.has(said)) return 'paid';
    if (UNPAID.has(said)) return 'unpaid';
    return PAID_WHEN_PLACED.includes(platformOf(p)) ? 'paid' : 'unknown';
  }

  /**
   * May this queue item become a job with nobody pressing a button?
   *
   * Returns `{ auto, platform, paid, reason }`:
   *
   *   - `hand_request`    — not from a storefront: a customer's typed request is
   *                         a quote to price, never a job made on its own.
   *   - `no_reference`    — a storefront order with no id of its own. Without
   *                         one nothing can tell a retry from a second order,
   *                         so it waits for a person.
   *   - `unpaid`          — the store says it has not been paid.
   *   - `payment_unknown` — the store did not say, and the platform can place
   *                         an unpaid order.
   *   - `ok`              — a paid web-store order: make the job.
   */
  function decide(payload) {
    const p = payload || {};
    const platform = platformOf(p);
    const paid = paidState(p);
    const out = (reason) => ({ auto: reason === 'ok', platform, paid: paid === 'paid', reason });
    if (!platform) return out('hand_request');
    if (!str(p.ref)) return out('no_reference');
    if (paid === 'unpaid') return out('unpaid');
    if (paid === 'unknown') return out('payment_unknown');
    return out('ok');
  }

  /** Arabic letters in a name decide which of the two name fields it goes in. */
  const ARABIC = /[؀-ۿݐ-ݿࢠ-ࣿ]/;

  /** An email and a phone out of whatever the queue item carries. */
  function contactOf(payload) {
    const p = payload || {};
    let email = str(p.email);
    let phone = str(p.phone);
    const contact = str(p.contact);
    if (contact) {
      if (contact.includes('@')) { if (!email) email = contact; }
      else if (!phone) phone = contact;
    }
    return { email: email.toLowerCase(), phone };
  }

  /**
   * A phone number as something to compare.
   *
   * Digits only, Arabic-Indic folded, and the LAST NINE kept: `+966 50 123
   * 4567`, `0501234567` and `966501234567` are one Saudi mobile written three
   * ways. Fewer than seven digits is not a number anybody can be found by.
   */
  function phoneKey(v) {
    const digits = str(v)
      .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
      .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06F0))
      .replace(/\D/g, '');
    if (digits.length < 7) return '';
    return digits.slice(-9);
  }

  /**
   * Which customer this order belongs to.
   *
   * The desktop's Order requests screen has always done this
   * (`clientFromIntake`): the same email, or the same phone, is the same
   * customer; anyone else is a new one, filed with `source: 'online'`. The
   * phone is compared by `phoneKey` rather than as typed, so a returning
   * customer who wrote `05…` the second time is not made twice.
   *
   * A NAME ALONE NEVER MATCHES. Two customers called Mohammed are two
   * customers, and putting one's order on the other's account is a worse
   * mistake than a duplicate a shop can merge.
   *
   * Returns `{ clientId, name, matched, create }`:
   *   - an existing customer: `clientId` set, `matched` 'email' or 'phone',
   *     `create` null;
   *   - a new one: `clientId` null, `create` the record to add (the caller
   *     gives it an id and a date);
   *   - nothing to go on at all: null.
   */
  function customerFor(payload, clients) {
    const p = payload || {};
    const { email, phone } = contactOf(p);
    const name = str(p.name).slice(0, 200);
    const rows = Array.isArray(clients) ? clients : [];
    const nameOf = (c) => str(c.nameEn) || str(c.nameAr) || str(c.name) || name;

    if (email) {
      const hit = rows.find((c) => c && c.id && lower(c.email) === email);
      if (hit) return { clientId: str(hit.id), name: nameOf(hit), matched: 'email', create: null };
    }
    const key = phoneKey(phone);
    if (key) {
      const hit = rows.find((c) => c && c.id && phoneKey(c.phone) === key);
      if (hit) return { clientId: str(hit.id), name: nameOf(hit), matched: 'phone', create: null };
    }
    if (!name && !email && !phone) return null;

    // Somebody has to be called something — Khayt's own rule is that a
    // customer has a name — and the address they wrote is what the shop
    // would recognise them by.
    const called = name || email || phone;
    const arabic = ARABIC.test(called);
    return {
      clientId: null,
      name: called,
      matched: null,
      create: {
        nameEn: arabic ? '' : called,
        nameAr: arabic ? called : '',
        email,
        phone,
        source: 'online',
      },
    };
  }

  // ── Back out: where the job has got to ─────────────────────────────────

  /**
   * The status a customer's store understands, from a job's status and stamps.
   *
   * Six words, not Khayt's ten. A storefront has no use for `qc` or `post` —
   * to the customer the piece is still being made — and a word it does not
   * know is a word it shows raw. Shipped and delivered are STAMPS on a job
   * that stays `completed` (see `KhaytOrderStatus.stageOf`), so they are read
   * from `shippedAt` and `deliveredAt`, never from the status.
   */
  function storeStatusOf(order) {
    const status = str(order && order.status);
    if (status === 'cancelled') return 'cancelled';
    if (status === 'completed' || status === 'delivered') {
      if (status === 'delivered' || order.deliveredAt) return 'delivered';
      if (order.shippedAt) return 'shipped';
      return 'ready';
    }
    if (['printing', 'post', 'qc', 'paused'].includes(status)) return 'printing';
    return 'received';
  }

  /** The platform-scoped reference the cloud filed the order under. */
  function scopedRef(platform, ref) {
    const r = str(ref);
    if (!r) return '';
    return r.startsWith(platform + ':') ? r : `${platform}:${r}`;
  }

  /** The latest ISO moment the job records, so the store can order two updates. */
  function lastMoment(order) {
    const at = [];
    for (const h of Array.isArray(order.statusHistory) ? order.statusHistory : []) {
      if (h && h.at) at.push(str(h.at));
    }
    for (const h of Array.isArray(order.shippingHistory) ? order.shippingHistory : []) {
      if (h && h.at) at.push(str(h.at));
    }
    for (const k of ['deliveredAt', 'shippedAt', 'completedAt', 'timestamp']) {
      if (order[k]) at.push(str(order[k]));
    }
    // ISO strings compare as text; a bare day sorts before any moment in it.
    return at.filter(Boolean).sort().pop() || '';
  }

  /**
   * What the store should be told about this job, or null when it is not a
   * web-store order.
   *
   * `{ ref, platform, jobId, status, trackingNumber, carrier, carrierName,
   * trackingUrl, shippedAt, deliveredAt, updatedAt }` — the body
   * docs/handoffs/webstore-order-status.md specifies. A STATE, not an event:
   * sending it twice says the same thing twice, which is what makes a resend
   * after a lost answer harmless.
   *
   * Nothing a customer should not see: no price, no cost, no notes, no
   * customer details. The store already has those; what it lacks is progress.
   */
  function statusFor(order) {
    if (!order || typeof order !== 'object') return null;
    const platform = platformOf({ source: order.source, ref: order.sourceOrderId });
    if (!platform || !str(order.sourceOrderId)) return null;
    const shipping = Carriers && Carriers.projectShipping ? Carriers.projectShipping(order) : null;
    const status = storeStatusOf(order);
    const shipped = status === 'shipped' || status === 'delivered';
    const label = shipping && shipping.carrierLabel;
    return {
      ref: scopedRef(platform, order.sourceOrderId),
      platform,
      jobId: str(order.id),
      status,
      trackingNumber: shipped ? (str(order.trackingNumber) || null) : null,
      carrier: shipped ? (str(order.carrier) || null) : null,
      carrierName: shipped ? (str(label && (label.en || label.ar)) || str(order.courierName) || null) : null,
      trackingUrl: shipped ? ((shipping && shipping.trackingUrl) || null) : null,
      shippedAt: str(order.shippedAt) || null,
      deliveredAt: str(order.deliveredAt) || null,
      updatedAt: lastMoment(order) || null,
    };
  }

  /** What makes two updates the same update. The moment is not part of it. */
  function fingerprint(update) {
    if (!update) return '';
    return [update.status, update.trackingNumber || '', update.carrier || ''].join('|');
  }

  /**
   * The updates the store has not been told, oldest change first.
   *
   * `sent` is `{ ref: fingerprint }` — what this host last delivered. A job
   * whose update matches is skipped; everything else is owed.
   *
   * `opts.notBefore` (ISO) leaves out FINISHED business older than it: a job
   * delivered last year is not news, and a host that lost its memory would
   * otherwise resend the shop's whole history. Unfinished work is always
   * owed, however old. `opts.max` caps one batch (default 100).
   */
  function pending(printLog, sent, opts) {
    const o = opts || {};
    const memory = sent && typeof sent === 'object' ? sent : {};
    const notBefore = str(o.notBefore);
    const max = Number.isFinite(o.max) && o.max > 0 ? Math.floor(o.max) : 100;
    const out = [];
    for (const order of Array.isArray(printLog) ? printLog : []) {
      const update = statusFor(order);
      if (!update) continue;
      if (memory[update.ref] === fingerprint(update)) continue;
      const finished = ['delivered', 'cancelled'].includes(update.status);
      if (finished && notBefore && (update.updatedAt || '') < notBefore) continue;
      out.push(update);
    }
    out.sort((a, b) => (a.updatedAt || '').localeCompare(b.updatedAt || ''));
    return out.slice(0, max);
  }

  // ── WHAT THE ORDER COMES TO ─────────────────────────────────────────────

  /** A money figure, or null — never 0 for "not said". */
  const moneyOf = (v) => {
    if (v === null || v === undefined || (typeof v === 'string' && v.trim() === '')) return null;
    const n = Number(v);
    return Number.isFinite(n) && n >= 0 ? n : null;
  };
  const round2 = (n) => Math.round(n * 100) / 100;

  /** `lib/storefront-catalog.js`, however this file was loaded. */
  function catalogApi() {
    if (global.KhaytStorefrontCatalog) return global.KhaytStorefrontCatalog;
    try { return require('./storefront-catalog.js'); } catch (e) { return null; }
  }

  /**
   * Each line of an online order at the price the shop SELLS it for, and the
   * job's total as their sum.
   *
   * ── WHY PER LINE ─────────────────────────────────────────────────────────
   *
   * The Mac priced a web-store order by handing the whole basket to the job
   * calculator with ONE product's rule: the parts were multiplied by the
   * quantity, but a product with a typed price brought that price in as the
   * job's total — so three of a 50 product became a job of 50, recorded as
   * paid 50. And a basket of two products lost both typed prices and was
   * priced at the first product's margin. Neither is what the storefront
   * charged.
   *
   * A line is priced, in order:
   *
   *   published  what the catalogue PUBLISHED for it — the storefront's own
   *              price, else the product's price, else its base price
   *              (`KhaytStorefrontCatalog.publishedPrice`, the rule `build`
   *              publishes with). This is the figure the customer was shown.
   *   typed      the product's own `priceOverride`, for a product the
   *              catalogue has no price for.
   *   computed   `ctx.computed[productId]` — what the host's own price rule
   *              makes it (the Mac's catalogue row `final`), for a product
   *              priced by its parts and margin and never published.
   *   none       a line naming nothing this shop sells, or a product nothing
   *              can price. It is 0 because it genuinely is not priced yet.
   *
   * × the line's quantity, every time.
   *
   * `lines`: `[{ productId?, qty }]` — the shelf reading's lines will do.
   * `ctx`: `{ products, settings, computed }`.
   * Returns `{ lines: [{ productId, qty, unit, total, source }], total, priced }`
   * — `priced` is false when no line found a price at all.
   */
  function linePrices(lines, ctx) {
    const c = ctx || {};
    const products = Array.isArray(c.products) ? c.products : [];
    const settings = c.settings || {};
    const computed = (c.computed && typeof c.computed === 'object') ? c.computed : {};
    const Cat = catalogApi();
    const out = [];
    let total = 0;
    let priced = false;
    for (const line of Array.isArray(lines) ? lines : []) {
      if (!line) continue;
      const qty = Math.max(1, Math.round(Number(line.qty) || 1));
      const productId = str(line.productId) || null;
      const product = productId ? products.find((p) => p && str(p.id) === productId) : null;
      let unit = null;
      let source = 'none';
      if (product) {
        const published = Cat && typeof Cat.publishedPrice === 'function'
          ? moneyOf(Cat.publishedPrice(product, settings)) : null;
        const typed = moneyOf(product.priceOverride);
        const made = moneyOf(computed[productId]);
        if (published !== null) { unit = published; source = 'published'; }
        else if (typed !== null) { unit = typed; source = 'typed'; }
        else if (made !== null) { unit = made; source = 'computed'; }
      }
      const lineTotal = unit === null ? 0 : round2(unit * qty);
      if (unit !== null) priced = true;
      total += lineTotal;
      out.push({ productId, qty, unit, total: lineTotal, source });
    }
    return { lines: out, total: round2(total), priced };
  }

  /**
   * What the platform says the customer paid, or null when it did not say.
   *
   * khayt-cloud carries a line's `unitPrice` from a KEYED import only
   * (docs/api-contract.md, "Intake fields") — an open form cannot name a price.
   * The total is the sum of `unitPrice × qty`, and only when EVERY line carries
   * one: a basket half of whose lines are unpriced has not told us its total,
   * and a partial sum recorded as "paid" would leave a balance that is not owed.
   * A payload `paidTotal`, should the cloud ever send one, wins.
   *
   * `ctx` is optional and carries the shop's `settings`. A line's `unitPrice`
   * is the catalogue's price, and on a shop that ADDS TAX ON TOP that is the
   * pre-tax figure: the customer paid it plus the tax. Summed bare, a paid
   * order was recorded short by exactly the tax and could never settle. Given
   * the settings, the line total is grossed up the way `orderGrossRaw` grosses
   * up a job's price; an inclusive or untaxed shop is unchanged, and so is an
   * explicit `paidTotal`, which is already the money that moved.
   */
  function paidTotal(payload, ctx) {
    const p = payload || {};
    const said = moneyOf(p.paidTotal);
    if (said !== null) return said;
    const lines = Array.isArray(p.lines) ? p.lines.filter((l) => l && typeof l === 'object') : [];
    if (!lines.length) return null;
    let sum = 0;
    for (const l of lines) {
      const unit = moneyOf(l.unitPrice);
      if (unit === null) return null;
      const q = Math.round(Number(l.qty != null ? l.qty : l.quantity));
      sum += unit * (Number.isFinite(q) && q > 0 ? q : 1);
    }
    sum = round2(sum);
    const Money = global.KhaytOrderMoney
      || (typeof require === 'function' ? require('./order-money.js') : null);
    if (ctx && ctx.settings && Money && typeof Money.orderGrossRaw === 'function') {
      return round2(Money.orderGrossRaw({ price: sum }, { settings: ctx.settings }));
    }
    return sum;
  }

  const api = {
    PLATFORMS, PAID_WHEN_PLACED,
    platformOf, paidState, decide, contactOf, phoneKey, customerFor,
    storeStatusOf, scopedRef, statusFor, fingerprint, pending,
    linePrices, paidTotal,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytWebstoreOrder = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
