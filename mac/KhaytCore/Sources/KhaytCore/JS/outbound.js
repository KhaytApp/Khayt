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
 * included (D1), the online store among them (`storefront`, round 2). Printers, cameras and phones on the shop's own network are
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
 *        'switch-sync' is kept by its own rule, never by `keep`: only when
 *        settings.network.via is 'cloud' and dropSwitchSync is not true
 *   6. the purpose's own switch says no → blocked, 'opted-out'
 *        crash-reports: settings.telemetry.crashOptIn must be true
 *        usage-stats:   settings.telemetry.usageOptIn must be true
 *        install-count: ctx.local.installCountOff must not be true (D3: per computer)
 *   7. otherwise allowed, 'kept' while offline, else 'ok'
 *
 * ONE switch-sync call a PERSON started (answering "Use the newer setting"
 * while nothing keeps switch-sync): the host makes a token when the person
 * answers, `answerToken(now)`, and passes it as `ctx.answer` with `ctx.now`.
 * At step 5 a LIVE token turns a 'switch-sync' 'offline' into allowed,
 * 'kept', `once: true`; the host must then keep `spend(token)` in its place,
 * so it is used once. It never opens anything else:
 *   - only 'switch-sync' (any other purpose ignores it);
 *   - only against the SHOP's switch: step 4 ('offline-here', this
 *     computer's own switch) comes first, so a computer offline by its own
 *     switch makes no call; nor 'settings-unknown';
 *   - live for ANSWER_MS from `at`, by the clock the host hands in: a token
 *     from the future, one stretched past ANSWER_MS, or one already spent is
 *     dead.
 * The desktop's main process and the Mac's gate hold the token; it is never
 * an IPC or a request field, so a window or a phone cannot make one.
 *
 * The switch only takes away: keeping a purpose does not opt the shop in to
 * it. Whether an integration is SET UP (an SMTP host, an S3 key) stays at the
 * call site. Blocked telemetry is dropped, not queued (D5): that is the
 * sender's business, and it must not grow a backlog on 'offline'.
 *
 * Pure, self-contained and JavaScriptCore-safe: no other module, no Node API.
 */
(function (root) {

const PURPOSES = Object.freeze(['updates', 'install-count', 'crash-reports', 'usage-stats', 'cloud', 'makerrun',
  'catalogues', 'storage', 'messaging', 'webhooks', 'payments', 'storefront', 'ai', 'tax-authority', 'exchange-rates',
  'lookups', 'tunnel', 'switch-sync', 'lan']);

/** How long a person's answer lets one switch-sync call through (ms). */
const ANSWER_MS = 20000;

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
  // The shop's online store (Turki, Nov 22 round 2: a purpose of its own,
  // "Online store", keepable like the others). The Mac calls Medusa, Salla
  // and Zid itself; the desktop publishes its catalogue, delivery dates and
  // store figures through Khayt Cloud's storefront routes. Automatic: the
  // delivery date is published every 6 h, and the Mac fetches store orders.
  storefront: Object.freeze({ owner: 'shop', automatic: true }),
  ai: Object.freeze({ owner: 'shop', automatic: false }),
  'tax-authority': Object.freeze({ owner: 'shop', automatic: false }),
  'exchange-rates': Object.freeze({ owner: 'shop', automatic: false }),
  lookups: Object.freeze({ owner: 'shop', automatic: false }),
  tunnel: Object.freeze({ owner: 'shop', automatic: false }),
  // The ONE call an offline computer keeps (Turki, Nov 22): GET Khayt Cloud's
  // /network-switch at start and every 15 min, only to hear the switch turned
  // off. Allowed while offline only when the switch came THROUGH Khayt Cloud
  // (`settings.network.via === 'cloud'`: applied from the route, or sent there
  // by this computer) and the row is not unticked (`settings.network.dropSwitchSync`).
  // A computer offline by its own switch or by the LAN alone makes no call.
  'switch-sync': Object.freeze({ owner: 'khayt', automatic: true, every: '15m' }),
  lan: Object.freeze({ owner: 'shop', automatic: true }),
});

const isPlain = (o) => !!o && typeof o === 'object' && !Array.isArray(o);

/**
 * The host a caller holds, as a bare lower-case name or literal: callers keep
 * `printerApi.host` with a scheme or a port (`http://192.168.1.40:7125`), so
 * both come off. Null when it cannot be one host: userinfo (`a@b`), a path,
 * whitespace inside, or nothing left.
 */
