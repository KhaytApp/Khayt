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

const BnplRequests = require('../bnpl-requests.js');

function registerPaymentLinks({ ipcMain, resolveStoreSecret }) {
  // ── BNPL: Tabby and Tamara ───────────────────────────────────────────────────
  // What is sent and what the answers mean are lib/bnpl-requests.js — the same
  // requests the native Mac app sends. This only carries them.
  const send = async (req, apiKey) => {
    const res = await fetch(req.url, {
      method: req.method,
      headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
      body: req.body ? JSON.stringify(req.body) : undefined,
      signal: AbortSignal.timeout(req.timeoutMs || 15000),
    });
    const data = await res.json().catch(() => ({}));
    return { ok: res.ok, status: res.status, data };
  };
  /** Run one flow to its result. The arguments are checked first; a missing key is said after that. */
  const run = async (flow, args, apiKey) => {
    const replies = [];
    let step = BnplRequests.plan(flow, args, replies);
    if (step.result) return step.result;
    if (!apiKey) return { ok: false, error: 'No API key configured' };
    while (step.request) {
      replies.push(await send(step.request, apiKey));
      step = BnplRequests.plan(flow, args, replies);
    }
    return step.result;
  };

  ipcMain.handle('hub:bnpl-tabby', async (_e, { apiKey, merchantCode, amount, currency, description, buyer, orderId, itemName }) => {
    apiKey = resolveStoreSecret(apiKey, d => d?.settings?.bnpl?.tabby?.apiKey);
    if (!apiKey) return { ok: false, error: 'No API key configured' };
    try {
      return await run('checkout', { provider: 'tabby', merchantCode, amount, currency, description, buyer, orderId, itemName }, apiKey);
    } catch (e) { return { ok: false, error: String(e) }; }
  });

  ipcMain.handle('hub:bnpl-tamara', async (_e, { apiKey, amount, currency, country, description, buyer, orderId, itemName }) => {
    apiKey = resolveStoreSecret(apiKey, d => d?.settings?.bnpl?.tamara?.apiKey);
    if (!apiKey) return { ok: false, error: 'No API key configured' };
    try {
      return await run('checkout', { provider: 'tamara', amount, currency, country, description, buyer, orderId, itemName }, apiKey);
    } catch (e) { return { ok: false, error: String(e) }; }
  });

  // ── BNPL: finish a payment the customer completed ───────────────────────────
  // The shop's window asks about each open link (lib/bnpl-confirm.js linksToCheck);
  // this asks the provider, takes the step the provider is waiting for — Tamara's
  // authorise, Tabby's capture — and says where the link now stands. The key is read
  // from disk only: nothing the window sends is used as a credential here, and it is
  // not even read for a provider or an id the plan refuses.
  ipcMain.handle('hub:bnpl-check', async (_e, { provider, id, currency } = {}) => {
    const args = { provider, id, currency };
    try {
      const first = BnplRequests.plan('check', args, []);
      if (first.result) return first.result;
      return await run('check', args, resolveStoreSecret('', d => d?.settings?.bnpl?.[provider]?.apiKey));
    } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
  });

  // ── BNPL: Tamara capture, once the job has gone out ─────────────────────────
  // Capture tells Tamara the order was fulfilled (POST /payments/capture). The
  // amount is Tamara's own figure for the order, read first, never the
  // window's; an order already captured (by Tamara at 21 days, or an earlier
  // run) is reported as such and nothing is posted.
  ipcMain.handle('hub:bnpl-capture', async (_e, { provider, id, shipping } = {}) => {
    const args = { provider, id, shipping };
    try {
      const first = BnplRequests.plan('capture', args, []);
      if (first.result) return first.result;
      return await run('capture', args, resolveStoreSecret('', d => d?.settings?.bnpl?.tamara?.apiKey));
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
