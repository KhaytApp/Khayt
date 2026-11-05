'use strict';
/**
 * What Khayt says to Tabby and Tamara, and what it makes of their answers
 * (KhaytBnplRequests).
 *
 * ── WHY THIS IS ITS OWN FILE ──────────────────────────────────────────────
 *
 * These requests were written inline in lib/main/payment-links.js, inside
 * Electron IPC handlers that also did the fetching. The native Mac app needs
 * the very same requests — the same body, the same host, the same reading of
 * the status — and a Swift copy of them would be a second definition of what
 * "authorised" means that agrees with this one until somebody edits either.
 * So the requests are here, pure, and each host only carries them.
 *
 * ── THE SHAPE ─────────────────────────────────────────────────────────────
 *
 * One function, `plan(flow, args, replies)`. A host calls it with the replies
 * it has had so far (none, to begin) and gets back either
 *
 *   { request: { method, url, body?, timeoutMs } }   send this, then ask again
 *   { result: {...} }                                 the flow is over
 *
 * A reply is `{ ok, status, data }` — `data` is the parsed JSON body, or {}
 * when it was not JSON. The host attaches `Authorization: Bearer <key>` and
 * `Content-Type: application/json` to every request, resolves the key from
 * the book itself (never from what a window sent), and answers a thrown
 * network error with `{ ok: false, error }` of its own. When the first plan
 * is a request rather than a result, the host checks it HAS a key before
 * sending it — the validation below comes first, as it always did.
 *
 * Flows:
 *   'checkout'  args { provider: 'tabby'|'tamara', amount, currency, description,
 *                      buyer: {name, phone, email}, orderId, itemName,
 *                      merchantCode (Tabby), country (Tamara) }
 *               → { ok, url, checkoutId, paymentId (Tabby) | orderId (Tamara) }
 *   'check'     args { provider, id, currency }  — lib/bnpl-confirm.js nextStep,
 *               then Tamara's authorise or Tabby's capture when one is due
 *               → { ok, state: 'open'|'paid'|'closed', remoteStatus, step? }
 *   'capture'   args { provider: 'tamara', id, shipping } — Tamara's capture,
 *               once the job has gone out
 *               → { ok, captured, remoteStatus }
 *
 * And `checkoutArgs(order, provider, ctx)` — what a checkout for a job asks
 * for, which both apps' "pay later" buttons build their 'checkout' from.
 *
 * Pure: no network, no store, no clock.
 */
