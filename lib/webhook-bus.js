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
    // A job failed inspection. The desktop's QC sheet has fired it all along
    // (`fireQcWebhook('qc_failed')`) and no subscription could list it, so it
    // never left the building; the Mac fires it too now.
    'qc_failed',
    // A customer reported a defect on a delivered job. Fired by the desktop's
    // RMA sheet (`fireQcWebhook('rma_opened')`) and dead the same way; the Mac
    // has no RMA flow yet, so only the desktop sends it.
    'rma_opened',
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

  /**
   * What a lifecycle event carries.
   *
   * Four fields, written down ONCE. Both apps sign the bytes of this object, so
   * a field renamed in one of them — or the keys written in a different order,
   * which changes the JSON and therefore the HMAC — is a delivery a consumer
   * verifies and rejects. `order_delivered` deliberately carries no status:
   * delivered is not one (a handed-over job stays `completed` with a
   * `deliveredAt`), so a `newStatus` here would be inventing a state.
   */
  function statusPayload(event, order, newStatus) {
    const o = order || {};
    // `quote_approved` is the desktop's own shape too (renderer/app-boot.js,
    // the LAN approval): who approved what, and no status — the approval is
    // the event, and the Pending it moves the job to is `status_changed`'s.
    if (event === 'order_delivered' || event === 'quote_approved') {
      return { orderId: o.id, project: o.project, client: o.client };
    }
    // A parcel leaving: who carries it and how to follow it. The keys and
    // their order are the ones Khayt's Ship dialog has always sent
    // (`renderer/order-flows.js`), so a consumer's parser — and the HMAC over
    // the bytes — does not change with the app that shipped it.
    // A failed inspection, or a warranty claim opened: the keys, in order, that the desktop's
    // `fireQcWebhook` sends (renderer/operations-extras.js), so the two apps
    // sign the same bytes for the same event.
    if (event === 'qc_failed' || event === 'rma_opened') {
      return { orderId: o.id, project: o.project, status: o.status,
               qcStatus: o.qcStatus || null, reprintOf: o.reprintOf || null, client: o.client || null };
    }
    if (event === 'order_shipped') {
      return { orderId: o.id, project: o.project, carrier: o.carrier, trackingNumber: o.trackingNumber };
    }
    return { orderId: o.id, project: o.project, newStatus: newStatus, client: o.client };
  }

  /**
   * The envelope that actually goes on the wire.
   *
   * `main.js` hub:fire-webhook has posted this shape since the day webhooks
   * shipped, so it is what every consumer's parser is written against — the
   * delivery body above is NESTED inside it rather than being the body. It is
   * here rather than inline in the transport because a second app now sends
   * these, and a consumer cannot be asked to accept two shapes.
   */
  function buildWireBody(event, body, nowMs) {
    return {
      event,
      payload: body,
      timestamp: typeof nowMs === 'number' ? nowMs : Date.now(),
    };
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

  // ── EDITING THE SUBSCRIPTIONS ──────────────────────────────────────────
  //
  // The desktop's settings screen edits the LEGACY shape — one URL per event
  // and one signing secret (`settings.webhooks.events{}`, `.secret`) — and
  // migrates it into subscriptions on first use. The Mac edits the
  // subscriptions themselves: several URLs, each listening to the events it
  // names. Both are kept in step, so either screen shows what the other saved.

  /**
   * The secret a subscription signs with: its own, else the shop's one
   * signing secret. `settings.webhooks.secret` is a registered (sealed)
   * secret and a subscription's is not, so the Mac stores none per
   * subscription and every delivery signs with the shared one — the only
   * secret the desktop's screen has ever offered.
   */
  function subscriptionSecret(sub, webhooks) {
    return String((sub && sub.secret) || (webhooks && webhooks.secret) || '');
  }

  /**
   * The legacy one-URL-per-event map for these subscriptions: for each event,
   * the first enabled subscription listening to it. What the desktop's screen
   * shows, and what `migrateLegacyWebhooks` would turn back into them.
   */
  function legacyEvents(subscriptions) {
    const out = {};
    for (const s of Array.isArray(subscriptions) ? subscriptions : []) {
      if (!s || s.enabled === false || !s.url || !Array.isArray(s.events)) continue;
      for (const e of s.events) if (EVENTS.includes(e) && !out[e]) out[e] = String(s.url);
    }
    return out;
  }

  /** Is this a URL a subscription may post to? https only, as both transports send. */
  function isSubscriptionUrl(url) {
    return /^https:\/\/[^\s/]+/i.test(String(url || '').trim());
  }

  /**
   * One subscription as a form describes it: the URL trimmed, only events
   * from the catalogue, each once, in catalogue order. `prev` is the stored
   * one being edited (its id and createdAt are kept), or null for a new one,
   * which takes `id` and `nowIso`. Never a secret: see `subscriptionSecret`.
   */
  function editSubscription(prev, form, id, nowIso) {
    const p = prev || {};
    const f = form || {};
    const asked = Array.isArray(f.events) ? f.events : [];
    const out = Object.assign({}, p, {
      id: p.id || String(id || ''),
      url: String(f.url == null ? (p.url || '') : f.url).trim(),
      events: EVENTS.filter((e) => asked.includes(e)),
      secret: '',
      enabled: f.enabled == null ? p.enabled !== false : !!f.enabled,
      createdAt: p.createdAt || String(f.createdAt || nowIso || ''),
    });
    // A subscription switched back on is no longer "gone".
    if (out.enabled) delete out.disabledReason;
    return out;
  }

  /**
   * The webhooks block with these subscriptions in it: the legacy map
   * rebuilt from them, and the retries for a subscription that is no longer
   * there (or no longer on) dropped — a retry for a deleted URL would post to
   * an address the shop took away. Everything else is kept as stored.
   */
  function withSubscriptions(webhooks, subscriptions) {
    const wh = webhooks || {};
    const subs = (Array.isArray(subscriptions) ? subscriptions : []).filter((s) => s && s.id);
    const live = new Set(subs.filter((s) => s.enabled !== false).map((s) => s.id));
    const pending = (Array.isArray(wh.pending) ? wh.pending : [])
      .filter((p) => p && (live.has(p.subscriptionId) || String(p.subscriptionId || '').startsWith('event:')));
    return Object.assign({}, wh, { subscriptions: subs, events: legacyEvents(subs), pending });
  }

  /**
   * The desktop's legacy screen, saved: keep the subscriptions when the URLs
   * it shows are the ones they already make (the shop changed the switch or
   * the secret), and rebuild them from the screen only when a URL changed —
   * that screen cannot show a second URL on one event, and rebuilding on
   * every save threw away the deliveries' subscription ids for nothing.
   */
  function fromLegacyForm(webhooks, form) {
    const wh = webhooks || {};
    const f = form || {};
    const events = {};
    for (const [k, v] of Object.entries(f.events || {})) { const u = String(v || '').trim(); if (u) events[k] = u; }
    const base = Object.assign({}, wh, { enabled: !!f.enabled, secret: f.secret == null ? wh.secret : f.secret });
    const subs = Array.isArray(wh.subscriptions) ? wh.subscriptions : null;
    const same = (a, b) => {
      const ka = Object.keys(a).sort(), kb = Object.keys(b).sort();
      return ka.length === kb.length && ka.every((k, i) => k === kb[i] && a[k] === b[k]);
    };
    if (subs && same(legacyEvents(subs), events)) return Object.assign(base, { events });
    const out = Object.assign(base, { events });
    delete out.subscriptions;
    return out;
  }

  /**
   * The secret to sign a delivery to `url` with, filled in from the store.
   * For a host whose window holds the MASK rather than a secret (the
   * desktop): the event webhook's when `url` is its address, else the shop's
   * signing secret when `url` is one of its subscriptions'. `{ found, secret }`
   * — not found means the address is none the shop saved, and nothing from
   * the store may sign for it. `urlKey` is `lib/secret-destination.js`'s.
   */
  function signingSecretFor(settings, url, urlKey, mask) {
    const s = settings || {};
    const key = urlKey(url);
    if (!key) return { found: false, secret: '' };
    const ew = s.eventWebhooks || {};
    if (ew.url && urlKey(ew.url) === key) return { found: true, secret: String(ew.secret || '') };
    const wh = s.webhooks || {};
    const subs = Array.isArray(wh.subscriptions) && wh.subscriptions.length
      ? wh.subscriptions : migrateLegacyWebhooks(wh);
    const sub = subs.find((x) => x && x.url && urlKey(x.url) === key);
    if (!sub) return { found: false, secret: '' };
    const own = String(sub.secret || '');
    const usable = own && own !== mask && !own.startsWith('__enc__');
    return { found: true, secret: usable ? own : String(wh.secret || '') };
  }

  /**
   * A line of the delivery log. The payload is kept with it (the desktop's
   * `resendWebhookDelivery` already read `rec.payload`, which nothing wrote),
   * so a resend sends what the first attempt did.
   */
  function deliveryRecord(o) {
    const r = o || {};
    return {
      id: String(r.id || ''), subscriptionId: String(r.subscriptionId || ''), event: String(r.event || ''),
      at: String(r.at || ''), status: r.status || 'failed', httpStatus: r.httpStatus || null,
      attempts: r.attempts || 1, error: r.error || null, payload: r.payload || {},
    };
  }

  const api = {
    EVENTS, MAX_ATTEMPTS, DELIVERY_LOG_CAP, PENDING_CAP,
    schedulePending, duePending, futurePending, removePending,
    migrateLegacyWebhooks, matchSubscriptions, buildDeliveryBody,
    statusPayload, buildWireBody,
    subscriptionSecret, legacyEvents, isSubscriptionUrl, editSubscription, withSubscriptions,
    fromLegacyForm, signingSecretFor, deliveryRecord,
    backoffDelayMs, shouldRetry, isGone, appendDelivery, deliveriesFor,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytWebhookBus = api;
})();
