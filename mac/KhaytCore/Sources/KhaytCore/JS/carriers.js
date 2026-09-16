'use strict';
/**
 * Shipping carrier adapters — pluggable, Saudi-market first (SMSA, Aramex, Saudi Post/SPL),
 * plus an always-available "Manual" carrier. Mirrors renderer/integrations.js: pure data +
 * lookups here; any network call is proxied through the main process (window.hubAPI).
 *
 * Governing principle (see docs/KHAYT-3.0-SHIPPING-SPEC.md): cloud-optional, manual-first.
 * A maker can always type a carrier + tracking number by hand with zero internet or keys;
 * carrier API calls are an opt-in enhancement that degrades to manual on any error.
 *
 * Each adapter:
 *   id, label:{en,ar}, services:[{id,label}], configFields:[{key,secret?}],
 *   async createShipment(order, cfg)  -> { trackingNumber, labelUrl, service, meta } | throws
 *   trackingUrl(trackingNumber)       -> carrier public tracking deep link | null
 *   parseWebhook(body, headers, cfg)  -> { trackingNumber, shippingStatus, at } | null
 */
(function (global) {
  // Canonical status enum + rank for monotonic advance (status never regresses).
  const SHIPPING_STATUSES = ['unshipped', 'label_created', 'in_transit', 'out_for_delivery', 'delivered', 'exception'];
  const RANK = { unshipped: 0, label_created: 1, in_transit: 2, out_for_delivery: 3, delivered: 4 };

  // Advance a shipping status without regressing. 'exception' can always be set;
  // a delivered order ignores a later in_transit (out-of-order webhook).
  function advanceShippingStatus(current, next) {
    if (!next || !SHIPPING_STATUSES.includes(next)) return current || null;
    if (next === 'exception') return 'exception';
    if (current === 'delivered') return 'delivered';
    const c = RANK[current] != null ? RANK[current] : -1;
    const n = RANK[next] != null ? RANK[next] : -1;
    return n > c ? next : (current || next);
  }

  // Map a free-text/coded carrier status to the canonical enum. Shared fallback used by
  // every adapter's normalizer so unknown codes degrade to a sensible value, not a throw.
  function normalizeGeneric(raw) {
    const s = String(raw == null ? '' : raw).toLowerCase().trim();
    if (!s) return null;
    // Order matters: "out for delivery" contains "deliver", so test it first.
    if (/out.?for.?deliver|ofd|with.?courier|last.?mile/.test(s)) return 'out_for_delivery';
    if (/deliver/.test(s)) return 'delivered';
    if (/transit|shipped|in.?progress|picked|depart|arriv|hub|sorting|on.?the.?way/.test(s)) return 'in_transit';
    if (/label|created|manifest|booked|awb|ready/.test(s)) return 'label_created';
    if (/except|fail|return|rto|hold|delay|lost|damage|refus|undeliver/.test(s)) return 'exception';
    return null;
  }

  // Pull a tracking number and status from a webhook body regardless of the exact field
  // names a carrier uses (they all differ). Returns null when nothing usable is present.
  /** One object's own keys, tried for a tracking number and a status. */
  function parseOneLevel(src, normalize) {
    if (!src || typeof src !== 'object') return null;
    // Carriers vary the casing (Aramex 'ShipmentNumber', others 'awb'/'tracking_number');
    // index by lowercased key so field lookup is case-insensitive.
    const b = {};
    for (const k of Object.keys(src)) b[k.toLowerCase()] = src[k];
    const tn = b.trackingnumber || b.tracking_number || b.awb || b.awbnumber || b.waybill ||
      b.shipmentnumber || b.reference || b.trackingno || null;
    const rawStatus = b.status || b.shippingstatus || b.event || b.event_code || b.eventcode ||
      b.statuscode || b.state || b.activity || null;
    const shippingStatus = normalize(rawStatus);
    if (!tn || !shippingStatus) return null;
    // `eventTime` was in this list and could never match: every key in `b` has
    // been lowercased, so a camelCase lookup is always undefined. A dead branch
    // in a fallback chain reads as a handled case and is not one.
    const at = b.at || b.timestamp || b.time || b.date || b.eventtime || null;
    return { trackingNumber: String(tn), shippingStatus, at: at ? String(at) : null };
  }

  /**
   * A carrier event, from the top level or one level in.
   *
   * Carriers nest. `{"Shipments":[{"ShipmentNumber":…,"Status":…}]}` and
   * `{"data":{…}}` are both ordinary shapes, and this used to read only the top
   * level — so a nested payload produced no event, the handler answered
   * "received, ignored", and the shop's shipments simply never advanced. Silent
   * and indistinguishable from a carrier that sends nothing.
   *
   * The descent is ONE level and stops at the first complete match. It cannot
   * invent an event: a candidate still has to carry both a tracking number and
   * a status that normalises to a known one, so a wrong container yields null
   * rather than a wrong status on somebody's order.
   */
  function parseGenericWebhook(body, normalize) {
    const top = parseOneLevel(body, normalize);
    if (top) return top;
    if (!body || typeof body !== 'object') return null;
    for (const value of Object.values(body)) {
      const candidate = Array.isArray(value) ? value[0] : value;
      const nested = parseOneLevel(candidate, normalize);
      if (nested) return nested;
    }
    return null;
  }

  const MANUAL = {
    id: 'manual',
    label: { en: 'Manual', ar: 'يدوي' },
    services: [],
    configFields: [],
    // Manual carrier just records whatever the user typed; never touches the network.
    async createShipment(order, cfg, typed) {
      const tn = (typed && typed.trackingNumber) || '';
      return { trackingNumber: tn, labelUrl: null, service: (typed && typed.service) || null, meta: null };
    },
    // Best-effort: a generic tracking search so the customer still gets a link.
    trackingUrl(tn) { return tn ? `https://www.google.com/search?q=${encodeURIComponent('track parcel ' + tn)}` : null; },
    parseWebhook() { return null; },
  };

  // API carriers: framework + real tracking URLs + real webhook normalization. The live
  // createShipment call needs carrier credentials + endpoint access, proxied via the main
  // process when available; until then it throws so the Ship modal degrades to manual entry.
  function apiCarrier({ id, label, services, trackingUrl, webhookNormalizer }) {
    return {
      id, label, services,
      configFields: [{ key: 'apiKey', secret: true }, { key: 'accountNumber' }, { key: 'webhookSecret', secret: true }],
      async createShipment(order, cfg) {
        if (typeof global.hubAPI !== 'undefined' && global.hubAPI && typeof global.hubAPI.carrierCreateShipment === 'function') {
          const r = await global.hubAPI.carrierCreateShipment({ carrier: id, order, cfg });
          if (r && r.ok && r.trackingNumber) return { trackingNumber: r.trackingNumber, labelUrl: r.labelUrl || null, service: r.service || null, meta: r.meta || null };
          throw new Error((r && r.error) || 'carrier_error');
        }
        // No proxy available (offline build / not yet wired) — caller falls back to manual.
        throw new Error('carrier_api_unavailable');
      },
      trackingUrl(tn) { return tn ? trackingUrl(tn) : null; },
      parseWebhook(body /*, headers, cfg */) { return parseGenericWebhook(body, webhookNormalizer); },
    };
  }

  const SMSA = apiCarrier({
    id: 'smsa', label: { en: 'SMSA Express', ar: 'سمسا إكسبريس' },
    services: [{ id: 'dom_exp', label: 'Domestic Express' }, { id: 'intl_exp', label: 'International Express' }],
    trackingUrl: (tn) => `https://www.smsaexpress.com/trackingdetails?tracknumbers=${encodeURIComponent(tn)}`,
    webhookNormalizer: normalizeGeneric,
  });

  const ARAMEX = apiCarrier({
    id: 'aramex', label: { en: 'Aramex', ar: 'أرامكس' },
    services: [{ id: 'dom', label: 'Domestic' }, { id: 'intl', label: 'International' }],
    trackingUrl: (tn) => `https://www.aramex.com/us/en/track/results?ShipmentNumber=${encodeURIComponent(tn)}`,
    webhookNormalizer: normalizeGeneric,
  });

  const SPL = apiCarrier({
    id: 'spl', label: { en: 'Saudi Post (SPL)', ar: 'البريد السعودي (سبل)' },
    services: [{ id: 'domestic', label: 'Domestic' }, { id: 'express', label: 'Express' }],
    trackingUrl: (tn) => `https://splonline.com.sa/en/track-and-trace/?trackingNumber=${encodeURIComponent(tn)}`,
    webhookNormalizer: normalizeGeneric,
  });

  const CARRIERS = { manual: MANUAL, smsa: SMSA, aramex: ARAMEX, spl: SPL };

  function getCarrier(id) { return CARRIERS[id] || null; }
  function listCarriers() { return Object.values(CARRIERS); }

  // Carriers a maker can pick in the Ship modal: any API carrier with an apiKey configured,
  // plus Manual (always). settings.shipping.<id> holds per-carrier config.
  function configuredCarriers(settings) {
    const cfg = (settings && settings.shipping) || {};
    const out = [];
    for (const c of Object.values(CARRIERS)) {
      if (c.id === 'manual') continue;
      const cc = cfg[c.id] || {};
      if (cc.enabled && (cc.apiKey || cc.accountNumber)) out.push(c);
    }
    out.push(MANUAL);
    return out;
  }

  // Fields safe to show a customer on the tracking portal — never shipmentMeta/cost/notes.
  function projectShipping(order) {
    if (!order) return null;
    const carrier = getCarrier(order.carrier);
    const tn = order.trackingNumber || null;
    if (!order.shippingStatus && !tn) return null;
    return {
      shippingStatus: order.shippingStatus || null,
      carrier: order.carrier || null,
      carrierLabel: carrier ? carrier.label : null,
      trackingNumber: tn,
      trackingUrl: (carrier && tn) ? carrier.trackingUrl(tn) : null,
      history: Array.isArray(order.shippingHistory)
        ? order.shippingHistory.map((h) => ({ status: h.status, at: h.at })) : [],
    };
  }

  const api = {
    SHIPPING_STATUSES,
    advanceShippingStatus,
    normalizeGeneric,
    parseGenericWebhook,
    getCarrier,
    listCarriers,
    configuredCarriers,
    projectShipping,
    CARRIERS,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof global !== 'undefined') global.KhaytCarriers = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
