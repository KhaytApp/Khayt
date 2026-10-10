'use strict';

/**
 * Buy-now-pay-later checkout links: Tabby, Tamara and Stripe Checkout.
 *
 * Lifted out of main.js unchanged. Three providers that share one shape — take a
 * shop's API key, POST an amount, hand back a URL for the customer — and that
 * shape has nothing to do with printers, files or windows, which is what the
 * rest of the main process is about.
 *
 * Registered the way lib/updater.js is, with its dependencies passed in rather
 * than reached for. There are only two, which is why this was the first section
 * to move: `ipcMain`, and `resolveStoreSecret` because a key may be stored
 * masked and has to be resolved from disk before it is sent anywhere.
 */

function registerPaymentLinks({ ipcMain, resolveStoreSecret }) {
  // ── BNPL: Tabby ──────────────────────────────────────────────────────────────
  ipcMain.handle('hub:bnpl-tabby', async (_e, { apiKey, merchantCode, amount, currency, description, buyer, orderId, itemName }) => {
    apiKey = resolveStoreSecret(apiKey, d => d?.settings?.bnpl?.tabby?.apiKey);
    if (!apiKey) return { ok: false, error: 'No API key configured' };
    try {
      const body = {
        payment: {
          amount:      (+amount || 0).toFixed(2),
          currency:    currency  || 'SAR',
          description: String(description || ''),
          buyer: {
            phone: String(buyer?.phone || ''),
            name:  String(buyer?.name  || ''),
            email: String(buyer?.email || ''),
          },
          buyer_history: { registered_since: '2024-01-01T00:00:00Z', loyalty_level: 0 },
          order: {
            reference_id: String(orderId || ''),
            items: [{ title: String(itemName || description || ''), unit_price: (+amount || 0).toFixed(2), qty: 1, category: '3D Printing', reference_id: String(orderId || '') }],
            tax_amount: '0.00', shipping_amount: '0.00',
          },
          meta: { order_id: String(orderId || ''), customer: String(buyer?.name || '') },
        },
        lang: 'en',
        merchant_code: String(merchantCode || ''),
        merchant_urls: {
          success: 'https://khaytapp.com/success',
          cancel:  'https://khaytapp.com/cancel',
          failure: 'https://khaytapp.com/failure',
        },
      };
      const res = await fetch('https://api.tabby.ai/api/v2/checkout', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) return { ok: false, status: res.status, error: data?.error || JSON.stringify(data) };
      const url = data?.configuration?.available_products?.installments?.[0]?.web_url
               || data?.configuration?.available_products?.pay_now?.[0]?.web_url
               || null;
      // payment.id is what a later check and capture take (lib/bnpl-confirm.js); the
      // session id is not.
      return { ok: true, url, checkoutId: data?.id, paymentId: typeof data?.payment?.id === 'string' ? data.payment.id : null };
    } catch (e) { return { ok: false, error: String(e) }; }
  });

  // ── BNPL: Tamara ─────────────────────────────────────────────────────────────
  ipcMain.handle('hub:bnpl-tamara', async (_e, { apiKey, amount, currency, country, description, buyer, orderId, itemName }) => {
    apiKey = resolveStoreSecret(apiKey, d => d?.settings?.bnpl?.tamara?.apiKey);
    if (!apiKey) return { ok: false, error: 'No API key configured' };
    try {
      const cur = (currency || 'SAR').toUpperCase();
      const body = {
        order_reference_id: String(orderId || ''),
        total_amount:       { amount: (+amount || 0).toFixed(2), currency: cur },
        description:        String(description || itemName || ''),
        country_code:       (country || 'SA').toUpperCase(),
        payment_type:       'PAY_BY_INSTALMENTS',
        instalments:        3,
        items: [{
          name:         String(itemName || description || ''),
          sku:          String(orderId  || ''),
          quantity:     1,
          unit_price:   { amount: (+amount || 0).toFixed(2), currency: cur },
          total_amount: { amount: (+amount || 0).toFixed(2), currency: cur },
          type:         'digital',
        }],
        consumer: {
          email:        String(buyer?.email || ''),
          first_name:   (String(buyer?.name || '')).split(' ')[0]             || '',
          last_name:    (String(buyer?.name || '')).split(' ').slice(1).join(' ') || '',
          phone_number: String(buyer?.phone || ''),
        },
        merchant_url: {
          success:      'https://khaytapp.com/success',
          failure:      'https://khaytapp.com/failure',
          cancel:       'https://khaytapp.com/cancel',
          // Nothing receives this (khaytapp.com is a static site, and Khayt has no public
          // server); kept because Tamara's checkout may require the field. The app asks
          // Tamara instead — hub:bnpl-check below.
          notification: 'https://khaytapp.com/notify',
        },
      };
      const res = await fetch('https://api.tamara.co/checkout', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(10000),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) return { ok: false, status: res.status, error: data?.message || JSON.stringify(data) };
      // order_id is what a later check and authorise take (lib/bnpl-confirm.js). It used to
      // be dropped, so nothing could ever finish a Tamara payment.
      return { ok: true, url: data?.checkout_url, checkoutId: data?.checkout_id, orderId: typeof data?.order_id === 'string' ? data.order_id : null };
    } catch (e) { return { ok: false, error: String(e) }; }
  });

  // ── BNPL: finish a payment the customer completed ───────────────────────────
  // The shop's window asks about each open link (lib/bnpl-confirm.js linksToCheck);
  // this asks the provider, takes the step the provider is waiting for — Tamara's
  // authorise, Tabby's capture — and says where the link now stands. The key is read
  // from disk only: nothing the window sends is used as a credential here.
  const BnplRules = require('../bnpl-confirm.js');
  const SAFE_ID = /^[A-Za-z0-9-]{8,64}$/;
  const call = async (url, apiKey, method, body) => {
    const res = await fetch(url, {
      method,
      headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(15000),
    });
    const data = await res.json().catch(() => ({}));
    return { ok: res.ok, status: res.status, data };
  };
  ipcMain.handle('hub:bnpl-check', async (_e, { provider, id } = {}) => {
    if (provider !== 'tabby' && provider !== 'tamara') return { ok: false, error: 'Unknown provider' };
    if (typeof id !== 'string' || !SAFE_ID.test(id)) return { ok: false, error: 'Invalid payment id' };
    const apiKey = resolveStoreSecret('', d => d?.settings?.bnpl?.[provider]?.apiKey);
    if (!apiKey) return { ok: false, error: 'No API key configured' };
    try {
      if (provider === 'tamara') {
        const base = 'https://api.tamara.co';
        const got = await call(`${base}/merchants/orders/${id}`, apiKey, 'GET');
        if (!got.ok) return { ok: false, status: got.status, error: got.data?.message || `HTTP ${got.status}` };
        const remote = got.data?.status;
        const step = BnplRules.nextStep('tamara', remote);
        if (step !== 'authorise') return { ok: true, state: step === 'paid' ? 'paid' : step === 'closed' ? 'closed' : 'open', remoteStatus: remote };
        const auth = await call(`${base}/orders/${id}/authorise`, apiKey, 'POST');
        if (!auth.ok) return { ok: false, status: auth.status, remoteStatus: remote, error: auth.data?.message || `Authorise failed (HTTP ${auth.status})` };
        return { ok: true, state: 'paid', remoteStatus: auth.data?.status || 'authorised', step: 'authorised' };
      }
      // Tabby — the same host the checkout was made on.
      const base = 'https://api.tabby.ai/api/v2';
      const got = await call(`${base}/payments/${id}`, apiKey, 'GET');
      if (!got.ok) return { ok: false, status: got.status, error: got.data?.error || `HTTP ${got.status}` };
      const remote = got.data?.status;
      const step = BnplRules.nextStep('tabby', remote);
      if (step !== 'capture') return { ok: true, state: step === 'paid' ? 'paid' : step === 'closed' ? 'closed' : 'open', remoteStatus: remote };
      // Capture what Tabby authorised — its own figure, not the window's. reference_id is
      // Tabby's idempotency key, so a check that runs twice cannot capture twice.
      const amount = String(got.data?.amount || '');
      if (!/^\d+(\.\d{1,2})?$/.test(amount)) return { ok: false, remoteStatus: remote, error: 'Tabby did not say how much was authorised' };
      const cap = await call(`${base}/payments/${id}/captures`, apiKey, 'POST', { amount, reference_id: `khayt-capture-${id}` });
      if (!cap.ok) return { ok: false, status: cap.status, remoteStatus: remote, error: cap.data?.error || `Capture failed (HTTP ${cap.status})` };
      return { ok: true, state: 'paid', remoteStatus: cap.data?.status || 'CLOSED', step: 'captured' };
    } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
  });

  // ── BNPL: Stripe Checkout (supports Klarna/Afterpay/Affirm via dashboard) ────
  ipcMain.handle('hub:bnpl-stripe', async (_e, { apiKey, amount, currency, description, successUrl, cancelUrl, customerEmail }) => {
    apiKey = resolveStoreSecret(apiKey, d => d?.settings?.bnpl?.stripe?.apiKey);
    if (!apiKey || !apiKey.startsWith('sk_')) return { ok: false, error: 'Invalid Stripe secret key (must start with sk_)' };
    // Validate redirect URLs — must be https:// and must not point to private/loopback addresses
    const validateStripeRedirectUrl = (u, fallback) => {
      const s = String(u || '');
      if (!s) return fallback;
      if (!s.startsWith('https://')) return fallback;
      try {
        const parsed = new URL(s);
        if (isBlockedHost(parsed.hostname)) return fallback;
        return s;
      } catch { return fallback; }
    };
    const safeSuccessUrl = validateStripeRedirectUrl(successUrl, 'https://khaytapp.com/success');
    const safeCancelUrl  = validateStripeRedirectUrl(cancelUrl,  'https://khaytapp.com/cancel');
    try {
      const params = new URLSearchParams({
        'mode':                                         'payment',
        'payment_method_types[]':                       'card',
        'line_items[0][price_data][currency]':          (currency || 'sar').toLowerCase(),
        'line_items[0][price_data][product_data][name]':String(description || 'Order'),
        'line_items[0][price_data][unit_amount]':       String(Math.round((+amount || 0) * 100)),
        'line_items[0][quantity]':                      '1',
        'success_url':                                  safeSuccessUrl,
        'cancel_url':                                   safeCancelUrl,
      });
      if (customerEmail) params.set('customer_email', String(customerEmail));
      const res = await fetch('https://api.stripe.com/v1/checkout/sessions', {
        method: 'POST',
        headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/x-www-form-urlencoded' },
        body: params.toString(),
        signal: AbortSignal.timeout(10000),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) return { ok: false, status: res.status, error: data?.error?.message || JSON.stringify(data) };
      return { ok: true, url: data?.url, sessionId: data?.id };
    } catch (e) { return { ok: false, error: String(e) }; }
  });
}

module.exports = { registerPaymentLinks };
