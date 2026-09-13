'use strict';
/**
 * Outbound webhook event bus — subscriptions, fan-out, retry policy and a bounded
 * delivery log. Implements §2 of docs/KHAYT-3.0-PUBLIC-API-SPEC.md.
 *
 * Pure logic only: no network, no DOM. The actual POST stays in the main process
 * (main.js `hub:fire-webhook`) so the existing SSRF hardening — https-only, blocked
 * host + DNS-rebinding checks, no redirects, HMAC signing — is preserved untouched.
 */
(function () {
  // Events a subscription can listen to (spec §2 catalog).
  const EVENTS = [
    'order_created', 'status_changed', 'order_shipped', 'order_delivered',
    'payment_received', 'quote_created', 'quote_approved',
    'low_stock', 'printer_alert', 'intake_submitted',
  ];

  const MAX_ATTEMPTS = 5;
  const DELIVERY_LOG_CAP = 200;

  /**
   * Legacy config was one URL per event (`settings.webhooks.events{}`). Collapse it into
   * subscriptions — one per distinct URL, listening to every event that pointed at it —
   * so an upgrade keeps working without the owner reconfiguring anything.
   */
  function migrateLegacyWebhooks(webhooks) {
    const wh = webhooks || {};
    if (Array.isArray(wh.subscriptions) && wh.subscriptions.length) return wh.subscriptions;
    const byUrl = new Map();
    for (const [event, url] of Object.entries(wh.events || {})) {
      const u = String(url || '').trim();
      if (!u) continue;
      if (!byUrl.has(u)) {
        byUrl.set(u, {
          id: 'whs_' + Math.abs(hashString(u)).toString(36),
          url: u, events: [], secret: wh.secret || '', enabled: wh.enabled !== false,
          createdAt: new Date().toISOString(),
        });
      }
      const sub = byUrl.get(u);
      if (EVENTS.includes(event) && !sub.events.includes(event)) sub.events.push(event);
    }
    return Array.from(byUrl.values());
  }

  // Small stable string hash — only used to derive a deterministic id on migration.
  function hashString(s) {
    let h = 0;
    for (let i = 0; i < s.length; i++) { h = ((h << 5) - h + s.charCodeAt(i)) | 0; }
    return h;
  }

  /** Enabled subscriptions listening for this event (fan-out target set). */
  function matchSubscriptions(subscriptions, event) {
    return (Array.isArray(subscriptions) ? subscriptions : []).filter(
      s => s && s.enabled !== false && s.url && Array.isArray(s.events) && s.events.includes(event)
    );
  }

  /** The signed body a consumer receives. `id` doubles as the idempotency key. */
  function buildDeliveryBody(event, payload, id, nowIso) {
    return {
      id: id || ('dlv_' + Math.random().toString(36).slice(2, 12)),
      event,
      version: 1,
      timestamp: nowIso || new Date().toISOString(),
      payload: payload || {},
    };
  }

  /** Exponential-ish backoff: immediate, 30s, 2m, 10m, 1h. */
  function backoffDelayMs(attempt) {
    const ladder = [0, 30_000, 120_000, 600_000, 3_600_000];
    const i = Math.max(1, Math.min(MAX_ATTEMPTS, attempt || 1)) - 1;
    return ladder[i];
  }

  /**
   * Retry policy. 410 Gone is a permanent "stop sending" from the consumer — never retry
   * (the caller also disables the subscription). 2xx is success. Everything else retries
   * until MAX_ATTEMPTS.
   */
  function shouldRetry(status, attempt) {
    if (attempt >= MAX_ATTEMPTS) return false;
    if (status === 410) return false;
    if (typeof status === 'number' && status >= 200 && status < 300) return false;
    return true;
  }

  function isGone(status) { return status === 410; }

  /** Append a delivery record, keeping only the most recent `cap` entries. */
  function appendDelivery(log, entry, cap) {
    const out = Array.isArray(log) ? log.slice() : [];
    out.push(entry);
    const limit = cap || DELIVERY_LOG_CAP;
    return out.length > limit ? out.slice(out.length - limit) : out;
  }

  /** Deliveries for one subscription, newest first (for the settings panel). */
  function deliveriesFor(log, subscriptionId) {
    return (Array.isArray(log) ? log : [])
      .filter(d => d && d.subscriptionId === subscriptionId)
      .slice()
      .reverse();
  }

  // ── Durable retry queue ────────────────────────────────────────────────
  // Pending retries are persisted with the store, so a delivery that is mid-backoff when
  // the app quits is resumed on next launch instead of being silently lost.
  const PENDING_CAP = 500;

  /** Queue (or re-queue) a delivery for a later attempt. */
  function schedulePending(pending, entry, delayMs, nowMs) {
    const now = typeof nowMs === 'number' ? nowMs : Date.now();
    const list = (Array.isArray(pending) ? pending : []).filter(p => p && p.id !== entry.id);
    list.push({
      id: entry.id,
      subscriptionId: entry.subscriptionId,
      event: entry.event,
      payload: entry.payload || {},
      attempt: entry.attempt || 1,
      nextAttemptAt: new Date(now + (delayMs || 0)).toISOString(),
    });
    return list.length > PENDING_CAP ? list.slice(list.length - PENDING_CAP) : list;
  }

  /** Retries whose time has come (including any that came due while the app was closed). */
  function duePending(pending, nowMs) {
    const now = typeof nowMs === 'number' ? nowMs : Date.now();
    return (Array.isArray(pending) ? pending : []).filter(p => {
      if (!p || !p.subscriptionId) return false;
      const t = Date.parse(p.nextAttemptAt || '');
      return !Number.isFinite(t) || t <= now;
    });
  }

  /** Retries still in the future, with the ms remaining (so the app can re-arm timers). */
  function futurePending(pending, nowMs) {
    const now = typeof nowMs === 'number' ? nowMs : Date.now();
    return (Array.isArray(pending) ? pending : [])
      .filter(p => {
        const t = Date.parse(p && p.nextAttemptAt || '');
        return Number.isFinite(t) && t > now;
      })
      .map(p => ({ ...p, inMs: Date.parse(p.nextAttemptAt) - now }));
  }

  function removePending(pending, id) {
    return (Array.isArray(pending) ? pending : []).filter(p => p && p.id !== id);
  }

  const api = {
    EVENTS, MAX_ATTEMPTS, DELIVERY_LOG_CAP, PENDING_CAP,
    schedulePending, duePending, futurePending, removePending,
    migrateLegacyWebhooks, matchSubscriptions, buildDeliveryBody,
    backoffDelayMs, shouldRetry, isGone, appendDelivery, deliveriesFor,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytWebhookBus = api;
})();
