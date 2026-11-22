'use strict';
/**
 * May Khayt make this internet call? One answer for every app (P8, batch 4;
 * ~/Khayt-proposals/outbound-switch-design.md, decided by Turki Nov 22: all as
 * recommended, D1–D6).
 *
 * The shop can turn every internet call off with one switch,
 * `settings.network.offline`, kept in the BOOK so every computer and the phone
 * follow it (D4). A computer can be stricter on its own (`ctx.local.offline`,
 * a file on that computer), never looser. While offline the shop may still
 * KEEP named purposes (`settings.network.keep`), its own integrations
 * included (D1). Printers, cameras and phones on the shop's own network are
 * `lan`, which the switch never blocks, but only at a private address.
 *
 *   allowed(settings, purpose, ctx?) → { allowed, reason, purpose }
 *   describe(settings, ctx?)         → one row per purpose, in PURPOSES order,
 *                                      for the Settings list
 *   PURPOSES, REASONS, INFO          frozen
 *
 *   ctx = { local: { offline, installCountOff }, host }
 *     local  what this computer says (Electron userData/network-local.json and
 *            active-count.json; Mac and iPhone UserDefaults)
 *     host   the address a `lan` call goes to (a hostname or IP literal, IPv6
 *            with or without brackets, no port)
 *
 * Order of checks, the first that applies decides:
 *   1. an unknown purpose            → blocked, 'unknown-purpose' (a typo fails closed)
 *   2. 'lan'                          → online: allowed; offline: allowed only to a
 *                                       private address or a LAN name, else
 *                                       'lan-host-public' ('lan-host-missing' for none)
 *   3. no settings (the book not read yet) → blocked, 'settings-unknown'
 *   4. this computer is offline       → blocked, 'offline-here'
 *   5. the shop is offline, not kept  → blocked, 'offline'
 *   6. the purpose's own switch says no → blocked, 'opted-out'
 *        crash-reports: settings.telemetry.crashOptIn must be true
 *        usage-stats:   settings.telemetry.usageOptIn must be true
 *        install-count: ctx.local.installCountOff must not be true (D3: per computer)
 *   7. otherwise allowed, 'kept' while offline, else 'ok'
 *
 * The switch only takes away: keeping a purpose does not opt the shop in to
 * it. Whether an integration is SET UP (an SMTP host, an S3 key) stays at the
 * call site. Blocked telemetry is dropped, not queued (D5): that is the
 * sender's business, and it must not grow a backlog on 'offline'.
 *
 * Pure and JavaScriptCore-safe. The Mac loads lib/host-ranges.js (and
 * lib/printer-host.js) before this file and reads them from the global.
 */
