'use strict';
/**
 * An order that arrives twice from a storefront is one order.
 *
 * Salla and Zid POST a signed webhook when an order is placed, and lan-server
 * turns it into a row in the shop's print log. Each row got a fresh random id —
 * `uniqueLanId('salla')` — and the platform's own order reference was written
 * into the free-text `notes` field. So nothing about the record said which order
 * it was, and two deliveries of the same order made two orders.
 *
 * The only thing standing in the way was `isReplayedWebhook`, an in-memory LRU
 * of recently-seen signatures. Its own comment is honest about the shape of it:
 * "per-process (cleared on restart) and capped in size", with a ten-minute TTL.
 * All three of those are ordinary events rather than edge cases:
 *
 *   - providers RETRY. A delivery that times out or answers non-2xx comes back,
 *     and it comes back byte-identical, which is the only reason the signature
 *     cache works at all when it works.
 *   - Khayt restarts. A shop closes the app at night.
 *   - 500 webhooks evict the entry, or ten minutes pass.
 *
 * Any one of those turns a retry into a duplicate order in the shop's queue —
 * printed twice, or invoiced twice.
 *
 * So the durable answer is the platform's own order id, which is in the payload
 * already and simply was not being kept. The print log is persisted, so a check
 * against it survives everything the signature cache does not. The cache stays:
 * it is a cheap early-out that costs nothing, and it still catches a replay of a
 * payload carrying no id at all.
 *
 * Pure: takes a payload and a print log, returns strings and booleans.
 */
