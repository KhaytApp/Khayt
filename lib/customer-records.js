'use strict';
/**
 * What a shop's own storefront may know about its customers: the body of
 * khayt-cloud's `PUT /v1/shops/{id}/customers`.
 *
 * ── A PLAINTEXT COPY, AND ONLY WHEN ASKED ─────────────────────────────────
 *
 * The book is end-to-end encrypted, so the cloud has no customers of its own.
 * This is a copy in the clear that the storefront server reads one email at a
 * time ("your orders", "order again"). OFF by default, and a shop turns it on
 * itself; turning it off deletes the copy (khayt-cloud docs/api-contract.md,
 * "Customer records").
 *
 * `READY` held the switch shut until khaytapp.com/privacy said this copy
 * exists; it does now (https://khaytapp.com/privacy/#customer-records-en and
 * #customer-records-ar, khayt-website #57). The policy names every field below,
 * and test/customer-records.test.js pins the body to that list: a new field
 * here is a change to the published policy first (tell the website lane).
 *
 * ── WHAT GOES, WHAT DOES NOT ──────────────────────────────────────────────
 *
 *   - A customer WITH an email. The storefront looks a record up by the email
 *     a customer has proved, so a record without one could never be shown and
 *     is left here rather than sent.
 *   - A job linked by `clientId`, never by name. Two customers can share a
 *     name, and a false match here is one customer's orders shown to another
 *     (the rule `lib/privacy.js` keeps for the data export).
 *   - Not quotes (nothing was ordered) and not a split job's parent (its
 *     parts are the orders). Not jobs kept out of the business.
 *   - The total the customer PAYS: tax included where the shop adds it on top
 *     (`KhaytOrderMoney.orderGrossRaw`). Never cost, margin, notes or files.
 *   - No addresses: the book keeps none in a shape the route accepts, and a
 *     guessed split of a free-text address is a wrong address.
 *
 * Pure: no clock, no I/O. The caller sends the result and remembers when.
 */