(function (root) {

const PURPOSES = Object.freeze(['updates', 'install-count', 'crash-reports', 'usage-stats', 'cloud', 'makerrun',
  'catalogues', 'storage', 'messaging', 'webhooks', 'payments', 'ai', 'tax-authority', 'exchange-rates',
  'lookups', 'tunnel', 'lan']);

const REASONS = Object.freeze(['ok', 'kept', 'lan', 'offline', 'offline-here', 'opted-out', 'settings-unknown',
  'unknown-purpose', 'lan-host-public', 'lan-host-missing']);

/** What each purpose is, for the Settings list: who it serves and whether it runs by itself. */
const INFO = Object.freeze({
  updates: Object.freeze({ owner: 'khayt', automatic: true }),
  'install-count': Object.freeze({ owner: 'khayt', automatic: true }),
  'crash-reports': Object.freeze({ owner: 'khayt', automatic: true }),
  'usage-stats': Object.freeze({ owner: 'khayt', automatic: true }),
  cloud: Object.freeze({ owner: 'both', automatic: true }),
  makerrun: Object.freeze({ owner: 'khayt', automatic: false }),
  catalogues: Object.freeze({ owner: 'khayt', automatic: false }),
  storage: Object.freeze({ owner: 'shop', automatic: true }),
  messaging: Object.freeze({ owner: 'shop', automatic: true }),
  webhooks: Object.freeze({ owner: 'shop', automatic: true }),
  payments: Object.freeze({ owner: 'shop', automatic: true }),
  ai: Object.freeze({ owner: 'shop', automatic: false }),
  'tax-authority': Object.freeze({ owner: 'shop', automatic: false }),
  'exchange-rates': Object.freeze({ owner: 'shop', automatic: false }),
  lookups: Object.freeze({ owner: 'shop', automatic: false }),
  tunnel: Object.freeze({ owner: 'shop', automatic: false }),
  lan: Object.freeze({ owner: 'shop', automatic: true }),
});

const isPlain = (o) => !!o && typeof o === 'object' && !Array.isArray(o);

function hostRanges() {
  const g = root && root.KhaytHostRanges;
  if (g) return g;
  if (typeof require === 'function') {
    try { require('./printer-host.js'); } catch (_) { /* numeric IPv4 then reads as public: fails closed */ }
    try { return require('./host-ranges.js'); } catch (_) { return null; }
  }
  return null;
}

/** The host as a bare, lower-case name: brackets off an IPv6 literal, nothing else touched. */
function bareHost(h) {
  return String(h == null ? '' : h).trim().replace(/^\[/, '').replace(/\]$/, '').toLowerCase();
}

/**
 * On the shop's own network: a private, loopback or link-local address
 * (lib/host-ranges.js isBlockedHost, the same list that keeps webhooks off
 * the LAN), or a name only the LAN can answer: `.local` (mDNS, how a Prusa
 * or a U1 is found) or a single label (`octopi`) the LAN's own DNS resolves.
 */
function isLanHost(host) {
  const h = bareHost(host);
  if (!h || h.length > 253) return false;
  if (h.endsWith('.local') || h === 'local') return true;
  if (h.indexOf('.') === -1 && h.indexOf(':') === -1 && /^[a-z0-9-]+$/.test(h) && !/^\d+$/.test(h)) return true;
  const HR = hostRanges();
  return !!(HR && typeof HR.isBlockedHost === 'function' && HR.isBlockedHost(h));
}

/** The purposes kept while offline: only real ids, never 'lan', each once. */
function keptOf(settings) {
  const net = isPlain(settings) && isPlain(settings.network) ? settings.network : null;
  const keep = net && Array.isArray(net.keep) ? net.keep : [];
  const out = [];
  for (const k of keep) if (typeof k === 'string' && k !== 'lan' && PURPOSES.indexOf(k) !== -1 && out.indexOf(k) === -1) out.push(k);
  return out;
}

function shopOffline(settings) {
  return isPlain(settings) && isPlain(settings.network) && settings.network.offline === true;
}

function allowed(settings, purpose, ctx) {
  const c = isPlain(ctx) ? ctx : {};
  const local = isPlain(c.local) ? c.local : {};
  const out = (ok, reason) => ({ allowed: ok, reason, purpose: typeof purpose === 'string' ? purpose : String(purpose) });
  if (typeof purpose !== 'string' || PURPOSES.indexOf(purpose) === -1) return out(false, 'unknown-purpose');
  const offlineHere = local.offline === true;
  if (purpose === 'lan') {
    // The book not read yet does not stop a printer poll on the LAN, but it
    // does stop one to the internet: unknown reads as offline.
    const offline = offlineHere || !isPlain(settings) || shopOffline(settings);
    if (!offline) return out(true, 'lan');
    if (!bareHost(c.host)) return out(false, 'lan-host-missing');
    return isLanHost(c.host) ? out(true, 'lan') : out(false, 'lan-host-public');
  }
  if (!isPlain(settings)) return out(false, 'settings-unknown');
  if (offlineHere) return out(false, 'offline-here');
  const offline = shopOffline(settings);
  if (offline && keptOf(settings).indexOf(purpose) === -1) return out(false, 'offline');
  const tel = isPlain(settings.telemetry) ? settings.telemetry : {};
  if (purpose === 'crash-reports' && tel.crashOptIn !== true) return out(false, 'opted-out');
  if (purpose === 'usage-stats' && tel.usageOptIn !== true) return out(false, 'opted-out');
  if (purpose === 'install-count' && local.installCountOff === true) return out(false, 'opted-out');
  return out(true, offline ? 'kept' : 'ok');
}

/** One row per purpose, in order: what the Settings list draws. */
function describe(settings, ctx) {
  const kept = keptOf(settings);
  return PURPOSES.map((p) => {
    const r = p === 'lan' ? { allowed: true, reason: 'lan' } : allowed(settings, p, ctx);
    return { purpose: p, allowed: r.allowed, reason: r.reason, kept: kept.indexOf(p) !== -1,
      automatic: INFO[p].automatic, owner: INFO[p].owner };
  });
}

/** The effective switch for this computer: the shop's, or this computer's own. */
function isOffline(settings, ctx) {
  const local = isPlain(ctx) && isPlain(ctx.local) ? ctx.local : {};
  return local.offline === true || shopOffline(settings);
}

const api = { PURPOSES, REASONS, INFO, allowed, describe, isOffline, isLanHost, keptOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (root) root.KhaytOutbound = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