(function (global) {
  const str = (v) => String(v == null ? '' : v).trim();

  /**
   * Where each platform puts its own order id.
   *
   * Deliberately the SAME field the notes line already quoted, so an order
   * recorded before this existed can still be recognised — see recordedNoteRef.
   */
  function sourceOrderIdFrom(source, payload) {
    const p = payload || {};
    if (source === 'salla') return str(p.data && p.data.reference_id);
    if (source === 'zid') {
      // The wrapper is accepted, not assumed — see orderObject below.
      const o = (p.order && typeof p.order === 'object') ? p.order : p;
      return str(o.reference_id) || str(o.code) || str(o.id);
    }
    return '';
  }

  /** The `notes` line lan-server writes, so the two cannot drift apart. */
  function noteFor(source, sourceOrderId) {
    const label = source === 'zid' ? 'Zid' : 'Salla';
    return `${label} order #${str(sourceOrderId).slice(0, 100)}`;
  }

  /**
   * Pull an order reference back out of a note written before `sourceOrderId`
   * was recorded as a field.
   *
   * A migration aid, and bounded: the string being parsed is one Khayt wrote
   * itself, in a format defined immediately above. Without it the fix protects
   * only orders that arrive from now on, and a shop's existing queue — which is
   * exactly where a duplicate is most annoying — would keep collecting them.
   */
  function recordedNoteRef(entry) {
    const m = /^(?:Salla|Zid) order #(.+)$/.exec(str(entry && entry.notes));
    return m ? str(m[1]) : '';
  }

  /**
   * Has this exact platform order already been written down?
   *
   * An EMPTY id is never a match. Two payloads that both failed to name
   * themselves are not thereby the same order, and treating them as one would
   * silently drop a real second order — a worse failure than the duplicate this
   * is here to prevent, because nothing about it is visible.
   */
  function alreadyRecorded(printLog, source, sourceOrderId) {
    const id = str(sourceOrderId);
    if (!id) return false;
    const src = str(source);
    return (Array.isArray(printLog) ? printLog : []).some((e) => {
      if (!e || str(e.source) !== src) return false;
      const known = str(e.sourceOrderId) || recordedNoteRef(e);
      return !!known && known === id;
    });
  }

  /**
   * The order object, wherever this platform puts it.
   *
   * Salla wraps it: `{event, merchant, created_at, data:{…}}` — confirmed
   * against Salla's own published webhook sample. Zid was read as
   * `{order:{…}}`, and this audit could NOT confirm that: Zid renders its
   * webhook schema through a documentation component that does not come out as
   * text, and its sample apps do not carry a payload fixture.
   *
   * So the wrapper is accepted rather than assumed — if `order` is there it is
   * used, and if the order was posted at the top level instead, the same fields
   * are found anyway. That is the shape the Repetier work settled into for the
   * same reason: with no way to test, accept every attested shape rather than
   * betting on one and reporting nothing when the bet is wrong.
   */
  function orderObject(source, payload) {
    const p = payload || {};
    if (source === 'salla') return (p.data && typeof p.data === 'object') ? p.data : {};
    if (source === 'zid') {
      if (p.order && typeof p.order === 'object') return p.order;
      // No wrapper: treat the body itself as the order, but only if it looks
      // like one. Otherwise an unrelated payload would donate stray fields.
      return (p.id || p.reference_id || p.code || p.total || p.order_total) ? p : {};
    }
    return {};
  }

  /**
   * A money figure, whether the platform sends a number or an object.
   *
   * THIS IS THE ONE THAT COST REAL MONEY. The Salla import read
   * `data.total` — a field that does not exist anywhere in Salla's payload.
   * `Number(undefined)` is `NaN`, `isFinite(NaN)` is false, and the guard then
   * substituted **0**. So every Salla order Khayt ever imported was written
   * into the shop's print log priced at zero, and nothing anywhere threw.
   *
   * A guard that turns "I could not read this" into "it is free" is worse than
   * no guard: 0 is a number a shop can act on, and it is in the column the
   * whole business is measured in.
   *
   * The real field is `amounts.total.amount`, an object — which is also why the
   * bare `Number()` could never have worked even against the right key. Both
   * shapes are read here, because a platform sending a plain number is equally
   * ordinary.
   *
   * Returns null, never 0, when there is nothing to read. The caller decides
   * what to do with "unknown"; this refuses to invent it.
   */
  function money(v) {
    if (v === null || v === undefined || v === '') return null;
    const raw = (typeof v === 'object') ? (v.amount ?? v.value ?? v.total) : v;
    if (raw === null || raw === undefined || raw === '') return null;
    const n = Number(raw);
    return Number.isFinite(n) && n >= 0 ? n : null;
  }

  /**
   * What the shop's queue should say about this order.
   *
   * Salla's `data` has no `name` either — its keys are id, reference_id, urls,
   * date, draft, read, source, source_device, source_details, status,
   * receipt_image, payment_method, currency, amounts, shipping, items,
   * customer. So `data.name || 'Order'` was always "Order", and every Salla
   * order in the queue was titled `Salla: Order`, indistinguishable from every
   * other one. The first item's name is what a shop would call the job; the
   * order reference is the fallback, because a number identifies it and the
   * word "Order" does not.
   */
  function orderTitleFrom(source, payload) {
    const o = orderObject(source, payload);
    const items = Array.isArray(o.items) ? o.items : [];
    const firstNamed = items.find((it) => it && str(it.name));
    if (firstNamed) {
      const extra = items.length - 1;
      const name = str(firstNamed.name).slice(0, 100);
      return extra > 0 ? `${name} +${extra}` : name;
    }
    const named = str(o.name);
    if (named) return named.slice(0, 100);
    const ref = sourceOrderIdFrom(source, payload);
    return ref ? `#${ref.slice(0, 100)}` : 'Order';
  }

  /** The customer's name, per platform. */
  function customerNameFrom(source, payload) {
    const o = orderObject(source, payload);
    const c = (o.customer && typeof o.customer === 'object') ? o.customer : {};
    const joined = [str(c.first_name), str(c.last_name)].filter(Boolean).join(' ');
    return (joined || str(c.name) || str(o.customer_name) || '').slice(0, 200);
  }

  /**
   * The order total, or null when the platform did not say.
   *
   * Salla's own field is checked first and by name. The rest are the spellings
   * a storefront plausibly uses, tried in order — only one is ever present, so
   * this cannot pick the wrong one out of two that both exist.
   */
  function orderPriceFrom(source, payload) {
    const o = orderObject(source, payload);
    const amounts = (o.amounts && typeof o.amounts === 'object') ? o.amounts : {};
    const candidates = [amounts.total, o.order_total, o.total, o.total_price, o.grand_total];
    for (const c of candidates) {
      const n = money(c);
      if (n !== null) return n;
    }
    return null;
  }

  const api = {
    sourceOrderIdFrom, alreadyRecorded, noteFor, recordedNoteRef,
    orderObject, orderTitleFrom, customerNameFrom, orderPriceFrom, money,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytStorefrontOrders = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