(function (global) {
  // The status rules and Tabby's host (lib/bnpl-confirm.js): on the global where a
  // page or the Mac's engine loaded it, else required — loaded by the Mac first.
  const rules = () => (global && global.KhaytBnplConfirm)
    || (typeof require === 'function' ? require('./bnpl-confirm.js') : null);

  const TAMARA = 'https://api.tamara.co';
  const CHECKOUT_MS = 10000;
  const CALL_MS = 15000;
  const SAFE_ID = /^[A-Za-z0-9-]{8,64}$/;
  const fixed2 = (v) => (+v || 0).toFixed(2);
  const clip = (v, n) => String(v || '').trim().slice(0, n);

  // The money rules (lib/order-money.js) and the document number
  // (lib/invoice-document.js), found the same way.
  const money = () => (global && global.KhaytOrderMoney)
    || (typeof require === 'function' ? require('./order-money.js') : null);
  const docs = () => (global && global.KhaytInvoiceDocument)
    || (typeof require === 'function' ? require('./invoice-document.js') : null);

  // ── what a checkout for a job asks for ──────────────────────────────────

  /**
   * The 'checkout' arguments for one job, or `{ refused: 'nothing_owed' }`.
   *
   * THE AMOUNT IS WHAT IS STILL OWED — `KhaytOrderMoney.orderOwedRaw`, the
   * rule the invoice's balance line and a payment plan read: the bill (price +
   * tax for a shop that adds tax on top) less what was paid, gift cards and
   * credit notes. It used to be `order.price`: a link for a job with a deposit
   * asked the customer for the whole price again, and one for a tax-on-top
   * shop asked for less than the bill. A link for a job already settled is
   * refused rather than made for nothing.
   *
   * ctx: { settings, clients, buyerName } — `buyerName` is the customer's name
   * in the shop's language as the host reads it (`localName`); without a
   * customer record the name typed on the job is used.
   */
  function checkoutArgs(order, provider, ctx) {
    const o = order || {};
    const c = ctx || {};
    const settings = c.settings || {};
    if (provider !== 'tabby' && provider !== 'tamara') return { refused: 'unknown_provider' };
    const M = money();
    const owed = Math.round((M ? M.orderOwedRaw(o, { settings }) : 0) * 100) / 100;
    if (!(owed > 0)) return { refused: 'nothing_owed' };
    const cfg = ((settings.bnpl || {})[provider]) || {};
    const client = o.clientId ? (c.clients || []).find((x) => x && x.id === o.clientId) : null;
    const ref = String((typeof o.jobNumber === 'string' && o.jobNumber) || o.id || '');
    const label = o.project || ref;
    const D = docs();
    const args = {
      provider,
      amount: owed,
      currency: cfg.currency || 'SAR',
      description: label,
      buyer: {
        name: client ? String(c.buyerName || '') : String(o.client || ''),
        phone: (client && client.phone) || '',
        email: (client && client.email) || '',
      },
      orderId: D ? D.documentNumber(o, settings) : ref,
      itemName: label,
    };
    if (provider === 'tabby') args.merchantCode = cfg.merchantCode;
    if (provider === 'tamara') args.country = cfg.country || 'SA';
    return args;
  }

  // ── checkout ────────────────────────────────────────────────────────────

  function tabbyCheckout(a) {
    const buyer = a.buyer || {};
    const amount = fixed2(a.amount);
    return {
      method: 'POST',
      // A Saudi merchant's key belongs on api.tabby.sa (KhaytBnplConfirm.tabbyBase).
      url: `${rules().tabbyBase(a.currency || 'SAR')}/checkout`,
      timeoutMs: CHECKOUT_MS,
      body: {
        payment: {
          amount,
          currency: a.currency || 'SAR',
          description: String(a.description || ''),
          buyer: {
            phone: String(buyer.phone || ''),
            name: String(buyer.name || ''),
            email: String(buyer.email || ''),
          },
          buyer_history: { registered_since: '2024-01-01T00:00:00Z', loyalty_level: 0 },
          order: {
            reference_id: String(a.orderId || ''),
            items: [{ title: String(a.itemName || a.description || ''), unit_price: amount, qty: 1, category: '3D Printing', reference_id: String(a.orderId || '') }],
            tax_amount: '0.00', shipping_amount: '0.00',
          },
          meta: { order_id: String(a.orderId || ''), customer: String(buyer.name || '') },
        },
        lang: 'en',
        merchant_code: String(a.merchantCode || ''),
        merchant_urls: {
          success: 'https://khaytapp.com/success',
          cancel: 'https://khaytapp.com/cancel',
          failure: 'https://khaytapp.com/failure',
        },
      },
    };
  }

  function tamaraCheckout(a) {
    const buyer = a.buyer || {};
    const cur = (a.currency || 'SAR').toUpperCase();
    const amount = fixed2(a.amount);
    const name = String(buyer.name || '');
    return {
      method: 'POST',
      url: `${TAMARA}/checkout`,
      timeoutMs: CHECKOUT_MS,
      body: {
        order_reference_id: String(a.orderId || ''),
        total_amount: { amount, currency: cur },
        description: String(a.description || a.itemName || ''),
        country_code: (a.country || 'SA').toUpperCase(),
        payment_type: 'PAY_BY_INSTALMENTS',
        instalments: 3,
        items: [{
          name: String(a.itemName || a.description || ''),
          sku: String(a.orderId || ''),
          quantity: 1,
          unit_price: { amount, currency: cur },
          total_amount: { amount, currency: cur },
          type: 'digital',
        }],
        consumer: {
          email: String(buyer.email || ''),
          first_name: name.split(' ')[0] || '',
          last_name: name.split(' ').slice(1).join(' ') || '',
          phone_number: String(buyer.phone || ''),
        },
        merchant_url: {
          success: 'https://khaytapp.com/success',
          failure: 'https://khaytapp.com/failure',
          cancel: 'https://khaytapp.com/cancel',
          // Nothing receives this (khaytapp.com is a static site, and Khayt has no public
          // server); kept because Tamara's checkout may require the field. The app asks
          // Tamara instead — the 'check' flow below.
          notification: 'https://khaytapp.com/notify',
        },
      },
    };
  }

  function checkoutResult(provider, res) {
    const data = (res && res.data) || {};
    if (provider === 'tamara') {
      if (!res.ok) return { ok: false, status: res.status, error: data.message || JSON.stringify(data) };
      // order_id is what a later check and authorise take (lib/bnpl-confirm.js).
      return { ok: true, url: data.checkout_url, checkoutId: data.checkout_id, orderId: typeof data.order_id === 'string' ? data.order_id : null };
    }
    if (!res.ok) return { ok: false, status: res.status, error: data.error || JSON.stringify(data) };
    const products = (data.configuration && data.configuration.available_products) || {};
    const first = (list) => (Array.isArray(list) && list[0] && list[0].web_url) || null;
    const url = first(products.installments) || first(products.pay_now) || null;
    // payment.id is what a later check and capture take; the session id is not.
    return { ok: true, url, checkoutId: data.id, paymentId: data.payment && typeof data.payment.id === 'string' ? data.payment.id : null };
  }

  function planCheckout(a, replies) {
    if (a.provider !== 'tabby' && a.provider !== 'tamara') return { result: { ok: false, error: 'Unknown provider' } };
    if (!replies.length) return { request: a.provider === 'tamara' ? tamaraCheckout(a) : tabbyCheckout(a) };
    return { result: checkoutResult(a.provider, replies[0]) };
  }

  // ── check: finish a payment the customer completed ──────────────────────

  const stateOf = (step) => (step === 'paid' ? 'paid' : step === 'closed' ? 'closed' : 'open');

  function planCheck(a, replies) {
    const { provider, id } = a;
    if (provider !== 'tabby' && provider !== 'tamara') return { result: { ok: false, error: 'Unknown provider' } };
    if (typeof id !== 'string' || !SAFE_ID.test(id)) return { result: { ok: false, error: 'Invalid payment id' } };
    const R = rules();
    if (provider === 'tamara') {
      if (replies.length === 0) return { request: { method: 'GET', url: `${TAMARA}/merchants/orders/${id}`, timeoutMs: CALL_MS } };
      const got = replies[0];
      const gd = got.data || {};
      if (!got.ok) return { result: { ok: false, status: got.status, error: gd.message || `HTTP ${got.status}` } };
      const remote = gd.status;
      const step = R.nextStep('tamara', remote);
      if (step !== 'authorise') return { result: { ok: true, state: stateOf(step), remoteStatus: remote } };
      if (replies.length === 1) return { request: { method: 'POST', url: `${TAMARA}/orders/${id}/authorise`, timeoutMs: CALL_MS } };
      const auth = replies[1];
      const ad = auth.data || {};
      if (!auth.ok) return { result: { ok: false, status: auth.status, remoteStatus: remote, error: ad.message || `Authorise failed (HTTP ${auth.status})` } };
      return { result: { ok: true, state: 'paid', remoteStatus: ad.status || 'authorised', step: 'authorised' } };
    }
    // Tabby — the same host the checkout was made on, by the link's currency.
    const base = R.tabbyBase(a.currency || 'SAR');
    if (replies.length === 0) return { request: { method: 'GET', url: `${base}/payments/${id}`, timeoutMs: CALL_MS } };
    const got = replies[0];
    const gd = got.data || {};
    if (!got.ok) return { result: { ok: false, status: got.status, error: gd.error || `HTTP ${got.status}` } };
    const remote = gd.status;
    const step = R.nextStep('tabby', remote);
    if (step !== 'capture') return { result: { ok: true, state: stateOf(step), remoteStatus: remote } };
    // Capture what Tabby authorised — its own figure, not the window's. reference_id is
    // Tabby's idempotency key, so a check that runs twice cannot capture twice.
    const amount = String(gd.amount || '');
    if (!/^\d+(\.\d{1,2})?$/.test(amount)) return { result: { ok: false, remoteStatus: remote, error: 'Tabby did not say how much was authorised' } };
    if (replies.length === 1) {
      return { request: { method: 'POST', url: `${base}/payments/${id}/captures`, timeoutMs: CALL_MS, body: { amount, reference_id: `khayt-capture-${id}` } } };
    }
    const cap = replies[1];
    const cd = cap.data || {};
    if (!cap.ok) return { result: { ok: false, status: cap.status, remoteStatus: remote, error: cd.error || `Capture failed (HTTP ${cap.status})` } };
    return { result: { ok: true, state: 'paid', remoteStatus: cd.status || 'CLOSED', step: 'captured' } };
  }

  // ── capture: Tamara, once the job has gone out ──────────────────────────

  function planCapture(a, replies) {
    const { provider, id } = a;
    if (provider !== 'tamara') return { result: { ok: false, error: 'Unknown provider' } };
    if (typeof id !== 'string' || !SAFE_ID.test(id)) return { result: { ok: false, error: 'Invalid payment id' } };
    const sh = a.shipping || {};
    const at = Date.parse(sh.shipped_at || '');
    if (!Number.isFinite(at)) return { result: { ok: false, error: 'No shipping date' } };
    const shipping_info = { shipped_at: new Date(at).toISOString(), shipping_company: clip(sh.shipping_company, 100) || 'Own delivery' };
    if (clip(sh.tracking_number, 100)) shipping_info.tracking_number = clip(sh.tracking_number, 100);
    if (/^https:\/\//i.test(clip(sh.tracking_url, 1024))) shipping_info.tracking_url = clip(sh.tracking_url, 1024);
    if (replies.length === 0) return { request: { method: 'GET', url: `${TAMARA}/merchants/orders/${id}`, timeoutMs: CALL_MS } };
    const got = replies[0];
    const gd = got.data || {};
    if (!got.ok) return { result: { ok: false, status: got.status, error: gd.message || `HTTP ${got.status}` } };
    const remote = String(gd.status || '');
    const s = remote.toLowerCase();
    if (s === 'fully_captured' || s === 'partially_captured') return { result: { ok: true, captured: true, remoteStatus: remote } };
    // Refunded, cancelled… : there is nothing to capture, ever.
    if (s !== 'authorised' && s !== 'authorized') return { result: { ok: true, captured: false, remoteStatus: remote } };
    const total = gd.total_amount || {};
    const amount = Number(total.amount);
    if (!(amount > 0) || typeof total.currency !== 'string') return { result: { ok: false, remoteStatus: remote, error: 'Tamara did not say the order total' } };
    if (replies.length === 1) {
      return { request: { method: 'POST', url: `${TAMARA}/payments/capture`, timeoutMs: CALL_MS,
        body: { order_id: id, total_amount: { amount, currency: total.currency }, shipping_info } } };
    }
    const cap = replies[1];
    const cd = cap.data || {};
    if (!cap.ok) return { result: { ok: false, status: cap.status, remoteStatus: remote, error: cd.message || `Capture failed (HTTP ${cap.status})` } };
    return { result: { ok: true, captured: true, remoteStatus: cd.status || 'fully_captured' } };
  }

  /** The next request of a flow, or its result. See the header. */
  function plan(flow, args, replies) {
    const a = args || {};
    const r = Array.isArray(replies) ? replies : [];
    if (flow === 'checkout') return planCheckout(a, r);
    if (flow === 'check') return planCheck(a, r);
    if (flow === 'capture') return planCapture(a, r);
    return { result: { ok: false, error: 'Unknown flow' } };
  }

  const api = { plan, checkoutArgs, SAFE_ID };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.KhaytBnplRequests = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