(function (global) {
  const Webstore = global.KhaytWebstoreOrder
    || (typeof require === 'function' ? require('./webstore-order.js') : null);
  const Money = global.KhaytOrderMoney
    || (typeof require === 'function' ? require('./order-money.js') : null);
  // `orderGrossRaw` reads the tax rule off the global; under Node nothing
  // else may have loaded it, and without it every total would leave out tax
  // added on top.
  if (!global.KhaytTax && typeof require === 'function') require('./tax.js');

  /** The privacy policy covers the copy (#customer-records-en/-ar). See the header. */
  const READY = true;

  /** The route's own limits (khayt-cloud CUSTOMERS_MAX and the per-record caps). */
  const LIMITS = { customers: 5000, orders: 100, lines: 50, bytes: 4 * 1024 * 1024 };

  /** A published set this old is deleted by the cloud; refresh well inside it. */
  const REFRESH_HOURS = 24;

  const str = (v) => String(v == null ? '' : v).trim();
  const round2 = (n) => Math.round(n * 100) / 100;
  const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

  /** The switch as the book holds it, and whether this build lets it be on. */
  function enabled(settings) {
    const s = settings && settings.customerRecords;
    return READY && !!(s && s.enabled === true);
  }

  function emailOf(client) {
    const e = str(client && client.email).toLowerCase();
    return e.length <= 254 && EMAIL.test(e) ? e : '';
  }

  function nameOf(client) {
    return str(client && client.nameEn) || str(client && client.nameAr) || str(client && client.name);
  }

  /** Is this job something the customer ordered? */
  function counts(order) {
    if (!order || typeof order !== 'object' || !str(order.id)) return false;
    if (order.status === 'quote' || order.status === 'split') return false;
    if (order.nonBusiness === true) return false;
    return !!str(order.date);
  }

  /** What the customer bought, as the storefront can re-offer it. */
  function linesOf(order) {
    const out = [];
    const product = str(order.productId);
    if (product) {
      // Whole, 1 to 100,000: the cloud stores anything else as 1, so a
      // fraction would arrive as one without anybody being told.
      const qty = Math.round(Number(order.qty));
      out.push({ productId: product, name: str(order.project) || undefined,
        qty: Number.isFinite(qty) ? Math.min(100000, Math.max(1, qty)) : 1 });
    }
    return out.slice(0, LIMITS.lines);
  }

  function orderOf(order, settings) {
    const platform = Webstore ? Webstore.platformOf({ source: order.source, ref: order.sourceOrderId }) : null;
    const ref = platform && str(order.sourceOrderId) ? Webstore.scopedRef(platform, order.sourceOrderId) : undefined;
    const price = Number(order.price);
    const priced = Number.isFinite(price) && price > 0;
    const total = priced
      ? round2(Money && Money.orderGrossRaw ? Money.orderGrossRaw(order, { settings }) : price)
      : undefined;
    const out = {
      orderId: str(order.id),
      at: str(order.date),
      title: str(order.project) || undefined,
      status: Webstore ? Webstore.storeStatusOf(order) : undefined,
    };
    if (ref) out.ref = ref;
    if (total !== undefined) {
      out.total = total;
      const currency = str(order.currency || (settings && settings.currency)).toUpperCase();
      if (/^[A-Z]{3}$/.test(currency)) out.currency = currency;
    }
    const lines = linesOf(order);
    if (lines.length) out.lines = lines;
    return out;
  }

  /**
   * The body to PUT, and what was left out.
   *
   * `{ body: { customers: [...] }, published, withoutEmail, sharedEmail }`.
   * `sharedEmail` counts customers dropped because an earlier one already
   * holds that email — the cloud would keep only one, so it is decided here,
   * where it can be said, and the first in the book wins.
   */
  function build(clients, printLog, settings) {
    const byClient = new Map();
    for (const o of Array.isArray(printLog) ? printLog : []) {
      if (!counts(o)) continue;
      const id = str(o.clientId);
      if (!id) continue;
      if (!byClient.has(id)) byClient.set(id, []);
      byClient.get(id).push(o);
    }
    const seen = new Set();
    const customers = [];
    let withoutEmail = 0, sharedEmail = 0;
    for (const c of Array.isArray(clients) ? clients : []) {
      if (!c || typeof c !== 'object') continue;
      const email = emailOf(c);
      if (!email) { withoutEmail++; continue; }
      if (seen.has(email)) { sharedEmail++; continue; }
      if (customers.length >= LIMITS.customers) break;
      seen.add(email);
      const orders = (byClient.get(str(c.id)) || [])
        .slice()
        .sort((a, b) => str(b.date).localeCompare(str(a.date)))
        .slice(0, LIMITS.orders)
        .map((o) => orderOf(o, settings));
      const record = { email };
      const name = nameOf(c);
      if (name) record.name = name;
      const phone = str(c.phone);
      if (phone) record.phone = phone;
      if (orders.length) record.orders = orders;
      customers.push(record);
    }
    const trimmed = fit(customers, LIMITS.bytes);
    return { body: { customers }, published: customers.length, withoutEmail, sharedEmail, trimmed };
  }

  /** UTF-8 bytes of a string, without TextEncoder (JavaScriptCore has none here). */
  function utf8Bytes(text) {
    let n = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c < 0x80) n += 1;
      else if (c < 0x800) n += 2;
      else if (c >= 0xd800 && c <= 0xdbff) { n += 4; i++; }
      else n += 3;
    }
    return n;
  }

  /**
   * Under the cloud's 4 MB, IN PLACE. Over it, every PUT is a 413 and the set
   * never publishes at all. So the oldest orders go first, each customer
   * keeping fewer (100, 50, 25 … 0), and only then the customers at the end of
   * the book. Returns how many orders and customers were left out.
   */
  function fit(customers, limit) {
    const size = () => utf8Bytes(JSON.stringify({ customers }));
    let orders = 0, people = 0;
    if (size() <= limit) return { orders, people };
    for (let keep = LIMITS.orders / 2; keep >= 1 && size() > limit; keep = Math.floor(keep / 2)) {
      for (const c of customers) {
        if (c.orders && c.orders.length > keep) { orders += c.orders.length - keep; c.orders = c.orders.slice(0, keep); }
      }
    }
    if (size() > limit) {
      for (const c of customers) { if (c.orders) { orders += c.orders.length; delete c.orders; } }
    }
    while (customers.length && size() > limit) { customers.pop(); people++; }
    return { orders, people };
  }

  /**
   * What to send now: a refresh, a delete, or nothing.
   *
   * `on` is `enabled(settings)` — handed in, so the decision can be tested
   * apart from `READY`. `memory` is `{ fingerprint, at }` — the last body this host published and
   * when (ISO), or null. On: send when the set changed, or when the last send
   * is `REFRESH_HOURS` old. Off: delete once, when the memory says something
   * was published. `now` is ISO, handed in.
   */
  function next(on, fingerprint, memory, now) {
    const m = memory && typeof memory === 'object' ? memory : null;
    if (!on) return m && m.fingerprint ? 'delete' : 'none';
    if (!m || m.fingerprint !== fingerprint) return 'put';
    const last = Date.parse(str(m.at));
    const at = Date.parse(str(now));
    if (!Number.isFinite(last) || !Number.isFinite(at)) return 'put';
    return at - last >= REFRESH_HOURS * 3600 * 1000 ? 'put' : 'none';
  }

  const api = { READY, LIMITS, REFRESH_HOURS, enabled, build, next, fit, utf8Bytes };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytCustomerRecords = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