function bareHost(h) {
  let s = String(h == null ? '' : h).trim().toLowerCase();
  if (!s || s.length > 300) return null;
  const scheme = s.indexOf('://');
  if (scheme !== -1) s = s.slice(scheme + 3);
  if (s.endsWith('/')) s = s.slice(0, -1);
  if (/[@/?#\s\\]/.test(s)) return null;
  if (s.startsWith('[')) {                              // [v6] or [v6]:port
    const close = s.indexOf(']');
    if (close === -1) return null;
    const rest = s.slice(close + 1);
    if (rest && !(/^:\d{1,5}$/.test(rest) && +rest.slice(1) <= 65535)) return null;
    s = s.slice(1, close);
  } else if (s.indexOf(':') === s.lastIndexOf(':') && s.indexOf(':') !== -1) {   // name:port or v4:port
    const [hostPart, port] = s.split(':');
    if (!/^\d{1,5}$/.test(port) || +port > 65535) return null;
    s = hostPart;
  }
  const zone = s.indexOf('%');                          // fe80::1%en0
  if (zone !== -1 && s.indexOf(':') !== -1) s = s.slice(0, zone);
  if (s.endsWith('.')) s = s.slice(0, -1);              // a fully-qualified trailing dot
  return s || null;
}

/** Every IPv4 spelling a connect() accepts (dotted, 1-3 parts, hex, octal) as four octets, or null. */
function ipv4(h) {
  if (!/^[0-9a-fx.]+$/.test(h)) return null;
  const parts = h.split('.');
  if (parts.length > 4) return null;
  const nums = [];
  for (const p of parts) {
    let n;
    if (/^0x[0-9a-f]+$/.test(p)) n = parseInt(p, 16);
    else if (/^0[0-7]+$/.test(p)) n = parseInt(p, 8);
    else if (/^\d+$/.test(p)) n = parseInt(p, 10);
    else return null;
    if (!Number.isFinite(n) || n < 0) return null;
    nums.push(n);
  }
  const last = nums.pop();
  if (nums.some((n) => n > 255)) return null;
  const rem = 4 - nums.length;
  if (last > Math.pow(256, rem) - 1) return null;
  const bytes = nums.slice();
  for (let i = rem - 1; i >= 0; i--) bytes.push(Math.floor(last / Math.pow(256, i)) % 256);
  return bytes;
}

/** The shop's own network by ADDRESS: private, loopback, link-local, CGNAT/Tailscale, multicast, broadcast. */
function lanV4([a, b]) {
  return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168)
    || (a === 169 && b === 254) || (a === 100 && b >= 64 && b <= 127) || (a >= 224 && a <= 239)
    || (a === 255);
}

/** IPv6 literal on the shop's network: ::1, fe80::/10, fc00::/7, ff00::/8, or an IPv4-mapped LAN address. */
function lanV6(h) {
  if (h.indexOf(':') === -1 || !/^[0-9a-f:.]+$/.test(h)) return false;
  if ((h.match(/::/g) || []).length > 1) return false;
  if (h === '::1') return true;
  const mapped = /^(?:0{0,4}:){0,5}(?:0{0,4}::?)?ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(h) || /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/.exec(h);
  if (mapped) { const v4 = ipv4(mapped[1]); return !!(v4 && lanV4(v4)); }
  const hex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(h);
  if (hex) { const n = parseInt(hex[1], 16) * 65536 + parseInt(hex[2], 16); return lanV4([Math.floor(n / 16777216) % 256, Math.floor(n / 65536) % 256]); }
  const first = h.split(':')[0];
  if (!/^[0-9a-f]{1,4}$/.test(first) || h.indexOf(':') === h.length - 1) return false;
  const w = parseInt(first, 16);
  return (w & 0xffc0) === 0xfe80 || (w & 0xfe00) === 0xfc00 || (w & 0xff00) === 0xff00;
}

/** Names only the shop's network answers: mDNS `.local`, the routers' `.lan`, `.home.arpa`, `.internal`, `localhost`. */
const LAN_SUFFIXES = ['.local', '.lan', '.home.arpa', '.internal'];

/**
 * On the shop's own network, decided by an ALLOW-list of addresses and names
 * (security review of #2626: lib/host-ranges.js isBlockedHost is a deny-list
 * that errs toward "blocked", and its prefix tests let `fcc.gov` and
 * `fdroid.org` through as if they were IPv6 ULAs). A number is judged only as
 * an address, whatever its spelling (`0x08080808` is 8.8.8.8). A single label
 * (`octopi`) must start with a letter.
 *
 * BY NAME ONLY. A name can still resolve somewhere public (a hostile LAN DNS,
 * a search domain that expands `octopi`, a dotless top-level domain). The
 * sender that makes a `lan` call while offline must resolve the name, require
 * EVERY answer to pass lanV4/lanV6, and connect to the address it checked
 * (design §1.2; lib/host-guard.js does the same walk the other way round).
 */
function isLanHost(host) {
  const h = bareHost(host);
  if (!h) return false;
  const v4 = ipv4(h);
  if (v4) return lanV4(v4);
  if (h.indexOf(':') !== -1) return lanV6(h);
  if (/^[0-9a-fx.]+$/.test(h)) return false;            // looks numeric but is no address: refuse
  if (!/^[a-z0-9.-]+$/.test(h)) return false;
  if (h === 'localhost' || h.endsWith('.localhost')) return true;
  for (const suf of LAN_SUFFIXES) if (h.endsWith(suf) && h.length > suf.length) return true;
  return h.indexOf('.') === -1 && /^[a-z][a-z0-9-]{0,62}$/.test(h);
}

/**
 * Whether the switch-sync call is kept while offline: the switch came through
 * Khayt Cloud and the row is not unticked. It is never in `keep` (the sealed
 * value's `keep` comes from another computer, and this choice is this
 * computer's): a `keep` entry for it is ignored.
 */
function switchSyncKept(settings) {
  const net = isPlain(settings) && isPlain(settings.network) ? settings.network : null;
  return !!net && net.via === 'cloud' && net.dropSwitchSync !== true;
}

/** The purposes kept while offline: only real ids, never 'lan', each once; switch-sync by its own rule. */
function keptOf(settings) {
  const net = isPlain(settings) && isPlain(settings.network) ? settings.network : null;
  const keep = net && Array.isArray(net.keep) ? net.keep : [];
  const out = [];
  for (const k of keep) if (typeof k === 'string' && k !== 'lan' && k !== 'switch-sync' && PURPOSES.indexOf(k) !== -1 && out.indexOf(k) === -1) out.push(k);
  if (switchSyncKept(settings)) out.push('switch-sync');
  return out;
}

/**
 * Anything present that is not exactly `false` reads as OFFLINE (security
 * review of #2626): a form or an older client that wrote "true", 1 or an
 * object meant "off", and reading it as online failed open. Missing is today's
 * behaviour (online).
 */
const onSwitch = (v) => v !== undefined && v !== null && v !== false;
/**
 * The same rule one level up (Mac review of #2626): a `settings.network` that
 * is PRESENT but not an object ("x", true, false, [], a number, null) is a
 * block something wrote wrong, and reads as OFFLINE with nothing kept. Only a
 * missing block is today's behaviour (online).
 */
function shopOffline(settings) {
  if (!isPlain(settings) || settings.network === undefined) return false;
  if (!isPlain(settings.network)) return true;
  return onSwitch(settings.network.offline);
}

function allowed(settings, purpose, ctx) {
  const c = isPlain(ctx) ? ctx : {};
  const local = isPlain(c.local) ? c.local : {};
  const out = (ok, reason) => ({ allowed: ok, reason, purpose: typeof purpose === 'string' ? purpose : String(purpose) });
  if (typeof purpose !== 'string' || PURPOSES.indexOf(purpose) === -1) return out(false, 'unknown-purpose');
  const offlineHere = onSwitch(local.offline);
  if (purpose === 'lan') {
    // The book not read yet does not stop a printer poll on the LAN, but it
    // does stop one to the internet: unknown reads as offline.
    const offline = offlineHere || !isPlain(settings) || shopOffline(settings);
    if (!offline) return out(true, 'lan');
    if (c.host === undefined || c.host === null || String(c.host).trim() === '') return out(false, 'lan-host-missing');
    return isLanHost(c.host) ? out(true, 'lan') : out(false, 'lan-host-public');
  }
  if (!isPlain(settings)) return out(false, 'settings-unknown');
  if (offlineHere) return out(false, 'offline-here');
  const offline = shopOffline(settings);
  if (offline && keptOf(settings).indexOf(purpose) === -1) {
    if (purpose === 'switch-sync' && answerLive(c.answer, c.now)) return Object.assign(out(true, 'kept'), { once: true });
    return out(false, 'offline');
  }
  const tel = isPlain(settings.telemetry) ? settings.telemetry : {};
  if (purpose === 'crash-reports' && tel.crashOptIn !== true) return out(false, 'opted-out');
  if (purpose === 'usage-stats' && tel.usageOptIn !== true) return out(false, 'opted-out');
  if (purpose === 'install-count' && local.installCountOff === true) return out(false, 'opted-out');
  return out(true, offline ? 'kept' : 'ok');
}

/** A person's answer, made by the host when they answer (see the header). */
function answerToken(now) {
  const t = typeof now === 'number' && Number.isFinite(now) ? now : NaN;
  return Object.freeze({ purpose: 'switch-sync', at: t, until: t + ANSWER_MS, spent: false });
}

/** The same token, used: what the host keeps after an allowed `once`. */
function spend(token) {
  return Object.freeze(Object.assign({}, isPlain(token) ? token : {}, { spent: true }));
}

/** Whether `token` still lets one switch-sync call through at `now`. */
function answerLive(token, now) {
  if (!isPlain(token) || token.purpose !== 'switch-sync' || token.spent !== false) return false;
  const at = token.at, until = token.until;
  if (typeof now !== 'number' || !Number.isFinite(now)) return false;
  if (typeof at !== 'number' || typeof until !== 'number' || !Number.isFinite(at) || !Number.isFinite(until)) return false;
  if (until - at > ANSWER_MS || until <= at) return false;   // stretched or empty
  return now >= at && now < until;                            // not from the future, not expired
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
  return onSwitch(local.offline) || shopOffline(settings);
}

const api = Object.freeze({ PURPOSES, REASONS, INFO, ANSWER_MS, allowed, describe, isOffline, isLanHost, keptOf, switchSyncKept,
  answerToken, spend, answerLive });
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (root) root.KhaytOutbound = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
