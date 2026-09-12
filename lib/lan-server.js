'use strict';

const http = require('http');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const {
  renderLanQuoteApprovalPage,
  applyQuoteApprovalToStore,
  isQuoteExpired,
  ensureQuoteApprovalToken,
  verifyOrderAccessToken,
  verifyQuoteApprovalToken,
} = require('./lan-quote-page');
const { prepareStatusHtmlForServe } = require('./status-html');
// The phone and the quote page are readers like any other, and a shop that
// writes neither English nor Arabic was invisible to both.
const KhaytContentLanguages = require('./content-languages.js');
// The desktop's own costing maths, reused rather than reimplemented. A second
// implementation would mean two different costs for one part, and the wrong one
// would be whichever the shop happened to be looking at.
const KhaytCost = require('./calculator-cost.js');
// ...and the cost→price maths, extracted out of build.js for exactly this: so a
// quote from the phone is the same arithmetic the calculator screen runs.
const KhaytPricing = require('./pricing.js');
// …and the file → numbers → price path, so a customer's uploaded model is
// costed by exactly the same code as a part the shop types in by hand.
const { intake: intakeModel } = require('./model-intake.js');
const storefrontOrders = require('./storefront-orders.js');
const { publicQuote } = require('./public-quote.js');
const { estimateFromStl, fromSettings: estimatorFromSettings } = require('./stl-estimate.js');
const KhaytCalibration = require('./estimate-calibration.js');
const { allocateActuals } = require('./order-file-link.js');
// The shelf's own rule for what a spool IS. This endpoint composed the record
// itself for years — its own allowlist, its own idea of what was left — which
// is how `spoolWeight` reached every spool added at the desk and none added
// from the phone, and how the phone's own temperatures were dropped in silence.
// A spool booked in at the shelf is now the same object as one typed at the
// desk, because it is made by the same function.
const KhaytSpoolEdit = require('./spool-edit.js');

/**
 * Estimator options for a customer-facing quote: the shop's settings, plus the
 * throughput its own measured jobs imply. Same inputs the shop's calculator
 * uses, so the two cannot disagree about the same part.
 */
function publicEstimatorOpts(store) {
  const s = (store && store.settings) || {};
  const opts = estimatorFromSettings(s);
  const cal = KhaytCalibration.calibrate((store && store.printLog) || [], { allocate: allocateActuals }, {});
  return KhaytCalibration.applyCalibration(opts, cal);
}
const { createEstimateLedger } = require('./estimate-ledger.js');

/**
 * The shop's calendar day. NOT `toISOString().slice(0,10)`, which is UTC and so
 * names the wrong day for part of every day: in Riyadh (UTC+3) from local
 * midnight to 03:00 it returns YESTERDAY, and in New York (UTC-4) after 20:00 it
 * returns TOMORROW.
 *
 * That matters more here than in most places. An order taken through the LAN
 * intake at 01:00 local was DATED yesterday, and that field is what
 * revenue-by-day analytics group on, so the money landed on the wrong day.
 * Quote expiry was written in UTC as well, and the kiosk count of work
 * "completed today" covered the wrong set of hours.
 *
 * renderer/util.js standardised on this form and a test bans the UTC one there;
 * lib sat outside that guard until now.
 */
function localDay(d = new Date()) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

function lanEscapeHtml(s) {
  return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function safeTokenEqual(a, b) {
  if (!a || !b) return false;
  try {
    const ba = Buffer.from(String(a)), bb = Buffer.from(String(b));
    if (ba.length !== bb.length) return false;
    return crypto.timingSafeEqual(ba, bb);
  } catch { return false; }
}

// ── Webhook replay guard ─────────────────────────────────────────────────────
// Salla/Zid sign each delivery (HMAC) but do not reliably send a timestamp or
// event-id header we can window on, so we keep a small bounded in-memory LRU of
// recently-seen signatures and drop exact duplicates. This stops naive replay
// of a captured valid delivery without breaking a legitimate single delivery.
// The cache is per-process (cleared on restart) and capped in size.
const SEEN_WEBHOOK_SIG_MAX = 500;
const SEEN_WEBHOOK_TTL_MS = 10 * 60_000;
const _seenWebhookSigs = new Map(); // signature -> expiry epoch ms

function isReplayedWebhook(signature, now = Date.now()) {
  const sig = String(signature || '');
  if (!sig) return false; // unsigned requests are rejected upstream by HMAC check
  // Evict expired entries (constant TTL ⇒ insertion order == expiry order).
  for (const [k, exp] of _seenWebhookSigs) {
    if (exp <= now) _seenWebhookSigs.delete(k);
  }
  if (_seenWebhookSigs.has(sig)) return true;
  _seenWebhookSigs.set(sig, now + SEEN_WEBHOOK_TTL_MS);
  while (_seenWebhookSigs.size > SEEN_WEBHOOK_SIG_MAX) {
    _seenWebhookSigs.delete(_seenWebhookSigs.keys().next().value);
  }
  return false;
}

// ── Global brute-force backstop (tunnel mode) ────────────────────────────────
// The per-IP lockout keys off X-Forwarded-For, which a remote attacker behind
// the tunnel can spoof to dodge the per-IP counter. This module-level throttle
// is a coarse second line of defence: once too many auth attempts fail globally
// within the window, ALL auth attempts are blocked for a cooldown. It only
// engages while the tunnel is active (LAN-only deployments keep the per-IP
// behaviour untouched).
const GLOBAL_THROTTLE_LIMIT = 50;            // failed attempts before the gate trips
const GLOBAL_THROTTLE_WINDOW_MS = 60_000;    // rolling window for counting failures
const GLOBAL_THROTTLE_COOLDOWN_MS = 60_000;  // how long all attempts stay blocked
const _globalAuthThrottle = { count: 0, windowStart: 0, blockedUntil: 0 };

/**
 * Pure helper for the global failed-attempt backstop. Mutates and reads `state`
 * (a `{ count, windowStart, blockedUntil }` object) so it is trivially testable.
 *
 * @param {object} state    persistent throttle state
 * @param {number} now      current epoch ms
 * @param {boolean} failed  whether this attempt was a failed auth
 * @param {object} [opts]   { limit, windowMs, cooldownMs }
 * @returns {boolean} true when the request should be blocked (gate is tripped)
 */
/**
 * Drop expired lockout buckets, and hard-cap the map.
 *
 * failedAttempts entries were only ever deleted by a SUCCESSFUL auth on that exact key.
 * The key is a client id derived from X-Forwarded-For in tunnel mode, which the caller
 * controls — so rotating it left one permanent entry per request and grew the main
 * process without bound. Cheap: called only on a failed attempt.
 */
/**
 * Count one failed auth attempt into a rolling window and return the new record.
 *
 * THE BUG THIS REPLACES, because it is worth not reinventing: every lockout in
 * this file used to read
 *
 *   const count = (now >= rec.resetAt ? 0 : rec.count) + 1;
 *   set({ count, resetAt: count >= 10 ? now + LOCKOUT_MS : rec.resetAt });
 *
 * `resetAt` starts at 0, and it was only ever advanced once `count` reached the
 * limit — but `count` could never reach the limit, because `now >= 0` is always
 * true and reset it to 0 on every single attempt. The counter sat at 1 forever:
 * it could not lock out because it never counted, and it never counted because
 * it was not locked out. Every brute-force lockout in the LAN server was inert,
 * including the one on the owner PIN.
 *
 * The window therefore has to open on the FIRST failure, not on the last one.
 * Reaching the limit then restarts the clock from the offending attempt, so a
 * lockout is a full cooldown rather than whatever remained of the window.
 *
 * @param {object|undefined} prev  existing `{ count, resetAt }`, if any
 * @param {number} now             epoch ms
 * @param {object} [opts]          { limit, lockoutMs }
 * @returns {{count: number, resetAt: number}} the record to store
 */
function bumpFailure(prev, now, opts = {}) {
  const limit = Math.max(1, opts.limit ?? 10);
  const lockoutMs = Math.max(1, opts.lockoutMs ?? 60_000);
  const rec = prev || { count: 0, resetAt: 0 };
  const expired = now >= (rec.resetAt || 0);
  const count = (expired ? 0 : rec.count || 0) + 1;
  let resetAt = expired ? now + lockoutMs : rec.resetAt;
  if (count >= limit) resetAt = now + lockoutMs;
  return { count, resetAt };
}

/** Companion read for {@link bumpFailure}: is this bucket currently locked out? */
function isLockedOut(rec, now, limit = 10) {
  return !!rec && now < (rec.resetAt || 0) && (rec.count || 0) >= limit;
}

function sweepFailedAttempts(map, now, maxKeys = 5000) {
  for (const [k, v] of map) {
    if (!v || now >= (v.resetAt || 0)) map.delete(k);
  }
  // Still too big (a burst inside one lockout window): drop oldest-inserted first.
  if (map.size > maxKeys) {
    const excess = map.size - maxKeys;
    let i = 0;
    for (const k of map.keys()) {
      if (i++ >= excess) break;
      map.delete(k);
    }
  }
  return map.size;
}

/**
 * Rolling-window gate that counts EVERY call, not just failed ones.
 *
 * `globalAuthThrottle` above only counts failed auth. An estimate request is not
 * an auth attempt and it always succeeds, so it never touches that gate — yet it
 * is the most expensive thing an anonymous caller can ask this server to do
 * (read up to 32 MB, then parse a mesh on Electron's main thread). Behind the
 * tunnel the per-IP limit is keyed on X-Forwarded-For, so rotating that header
 * hands the caller a fresh hourly allowance on every request and the per-IP
 * bound stops being a bound at all. This gate is keyed on nothing, which is
 * precisely why a spoofed key cannot move it.
 *
 * No cooldown: unlike a brute-force gate there is nothing to punish here, so it
 * simply stops accepting until the window rolls.
 *
 * @param {object} state  persistent `{ count, windowStart }`
 * @param {number} now    epoch ms
 * @param {object} [opts] { limit, windowMs }
 * @returns {boolean} true when this call should be REFUSED
 */
function globalWindowGate(state, now, opts = {}) {
  const limit = Math.max(1, opts.limit ?? 120);
  const windowMs = Math.max(1, opts.windowMs ?? 3_600_000);
  if (now - state.windowStart > windowMs) {
    state.windowStart = now;
    state.count = 0;
  }
  if (state.count >= limit) return true;
  state.count += 1;
  return false;
}

function globalAuthThrottle(state, now, failed, opts = {}) {
  const limit = opts.limit ?? GLOBAL_THROTTLE_LIMIT;
  const windowMs = opts.windowMs ?? GLOBAL_THROTTLE_WINDOW_MS;
  const cooldownMs = opts.cooldownMs ?? GLOBAL_THROTTLE_COOLDOWN_MS;
  // Still inside an active cooldown → block regardless of this attempt.
  if (now < state.blockedUntil) return true;
  if (!failed) return false;
  // Reset the rolling window if it has elapsed.
  if (now - state.windowStart > windowMs) {
    state.windowStart = now;
    state.count = 0;
  }
  state.count += 1;
  if (state.count >= limit) {
    state.blockedUntil = now + cooldownMs;
    state.count = 0;
    state.windowStart = now;
    return true;
  }
  return false;
}

/**
 * Returns a human-readable warning when tunnel mode is on and the PIN is too
 * weak to expose to the public internet, or null when it is acceptable. Does
 * not block — callers surface this as advice only.
 */
function weakTunnelPinWarning(pin, tunnelActive) {
  if (!tunnelActive) return null;
  const p = String(pin || '');
  if (p.length < 6 || (/^\d+$/.test(p) && p.length < 8)) {
    return 'LAN PIN is weak for remote tunnel exposure — use at least 8 characters mixing letters and digits.';
  }
  return null;
}

/**
 * Resolve the effective client IP for rate-limiting / lockouts.
 * Behind the localtunnel every request arrives from a loopback socket, which
 * would collapse all remote users into a single bucket — so when the tunnel is
 * active we trust the tunnel hop's X-Forwarded-For first entry instead.
 */
function tunnelClientIp(directIp, xffHeader, tunnelActive) {
  const direct = String(directIp || '');
  if (tunnelActive && /^(::1|::ffff:127\.|127\.)/.test(direct)) {
    const xff = String(xffHeader || '').split(',')[0].trim();
    if (xff) return xff;
  }
  return direct;
}

/** JSON-encode a value for safe embedding inside an inline <script> block. */
function scriptSafeJson(value) {
  return JSON.stringify(value)
    .replace(/</g, '\\u003c')
    .replace(/>/g, '\\u003e')
    .replace(/&/g, '\\u0026');
}

function uniqueLanId(prefix) {
  return `${prefix}-${Date.now()}-${crypto.randomBytes(2).toString('hex')}`;
}

/**
 * What the write path TAKES OFF THE WIRE. Not the same list as the fields a
 * spool ends up with: `id` and `purchasedAt` are the server's to decide, not
 * the caller's — see the POST handler for why the shop's clock outranks the
 * phone's.
 */
const LAN_SPOOL_FIELDS = new Set([
  'material', 'brand', 'color', 'colour', 'cost', 'weight', 'weightTotal', 'weightRemaining',
  'vendor', 'notes', 'materialType', 'lot', 'filament', 'reorderPoint', 'colourVariant',
  // Off the label or the NFC tag. The companion has a camera and a tag reader
  // largely to read these three, sent them from the first version, and had them
  // dropped here every time because this list never named them.
  'sku', 'printTemp', 'bedTemp',
]);

/** @param {Record<string, unknown>} raw */
function pickLanSpoolFields(raw) {
  const spool = {};
  for (const key of LAN_SPOOL_FIELDS) {
    const v = raw[key];
    if (v === undefined || v === null) continue;
    if (typeof v === 'string') spool[key] = v.trim().slice(0, 500);
    else if (typeof v === 'number' && Number.isFinite(v)) spool[key] = v;
  }
  return spool;
}

/**
 * Receipt images, identified by their first bytes rather than by what the caller
 * says they are.
 *
 * A filename or a content-type is a claim; magic bytes are evidence. Accepting a
 * declared type would let anything at all be written into the app's storage
 * directory under a name the desktop will happily hand to `shell.openPath`.
 */
const RECEIPT_MAGIC = [
  { ext: 'jpg', bytes: [0xFF, 0xD8, 0xFF] },
  { ext: 'png', bytes: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] },
  { ext: 'pdf', bytes: [0x25, 0x50, 0x44, 0x46] },          // %PDF
];

/** The extension implied by a buffer's own header, or null if it is not one we take. */
function sniffReceiptType(buf) {
  if (!Buffer.isBuffer(buf)) return null;
  for (const { ext, bytes } of RECEIPT_MAGIC) {
    if (buf.length >= bytes.length && bytes.every((b, i) => buf[i] === b)) return ext;
  }
  return null;
}

/**
 * A filename that cannot escape its directory or collide.
 *
 * Generated, never derived from the caller: a name that came in over the network
 * is how "../../" and overwriting someone else's file happen. The extension
 * comes from the sniffed type, not from anything supplied.
 */
function receiptFilename(ext) {
  return `receipt-${Date.now().toString(36)}-${crypto.randomBytes(4).toString('hex')}.${ext}`;
}

/**
 * What a spool looks like on the way OUT.
 *
 * Writes have always gone through an allowlist; reads returned `store.inventory`
 * verbatim. The asymmetry meant every field the desktop ever adds to a spool is
 * published the moment it exists — nobody has to decide, or even notice. Over
 * the tunnel this endpoint is reachable from the internet behind one PIN, so
 * "whatever happens to be on the record" is the wrong default even though the
 * caller is the owner.
 *
 * The rule is deliberate symmetry: **return what the API accepts**, plus the few
 * extra fields the companion genuinely reads (`KhaytModels.swift`). A field the
 * API never accepted is not something a caller can be relying on having written.
 *
 * Dropped by this, all pre-existing store fields: `supplier`, `invoice`,
 * `costPerGram` — and, more to the point, anything added later. Automation using
 * an `inventory:read` token loses those three; everything the write path accepts
 * still round-trips.
 */
const LAN_SPOOL_READ_FIELDS = new Set([
  ...LAN_SPOOL_FIELDS,
  'id',           // every consumer keys on it
  'remaining',    // the companion's preferred name for weightRemaining
  'purchasedAt',  // written by the server, read by everyone
  'spoolWeight',  // what it weighed on arrival, so cost per kilo has a divisor
  'addedAt',
]);

/** @param {Record<string, unknown>} raw */
function pickLanSpoolRead(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const out = {};
  for (const key of LAN_SPOOL_READ_FIELDS) {
    const v = raw[key];
    if (v === undefined) continue;
    out[key] = v;
  }
  return out;
}

/** @param {unknown} v */
function sanitizeLanHttpUrl(v) {
  if (typeof v !== 'string') return undefined;
  const s = v.trim().slice(0, 500);
  if (!s) return undefined;
  try {
    const u = new URL(s);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return undefined;
    return u.href;
  } catch {
    return undefined;
  }
}

function setLanHtmlSecurityHeaders(res) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader(
    'Content-Security-Policy',
    "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'",
  );
}

/** Prefer Wi‑Fi/LAN IPv4 (192.168.x) over VPN 10.x when showing URLs to users. */
function pickLanIPv4(ifaces) {
  const candidates = [];
  for (const [name, addrs] of Object.entries(ifaces || {})) {
    for (const a of addrs || []) {
      const fam = a.family;
      if (fam !== 'IPv4' && fam !== 4) continue;
      if (a.internal) continue;
      const ip = a.address;
      const p = ip.split('.').map(Number);
      if (p.length !== 4 || p.some(n => Number.isNaN(n))) continue;
      let score = 0;
      if (/^en\d/i.test(name)) score += 20;
      if (/^(wlan|wifi|eth|enp|wlp)/i.test(name)) score += 15;
      if (p[0] === 192 && p[1] === 168) score += 40;
      else if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) score += 30;
      else if (p[0] === 10) score += 12;
      else score += 5;
      candidates.push({ ip, score });
    }
  }
  candidates.sort((a, b) => b.score - a.score);
  return candidates[0]?.ip || '127.0.0.1';
}

function parseRequestCookies(req) {
  const header = req.headers.cookie || '';
  return Object.fromEntries(header.split(';').map(part => {
    const idx = part.indexOf('=');
    if (idx < 0) return [part.trim(), ''];
    return [part.slice(0, idx).trim(), decodeURIComponent(part.slice(idx + 1).trim())];
  }).filter(([k]) => k));
}

function normalizePrinterEvent(body) {
  if (typeof body.topic === 'string') {
    const t = body.topic.toLowerCase();
    if (t.includes('done') || t.includes('finished') || t.includes('complete')) return 'print_done';
    if (t.includes('started') || t.includes('start')) return 'print_started';
    if (t.includes('cancel') || t.includes('fail') || t.includes('error')) return 'print_cancelled';
  }
  if (typeof body.event === 'string') {
    const e = body.event.toLowerCase();
    if (e.includes('done') || e.includes('complete') || e.includes('finish')) return 'print_done';
    if (e.includes('start')) return 'print_started';
    if (e.includes('cancel') || e.includes('fail') || e.includes('error')) return 'print_cancelled';
    return body.event;
  }
  if (typeof body.state === 'string') {
    const s = body.state.toLowerCase();
    if (s === 'complete' || s === 'completed' || s === 'standby') return 'print_done';
    if (s === 'printing') return 'print_started';
    if (s === 'cancelled' || s === 'error') return 'print_cancelled';
  }
  return null;
}

function registerLanServer(deps) {
  const {
    fs,
    ipcMain,
    BrowserWindow,
    safeJsonParse,
    syncLanServerStoreFromDisk,
    resolveStoreSecret,
    isStoreSecretMasked,
    migrateLanApiSecrets,
    ensureLanIntakeToken,
    ensureLanIntakePin,
    ensureLanCalendarToken,
    writeStoreToDisk,
    persistLanStoreUpdate,
    updateStoreOnDisk,
    getLanServerStore,
    setLanServerStore,
    getMainWindow,
    statusPagesDir,
    appRoot,
    getPrinterStatusCache,
    receiptsDir,
  } = deps;
  const printerCache = typeof getPrinterStatusCache === 'function' ? getPrinterStatusCache : () => ({});
  const STORE = getLanServerStore;

// ── LAN Tunnel (localtunnel) ─────────────────────────────────────────────────
let _tunnelInstance = null;

ipcMain.handle('hub:start-tunnel', async (_e, arg) => {
  const opts = (arg && typeof arg === 'object') ? arg : { port: arg };
  const { port, acknowledgedRisk } = opts;
  if (!acknowledgedRisk) {
    return { ok: false, error: 'Tunnel risk acknowledgement required' };
  }
  syncLanServerStoreFromDisk();
  const lanPin = resolveStoreSecret(STORE()?.settings?.lanApi?.pin, d => d?.settings?.lanApi?.pin);
  if (!lanPin) return { ok: false, error: 'Configure a LAN PIN before enabling remote tunnel' };
  if (_tunnelInstance) {
    try { _tunnelInstance.close(); } catch {}
    _tunnelInstance = null;
  }
  syncLanServerStoreFromDisk();
  const ownerPin = STORE()?.settings?.lanApi?.pin || '';
  if (!ownerPin || isStoreSecretMasked(ownerPin)) {
    return { ok: false, error: 'Set an owner LAN PIN before enabling the remote tunnel' };
  }
  if (!lanServer) {
    return { ok: false, error: 'Start the LAN server before enabling the tunnel' };
  }
  // REFUSE to start the tunnel when the PIN is too weak for public internet
  // exposure. (LAN-only mode never reaches here and keeps its existing
  // behaviour — weak PINs are tolerated on a trusted local network.)
  const pinWarning = weakTunnelPinWarning(lanPin, true);
  if (pinWarning) return { ok: false, error: pinWarning };
  const portNum = parseInt(port, 10) || (lanServer?.address?.()?.port) || 3219;
  try {
    const localtunnel = require('localtunnel');
    const tunnel = await localtunnel({ port: portNum });
    _tunnelInstance = tunnel;
    tunnel.on('error', (err) => {
      _tunnelInstance = null;
      if (getMainWindow() && !getMainWindow().isDestroyed())
        getMainWindow().webContents.send('tunnel-status-changed', { active: false, error: String(err) });
    });
    tunnel.on('close', () => {
      _tunnelInstance = null;
      if (getMainWindow() && !getMainWindow().isDestroyed())
        getMainWindow().webContents.send('tunnel-status-changed', { active: false });
    });
    return { ok: true, url: tunnel.url };
  } catch (e) {
    return { ok: false, error: String(e) };
  }
});

ipcMain.handle('hub:stop-tunnel', async () => {
  if (_tunnelInstance) {
    try { _tunnelInstance.close(); } catch {}
    _tunnelInstance = null;
  }
  return { ok: true };
});

ipcMain.handle('hub:get-tunnel-url', async () => {
  if (!_tunnelInstance) return { ok: false };
  return { ok: true, url: _tunnelInstance.url };
});

// ── Feature R12-7: Embedded LAN REST API ────────────────────────────────────
let lanServer = null;

ipcMain.handle('hub:start-lan-server', async (_e, { port = 3219, pin = '', bindLan = 'loopback' } = {}) => {
  const portNum = parseInt(port, 10);
  if (!Number.isInteger(portNum) || portNum < 1024 || portNum > 65535) {
    return { ok: false, error: 'Invalid port number (must be 1024–65535)' };
  }
  port = portNum;
  syncLanServerStoreFromDisk();
  if (!STORE() || !Object.keys(STORE()).length) setLanServerStore({});
  migrateLanApiSecrets(STORE());
  const storedPin = STORE()?.settings?.lanApi?.pin || '';
  if (!pin || isStoreSecretMasked(pin)) pin = storedPin;
  pin = String(pin || '').slice(0, 256); // cap PIN length to prevent DoS via giant string comparisons
  let intakeTokenGenerated = false;
  let intakePinGenerated = false;
  let calendarTokenGenerated = false;
  let intakePinValue = '';
  let intakeTokenValue = '';
  let calendarTokenValue = '';
  try {
    const tokResult = ensureLanIntakeToken(STORE());
    if (tokResult.generated) intakeTokenGenerated = true;
    intakeTokenValue = tokResult.token;
    const pinResult = ensureLanIntakePin(STORE());
    if (pinResult.generated) intakePinGenerated = true;
    intakePinValue = pinResult.pin; // plaintext — returned to renderer for display
    const calResult = ensureLanCalendarToken(STORE());
    if (calResult.generated) calendarTokenGenerated = true;
    calendarTokenValue = calResult.token;
    if (intakeTokenGenerated || intakePinGenerated || calendarTokenGenerated) await writeStoreToDisk(STORE());
  } catch (e) {
    console.error('ensureLanIntakeToken/ensureLanIntakePin failed:', e);
  }
  const bindHost = (bindLan === 'lan' || bindLan === 'all') ? '0.0.0.0' : '127.0.0.1';
  if (lanServer) {
    if (_tunnelInstance) {
      try { _tunnelInstance.close(); } catch {}
      _tunnelInstance = null;
    }
    lanServer.close();
    lanServer = null;
  }
  // Brute-force tracking: { ip -> { count, resetAt } }
  const failedAttempts = new Map();
  // Evict expired buckets. Entries were previously removed only on a successful auth for
  // that exact key, so every distinct (spoofable) client id left a permanent entry — a
  // remote memory-exhaustion DoS through the tunnel. _seenWebhookSigs already sweeps; this
  // applies the same pattern. Hard cap is a last-resort backstop if sweeping cannot keep
  // up, dropping the oldest-inserted keys (Map preserves insertion order).
  const MAX_FAILED_ATTEMPT_KEYS = 5000;
  const intakePinAttempts = new Map();
  const intakeSubmitAttempts = new Map();
  const intakeSessionGrantAttempts = new Map();
  const surveyAttempts = new Map();
  const SURVEY_SUBMIT_LIMIT = 30;
  const INTAKE_SUBMIT_LIMIT = 20;
  const INTAKE_SESSION_GRANT_LIMIT = 40;
  const INTAKE_SUBMIT_WINDOW_MS = 60 * 60 * 1000;
  const intakeSessions = new Map();
  const INTAKE_COOKIE = 'khayt_intake';
  // Public model pricing (R5). Deliberately its own limits: this route parses a
  // mesh, which is far more expensive per request than recording a form, and it
  // accepts a body two orders of magnitude larger than any other public route.
  const ESTIMATE_MAX_BYTES = 32 * 1024 * 1024;
  // Per IP per window. A shop that publishes its intake form widely can raise
  // this; the default is deliberately low because each request parses a mesh.
  const ESTIMATE_LIMIT_DEFAULT = 12;
  const estimateAttempts = new Map();
  // How many uploads may be held in memory at once, across every caller. The
  // per-IP limit above bounds requests per hour; it does not bound how many
  // 32 MB bodies are buffered simultaneously, and 20 concurrent uploads is
  // 640 MB in the main process regardless of anybody's hourly allowance. This
  // is the only one of the three bounds a spoofed X-Forwarded-For cannot move.
  const ESTIMATE_MAX_IN_FLIGHT = 3;
  // Above this, a customer upload is priced but NOT analysed for print risk.
  //
  // The mesh analysis needs the triangle list, and a triangle list is several
  // times the size of the file it came from: a binary STL is 50 bytes per
  // triangle on the wire and roughly 200 as JavaScript objects. Letting that run
  // on the full 32 MB cap would take the worst case this bound was chosen for —
  // 3 × 32 MB ≈ 96 MB — past 600 MB, on an endpoint that answers strangers.
  //
  // 8 MB is about 160k triangles, so three of them add ~120 MB rather than
  // ~570 MB. Bigger uploads still get their price; they just do not get the
  // triage, which is the right thing to drop under pressure.
  const ESTIMATE_RISK_MAX_BYTES = 8 * 1024 * 1024;
  let estimatesInFlight = 0;
  // Tunnel-mode backstop for the per-IP limit, which is keyed on a header the
  // caller controls once the tunnel is up. See globalWindowGate.
  const _globalEstimateGate = { count: 0, windowStart: 0 };
  // What the server told a given visitor, so the figure attached to their
  // submitted request is OUR number and not one their browser posted back to us.
  const estimateLedger = createEstimateLedger({ newId: () => uniqueLanId('est') });
  const INTAKE_SESSION_MS = 4 * 60 * 60 * 1000;
  const LOCKOUT_MS = 60_000;     // 1-minute lockout after 10 failures
  const MAX_BODY   = 1_048_576; // 1 MB body limit
  // Raised for /api/expense ONLY, and nothing else: a phone photo is a few MB
  // before base64 adds a third on top, and it does not fit the limit that suits
  // a JSON payload. Two numbers rather than one, so the decoded image is capped
  // even if the transport somehow is not.
  const MAX_RECEIPT_BYTES = 6 * 1_048_576;                 // the image itself
  const MAX_RECEIPT_BODY  = Math.ceil(MAX_RECEIPT_BYTES * 4 / 3) + 8192; // + base64 + JSON
  const parseLanJsonBody = (body, fallback = {}) => {
    const raw = String(body || '').trim();
    if (!raw) return fallback;
    return safeJsonParse(raw);
  };
  const quoteExpiredHtml = () => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Quote Expired</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Quote expired</h2><p>This quote is no longer valid. Please contact the shop for an updated quote.</p></body></html>`;
  return new Promise(resolve => {
    try {
      lanServer = http.createServer((req, res) => {
        // Set ONCE, for every response, before any route runs.
        //
        // These were applied per-route, at sixteen call sites, and the page that
        // matters most had been missed: GET /intake — the intake form itself,
        // the one page a shop hands to its customers and the only public surface
        // that takes their input — went out with no CSP, no X-Frame-Options, no
        // nosniff and no Referrer-Policy, while the quote and tracking pages had
        // all four. So did the 429 shown when intake sessions are rate-limited,
        // and five of the quote-approval error pages.
        //
        // Nothing was wrong with any of the sixteen calls. The defect is that
        // the protection was OPT-IN: a route that forgets is a route that ships
        // unprotected, and it looks exactly like a route that did not need it.
        // The same shape as everything else found this week — a guard that is
        // absent rather than broken, and therefore silent.
        //
        // Applying to JSON responses too is deliberate rather than sloppy:
        // nosniff and DENY are correct on an API response as well, and a CSP on
        // JSON constrains nothing that was going to run anyway.
        setLanHtmlSecurityHeaders(res);
        const url = new URL(req.url, `http://localhost:${port}`);
        const ip = tunnelClientIp(req.socket.remoteAddress, req.headers['x-forwarded-for'], !!_tunnelInstance);
        const isWriteRequest = req.method !== 'GET' && req.method !== 'HEAD';
        const rawPathname = url.pathname.replace(/\/$/, '');
        // `/v1` is the documented, versioned public surface (KHAYT-3.0-PUBLIC-API-SPEC §1).
        // It maps onto exactly the same handlers as the long-standing `/api` routes, which
        // remain a permanent alias for the iOS companion and the PWA/kiosk callers.
        const isV1 = rawPathname === '/v1' || rawPathname.startsWith('/v1/');
        const pathname = isV1 ? ('/api' + rawPathname.slice(3)) : rawPathname;

        // Routes that are always public regardless of PIN configuration.
        // NOTE: /order/:id/approve POST is public (quote → pending only).
        // Legacy POST /order/:id with {action:"approve"} is also public for compatibility.
        const isIntakePublicGet = pathname === '/intake' && req.method === 'GET';
        const isIntakeSessionPost = pathname === '/api/intake/session' && req.method === 'POST';
        const isIntakeSubmitPost = pathname === '/api/intake' && req.method === 'POST';
        // Same standing as the intake submit: reachable without the shop's PIN
        // (a customer does not have one) but still gated on an intake session.
        const isIntakeEstimatePost = pathname === '/api/intake/estimate' && req.method === 'POST';
        const isQuoteApprovePost = req.method === 'POST' && /^\/order\/[^/]+\/approve$/.test(pathname);
        const isLegacyQuoteApprovePost = req.method === 'POST' && /^\/order\/[^/]+$/.test(pathname);
        const isQuotePageGet = req.method === 'GET' && /^\/order\/[^/]+\/quote$/.test(pathname);
        const isAlwaysPublic = pathname === '/api/status' ||
          (pathname.startsWith('/order/') && req.method === 'GET') ||
          isQuoteApprovePost || isLegacyQuoteApprovePost || isQuotePageGet ||
          pathname === '/manifest.json' || pathname === '/sw.js' ||
          pathname === '/icon-192.png' || pathname === '/icon-512.png' ||
          pathname === '/icon-maskable-512.png' ||
          pathname.startsWith('/api/webhook/printer/') ||
          pathname === '/api/webhook/salla' ||
          pathname === '/api/webhook/zid' ||
          pathname === '/api/webhook/smsa' ||
          pathname === '/api/webhook/aramex' ||
          pathname === '/api/webhook/spl';
        const isSurveyEndpoint = pathname === '/api/survey' && req.method === 'POST';

        // ── Scoped API tokens (automation) ────────────────────────────────
        // Additive to the PIN: humans and the iOS app keep using x-khayt-pin; automation
        // sends `Authorization: Bearer khayt_…`. A token grants ONLY its scopes — a
        // read-scoped token on a write is 403, never silently allowed. Tokens are stored
        // hashed, so verification is a constant-time hash compare.
        let apiTokenRec = null;
        // A token only stands in for the owner PIN on routes that are part of the scope
        // model AND whose scope it holds. On an unscoped route (a page, the kiosk shell)
        // it must NOT widen access — the PIN still applies. Without this, a token scoped
        // to e.g. machines:read could fetch any PIN-gated page.
        let apiTokenScoped = false;
        // Reuse the existing per-IP brute-force bucket for bad bearer tokens (10/min → 429),
        // keyed separately so it can't be confused with PIN failures.
        const apiTokKey = ip + ':apitok';
        const isApiTokenLocked = () => {
          return isLockedOut(failedAttempts.get(apiTokKey), Date.now());
        };
        const recordApiTokenFailure = () => {
          const now = Date.now();
          const d = failedAttempts.get(apiTokKey) || { count: 0, resetAt: 0 };
          failedAttempts.set(apiTokKey, bumpFailure(d, now, { lockoutMs: LOCKOUT_MS }));
          sweepFailedAttempts(failedAttempts, now, MAX_FAILED_ATTEMPT_KEYS);
        };
        if (!isAlwaysPublic) {
          let ApiTokens = null;
          try { ApiTokens = require('./api-tokens.js'); } catch (_) { ApiTokens = null; }
          const bearer = ApiTokens ? ApiTokens.bearerFromHeader(req.headers['authorization']) : null;
          if (bearer) {
            if (isApiTokenLocked()) {
              res.writeHead(429, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
              return;
            }
            const tokens = (STORE().settings && STORE().settings.lanApi && STORE().settings.lanApi.apiTokens) || [];
            apiTokenRec = ApiTokens.verifyToken(bearer, tokens);
            if (!apiTokenRec) {
              recordApiTokenFailure();
              res.writeHead(401, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'invalid_token' }));
              return;
            }
            const need = ApiTokens.requiredScope(isV1 ? rawPathname : pathname.replace('/api', '/v1'), req.method);
            apiTokenScoped = !!(need && ApiTokens.hasScope(apiTokenRec, need));
            if (need && !ApiTokens.hasScope(apiTokenRec, need)) {
              res.writeHead(403, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'insufficient_scope', required: need }));
              return;
            }
            // NOTE: lastUsedAt is intentionally not stamped here — persisting it would mean
            // a store write on every API request. Left for a future batched/throttled update.
          }
        }

        const requirePin = isWriteRequest && !isSurveyEndpoint && !isAlwaysPublic && !isIntakeSessionPost && !isIntakeSubmitPost && !isIntakeEstimatePost;
        if (!apiTokenScoped && !isAlwaysPublic && !isIntakePublicGet && !isIntakeSessionPost && !isIntakeSubmitPost && !isIntakeEstimatePost && (requirePin || (pin && !isSurveyEndpoint))) {
          const provided = (url.searchParams.get('pin') || req.headers['x-khayt-pin'] || '').trim();
          if (!pin) {
            // No PIN configured — block all write requests (survey is exempt via isSurveyEndpoint)
            if (isWriteRequest) {
              res.writeHead(403, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Write requests require a PIN to be configured in settings' }));
              return;
            }
          } else {
            // Brute-force lockout check
            const now = Date.now();
            const tunnelActive = !!_tunnelInstance;
            // Global backstop (tunnel mode only): if the gate is already tripped,
            // block every auth attempt regardless of (spoofable) per-IP bucket.
            if (tunnelActive && globalAuthThrottle(_globalAuthThrottle, now, false)) {
              res.writeHead(429, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
              return;
            }
            const ipData = failedAttempts.get(ip) || { count: 0, resetAt: 0 };
            if (now < ipData.resetAt && ipData.count >= 10) {
              res.writeHead(429, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
              return;
            }
            if (!safeTokenEqual(provided, pin)) {
              failedAttempts.set(ip, bumpFailure(ipData, now, { lockoutMs: LOCKOUT_MS }));
              sweepFailedAttempts(failedAttempts, now, MAX_FAILED_ATTEMPT_KEYS);
              // Feed the global backstop too; trips the cooldown after enough failures.
              if (tunnelActive && globalAuthThrottle(_globalAuthThrottle, now, true)) {
                res.writeHead(429, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
                return;
              }
              res.writeHead(401, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Unauthorized' }));
              return;
            }
            failedAttempts.delete(ip); // reset on success
          }
        }
        const store = STORE();
        // H4: restrict CORS — sensitive API routes get no wildcard, and the
        // reflected origin is limited to loopback / LAN hosts (the only legit
        // browser callers, e.g. the intake portal). A non-LAN http:// origin is
        // no longer echoed back. Non-browser clients (Electron IPC, iOS native,
        // curl) send no Origin and don't need CORS.
        const reqOrigin = req.headers['origin'] || null;
        const corsOriginAllowed = (origin) => {
          let host;
          try { host = new URL(origin).hostname; } catch { return false; }
          if (host === 'localhost' || host === '127.0.0.1' || host === '::1' || host.endsWith('.local')) return true;
          return /^10\./.test(host) || /^192\.168\./.test(host) ||
            /^172\.(1[6-9]|2\d|3[01])\./.test(host) || /^169\.254\./.test(host);
        };
        const isPublicRoute = isAlwaysPublic;
        if (isPublicRoute) {
          res.setHeader('Access-Control-Allow-Origin', '*');
        } else if (reqOrigin && corsOriginAllowed(reqOrigin)) {
          res.setHeader('Access-Control-Allow-Origin', reqOrigin);
        }
        if (!isIntakePublicGet) res.setHeader('Content-Type', 'application/json');

        // H3: helper to enforce PIN for sensitive GET routes
        const getIntakePin = () => STORE()?.settings?.lanApi?.intakePin || '';
        const getIntakeToken = () => STORE()?.settings?.lanApi?.intakeToken || '';
        // Every per-IP bucket below is keyed on `ip`, which is the first
        // X-Forwarded-For entry once the tunnel is up — a value the caller sets.
        // That has two consequences, and only the first was handled before:
        // rotating the header dodges the count, and it also leaves one Map entry
        // per request that nothing ever deleted, because these buckets were only
        // rewritten by the same key coming back. `failedAttempts` had exactly
        // this bug and got sweepFailedAttempts; these four are the same shape and
        // never called it. Sweeping on write is cheap and keeps the fix in one
        // place instead of four.
        const bumpRate = (map, limit) => {
          const now = Date.now();
          const rec = map.get(ip) || { count: 0, resetAt: now + INTAKE_SUBMIT_WINDOW_MS };
          if (now >= rec.resetAt) { rec.count = 0; rec.resetAt = now + INTAKE_SUBMIT_WINDOW_MS; }
          if (rec.count >= limit) return false;
          rec.count += 1;
          map.set(ip, rec);
          sweepFailedAttempts(map, now, MAX_FAILED_ATTEMPT_KEYS);
          return true;
        };
        const checkIntakeSubmitRate = () => bumpRate(intakeSubmitAttempts, INTAKE_SUBMIT_LIMIT);
        const checkEstimateRate = () => {
          const limit = Math.max(1, Math.min(10000,
            +(STORE()?.settings?.lanApi?.intakeQuote?.hourlyLimit) || ESTIMATE_LIMIT_DEFAULT));
          if (!bumpRate(estimateAttempts, limit)) return false;
          // Second bound, keyed on nothing. The per-IP allowance above is only a
          // bound while the key is honest; behind the tunnel it is not, so
          // without this an attacker rotating X-Forwarded-For gets a fresh 12
          // every request and the route is effectively unlimited. LAN-only
          // shops never reach this — their key is the real socket address.
          if (_tunnelInstance && globalWindowGate(_globalEstimateGate, Date.now(), {
            limit: Math.max(60, limit * 10), windowMs: INTAKE_SUBMIT_WINDOW_MS,
          })) return false;
          return true;
        };
        const rememberEstimate = (result) => estimateLedger.remember(result, ip);
        const recallEstimate = (ref) => estimateLedger.recall(ref, ip);
        const checkSurveyRate = () => bumpRate(surveyAttempts, SURVEY_SUBMIT_LIMIT);
        const checkIntakeSessionGrantRate = () => bumpRate(intakeSessionGrantAttempts, INTAKE_SESSION_GRANT_LIMIT);
        const getCalendarToken = () => STORE()?.settings?.lanApi?.calendarToken || '';
        // Sessions were only ever dropped when their OWN token came back and was
        // found expired, so a caller that takes a cookie and never reuses it
        // leaves an entry for the life of the process. Deliberately not
        // sweepFailedAttempts: these entries carry `created`, not `resetAt`, and
        // that helper treats a missing resetAt as "expired" — it would empty the
        // map and sign every visitor out on the next grant.
        const sweepIntakeSessions = (now) => {
          for (const [tok, sess] of intakeSessions) {
            if (!sess || now - sess.created > INTAKE_SESSION_MS) intakeSessions.delete(tok);
          }
        };
        const validateIntakeSession = (token, clientIp) => {
          const sess = intakeSessions.get(token);
          if (!sess) return false;
          if (Date.now() - sess.created > INTAKE_SESSION_MS) {
            intakeSessions.delete(token);
            return false;
          }
          if (clientIp && sess.ip && sess.ip !== clientIp) return false;
          return true;
        };
        const hasIntakeSession = (request, clientIp) => {
          const cookies = parseRequestCookies(request);
          const token = cookies[INTAKE_COOKIE];
          return token && validateIntakeSession(token, clientIp);
        };
        const checkIntakePost = (request) => {
          if (hasIntakeSession(request, ip)) return true;
          const intakeTok = getIntakeToken();
          const providedIntake = (request.headers['x-khayt-intake-token'] || '').trim();
          if (intakeTok && providedIntake && safeTokenEqual(providedIntake, intakeTok)) return true;
          return false;
        };
        const isWebhookAuthLocked = (channel) => {
          const key = `${ip}:wh:${channel}`;
          const ipData = failedAttempts.get(key) || { count: 0, resetAt: 0 };
          return isLockedOut(ipData, Date.now());
        };
        const recordWebhookAuthFailure = (channel) => {
          const key = `${ip}:wh:${channel}`;
          const now = Date.now();
          const ipData = failedAttempts.get(key) || { count: 0, resetAt: 0 };
          failedAttempts.set(key, bumpFailure(ipData, now, { lockoutMs: LOCKOUT_MS }));
          sweepFailedAttempts(failedAttempts, now, MAX_FAILED_ATTEMPT_KEYS);
        };
        const intakeSharedStyles = '*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',sans-serif;min-height:100vh;padding:24px 16px}.container{max-width:520px;margin:0 auto}.header{text-align:center;margin-bottom:28px}.header h1{font-size:1.5rem;font-weight:700;color:#f1f5f9;margin-bottom:4px}.header p{color:#94a3b8;font-size:.9rem}.card{background:#1e293b;border-radius:16px;padding:24px;margin-bottom:16px}.form-group{margin-bottom:16px}label{display:block;font-size:.8rem;font-weight:600;color:#94a3b8;margin-bottom:6px;text-transform:uppercase;letter-spacing:.05em}input,textarea,select{width:100%;background:#0f172a;color:#e2e8f0;border:1px solid #334155;border-radius:8px;padding:10px 12px;font-size:.9rem;outline:none;transition:border-color .2s}input:focus,textarea:focus,select:focus{border-color:#6366f1}textarea{resize:vertical;min-height:100px}select option{background:#1e293b}.req{color:#f87171}button[type=submit]{width:100%;background:#6366f1;color:#fff;border:none;border-radius:10px;padding:13px;font-size:1rem;font-weight:600;cursor:pointer;transition:background .2s}button[type=submit]:hover{background:#4f46e5}button[type=submit]:disabled{background:#334155;cursor:not-allowed}.thankyou{display:none;text-align:center;padding:40px 24px}.thankyou h2{font-size:1.3rem;color:#6366f1;margin-bottom:12px}.thankyou p{color:#94a3b8;line-height:1.6}.error-msg{color:#f87171;font-size:.8rem;margin-top:6px;display:none}';
        // The budget ranges are money shown to a CUSTOMER, so they carry the
        // shop's own currency. They used to say SAR unconditionally — not a
        // fallback, a literal — which is simply wrong for the USD flavour, every
        // time, for every customer who opens the form. Unknown currency shows the
        // numbers bare rather than naming the wrong one.
        //
        // The option VALUES ("<100", "100-500", …) are deliberately untouched:
        // they are stored on the intake record, and rewriting them would orphan
        // every request already taken.
        const renderIntakeFormPage = (shopName, currency, quoteEnabled) => `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Intake — ${shopName}</title><style>${intakeSharedStyles}</style></head><body><div class="container"><div class="header"><h1>${shopName}</h1><p>Submit a new order request</p></div><div class="card"><form id="intakeForm"><div class="form-group"><label>Name <span class="req">*</span></label><input type="text" name="name" required maxlength="200" placeholder="Your full name"></div><div class="form-group"><label>Email</label><input type="email" name="email" maxlength="500" placeholder="your@email.com"></div><div class="form-group"><label>Phone</label><input type="tel" name="phone" maxlength="500" placeholder="+966 5x xxx xxxx"></div>${quoteEnabled ? '<div class="form-group"><label>Your 3D model <span style="font-weight:400;color:#6b7280;">(optional — get an indicative price now)</span></label><input type="file" id="modelFile" accept=".stl,.obj,.3mf,.gcode,.gco"><div id="modelResult" style="display:none;margin-top:8px;padding:10px 12px;border-radius:8px;font-size:.9rem;line-height:1.5;"></div><p style="margin:6px 0 0;font-size:.78rem;color:#6b7280;">Your file is read to work out a price and is not stored. We will ask for it again if you go ahead.</p></div>' : ''}<div class="form-group"><label>Project Description <span class="req">*</span></label><textarea name="description" required maxlength="2000" placeholder="Describe your 3D printing project in detail..."></textarea></div><div class="form-group"><label>Reference / Link</label><input type="url" name="referenceLink" maxlength="500" placeholder="https://..."></div><div class="form-group"><label>Preferred Material</label><input type="text" name="material" maxlength="500" placeholder="e.g. PLA, PETG, Resin"></div><div class="form-group"><label>Budget Range</label><select name="budget"><option value="">— Select —</option><option value="&lt;100">Less than 100${currency ? ' ' + currency : ''}</option><option value="100-500">100 – 500${currency ? ' ' + currency : ''}</option><option value="500-1000">500 – 1,000${currency ? ' ' + currency : ''}</option><option value="1000+">1,000+${currency ? ' ' + currency : ''}</option></select></div><div class="form-group"><label>Preferred Due Date</label><input type="date" name="dueDate" maxlength="500"></div><div class="form-group" style="margin-top:4px;"><label style="display:flex;align-items:flex-start;gap:8px;font-weight:400;cursor:pointer;"><input type="checkbox" name="consent" id="intakeConsent" required style="width:auto;margin:3px 0 0;"><span style="font-size:.85rem;line-height:1.5;">I agree that ${shopName} may store my contact details to process this request. Your details are kept by ${shopName} and are not sold or shared. You may ask them to access or delete your data at any time.</span></label></div><div class="error-msg" id="errMsg">An error occurred. Please try again.</div><button type="submit">Submit Request</button></form><div class="thankyou" id="thankYou"><h2>Thank you!</h2><p>Your request has been received. We'll get back to you as soon as possible.</p></div></div></div><script>var estimateRef='';var mf=document.getElementById('modelFile');if(mf){mf.addEventListener('change',async function(){var box=document.getElementById('modelResult');var f=this.files&&this.files[0];estimateRef='';if(!f){box.style.display='none';return;}
var say=function(html,bg,fg){box.innerHTML=html;box.style.background=bg;box.style.color=fg;box.style.display='block';};
if(f.size>32*1024*1024){say('That file is larger than 32 MB — send it to us another way and we will price it by hand.','#fef3c7','#92400e');return;}
say('Reading your model…','#f3f4f6','#374151');
try{var r=await fetch('/api/intake/estimate?name='+encodeURIComponent(f.name),{method:'POST',credentials:'include',headers:{'Content-Type':'application/octet-stream'},body:f});var j=await r.json().catch(function(){return{};});
if(!j.ok){var why={'off':'We are not quoting online just now — send your request and we will come back to you.','not-configured':'We are not quoting online just now — send your request and we will come back to you.','no-numbers':'We could not read that file. Send your request anyway and we will take a look.','unsupported':'We can read STL, OBJ, 3MF and G-code files.','too-large':'That file is too large to price here.','no-price':'We could not price that automatically. Send your request and we will come back to you.'};say(why[j.reason]||why['no-price'],'#fef3c7','#92400e');return;}
estimateRef=j.ref||'';
var money=j.price.toFixed(2)+(j.currency?(' '+j.currency):'');
var head=j.exact?('<b>About '+money+'</b>'):('<b>Roughly '+money+'</b>');
var detail=j.exact?('Based on your sliced file'+(j.slicer?(' from '+j.slicer):'')+' — about '+j.grams+' g and '+j.hours+' h of printing.'):('Estimated from the shape of your model — about '+j.grams+' g and '+j.hours+' h of printing. Nobody has sliced this file yet, so the real figure can differ.');
/* Shapes with very thin or very detailed surfaces defeat a geometric estimate: measured against a real slicer they land anywhere from +58% to -66%. Showing the usual soft caveat there would be dishonest, so this one is louder and the panel turns amber. */
var shaky=(j.reliable===false);
var warn=shaky?'<br><b>This shape is hard to price automatically</b> — thin or highly detailed models can differ a long way from this figure. Send your request and we will price it properly.':'';
say(head+'<br>'+detail+warn+'<br><span style="font-size:.8rem;">This is an indication, not a confirmed quote. We will confirm before any work starts.</span>',shaky?'#fef3c7':'#ecfdf5',shaky?'#92400e':'#065f46');}
catch(ex){say('We could not price that just now. Send your request and we will come back to you.','#fef3c7','#92400e');}});}
document.getElementById('intakeForm').addEventListener('submit',async function(e){e.preventDefault();const btn=this.querySelector('button[type=submit]');const err=document.getElementById('errMsg');err.style.display='none';btn.disabled=true;btn.textContent='Submitting…';const data={};new FormData(this).forEach((v,k)=>{if(v)data[k]=v;});data.consent=document.getElementById('intakeConsent').checked;if(estimateRef)data.estimateRef=estimateRef;try{const r=await fetch('/api/intake',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});if(r.ok){this.style.display='none';document.getElementById('thankYou').style.display='block';}else{const j=await r.json().catch(()=>({}));err.textContent=j.error||'Submission failed.';err.style.display='block';btn.disabled=false;btn.textContent='Submit Request';}}catch(ex){err.textContent='Network error. Please try again.';err.style.display='block';btn.disabled=false;btn.textContent='Submit Request';}});<\/script></body></html>`;
        const checkPinForGet = () => {
          // A token satisfies this per-route gate ONLY when the route is part of the scope
          // model and the token holds that scope (checked above). An unscoped route still
          // requires the owner PIN, so a token cannot be used to widen access.
          if (apiTokenScoped) return true;
          if (!pin) {
            // Owner/queue data requires a configured PIN — respond explicitly so the
            // socket isn't left hanging when the server runs without an owner PIN.
            res.writeHead(401, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Configure a LAN PIN in Khayt settings to access this data' }));
            return false;
          }
          const provided = (url.searchParams.get('pin') || req.headers['x-khayt-pin'] || '').trim();
          const now = Date.now();
          const tunnelActive = !!_tunnelInstance;
          // Global backstop, mirroring the write path at :496. The per-IP bucket is keyed
          // on tunnelClientIp(), which trusts the first X-Forwarded-For entry — a value the
          // remote caller controls, so rotating it gives an attacker a fresh bucket every
          // request. The write path already blocks on the global gate for exactly this
          // reason; these PII-bearing GET routes (clients, orders, inventory, machines,
          // queue, waiting list) were left without it.
          if (tunnelActive && globalAuthThrottle(_globalAuthThrottle, now, false)) {
            res.writeHead(429, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
            return false;
          }
          const ipData = failedAttempts.get(ip) || { count: 0, resetAt: 0 };
          if (now < ipData.resetAt && ipData.count >= 10) {
            res.writeHead(429, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
            return false;
          }
          if (!safeTokenEqual(provided, pin)) {
            failedAttempts.set(ip, bumpFailure(ipData, now, { lockoutMs: LOCKOUT_MS }));
            if (tunnelActive) globalAuthThrottle(_globalAuthThrottle, now, true);
            sweepFailedAttempts(failedAttempts, now, MAX_FAILED_ATTEMPT_KEYS);
            res.writeHead(401, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Unauthorized' }));
            return false;
          }
          failedAttempts.delete(ip);
          return true;
        };

        if (pathname === '/api/status') {
          // Phones / old QRs often hit this with Accept: */* — send humans to the intake form.
          // API clients: GET /api/status?format=json
          const wantJson = url.searchParams.get('format') === 'json';
          if (req.method === 'GET' && !wantJson) {
            res.writeHead(302, { Location: '/intake', 'Cache-Control': 'no-cache' });
            res.end();
            return;
          }
          const queue = (store.printLog || []).filter(o => o.status !== 'completed');
          res.writeHead(200, { 'Content-Type': 'application/json' });
          const waitingActive = (store.waitingList || []).filter(w => w.status !== 'declined').length;
          res.end(JSON.stringify({
            queued: queue.length,
            pending:    queue.filter(o => o.status === 'pending').length,
            printing:   queue.filter(o => o.status === 'printing').length,
            post:       queue.filter(o => o.status === 'post').length,
            qc:         queue.filter(o => o.status === 'qc').length,
            completed_today: (store.printLog || []).filter(o => o.completedAt &&
              o.completedAt.startsWith(localDay())).length,
            waiting: waitingActive
          }));
        } else if (pathname === '/api/orders' && req.method === 'GET') {
          if (!checkPinForGet()) return;
          const limit = Math.min(parseInt(url.searchParams.get('limit') || '50', 10), 200);
          const status = url.searchParams.get('status');
          let orders = store.printLog || [];
          if (status) orders = orders.filter(o => o.status === status);
          orders = orders.slice(0, limit);
          res.writeHead(200);
          res.end(JSON.stringify(orders.map(o => ({
            id: o.id, project: o.project, client: o.client, status: o.status,
            material: o.material, price: o.price, dueDate: o.dueDate, date: o.date,
            paymentStatus: o.paymentStatus,
            quoteExpiresAt: o.quoteExpiresAt,
            quoteAcceptedAt: o.quoteAcceptedAt
          }))));
        } else if (pathname === '/api/orders' && req.method === 'POST') {
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const parsed = parseLanJsonBody(body);
              const project = String(parsed.project || '').trim().slice(0, 200);
              if (!project) {
                res.writeHead(400);
                res.end(JSON.stringify({ error: 'project is required' }));
                return;
              }
              const asQuote = parsed.status === 'quote';
              const validStatuses = asQuote ? ['quote'] : ['pending'];
              const status = asQuote ? 'quote' : 'pending';
              const now = new Date();
              const settings = STORE().settings || {};
              /* The SAME prefix the desktop uses — renderer/order-flows.js mints
               * `${settings.invPrefix || 'INV'}-${year}-${seq}`.
               *
               * This read `settings.orderPrefix`, a key that has never existed:
               * no default, no form field, nothing writes it. So it always fell
               * through to 'ORD', and an order raised on the phone came out
               * numbered differently from every order raised at the desk —
               * ignoring the prefix the shop had actually set. */
              const prefix = asQuote ? (settings.quotePrefix || 'QUO') : (settings.invPrefix || 'INV');
              const id = `${prefix}-${now.getFullYear()}-${Date.now()}-${crypto.randomBytes(2).toString('hex')}`;
              let clientName = String(parsed.client || '').trim().slice(0, 200) || null;
              let clientId = parsed.clientId || null;
              if (clientId) {
                const cl = (STORE().clients || []).find(c => c.id === clientId);
                // `cl.nameEn || cl.nameAr` is empty for a shop writing German or
                // Turkish, so an order raised from the phone lost the client's name
                // and fell back to whatever the phone had typed.
                if (cl) clientName = KhaytContentLanguages.read(cl, 'name', settings.lang || 'en', settings) || clientName;
              }
              const machineId = parsed.machineId || null;
              let machineName = null;
              if (machineId) {
                const m = (STORE().machines || []).find(x => x.id === machineId);
                if (!m) {
                  res.writeHead(404);
                  res.end(JSON.stringify({ error: 'Machine not found' }));
                  return;
                }
                machineName = m.name;
              }
              const price = parsed.price != null ? Math.max(0, +parsed.price) : 0;
              const order = {
                id,
                date: localDay(now),
                timestamp: now.toISOString(),
                project,
                client: clientName,
                clientId,
                material: String(parsed.material || '').trim().slice(0, 120) || null,
                price: +price.toFixed(2),
                status,
                statusHistory: [{ status, at: now.toISOString() }],
                queuePos: (STORE().printLog || []).filter(o => o.status === 'pending').length + 1,
                machineId,
                machine: machineName,
                notes: String(parsed.notes || '').trim().slice(0, 500) || '',
                dueDate: parsed.dueDate || null,
                paymentStatus: 'unpaid',
                parts: [],
              };
              if (asQuote) {
                const validityDays = settings.quoteValidityDays || 7;
                order.quoteSentAt = order.date;
                order.quoteExpiresAt = localDay(new Date(now.getTime() + validityDays * 86400000));
                order.quoteVersion = 1;
              }
              await updateStoreOnDisk((cur) => ({ ...cur, printLog: [order, ...(cur.printLog || [])] }));
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-order-created', order);
              }
              res.writeHead(201);
              res.end(JSON.stringify({ ok: true, order: {
                id: order.id, project: order.project, client: order.client,
                status: order.status, price: order.price, material: order.material,
                dueDate: order.dueDate, quoteExpiresAt: order.quoteExpiresAt
              }}));
            } catch (e) {
              res.writeHead(400);
              res.end(JSON.stringify({ error: String(e) }));
            }
          });
        } else if (pathname === '/api/queue') {
          // Owner data (client + project names): require PIN when one is configured.
          if (!checkPinForGet()) return;
          const queue = (store.printLog || []).filter(o =>
            ['pending','printing','post','qc'].includes(o.status));
          res.writeHead(200);
          res.end(JSON.stringify(queue.map(o => ({
            id: o.id, project: o.project, client: o.client, status: o.status,
            machine: o.machine, machineId: o.machineId || null,
            dueDate: o.dueDate, priority: o.priority
          }))));
        } else if (pathname === '/api/machines/live' && req.method === 'GET') {
          if (!checkPinForGet()) return;
          const cache = printerCache() || {};
          const live = (store.machines || []).map(m => {
            const s = cache[m.id] || {};
            return {
              id: m.id,
              name: m.name,
              hasPrinterApi: !!(m.printerApi?.type && m.printerApi.type !== 'none'),
              state: s.state || null,
              progress: s.progress != null ? Math.round(+s.progress) : null,
              filename: s.filename || null,
              timeRemaining: s.timeRemaining != null ? Math.round(+s.timeRemaining) : null,
              tempNozzle: s.tempNozzle != null ? Math.round(+s.tempNozzle) : null,
              tempBed: s.tempBed != null ? Math.round(+s.tempBed) : null,
              error: s.error || null,
              lastUpdated: s.lastUpdated || null,
              apiType: s.type || m.printerApi?.type || null
            };
          });
          res.writeHead(200);
          res.end(JSON.stringify(live));

        } else if (pathname === '/api/machines') {
          // Owner data (machine names): require PIN when one is configured.
          if (!checkPinForGet()) return;
          res.writeHead(200);
          res.end(JSON.stringify((store.machines || []).map(m => ({
            id: m.id, name: m.name, type: m.type, status: m.status,
            hasPrinterApi: !!(m.printerApi?.type && m.printerApi.type !== 'none')
          }))));

        // ── iOS companion: inventory ────────────────────────────
        // ── Cost a part from the phone ──────────────────────────────────────
        // A customer walks in holding a part; today that means walking back to
        // the desktop. This computes the cost with THE DESKTOP'S OWN maths
        // (lib/calculator-cost.js) against the live store, so the phone can
        // never quote a different number from the machine it is paired to.
        //
        // Scope, deliberately: this returns COST and the applicable price tier,
        // not a final customer price. Margin and VAT live inside build.js's DOM
        // rendering and are not extractable without a real refactor, and
        // reimplementing them here is precisely the divergence this endpoint
        // exists to avoid. Owner-gated: costs are not customer-facing.
        } else if (pathname === '/api/quote' && req.method === 'POST') {
          if (!checkPinForGet()) return;
          let body = '';
          req.on('data', (chunk) => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', () => {
            try {
              // `null` fallback, not the default `{}`: an empty body is a caller
              // mistake, and costing it would answer a question nobody asked
              // with a number that looks authoritative.
              const part = parseLanJsonBody(body, null);
              if (!part || typeof part !== 'object' || Array.isArray(part)) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid part payload' }));
                return;
              }
              const store = STORE() || {};
              const ctx = { inventory: store.inventory || [], settings: store.settings || {} };
              const qty = Math.max(1, Math.min(100000, +part.qty || 1));
              const unitCost = KhaytCost.computePartBaseCost({ ...part, qty }, ctx);
              const breakdown = KhaytCost.computePartBreakdown({ ...part, qty }, ctx);
              const tier = KhaytPricing.activePriceTier(part.priceTiers, qty);
              // Cost → price, through the same function the calculator screen
              // now calls. Margin and the rest come from the caller (a shop
              // types them, or pulls a product's defaultMargin); rush uses the
              // shop's own configured percentage. With no margin supplied the
              // price simply equals the cost, which is honest rather than a
              // guess at what this shop charges.
              const price = KhaytPricing.quoteTotal({
                baseCost: unitCost * qty,
                qty,
                margin: part.margin,
                priceTier: tier,
                discountPct: part.discountPct,
                rushEnabled: !!part.rush,
                rushPct: store.settings?.rushFeePct ?? 25,
                shippingCost: part.shippingCost,
                extraLines: part.extraLines,
              });
              const round = (n) => Math.round((Number.isFinite(n) ? n : 0) * 10000) / 10000;
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({
                ok: true,
                qty,
                unitCost: round(unitCost),
                totalCost: round(unitCost * qty),
                breakdown: {
                  material: round(breakdown.material),
                  machine: round(breakdown.machine),
                  labor: round(breakdown.labor),
                  buffer: round(breakdown.buffer),
                },
                // null when the part carries no tiers, or qty is below the
                // lowest one — the caller shows its own price in that case.
                priceTier: tier ? { minQty: +tier.minQty, pricePerUnit: +tier.pricePerUnit } : null,
                price: {
                  beforeDiscount: round(price.priceBeforeDiscount),
                  discount: round(price.discountAmount),
                  subtotal: round(price.subtotal),
                  rushFee: round(price.rushFee),
                  shipping: round(price.shipping),
                  extras: round(price.extras),
                  total: round(price.total),
                },
                currency: store.settings?.currency || null,
              }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Could not cost this part' }));
            }
          });

        } else if (pathname === '/api/inventory' && req.method === 'GET') {
          if (!checkPinForGet()) return;
          res.writeHead(200);
          // Projected, not dumped — see pickLanSpoolRead.
          res.end(JSON.stringify((store.inventory || []).map(pickLanSpoolRead).filter(Boolean)));

        } else if (pathname === '/api/waiting-list' && req.method === 'GET') {
          if (!checkPinForGet()) return;
          const items = (store.waitingList || []).filter(w => w.status !== 'declined');
          res.writeHead(200);
          res.end(JSON.stringify(items.map(w => ({
            id: w.id,
            project: w.project,
            clientName: w.clientName,
            notes: w.notes,
            email: w.email,
            phone: w.phone,
            material: w.material,
            priority: w.priority || 'normal',
            status: w.status || 'active',
            estValue: w.estValue ?? w.estimatedValue ?? 0,
            reminderDate: w.reminderDate,
            source: w.source,
            submittedAt: w.submittedAt || w.addedAt || w.createdAt
          }))));

        } else if (pathname === '/api/clients' && req.method === 'GET') {
          if (!checkPinForGet()) return;
          res.writeHead(200);
          const clientLang = (store.settings && store.settings.lang) || 'en';
          const clientName_ = (c) => KhaytContentLanguages.read(c, 'name', clientLang, store.settings);
          res.end(JSON.stringify((store.clients || []).map((c) => {
            /* `name` is the canonical one: resolved through the shop's own content
             * languages, so a German shop's clients have names on the phone.
             *
             * nameEn/nameAr stay because the SHIPPED companion decodes those two
             * and nothing else, and it releases on its own schedule. Where the
             * shop writes NEITHER, the resolved name goes in nameEn so that build
             * shows something instead of a blank row. Only then — a shop with real
             * English text keeps exactly what it wrote, and this projection is
             * read-only, so nothing is stored under a key it does not belong in.
             */
            const hasEnAr = !!(c.nameEn || c.nameAr);
            return {
              id: c.id,
              name: clientName_(c),
              nameEn: hasEnAr ? c.nameEn : clientName_(c),
              nameAr: c.nameAr,
              phone: c.phone,
              email: c.email,
            };
          })));

        // ── Record an expense, receipt and all ──────────────────────────────
        // A receipt is a photograph and the phone is the camera; the desktop's
        // own expense form expects a file already sitting on that machine.
        //
        // This is the first endpoint that accepts BINARY, so the care is all in
        // what it refuses:
        //   · the image is identified by its own first bytes, never by a
        //     declared type or filename — a claim is not evidence, and this
        //     writes into a directory the desktop will later shell-open;
        //   · the filename is generated here, so nothing caller-supplied can
        //     traverse out of the directory or overwrite another receipt;
        //   · the body cap is raised for this route ALONE, because a phone photo
        //     does not fit in the 1 MB that suits a JSON payload;
        //   · a failed write leaves no expense behind, so there is never a row
        //     pointing at a receipt that does not exist.
        // Owner-PIN gated by the global write rule, like every other write.
        } else if (pathname === '/api/expense' && req.method === 'POST') {
          let body = '';
          req.on('data', (chunk) => {
            if (Buffer.byteLength(body) + chunk.length > MAX_RECEIPT_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Receipt too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const raw = parseLanJsonBody(body, null);
              if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid expense payload' }));
                return;
              }
              const amount = Math.max(0, Number.isFinite(+raw.amount) ? +raw.amount : 0);
              // Mirrors the desktop form: an expense with no amount is not an
              // expense, and would sit in the ledger contributing nothing.
              if (!(amount > 0)) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Amount is required' }));
                return;
              }

              // Write the receipt FIRST. If this fails the expense is never
              // created, rather than leaving a row pointing at nothing.
              let receiptPath = null;
              if (raw.receiptBase64) {
                if (typeof receiptsDir !== 'function') {
                  res.writeHead(501, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'This desktop cannot store receipts' }));
                  return;
                }
                let buf;
                try { buf = Buffer.from(String(raw.receiptBase64), 'base64'); } catch (_) { buf = null; }
                const ext = sniffReceiptType(buf);
                if (!ext) {
                  res.writeHead(415, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'Receipt must be a JPEG, PNG or PDF' }));
                  return;
                }
                if (buf.length > MAX_RECEIPT_BYTES) {
                  res.writeHead(413, { 'Content-Type': 'application/json' });
                  res.end(JSON.stringify({ error: 'Receipt too large' }));
                  return;
                }
                const full = path.join(receiptsDir(), receiptFilename(ext));
                await fs.promises.writeFile(full, buf);
                receiptPath = full;
              }

              const str = (v, max = 500) => String(v || '').trim().slice(0, max);
              const entry = {
                id: uniqueLanId('EXP'),
                // The shop's calendar day, as everywhere else.
                date: localDay(),
                category: str(raw.category, 60) || 'other',
                amount,
                note: str(raw.note),
                orderId: str(raw.orderId, 128) || null,
                receiptPath,
                recurring: null,   // a phone capture is a one-off by definition
                nextDue: null,
                locationId: str(raw.locationId, 128) || '',
              };

              await updateStoreOnDisk((cur) => ({ ...cur, expenses: [entry, ...(cur.expenses || [])] }));
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-expense-added', { entry });
              }
              res.writeHead(201, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ ok: true, entry }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Could not record this expense' }));
            }
          });

        // ── Log a failed print, at the machine ──────────────────────────────
        // Waste gets recorded where it happens or it does not get recorded at
        // all, and unrecorded waste is exactly the number a shop most needs. The
        // desktop's own waste form is a walk back to the desk with a failed part
        // in your hand.
        //
        // Writes require the owner PIN through the global gate above (a POST is
        // a write, and this route is in no exemption list), and `waste` is not in
        // the API-token scope map, so a scoped automation token cannot reach it
        // either. Both are defaults rather than something remembered here.
        } else if (pathname === '/api/waste' && req.method === 'POST') {
          let body = '';
          req.on('data', (chunk) => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const raw = parseLanJsonBody(body, null);
              if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid waste payload' }));
                return;
              }
              const material = String(raw.material || '').trim().slice(0, 200);
              // Mirrors the desktop form, which refuses to save without one: a
              // waste entry with no material cannot be costed or reconciled
              // against a spool, so it is noise in the one report that matters.
              if (!material) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Material is required' }));
                return;
              }
              const str = (v, max = 500) => String(v || '').trim().slice(0, max);
              const pos = (v) => Math.max(0, Number.isFinite(+v) ? +v : 0);
              const entry = {
                id: uniqueLanId('w'),
                // The SHOP'S calendar day, never UTC's. A failure logged at
                // 01:00 in Riyadh belongs to that day's waste, not yesterday's.
                date: localDay(),
                material,
                failureType: str(raw.failureType, 60) || 'other',
                weight: pos(raw.weight),
                cost: pos(raw.cost),
                reason: str(raw.reason),
                notes: str(raw.notes),
                orderId: str(raw.orderId, 128) || null,
                machineId: str(raw.machineId, 128) || null,
              };

              // Same optional deduction the desktop form offers: find the spool
              // by material and take the grams off it. Opt-in, because the shop
              // may already have deducted it or be logging someone else's stock.
              //
              // The deduction is computed INSIDE the write, against the spool as it
              // stands when this write's turn comes. Computing it outside would take
              // the grams off a figure another tablet had already reduced, and the
              // second deduction would silently undo the first.
              let deducted = null;
              await updateStoreOnDisk((cur) => {
                const next = { ...cur, wasteLog: [entry, ...(cur.wasteLog || [])] };
                if (raw.deduct && entry.weight > 0) {
                  const inv = [...(cur.inventory || [])];
                  const i = inv.findIndex((f) => f && f.material === material);
                  if (i !== -1) {
                    inv[i] = { ...inv[i], weight: Math.max(0, (+inv[i].weight || 0) - entry.weight) };
                    next.inventory = inv;
                    deducted = { id: inv[i].id, weight: inv[i].weight };
                  }
                }
                return next;
              });
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-waste-logged', { entry, deducted });
              }
              res.writeHead(201, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ ok: true, entry, deducted }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Could not log this waste entry' }));
            }
          });

        } else if (pathname === '/api/inventory' && req.method === 'POST') {
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const rawSpool = parseLanJsonBody(body);
              if (!rawSpool || typeof rawSpool !== 'object' || Array.isArray(rawSpool)) {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid inventory payload' }));
                return;
              }
              const wire = pickLanSpoolFields(rawSpool);
              const settingsNow = (STORE() || {}).settings || {};
              const today = localDay();

              // A full roll arrives with one weight sent three times; a
              // part-used one arrives with two. `weightTotal` is what it weighed
              // when it arrived and never changes again; `weightRemaining` is
              // what is left and falls every time the shop prints.
              const arrived = wire.weightTotal ?? wire.weight ?? wire.weightRemaining;
              const left = wire.weightRemaining ?? wire.weightTotal ?? wire.weight;

              const made = KhaytSpoolEdit.newSpool({
                material: wire.material,
                cost: wire.cost,
                weight: arrived,
                color: wire.color || wire.colour,
                materialType: wire.materialType,
                lot: wire.lot,
              }, {
                id: uniqueLanId('spool'),
                // THE SHOP'S calendar day, not the phone's. The companion dates
                // a spool off `ISO8601DateFormatter`, which is UTC: a roll
                // booked in at 02:00 in Riyadh was shelved under yesterday.
                today,
                // The branch the desk is showing, when the caller names none —
                // and no caller names one, because the phone has no branch
                // picker.
                activeLocation: settingsNow.activeLocationId,
              });
              if (made.refused) {
                // The shelf's one refusal, now the API's too.
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'A spool needs a material' }));
                return;
              }
              const spool = made.spool;

              // Everything arrival does not set: what is LEFT of a part-used
              // roll, and the numbers read off the label. Same call the desk's
              // editor makes, so the two cannot disagree about a field again.
              //
              // `applyEdit` teaches the shop's colour library any variant it
              // has not seen by MUTATING the settings it is handed, so it gets
              // a scratch object here; the library is merged inside the write
              // below, where a read-modify-write of the store is safe.
              const { colourAdded } = KhaytSpoolEdit.applyEdit(spool, {
                weight: left,
                printTemp: wire.printTemp,
                bedTemp: wire.bedTemp,
                colourVariant: wire.colourVariant,
                reorderPoint: wire.reorderPoint,
              }, { today, settings: {} });

              // The record's own fields, which the shelf's rule has never
              // owned: who made the roll, where it came from, what it is called
              // in the supplier's catalogue.
              for (const key of ['brand', 'vendor', 'notes', 'filament', 'sku']) {
                if (wire[key] !== undefined) spool[key] = wire[key];
              }
              // `weight` is the store's word for what is left; `remaining` and
              // `weightRemaining` are the companion's, and the desktop reads
              // whichever it finds first. All three say the same thing.
              spool.remaining = spool.weight;
              spool.weightRemaining = spool.weight;
              // A caller that swaps the pair over would otherwise book in a roll
              // holding more than it ever weighed, and every cost per kilo taken
              // off it would read high for the rest of its life.
              spool.spoolWeight = Math.max(spool.spoolWeight, spool.weight);
              spool.weightTotal = spool.spoolWeight;
              spool.addedAt = new Date().toISOString();

              await updateStoreOnDisk((cur) => {
                const next = { ...cur, inventory: [...(cur.inventory || []), spool] };
                if (colourAdded) {
                  const settings = { ...(cur.settings || {}) };
                  const library = { ...(settings.filamentColours || {}) };
                  const known = library[spool.material] || [];
                  if (!known.includes(colourAdded)) {
                    library[spool.material] = [...known, colourAdded];
                    settings.filamentColours = library;
                    next.settings = settings;
                  }
                }
                return next;
              });
              // Notify renderer to reload
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-spool-added', spool);
              }
              res.writeHead(201);
              res.end(JSON.stringify({ ok: true, spool }));
            } catch (e) {
              res.writeHead(400);
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        } else if (pathname.startsWith('/api/inventory/') && (req.method === 'PATCH' || req.method === 'DELETE')) {
          const spoolId = decodeURIComponent(pathname.split('/api/inventory/')[1].split('/')[0]);
          if (!spoolId || spoolId.includes('..')) {
            res.writeHead(400);
            res.end(JSON.stringify({ error: 'Invalid spool ID' }));
            return;
          }
          if (req.method === 'DELETE') {
            (async () => {
              try {
                // The 404 is answered from the current view; the removal is redone
                // against whatever the store holds when the write's turn comes.
                const list = [...(STORE().inventory || [])];
                const idx = list.findIndex(s => s.id === spoolId);
                if (idx === -1) {
                  res.writeHead(404);
                  res.end(JSON.stringify({ error: 'Spool not found' }));
                  return;
                }
                const removed = list[idx];
                await updateStoreOnDisk((cur) => ({
                  ...cur, inventory: (cur.inventory || []).filter(s => s.id !== spoolId),
                }));
                if (getMainWindow() && !getMainWindow().isDestroyed()) {
                  getMainWindow().webContents.send('lan-spool-deleted', { id: spoolId });
                }
                res.writeHead(200);
                res.end(JSON.stringify({ ok: true, id: spoolId, spool: removed }));
              } catch (e) {
                res.writeHead(400);
                res.end(JSON.stringify({ error: String(e) }));
              }
            })();
            return;
          }
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const parsed = parseLanJsonBody(body);
              const remaining = parsed.remaining ?? parsed.weightRemaining;
              if (remaining === undefined || remaining === null || Number.isNaN(Number(remaining))) {
                res.writeHead(400);
                res.end(JSON.stringify({ error: 'remaining is required' }));
                return;
              }
              const grams = Math.max(0, Math.min(50000, Math.round(Number(remaining))));
              const view = [...(STORE().inventory || [])];
              const viewIdx = view.findIndex(s => s.id === spoolId);
              if (viewIdx === -1) {
                res.writeHead(404);
                res.end(JSON.stringify({ error: 'Spool not found' }));
                return;
              }
              /**
               * What is LEFT, in all three of its names.
               *
               * `weight` is the store's own word for it and the one every piece
               * of arithmetic uses: `order-deduction.js` takes grams off it, the
               * low-stock alert compares it, the shelf falls back to it.
               * `remaining` is the companion's word, and the only one this
               * endpoint used to write — so a shop that weighed a part-used roll
               * at the shelf saw its correction on the shelf and nowhere else.
               * The next print deducted from the figure it had just replaced.
               */
              const reweighed = (s) => {
                const next = { ...s };
                KhaytSpoolEdit.applyEdit(next, { weight: grams }, { today: localDay() });
                next.remaining = next.weight;
                next.weightRemaining = next.weight;
                return next;
              };
              const spool = reweighed(view[viewIdx]);
              // Re-find inside the write: the spool may have moved in the list, and a
              // spool deleted in between must not be resurrected by this patch.
              await updateStoreOnDisk((cur) => {
                const inv = [...(cur.inventory || [])];
                const i = inv.findIndex(s => s && s.id === spoolId);
                if (i === -1) return cur;
                inv[i] = reweighed(inv[i]);
                return { ...cur, inventory: inv };
              });
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-spool-updated', spool);
              }
              res.writeHead(200);
              res.end(JSON.stringify({ ok: true, spool }));
            } catch (e) {
              res.writeHead(400);
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        } else if (pathname.startsWith('/api/waiting-list/') && req.method === 'PATCH') {
          const itemId = decodeURIComponent(pathname.split('/api/waiting-list/')[1].split('/')[0]);
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const { status } = parseLanJsonBody(body);
              const valid = ['active', 'reminded', 'declined'];
              if (!valid.includes(status)) {
                res.writeHead(400);
                res.end(JSON.stringify({ error: 'Invalid status' }));
                return;
              }
              if (!(STORE().waitingList || []).some(w => w && w.id === itemId)) {
                res.writeHead(404);
                res.end(JSON.stringify({ error: 'Waiting list item not found' }));
                return;
              }
              const declinedAt = new Date().toISOString();
              await updateStoreOnDisk((cur) => {
                const list = [...(cur.waitingList || [])];
                const i = list.findIndex(w => w && w.id === itemId);
                if (i === -1) return cur;   // removed in between: do not bring it back
                if (status === 'declined') {
                  return {
                    ...cur,
                    waitingListHistory: [...(cur.waitingListHistory || []), { ...list[i], status: 'declined', declinedAt }],
                    waitingList: list.filter(w => w.id !== itemId),
                  };
                }
                list[i] = { ...list[i], status };
                return { ...cur, waitingList: list };
              });
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-waiting-updated', { id: itemId, status });
              }
              res.writeHead(200);
              res.end(JSON.stringify({ ok: true }));
            } catch (e) {
              res.writeHead(400);
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        } else if (pathname.match(/^\/api\/orders\/[^/]+\/quote-url$/) && req.method === 'GET') {
          if (!checkPinForGet()) return;
          const orderId = decodeURIComponent(pathname.split('/api/orders/')[1].replace('/quote-url', ''));
          const order = (store.printLog || []).find(o => o.id === orderId);
          if (!order) {
            res.writeHead(404);
            res.end(JSON.stringify({ error: 'Order not found' }));
            return;
          }
          const host = req.headers.host || 'localhost';
          const base = `http://${host}`;
          const quoteUrl = `${base}/order/${encodeURIComponent(orderId)}/quote`;
          const statusUrl = `${base}/order/${encodeURIComponent(orderId)}/status`;
          const canApprove = order.status === 'quote' || (order.status === 'on_hold' && order.hasQuote);
          res.writeHead(200);
          res.end(JSON.stringify({
            quoteUrl,
            statusUrl,
            canApprove: canApprove && !isQuoteExpired(order),
            expired: isQuoteExpired(order),
            quoteExpiresAt: order.quoteExpiresAt || null,
            alreadyApproved: order.status !== 'quote' && !!(order.quoteAcceptedAt || order.clientApprovedAt)
          }));

        } else if (pathname.match(/^\/api\/orders\/[^/]+\/approve$/) && req.method === 'POST') {
          const orderId = decodeURIComponent(pathname.split('/api/orders/')[1].replace('/approve', ''));
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              if (body.trim()) parseLanJsonBody(body);
              // Decide the answer on a throwaway copy of the current view, then redo
              // the same change inside the write so it lands on the newest store.
              const probe = { ...STORE(), printLog: [...(STORE().printLog || [])] };
              const result = applyQuoteApprovalToStore(probe, orderId);
              if (!result) {
                res.writeHead(404);
                res.end(JSON.stringify({ error: 'Order not found' }));
                return;
              }
              if (result.error === 'cannot_approve') {
                res.writeHead(409);
                res.end(JSON.stringify({ error: 'Quote cannot be approved in its current state' }));
                return;
              }
              await updateStoreOnDisk((cur) => {
                const next = { ...cur, printLog: [...(cur.printLog || [])] };
                const r = applyQuoteApprovalToStore(next, orderId);
                if (!r || r.error) return cur;   // it changed underneath us; leave it alone
                return next;
              });
              const approved = result.order;
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-order-updated', {
                  id: orderId,
                  status: approved.status,
                  clientApprovedAt: approved.clientApprovedAt,
                  quoteAcceptedAt: approved.quoteAcceptedAt,
                  quoteApproved: true,
                });
              }
              res.writeHead(200);
              res.end(JSON.stringify({ ok: true, order: {
                id: approved.id, status: approved.status,
                quoteAcceptedAt: approved.quoteAcceptedAt
              }}));
            } catch (e) {
              res.writeHead(400);
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        // ── iOS companion: update order status / machine ─────────
        } else if (pathname.startsWith('/api/orders/') && req.method === 'PATCH') {
          const orderId = decodeURIComponent(pathname.split('/api/orders/')[1].split('/')[0]);
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const { status, machineId } = parseLanJsonBody(body);
              if (!status && machineId === undefined) {
                res.writeHead(400);
                res.end(JSON.stringify({ error: 'status or machineId required' }));
                return;
              }
              const valid = ['pending','printing','post','qc','completed','on_hold'];
              if (status && !valid.includes(status)) {
                res.writeHead(400);
                res.end(JSON.stringify({ error: 'Invalid status' }));
                return;
              }
              const storeData = { ...STORE() };
              storeData.printLog = [...(STORE().printLog || [])];
              const idx = storeData.printLog.findIndex(o => o.id === orderId);
              if (idx === -1) {
                res.writeHead(404);
                res.end(JSON.stringify({ error: 'Order not found' }));
                return;
              }
              const updated = { ...storeData.printLog[idx] };
              if (status) updated.status = status;
              if (machineId !== undefined) {
                if (!machineId) {
                  updated.machineId = null;
                  updated.machine = null;
                } else {
                  const machine = (STORE().machines || []).find(m => m.id === machineId);
                  if (!machine) {
                    res.writeHead(404);
                    res.end(JSON.stringify({ error: 'Machine not found' }));
                    return;
                  }
                  updated.machineId = machineId;
                  updated.machine = machine.name;
                }
              }
              // Redo the assignment against the newest store: `updated` is a whole
              // record built from the view, so re-find it rather than trusting idx.
              await updateStoreOnDisk((cur) => {
                const log = [...(cur.printLog || [])];
                const i = log.findIndex(o => o && o.id === orderId);
                if (i === -1) return cur;   // deleted in between
                log[i] = { ...log[i], ...updated };
                return { ...cur, printLog: log };
              });
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-order-updated', {
                  id: orderId,
                  status: updated.status,
                  machineId: updated.machineId,
                  machine: updated.machine
                });
              }
              res.writeHead(200);
              res.end(JSON.stringify({ ok: true, order: {
                id: updated.id, status: updated.status,
                machineId: updated.machineId, machine: updated.machine
              }}));
            } catch (e) {
              res.writeHead(400);
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        // ── Customer survey submission (public — protected by one-time token) ──
        } else if (pathname === '/api/survey' && req.method === 'POST') {
          // Per-IP throttle: this is the one store-mutating public route without a
          // PIN gate, so cap it (like intake) to prevent token-guessing / write spam.
          if (!checkSurveyRate()) {
            res.writeHead(429, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
            res.end(JSON.stringify({ error: 'Too many attempts — try again later' }));
            return;
          }
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const parsed = parseLanJsonBody(body, {});
              if (typeof parsed.comment === 'string' && parsed.comment.length > 2000) {
                parsed.comment = parsed.comment.slice(0, 2000);
              }
              const { token, orderId, rating, comment } = parsed;
              if (!token || typeof rating !== 'number' || rating < 1 || rating > 5) {
                res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'Invalid payload — token and rating (1-5) are required' }));
                return;
              }
              const byToken = (list) => (list || []).findIndex(o => o && o.surveyToken && safeTokenEqual(o.surveyToken, token));
              if (byToken(STORE().printLog) === -1) {
                res.writeHead(404, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'Invalid or expired survey token' }));
                return;
              }
              const submittedAt = new Date().toISOString();
              await updateStoreOnDisk((cur) => {
                const log = [...(cur.printLog || [])];
                const i = byToken(log);
                if (i === -1) return cur;   // the token was spent by a concurrent submit
                log[i] = {
                  ...log[i],
                  survey: { rating, comment: (comment || '').trim(), submittedAt },
                  surveyToken: undefined,
                };
                return { ...cur, printLog: log };
              });
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-survey-submitted', {
                  orderId: storeData.printLog[idx].id,
                  rating
                });
              }
              res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ ok: true }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        } else if (pathname.match(/^\/order\/[^/]+\/quote$/) && req.method === 'GET') {
          const rawId = pathname.replace(/^\/order\//, '').replace(/\/quote$/, '');
          const safeId = rawId.replace(/[^a-zA-Z0-9_-]/g, '');
          const tokenParam = (url.searchParams.get('token') || '').trim();
          const order = (store.printLog || []).find(o => o.id === safeId);
          // A customer opening the quote saw the literal word "Khayt" as the shop
          // name unless the shop wrote English: `bizEn` is empty for a Turkish one.
          const shopName = store.settings?.shopName
            || KhaytContentLanguages.read(store.settings, 'biz', (store.settings && store.settings.lang) || 'en', store.settings)
            || 'Khayt';
          const invalidLinkHtml = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Invalid link</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Invalid link</h2><p style="color:#94a3b8;margin-top:8px;">Open the quote from the link your shop sent you.</p></body></html>`;
          setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
          res.setHeader('Cache-Control', 'no-cache');
          if (!order) {
            res.writeHead(404);
            res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Not Found</title></head><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Quote not found</h2></body></html>`);
          } else if (!order.quoteApprovalToken || !verifyQuoteApprovalToken(order, tokenParam)) {
            res.writeHead(403);
            res.end(invalidLinkHtml);
          } else {
            const alreadyApproved = order.status !== 'quote' && !(order.status === 'on_hold' && order.hasQuote);
            res.writeHead(200);
            res.end(renderLanQuoteApprovalPage({
              order,
              shopName,
              approvePath: `/order/${safeId}/approve`,
              approvalToken: order.quoteApprovalToken,
              alreadyApproved,
              expired: !alreadyApproved && isQuoteExpired(order),
              // The LAN server reads the store straight off disk, with no
              // defaultSettings() merge behind it — unlike the renderer, where
              // settings.currency is always present. Pass through what is there,
              // and let the page omit the unit rather than guess it.
              currencyLabel: store.settings?.currency || '',
            }));
          }

        } else if (pathname.match(/^\/order\/[^/]+\/approve$/) && req.method === 'POST') {
          const rawId = pathname.replace(/^\/order\//, '').replace(/\/approve$/, '');
          const safeId = rawId.replace(/[^a-zA-Z0-9_-]/g, '');
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const parsed = body.trim() ? parseLanJsonBody(body) : {};
              if (parsed.action && parsed.action !== 'approve') {
                res.writeHead(400, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid action' }));
                return;
              }
              const storeData = { ...STORE() };
              storeData.printLog = [...(STORE().printLog || [])];
              const idx = storeData.printLog.findIndex(o => o.id === safeId);
              if (idx === -1) {
                res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
                res.end(`<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Order not found</h2></body></html>`);
                return;
              }
              const approvalTok = (url.searchParams.get('token') || parsed.approvalToken || '').trim();
              if (!verifyQuoteApprovalToken(storeData.printLog[idx], approvalTok)) {
                res.writeHead(403, { 'Content-Type': 'text/html; charset=utf-8' });
                res.end(`<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Invalid link</h2><p>Open the quote page from the link your shop sent you, then approve from there.</p></body></html>`);
                return;
              }
              const result = applyQuoteApprovalToStore(storeData, safeId);
              if (!result) {
                res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
                res.end(`<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Order not found</h2></body></html>`);
                return;
              }
              if (result.error === 'expired') {
                res.writeHead(410, { 'Content-Type': 'text/html; charset=utf-8' });
                res.end(quoteExpiredHtml());
                return;
              }
              if (result.error === 'cannot_approve') {
                res.writeHead(409, { 'Content-Type': 'text/html; charset=utf-8' });
                res.end(`<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Cannot approve</h2><p>This quote is no longer awaiting approval.</p></body></html>`);
                return;
              }
              await updateStoreOnDisk((cur) => {
                const next = { ...cur, printLog: [...(cur.printLog || [])] };
                const r = applyQuoteApprovalToStore(next, safeId);
                if (!r || r.error) return cur;   // it changed underneath us
                return next;
              });
              const approved = result.order;
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-order-updated', {
                  id: safeId,
                  status: 'pending',
                  clientApprovedAt: approved.clientApprovedAt,
                  quoteAcceptedAt: approved.quoteAcceptedAt,
                  quoteApproved: true,
                });
              }
              const projectName = lanEscapeHtml(approved.project || approved.id);
              setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
              res.writeHead(200);
              res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Quote Approved</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#6366f1}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Quote Approved!</h2><p>Your approval for <strong>${projectName}</strong> has been received. We'll start working on your order shortly.</p></div></body></html>`);
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        } else if (pathname.startsWith('/status/')) {
          const rawId = path.basename(decodeURIComponent(pathname.slice('/status/'.length)).replace(/\.html$/, ''));
          const safeId = rawId.replace(/[^a-zA-Z0-9_-]/g, '');
          const order = (store.printLog || []).find(o => o.id === safeId);
          const accessTok = (url.searchParams.get('token') || '').trim();
          if (!order || !order.trackingToken || !verifyOrderAccessToken(order, accessTok, 'trackingToken')) {
            setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
            res.writeHead(403);
            res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Invalid link</title></head><body style="font-family:sans-serif;text-align:center;padding:60px;color:#666;"><h2>Invalid tracking link</h2><p>Use the tracking link your shop sent you.</p></body></html>`);
            return;
          }
          const statusDir = statusPagesDir();
          const filePath = path.join(statusDir, `order-status-${safeId}.html`);
          fs.promises.readFile(filePath, 'utf8').then(html => {
            setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
            res.setHeader('Cache-Control', 'no-cache');
            res.writeHead(200);
            res.end(prepareStatusHtmlForServe(html));
          }).catch(() => {
            setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
            res.writeHead(404);
            res.end(`<!DOCTYPE html><html><body style="font-family:sans-serif;text-align:center;padding:60px;color:#666;"><h2>Order not found</h2><p>The tracking page for this order is not available yet.</p></body></html>`);
          });
        } else if (pathname.startsWith('/order/') && req.method === 'GET') {
          const rawId = pathname.replace(/^\/order\//, '').replace(/\/status\/?$/, '').replace(/\/quote\/?$/, '');
          const safeId = rawId.replace(/[^a-zA-Z0-9_-]/g, '');
          const order = (store.printLog || []).find(o => o.id === safeId);
          setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
          res.setHeader('Cache-Control', 'no-cache');
          if (!order) {
            res.writeHead(404);
            res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Not Found</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Order Not Found</h2><p>We couldn't find an order with that ID. Please check the link and try again.</p></div></body></html>`);
          } else if (order.status === 'quote') {
            res.writeHead(302, { Location: `/order/${safeId}/quote` });
            res.end();
          } else {
            const accessTok = (url.searchParams.get('token') || '').trim();
            if (!order.trackingToken || !verifyOrderAccessToken(order, accessTok, 'trackingToken')) {
              res.writeHead(403);
              res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Invalid link</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Invalid tracking link</h2><p>Use the tracking link your shop sent you, or ask them for an updated link.</p></div></body></html>`);
              return;
            }
            const shopName = lanEscapeHtml(store.settings?.shopName || 'Khayt');
            const projectName = lanEscapeHtml(order.project || order.id);
            const clientName = order.client ? lanEscapeHtml(order.client) : null;
            const material = order.material ? lanEscapeHtml(order.material) : null;
            const dueDate = order.dueDate ? lanEscapeHtml(order.dueDate) : null;
            const status = (order.status || 'pending').toLowerCase();

            const statusLabels = {
              pending: 'Waiting to Start',
              printing: 'Printing',
              post: 'Post-Processing',
              qc: 'Quality Check',
              completed: 'Ready for Pickup / Completed',
              on_hold: 'On Hold',
              cancelled: 'Cancelled'
            };
            const statusDescriptions = {
              pending: 'Your order is in the queue and will start soon.',
              printing: 'Your order is currently being printed.',
              post: 'Your print is finished — post-processing is underway.',
              qc: 'Your order is going through a quality check.',
              completed: 'Your order is complete and ready for pickup!',
              on_hold: 'Your order is temporarily on hold. We\'ll update you soon.',
              cancelled: 'This order has been cancelled. Please contact us if you have questions.'
            };
            const steps = ['Pending', 'Printing', 'Post-Processing', 'Quality Check', 'Ready / Completed'];
            const stepMap = { pending: 0, printing: 1, post: 2, qc: 3, completed: 4 };
            const currentStep = stepMap[status] !== undefined ? stepMap[status] : (status === 'on_hold' || status === 'cancelled' ? -1 : 0);
            const isWarning = status === 'on_hold' || status === 'cancelled';
            const accentColor = isWarning ? (status === 'cancelled' ? '#ef4444' : '#f59e0b') : '#6366f1';
            const statusLabel = lanEscapeHtml(statusLabels[status] || status);
            const statusDesc = lanEscapeHtml(statusDescriptions[status] || 'We are working on your order.');

            const stepsHtml = steps.map((label, i) => {
              const active = !isWarning && i <= currentStep;
              const isCurrent = !isWarning && i === currentStep;
              return `<div class="step${active ? ' active' : ''}${isCurrent ? ' current' : ''}"><div class="dot"></div><div class="step-label">${lanEscapeHtml(label)}</div></div>`;
            }).join('');

            const detailsHtml = [
              clientName ? `<div class="detail"><span class="detail-label">Customer</span><span class="detail-val">${clientName}</span></div>` : '',
              material ? `<div class="detail"><span class="detail-label">Material</span><span class="detail-val">${material}</span></div>` : '',
              dueDate ? `<div class="detail"><span class="detail-label">Est. Due Date</span><span class="detail-val">${dueDate}</span></div>` : ''
            ].filter(Boolean).join('');

            // Shipping block — customer-safe projection only (status, carrier, tracking #,
            // carrier deep link). Never projects shipmentMeta / cost / internal notes.
            let shippingHtml = '';
            if (order.shippingStatus || order.trackingNumber) {
              let carriersLib = null;
              try { carriersLib = require('../renderer/carriers.js'); } catch (_) { carriersLib = null; }
              const proj = carriersLib ? carriersLib.projectShipping(order) : null;
              const shipLabels = { label_created: 'Label created', in_transit: 'In transit', out_for_delivery: 'Out for delivery', delivered: 'Delivered', exception: 'Delivery issue' };
              const carrierName = proj && proj.carrierLabel ? (proj.carrierLabel.en || '') : (order.carrier || '');
              const stLabel = proj && proj.shippingStatus ? (shipLabels[proj.shippingStatus] || proj.shippingStatus) : '';
              const rows = [];
              if (carrierName) rows.push(`<div class="detail"><span class="detail-label">Carrier</span><span class="detail-val">${lanEscapeHtml(carrierName)}</span></div>`);
              if (proj && proj.trackingNumber) {
                const tnCell = proj.trackingUrl
                  ? `<a href="${lanEscapeHtml(proj.trackingUrl)}" target="_blank" rel="noopener noreferrer" style="color:#a5b4fc;text-decoration:none;">${lanEscapeHtml(proj.trackingNumber)}</a>`
                  : lanEscapeHtml(proj.trackingNumber);
                rows.push(`<div class="detail"><span class="detail-label">Tracking #</span><span class="detail-val">${tnCell}</span></div>`);
              }
              if (stLabel) rows.push(`<div class="detail"><span class="detail-label">Shipping</span><span class="detail-val">${lanEscapeHtml(stLabel)}</span></div>`);
              if (rows.length) shippingHtml = `<div class="card"><div class="card-title">Shipping</div>${rows.join('')}</div>`;
            }

            let surveyHtml = '';
            if ((order.status === 'completed' || order.status === 'delivered') && order.surveyToken && !order.survey) {
              const tokJs = scriptSafeJson(order.surveyToken);
              const oidJs = scriptSafeJson(order.id);
              surveyHtml = `<div class="card" id="surveyCard"><div class="card-title">Rate Your Experience</div><p style="color:#94a3b8;font-size:.85rem;margin-bottom:12px;">How was your order?</p><div id="stars" style="display:flex;justify-content:center;gap:6px;font-size:28px;margin-bottom:12px">${[1, 2, 3, 4, 5].map(n => `<span data-v="${n}" style="cursor:pointer">☆</span>`).join('')}</div><textarea id="surveyComment" placeholder="Optional comment" style="width:100%;background:#0f172a;border:1px solid #334155;border-radius:8px;color:#e2e8f0;padding:10px;font-size:.85rem;min-height:72px;margin-bottom:10px;box-sizing:border-box;"></textarea><button id="surveyBtn" style="width:100%;padding:10px;border:none;border-radius:8px;background:#6366f1;color:#fff;font-weight:600;cursor:pointer;">Submit Feedback</button><p id="surveyThanks" style="display:none;color:#4ade80;margin-top:10px;text-align:center;">Thank you!</p></div><script>(function(){let r=0;document.querySelectorAll('#stars span').forEach(s=>s.addEventListener('click',()=>{r=+s.dataset.v;document.querySelectorAll('#stars span').forEach((st,i)=>st.textContent=i<r?'\\u2605':'\\u2606');}));document.getElementById('surveyBtn').addEventListener('click',async()=>{if(!r){alert('Please select a rating');return;}const btn=document.getElementById('surveyBtn');btn.disabled=true;try{const res=await fetch('/api/survey',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:${tokJs},orderId:${oidJs},rating:r,comment:document.getElementById('surveyComment').value.trim()})});if(res.ok){btn.style.display='none';document.getElementById('surveyThanks').style.display='block';}else{btn.disabled=false;alert('Could not submit — try again');}}catch(e){btn.disabled=false;}});})();</script>`;
            } else if (order.survey) {
              surveyHtml = `<div class="card"><p style="color:#4ade80;text-align:center;font-size:.9rem;">⭐ Thank you for your feedback!</p></div>`;
            }

            setLanHtmlSecurityHeaders(res);
            res.setHeader('Content-Type', 'text/html; charset=utf-8');
            res.writeHead(200);
            res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Status — ${projectName}</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;min-height:100vh;padding:24px 16px}.container{max-width:480px;margin:0 auto}.header{text-align:center;margin-bottom:28px}.header h1{font-size:1.5rem;font-weight:700;color:#f1f5f9;margin-bottom:4px}.header .subtitle{color:#94a3b8;font-size:.9rem}.card{background:#1e293b;border-radius:16px;padding:24px;margin-bottom:16px}.card-title{font-size:.75rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;color:#64748b;margin-bottom:16px}.status-badge{display:inline-block;padding:6px 14px;border-radius:20px;font-size:.85rem;font-weight:600;background:${accentColor}22;color:${accentColor};margin-bottom:12px}.status-desc{color:#94a3b8;font-size:.9rem;line-height:1.5}.progress{display:flex;align-items:flex-start;gap:0;margin-top:8px}.step{flex:1;display:flex;flex-direction:column;align-items:center;position:relative}.step:not(:last-child)::after{content:'';position:absolute;top:10px;left:50%;width:100%;height:2px;background:#334155;z-index:0}.step.active:not(:last-child)::after{background:#6366f1}.dot{width:20px;height:20px;border-radius:50%;background:#334155;border:2px solid #334155;position:relative;z-index:1;transition:all .2s}.step.active .dot{background:#6366f1;border-color:#6366f1}.step.current .dot{box-shadow:0 0 0 4px #6366f133}.step-label{font-size:.65rem;color:#64748b;margin-top:6px;text-align:center;line-height:1.3}.step.active .step-label{color:#a5b4fc}.detail{display:flex;justify-content:space-between;align-items:center;padding:10px 0;border-bottom:1px solid #0f172a}.detail:last-child{border-bottom:none}.detail-label{font-size:.8rem;color:#64748b}.detail-val{font-size:.85rem;color:#e2e8f0;font-weight:500;text-align:right;max-width:60%}.footer{text-align:center;margin-top:24px;color:#475569;font-size:.8rem;line-height:1.6}</style></head><body><div class="container"><div class="header"><h1>${projectName}</h1><div class="subtitle">Order Status</div></div><div class="card"><div class="card-title">Current Status</div><div class="status-badge">${statusLabel}</div><p class="status-desc">${statusDesc}</p>${!isWarning ? `<div class="progress" style="margin-top:20px">${stepsHtml}</div>` : ''}</div>${detailsHtml ? `<div class="card"><div class="card-title">Order Details</div>${detailsHtml}</div>` : ''}${shippingHtml}${surveyHtml}<div class="footer"><p>Thank you for choosing ${shopName}</p><p style="margin-top:4px;font-size:.75rem;color:#334155">Auto-refreshes every 30s</p></div></div><script>setTimeout(()=>location.reload(),30000);</script></body></html>`);
          }

        } else if (pathname === '/manifest.json' && req.method === 'GET') {
          const shopName = store.settings?.shopName || 'Khayt';
          res.setHeader('Content-Type', 'application/manifest+json');
          res.writeHead(200);
          res.end(JSON.stringify({
            name: shopName + ' Queue',
            short_name: shopName,
            start_url: '/',
            display: 'standalone',
            background_color: '#0A2A51',
            theme_color: '#E06010',
            icons: [
              { src: '/icon-192.png', sizes: '192x192', type: 'image/png' },
              { src: '/icon-512.png', sizes: '512x512', type: 'image/png' },
              { src: '/icon-maskable-512.png', sizes: '512x512', type: 'image/png',
                purpose: 'maskable' }
            ]
          }));

        } else if ((pathname === '/icon-192.png' || pathname === '/icon-512.png'
                    || pathname === '/icon-maskable-512.png') && req.method === 'GET') {
          // Serve the size the manifest asked for. This used to hand the same
          // 1024px file to every route, so a phone installing the companion
          // downloaded a megabyte to draw a 192px home screen tile.
          const iconFile = pathname === '/icon-192.png' ? 'icon-192.png'
            : pathname === '/icon-maskable-512.png' ? 'icon-maskable-512.png'
            : 'icon-512.png';
          const iconPath = path.join(appRoot, 'assets', 'pwa', iconFile);
          res.setHeader('Content-Type', 'image/png');
          res.setHeader('Cache-Control', 'public, max-age=86400');
          if (fs.existsSync(iconPath)) {
            const iconBuf = fs.readFileSync(iconPath);
            res.writeHead(200);
            res.end(iconBuf);
          } else {
            res.writeHead(200);
            res.end(Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64'));
          }

        } else if (pathname === '/sw.js' && req.method === 'GET') {
          res.setHeader('Content-Type', 'application/javascript');
          res.setHeader('Service-Worker-Allowed', '/');
          res.writeHead(200);
          res.end(`const CACHE='khayt-v1';
self.addEventListener('install',e=>e.waitUntil(caches.open(CACHE).then(c=>c.addAll(['/']))));
self.addEventListener('fetch',e=>e.respondWith(fetch(e.request).catch(()=>caches.match(e.request))));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(ks=>Promise.all(ks.filter(k=>k!==CACHE).map(k=>caches.delete(k))))));`);

        } else if ((pathname === '/' || pathname === '') && req.method === 'GET') {
          if (store.settings?.onlineEnabled) {
            res.writeHead(302, { Location: '/intake', 'Cache-Control': 'no-cache' });
            res.end();
            return;
          }
          if (!checkPinForGet()) return;
          const shopName = lanEscapeHtml(store.settings?.shopName || 'Khayt');
          const queue = (store.printLog || []).filter(o => ['pending','printing','post','qc','on_hold'].includes(o.status));
          const pending  = queue.filter(o => o.status === 'pending').length;
          const printing = queue.filter(o => o.status === 'printing').length;
          const post     = queue.filter(o => o.status === 'post').length;
          const qc       = queue.filter(o => o.status === 'qc').length;
          const onHold   = queue.filter(o => o.status === 'on_hold').length;
          const badgeMap = { pending:'#374151|#d1d5db', printing:'#1d4ed8|#bfdbfe', post:'#065f46|#a7f3d0', qc:'#7c3aed|#ddd6fe', on_hold:'#92400e|#fde68a' };
          const orderCards = queue.slice(0, 30).map(o => {
            const [bg, fg] = (badgeMap[o.status] || '#374151|#d1d5db').split('|');
            return `<div class="oc"><div><div class="on">${lanEscapeHtml(o.project || o.id)}</div><div class="cl">${lanEscapeHtml(o.client || '')}</div></div><span class="bd" style="background:${bg};color:${fg}">${lanEscapeHtml(o.status)}</span></div>`;
          }).join('') || '<div class="empty">No active orders</div>';
          const now = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
          const html = `<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-touch-icon" href="/icon-192.png">
<meta name="theme-color" content="#6366f1">
<link rel="manifest" href="/manifest.json">
<title>${shopName} Queue</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,system-ui,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:16px;max-width:480px;margin:0 auto}
h1{font-size:20px;color:#6366f1;margin-bottom:2px}
.sub{font-size:12px;color:#64748b;margin-bottom:18px;display:flex;align-items:center;gap:6px}
.dot{width:7px;height:7px;border-radius:50%;background:#22c55e;animation:pulse 2s infinite;display:inline-block}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
.stats{display:grid;grid-template-columns:repeat(2,1fr);gap:8px;margin-bottom:18px}
.sc{background:#1e293b;border-radius:10px;padding:12px 14px}
.sn{font-size:26px;font-weight:700}
.sl{font-size:11px;color:#64748b;margin-top:2px}
.oc{background:#1e293b;border-radius:10px;padding:11px 14px;margin-bottom:7px;display:flex;justify-content:space-between;align-items:center;gap:10px}
.on{font-size:13px;font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:200px}
.cl{font-size:11px;color:#94a3b8;margin-top:2px}
.bd{padding:3px 9px;border-radius:20px;font-size:11px;font-weight:600;white-space:nowrap}
.empty{text-align:center;padding:32px 20px;color:#475569;font-size:13px}
.rf{text-align:center;font-size:11px;color:#475569;margin-top:14px}
.hdr{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:18px}
</style></head><body>
<div class="hdr"><div><h1>${shopName}</h1><div class="sub"><span class="dot"></span>Live Queue</div></div></div>
<div class="stats">
<div class="sc"><div class="sn">${pending}</div><div class="sl">Pending</div></div>
<div class="sc"><div class="sn">${printing}</div><div class="sl">Printing</div></div>
<div class="sc"><div class="sn">${post}</div><div class="sl">Post-Processing</div></div>
<div class="sc"><div class="sn">${qc + onHold}</div><div class="sl">QC / On Hold</div></div>
</div>
${orderCards}
<div class="rf">Auto-refreshes every 30s &middot; Updated ${now}</div>
<script>
if('serviceWorker' in navigator){navigator.serviceWorker.register('/sw.js').catch(()=>{})}
setTimeout(()=>location.reload(),30000);
</script>
</body></html>`;
          setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
          res.setHeader('Cache-Control', 'no-cache');
          res.writeHead(200);
          res.end(html);

        } else if (pathname.startsWith('/api/webhook/printer/') && req.method === 'POST') {
          const machineId = decodeURIComponent(pathname.slice('/api/webhook/printer/'.length).split('/')[0]);
          // Header only — a `?token=` query param would leak the secret into
          // access logs, proxy logs and browser history. Senders must use the
          // X-Khayt-Webhook-Token header.
          const providedToken = req.headers['x-khayt-webhook-token'] || '';
          const expectedToken = store.settings?.lanApi?.webhookToken || '';
          // Rate-limit on a dedicated channel so a misconfigured printer spamming
          // bad tokens can't lock out the owner's PIN/queue access (and vice versa).
          if (isWebhookAuthLocked('printer')) {
            res.writeHead(429, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
            return;
          }
          if (!expectedToken || !safeTokenEqual(providedToken, expectedToken)) {
            recordWebhookAuthFailure('printer');
            res.writeHead(401, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: 'Unauthorized — set webhook token in Khayt LAN settings' }));
            return;
          }
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const parsed = parseLanJsonBody(body, {});
              const event = normalizePrinterEvent(parsed);
              // Find the order currently printing on this machine
              const storeData = { ...STORE() };
              const orders = storeData.printLog || [];
              // Find by machineId (order.machine === machine.name where machine.id === machineId)
              const machine = (storeData.machines || []).find(m => m.id === machineId);
              const machineName = machine?.name || machineId;
              let advancedOrder = null;
              if (event === 'print_done' || event === 'print_started' || event === 'print_cancelled') {
                const targetStatus = event === 'print_done' ? 'printing'
                                   : event === 'print_started' ? 'pending'
                                   : 'printing';
                const newStatus   = event === 'print_done' ? 'post'
                                  : event === 'print_started' ? 'printing'
                                  : 'on_hold';
                const idx = orders.findIndex(o => o.status === targetStatus &&
                  (o.machine === machineName || o.machineId === machineId));
                if (idx !== -1) {
                  const prev = orders[idx];
                  const at = new Date().toISOString();
                  // Re-find by ID inside the write. The order may have moved in the
                  // log, and a status the shop set on the desktop in between must
                  // not be undone by a machine event that predates it.
                  await updateStoreOnDisk((cur) => {
                    const log = [...(cur.printLog || [])];
                    const i = log.findIndex(o => o && o.id === prev.id);
                    if (i === -1) return cur;
                    log[i] = {
                      ...log[i],
                      status: newStatus,
                      ...(newStatus === 'printing' ? { printStartedAt: at } : {}),
                      ...(newStatus === 'post'     ? { printDoneAt:    at } : {}),
                    };
                    return { ...cur, printLog: log };
                  });
                  advancedOrder = { id: prev.id, from: targetStatus, to: newStatus, project: prev.project };
                  if (getMainWindow() && !getMainWindow().isDestroyed()) {
                    getMainWindow().webContents.send('lan-kanban-advanced', advancedOrder);
                  }
                }
              }
              res.setHeader('Content-Type', 'application/json');
              res.writeHead(200);
              res.end(JSON.stringify({ ok: true, event, advanced: advancedOrder }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        // ── iCal feed ───────────────────────────────────────────
        } else if (pathname === '/calendar.ics' && req.method === 'GET') {
          const calToken = getCalendarToken();
          const tokenParam = (url.searchParams.get('token') || '').trim();
          const pinParam = (url.searchParams.get('pin') || req.headers['x-khayt-pin'] || '').trim();
          const authorized = (calToken && tokenParam && safeTokenEqual(tokenParam, calToken))
            || (pin && pinParam && safeTokenEqual(pinParam, pin));
          if (!authorized) {
            res.writeHead(401, { 'Content-Type': 'text/plain; charset=utf-8' });
            res.end('Unauthorized — use the calendar subscription link from Khayt Settings → Online.');
            return;
          }
          const calOrders = (store.printLog || []).filter(o =>
            o.dueDate && o.status !== 'completed' && o.status !== 'cancelled'
          );
          const formatIcalDate = (dateStr) => {
            // Parse YYYY-MM-DD → YYYYMMDD
            const d = new Date(dateStr + 'T00:00:00Z');
            if (isNaN(d.getTime())) return null;
            const y = d.getUTCFullYear();
            const m = String(d.getUTCMonth() + 1).padStart(2, '0');
            const dy = String(d.getUTCDate()).padStart(2, '0');
            return `${y}${m}${dy}`;
          };
          const calStatusMap = {
            printing: 'CONFIRMED', post: 'CONFIRMED', qc: 'CONFIRMED',
            pending: 'TENTATIVE', on_hold: 'CANCELLED'
          };
          const vevents = calOrders.map(o => {
            const dtstart = formatIcalDate(o.dueDate);
            if (!dtstart) return '';
            // DTEND = dueDate + 1 day
            const dEnd = new Date(o.dueDate + 'T00:00:00Z');
            dEnd.setUTCDate(dEnd.getUTCDate() + 1);
            const ye = dEnd.getUTCFullYear();
            const me = String(dEnd.getUTCMonth() + 1).padStart(2, '0');
            const de = String(dEnd.getUTCDate()).padStart(2, '0');
            const dtend = `${ye}${me}${de}`;
            const icalEscape = s => String(s || '').replace(/[\r\n]+/g, ' ').replace(/[\\;,]/g, '\\$&');
            const summary = `${icalEscape(o.project || o.id)} (${icalEscape(o.client || 'No client')})`;
            const icalStatus = calStatusMap[o.status] || 'TENTATIVE';
            return [
              'BEGIN:VEVENT',
              `UID:khayt-${o.id}@khaytapp.com`,
              `DTSTART;VALUE=DATE:${dtstart}`,
              `DTEND;VALUE=DATE:${dtend}`,
              `SUMMARY:${summary}`,
              `STATUS:${icalStatus}`,
              'END:VEVENT'
            ].join('\r\n');
          }).filter(Boolean).join('\r\n');
          const shopName = (store.settings?.shopName || 'Khayt').replace(/[\r\n]+/g, ' ').replace(/[\\;,]/g, '\\$&');
          const icalBody = [
            'BEGIN:VCALENDAR',
            'VERSION:2.0',
            'PRODID:-//Khayt//Khayt//EN',
            'CALSCALE:GREGORIAN',
            'METHOD:PUBLISH',
            `X-WR-CALNAME:${shopName} Orders`,
            vevents,
            'END:VCALENDAR'
          ].join('\r\n');
          res.setHeader('Content-Type', 'text/calendar; charset=utf-8');
          res.setHeader('Content-Disposition', 'attachment; filename="khayt-orders.ics"');
          res.setHeader('Cache-Control', 'no-cache');
          res.writeHead(200);
          res.end(icalBody);

        // ── Online intake form ──────────────────────────────────
        } else if (pathname === '/intake' && req.method === 'GET') {
          const shopName = lanEscapeHtml(store.settings?.shopName || 'Khayt');
          res.setHeader('Cache-Control', 'no-cache');
          const grantIntakeSession = () => {
            const sessionToken = crypto.randomBytes(32).toString('hex');
            sweepIntakeSessions(Date.now());
            intakeSessions.set(sessionToken, { created: Date.now(), ip });
            return sessionToken;
          };
          const sendIntakeForm = (sessionToken) => {
            const headers = { 'Content-Type': 'text/html; charset=utf-8' };
            if (sessionToken) {
              headers['Set-Cookie'] = `${INTAKE_COOKIE}=${sessionToken}; HttpOnly; Path=/; SameSite=Lax; Max-Age=${Math.floor(INTAKE_SESSION_MS / 1000)}`;
            }
            res.writeHead(200, headers);
            res.end(renderIntakeFormPage(shopName, lanEscapeHtml(store.settings?.currency || ''), !!store.settings?.lanApi?.intakeQuote?.enabled));
          };
          if (hasIntakeSession(req, ip)) {
            sendIntakeForm();
          } else if (!checkIntakeSessionGrantRate()) {
            res.writeHead(429, { 'Content-Type': 'text/html; charset=utf-8' });
            res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Too many requests</title><style>${intakeSharedStyles}</style></head><body><div class="container"><div class="card"><h2 style="margin-bottom:12px;color:#f1f5f9">Too many requests</h2><p style="color:#94a3b8;line-height:1.6">Please wait a while before trying again.</p></div></div></body></html>`);
          } else {
            sendIntakeForm(grantIntakeSession());
          }

        // ── Intake session (PIN gate) ───────────────────────────
        } else if (pathname === '/api/intake/session' && req.method === 'POST') {
          const intakePin = getIntakePin();
          if (!intakePin) {
            res.writeHead(503, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
            res.end(JSON.stringify({ error: 'Intake PIN not configured' }));
            return;
          }
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', () => {
            try {
              const parsed = parseLanJsonBody(body, {});
              const providedPin = typeof parsed.pin === 'string' ? parsed.pin.trim() : '';
              const now = Date.now();
              const ipData = intakePinAttempts.get(ip) || { count: 0, resetAt: 0 };
              if (now < ipData.resetAt && ipData.count >= 10) {
                res.writeHead(429, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
                return;
              }
              if (!safeTokenEqual(providedPin, intakePin)) {
                intakePinAttempts.set(ip, bumpFailure(ipData, now, { lockoutMs: LOCKOUT_MS }));
                sweepFailedAttempts(intakePinAttempts, now, MAX_FAILED_ATTEMPT_KEYS);
                res.writeHead(401, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'Unauthorized' }));
                return;
              }
              intakePinAttempts.delete(ip);
              const sessionToken = crypto.randomBytes(32).toString('hex');
              sweepIntakeSessions(Date.now());
              intakeSessions.set(sessionToken, { created: Date.now(), ip });
              res.writeHead(200, {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*',
                'Set-Cookie': `${INTAKE_COOKIE}=${sessionToken}; HttpOnly; Path=/; SameSite=Lax; Max-Age=${Math.floor(INTAKE_SESSION_MS / 1000)}`,
              });
              res.end(JSON.stringify({ ok: true }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Invalid request' }));
            }
          });

        // ── Intake form submission ──────────────────────────────
        // ── Price a model the customer uploaded (R5) ────────────
        // The one route in Khayt that computes a price for someone who is not the
        // shop. It is off unless the shop switched it on, it never persists the
        // file, and what it returns is explicitly not binding.
        } else if (isIntakeEstimatePost) {
          if (!checkIntakePost(req)) {
            res.writeHead(401, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
            res.end(JSON.stringify({ error: 'Unauthorized' }));
            return;
          }
          if (!checkEstimateRate()) {
            res.writeHead(429, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
            res.end(JSON.stringify({ error: 'Too many estimates — try again later' }));
            return;
          }
          // Refuse before reading a single byte when the shop has not turned this
          // on. Accepting 32 MB and then saying "no" would make an off switch an
          // upload target.
          const quoteCfg = (STORE()?.settings?.lanApi?.intakeQuote) || {};
          if (!quoteCfg.enabled) {
            res.writeHead(403, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
            res.end(JSON.stringify({ ok: false, reason: 'off' }));
            return;
          }
          // The filename is only ever used to pick a parser — never to open,
          // write or serve anything — so its extension is all we keep.
          const rawName = String(url.searchParams.get('name') || '');
          const ext = (rawName.split('.').pop() || '').toLowerCase().replace(/[^a-z0-9]/g, '');
          if (!['stl', 'obj', '3mf', 'gcode', 'gco'].includes(ext)) {
            res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
            res.end(JSON.stringify({ ok: false, reason: 'unsupported' }));
            return;
          }
          // Bound how much is buffered at once. Refused BEFORE any body is read,
          // for the same reason the `off` check above is: accepting 32 MB and
          // then declining makes a limit into an upload target. Released on
          // response close, which covers every exit — replied, threw, or the
          // socket went away mid-upload.
          if (estimatesInFlight >= ESTIMATE_MAX_IN_FLIGHT) {
            res.writeHead(503, {
              'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Retry-After': '5',
            });
            res.end(JSON.stringify({ ok: false, reason: 'busy' }));
            return;
          }
          estimatesInFlight += 1;
          let released = false;
          const releaseSlot = () => { if (!released) { released = true; estimatesInFlight -= 1; } };
          res.on('close', releaseSlot);

          const chunks = [];
          let received = 0;
          let aborted = false;
          req.on('data', (chunk) => {
            if (aborted) return;
            received += chunk.length;
            if (received > ESTIMATE_MAX_BYTES) {
              aborted = true;
              res.writeHead(413, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ ok: false, reason: 'too-large' }));
              req.socket.destroy();
              return;
            }
            chunks.push(chunk);
          });
          req.on('end', () => {
            if (aborted) return;
            try {
              const buf = Buffer.concat(chunks);
              if (!buf.length) {
                res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ ok: false, reason: 'no-numbers' }));
                return;
              }
              // Parsed in memory and dropped. Khayt does not keep a stranger's
              // model on the shop's disk — the shop asks for the file if and when
              // they take the job, which keeps retention and consent simple.
              // Risk analysis for the SHOP's benefit, not the visitor's: what
              // comes back to the browser is unchanged. A stranger gets a price;
              // "this needs supports" is what the shop weighs when the request
              // lands in front of them, and is not an argument to have with
              // someone who cannot act on it.
              //
              // No machine has been chosen at this point — nobody has decided
              // which printer would take the job — so the analysis uses its own
              // defaults. Overhang and bridging, which are most of the value, do
              // not depend on the machine at all; only the thin-wall line does,
              // and the shop can re-check that against a real printer when they
              // accept.
              const read = intakeModel({ filename: 'upload.' + ext, bytes: buf },
                buf.length <= ESTIMATE_RISK_MAX_BYTES ? { risk: true } : undefined);
              const store = STORE() || {};
              const quote = publicQuote({
                intake: read,
                store,
                // publicQuote clamps this; a second clamp here would be a second
                // place to change the bound.
                qty: +url.searchParams.get('qty') || 1,
                deps: {
                  computePartBaseCost: KhaytCost.computePartBaseCost,
                  quoteTotal: KhaytPricing.quoteTotal,
                  estimate: estimateFromStl,
                  // Same assumptions the shop's own calculator uses, plus a rate
                  // learned from its measured jobs where there is one. A
                  // customer must not be quoted on different maths.
                  estimatorOpts: publicEstimatorOpts(store),
                },
              });
              if (!quote.ok) {
                res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ ok: false, reason: quote.reason }));
                return;
              }
              // Hand back a reference, not just a number: when the customer
              // submits the form we attach OUR figure to their request rather
              // than whatever their browser posts back at us.
              const ref = rememberEstimate(quote);
              res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({
                ok: true, ref,
                price: quote.price, currency: quote.currency, qty: quote.qty,
                grams: quote.grams, hours: quote.hours,
                exact: quote.exact, slicer: quote.slicer,
                binding: false,
              }));
            } catch (e) {
              console.error('LAN intake estimate:', e);
              res.writeHead(500, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ ok: false, reason: 'no-price' }));
            }
          });

        } else if (pathname === '/api/intake' && req.method === 'POST') {
          if (!checkIntakePost(req)) {
            res.writeHead(401, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
            res.end(JSON.stringify({ error: 'Unauthorized' }));
            return;
          }
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              if (!checkIntakeSubmitRate()) {
                res.writeHead(429, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'Too many submissions — try again later' }));
                return;
              }
              const parsed = parseLanJsonBody(body, {});
              // Validate required fields
              const name = typeof parsed.name === 'string' ? parsed.name.trim().slice(0, 200) : '';
              const description = typeof parsed.description === 'string' ? parsed.description.trim().slice(0, 2000) : '';
              if (!name) {
                res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'name is required' }));
                return;
              }
              if (!description) {
                res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'description is required' }));
                return;
              }
              // Optional fields — sanitize
              const sanitize = (v) => typeof v === 'string' ? v.trim().slice(0, 500) : undefined;
              const email = sanitize(parsed.email);
              const phone = sanitize(parsed.phone);
              const material = sanitize(parsed.material);
              const budget = sanitize(parsed.budget);
              const dueDate = sanitize(parsed.dueDate);
              const referenceLink = sanitizeLanHttpUrl(parsed.referenceLink);
              // PDPL: the intake form is the one place a customer submits their OWN data,
              // so explicit consent is required and recorded immutably with the exact
              // notice wording they saw. See docs/KHAYT-3.0-PRIVACY-COMPLIANCE-SPEC.md.
              let consent = null;
              try {
                const privacyLib = require('./privacy.js');
                const shopName = STORE().settings?.shopName || 'this shop';
                consent = privacyLib.consentRecord(parsed.consent === true || parsed.consent === 'true', shopName, 'en');
              } catch (_) { consent = null; }
              if (!consent) {
                res.writeHead(400, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
                res.end(JSON.stringify({ error: 'Please agree to the privacy notice to submit your request.' }));
                return;
              }
              // Store in renderer-compatible waiting-list format
              const entry = {
                id: uniqueLanId('intake'),
                project: description.slice(0, 80),  // first 80 chars as project name
                clientName: name,
                notes: description,
                email, phone, material, budget, referenceLink,
                reminderDate: dueDate || null,
                priority: 'normal',
                status: 'active',
                estValue: 0,
                source: 'intake_form',
                submittedAt: new Date().toISOString(),
                consent,
              };
              // If we priced a model for this visitor, attach OUR figure — looked up
              // by reference, never taken from the body. A browser can post any
              // number it likes; the shop must see what the server actually said.
              const quoted = recallEstimate(parsed.estimateRef);
              if (quoted && quoted.ok) {
                entry.estValue = quoted.price;
                entry.modelQuote = {
                  price: quoted.price,
                  currency: quoted.currency,
                  qty: quoted.qty,
                  grams: quoted.grams,
                  hours: quoted.hours,
                  // Carried through so the shop can see at a glance whether this
                  // came off a slicer or off a guess about geometry.
                  exact: quoted.exact,
                  slicer: quoted.slicer,
                  binding: false,
                  shownAt: new Date().toISOString(),
                };
                // What the mesh said might go wrong, recorded with the request
                // rather than shown to the visitor. This is the moment it is
                // worth something: the shop is deciding whether to take a job at
                // a price a stranger has already been shown, and "a fifth of
                // this needs supports" is exactly the thing that turns an
                // acceptable price into an unacceptable one.
                if (quoted.risk) entry.modelQuote.risk = quoted.risk;
              }
              // Remove undefined keys
              Object.keys(entry).forEach(k => entry[k] === undefined && delete entry[k]);
              await updateStoreOnDisk((cur) => ({ ...cur, waitingList: [...(cur.waitingList || []), entry] }));
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-intake-submitted', entry);
              }
              res.writeHead(200, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ ok: true }));
            } catch (e) {
              // Distinguish a bad submission from OUR failure to record it. This block
              // also covers persistLanStoreUpdate, so a full disk on the shop's machine
              // used to tell the CUSTOMER their input was malformed — they would retype a
              // perfectly good form and fail again. A parse/validation error is theirs; a
              // write error is ours.
              const isClientError = e instanceof SyntaxError || e?.name === 'ValidationError';
              if (!isClientError) console.error('LAN intake: failed to record submission:', e);
              const status = isClientError ? 400 : 500;
              const error = isClientError
                ? 'Invalid request — please check your submission and try again'
                : 'The shop could not record your request right now. Please try again shortly.';
              res.writeHead(status, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
              res.end(JSON.stringify({ error }));
            }
          });

        // ── Quote approval ──────────────────────────────────────
        } else if (pathname.startsWith('/order/') && req.method === 'POST') {
          const rawId = pathname.replace(/^\/order\//, '').replace(/\/?$/, '').split('/')[0];
          const safeId = rawId.replace(/[^a-zA-Z0-9_-]/g, '');
          let body = '';
          req.on('data', chunk => {
            if (Buffer.byteLength(body) + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            body += chunk;
          });
          req.on('end', async () => {
            try {
              const parsed = parseLanJsonBody(body, {});
              if (parsed.action && parsed.action !== 'approve') {
                setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
                res.writeHead(400);
                res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Bad Request</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Invalid Action</h2><p>Unknown action. Only "approve" is supported.</p></div></body></html>`);
                return;
              }
              const storeData = { ...STORE() };
              storeData.printLog = [...(STORE().printLog || [])];
              const idx = storeData.printLog.findIndex(o => o.id === safeId);
              if (idx === -1) {
                setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
                res.writeHead(404);
                res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Not Found</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Order Not Found</h2><p>We could not find an order with that ID.</p></div></body></html>`);
                return;
              }
              const approvalTok = (url.searchParams.get('token') || parsed.approvalToken || '').trim();
              if (!verifyQuoteApprovalToken(storeData.printLog[idx], approvalTok)) {
                setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
                res.writeHead(403);
                res.end(`<!DOCTYPE html><html lang="en"><body style="font-family:sans-serif;text-align:center;padding:48px;background:#0f172a;color:#e2e8f0"><h2>Invalid link</h2><p>Open the quote page from the link your shop sent you, then approve from there.</p></body></html>`);
                return;
              }
              const result = applyQuoteApprovalToStore(storeData, safeId);
              if (!result) {
                setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
                res.writeHead(404);
                res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Order Not Found</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Order Not Found</h2><p>We could not find an order with that ID.</p></div></body></html>`);
                return;
              }
              if (result.error === 'expired') {
                setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
                res.writeHead(410);
                res.end(quoteExpiredHtml());
                return;
              }
              if (result.error === 'cannot_approve') {
                setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
                res.writeHead(409);
                res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Cannot Approve</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#f1f5f9}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Cannot Approve</h2><p>This order is not in a state that can be approved.</p></div></body></html>`);
                return;
              }
              await updateStoreOnDisk((cur) => {
                const next = { ...cur, printLog: [...(cur.printLog || [])] };
                const r = applyQuoteApprovalToStore(next, safeId);
                if (!r || r.error) return cur;   // it changed underneath us
                return next;
              });
              const approved = result.order;
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-order-updated', {
                  id: safeId,
                  status: 'pending',
                  clientApprovedAt: approved.clientApprovedAt,
                  quoteAcceptedAt: approved.quoteAcceptedAt,
                  quoteApproved: true,
                });
              }
              const projectName = lanEscapeHtml(approved.project || approved.id);
              setLanHtmlSecurityHeaders(res);
          res.setHeader('Content-Type', 'text/html; charset=utf-8');
              res.writeHead(200);
              res.end(`<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Quote Approved</title><style>*{box-sizing:border-box;margin:0;padding:0}body{background:#0f172a;color:#e2e8f0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px}.card{background:#1e293b;border-radius:16px;padding:40px 32px;text-align:center;max-width:400px;width:100%}h2{font-size:1.4rem;margin-bottom:12px;color:#6366f1}p{color:#94a3b8;line-height:1.6}</style></head><body><div class="card"><h2>Quote Approved!</h2><p>Your approval for <strong>${projectName}</strong> has been received. We'll start working on your order shortly.</p></div></body></html>`);
            } catch (e) {
              res.setHeader('Content-Type', 'application/json');
              res.writeHead(400);
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        // ── Salla inbound order webhook ─────────────────────────
        } else if (pathname === '/api/webhook/salla' && req.method === 'POST') {
          let bodyBuf = Buffer.alloc(0);
          req.on('data', chunk => {
            if (bodyBuf.length + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            bodyBuf = Buffer.concat([bodyBuf, chunk]);
          });
          req.on('end', async () => {
            try {
              if (isWebhookAuthLocked('salla')) {
                res.writeHead(429, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
                return;
              }
              const sallaSecret = STORE().settings?.lanApi?.sallaWebhookSecret;
              // Always require a configured secret — reject without one to prevent
              // unauthenticated order injection from any LAN host.
              if (!sallaSecret) {
                res.writeHead(403, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Salla webhook secret not configured in LAN settings' }));
                return;
              }
              const sigHeader = req.headers['x-salla-signature'] || '';
              const expected = 'sha256=' + crypto.createHmac('sha256', sallaSecret).update(bodyBuf).digest('hex');
              if (!safeTokenEqual(sigHeader, expected)) {
                recordWebhookAuthFailure('salla');
                res.writeHead(401, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid signature' }));
                return;
              }
              // Replay guard: drop exact duplicates of an already-seen signed body.
              if (isReplayedWebhook(sigHeader)) {
                res.writeHead(409, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Duplicate delivery ignored' }));
                return;
              }
              const parsed = safeJsonParse(bodyBuf.toString('utf8'));
              const storeData = { ...STORE() };
              storeData.printLog = [...(STORE().printLog || [])];
              // The platform's own order id, checked against the print log —
              // which is on disk, so this survives the restart, the eviction and
              // the ten-minute TTL that the signature cache above does not. A
              // provider retry is an ordinary event, not an attack.
              const sallaRef = storefrontOrders.sourceOrderIdFrom('salla', parsed);
              if (storefrontOrders.alreadyRecorded(storeData.printLog, 'salla', sallaRef)) {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: true, duplicate: true }));
                return;
              }
              // `data.total` DOES NOT EXIST in a Salla webhook, and never did.
              // The total is `data.amounts.total.amount`. Number(undefined) is
              // NaN, isFinite(NaN) is false, and the guard then wrote 0 — so
              // every Salla order Khayt ever imported was priced at zero, in
              // the column the whole business is measured in, without throwing
              // anywhere. See lib/storefront-orders.js.
              const sallaPrice  = storefrontOrders.orderPriceFrom('salla', parsed);
              const newOrder = {
                id:      uniqueLanId('salla'),
                project: `Salla: ${storefrontOrders.orderTitleFrom('salla', parsed)}`,
                client:  storefrontOrders.customerNameFrom('salla', parsed),
                status:  'pending',
                date:    localDay(),
                // Unknown stays 0 here because the print log's price is a
                // number everywhere downstream — but it is now only reached
                // when the platform genuinely sent nothing, rather than on
                // every single order.
                price:   sallaPrice === null ? 0 : sallaPrice,
                notes:   storefrontOrders.noteFor('salla', sallaRef),
                source:  'salla',
                // Structured rather than only quoted in `notes`, so the next
                // delivery can be recognised without parsing prose.
                sourceOrderId: sallaRef || undefined
              };
              // The duplicate check is redone INSIDE the write. A provider retry
              // arriving while the first write is still in flight passes the check
              // above — the log it reads has not been updated yet — and both would
              // insert the same order.
              await updateStoreOnDisk((cur) => {
                const log = [...(cur.printLog || [])];
                if (storefrontOrders.alreadyRecorded(log, 'salla', sallaRef)) return cur;
                log.unshift(newOrder);
                return { ...cur, printLog: log };
              });
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-order-updated', newOrder);
              }
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ ok: true }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        // ── Zid inbound order webhook ───────────────────────────
        } else if (pathname === '/api/webhook/zid' && req.method === 'POST') {
          let bodyBuf = Buffer.alloc(0);
          req.on('data', chunk => {
            if (bodyBuf.length + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            bodyBuf = Buffer.concat([bodyBuf, chunk]);
          });
          req.on('end', async () => {
            try {
              if (isWebhookAuthLocked('zid')) {
                res.writeHead(429, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
                return;
              }
              const zidSecret = STORE().settings?.lanApi?.zidWebhookSecret;
              // Always require a configured secret — reject without one to prevent
              // unauthenticated order injection from any LAN host.
              if (!zidSecret) {
                res.writeHead(403, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Zid webhook secret not configured in LAN settings' }));
                return;
              }
              const sigHeader = req.headers['x-zid-signature'] || '';
              const expected = 'sha256=' + crypto.createHmac('sha256', zidSecret).update(bodyBuf).digest('hex');
              if (!safeTokenEqual(sigHeader, expected)) {
                recordWebhookAuthFailure('zid');
                res.writeHead(401, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid signature' }));
                return;
              }
              // Replay guard: drop exact duplicates of an already-seen signed body.
              if (isReplayedWebhook(sigHeader)) {
                res.writeHead(409, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Duplicate delivery ignored' }));
                return;
              }
              const parsed = safeJsonParse(bodyBuf.toString('utf8'));
              const storeData = { ...STORE() };
              storeData.printLog = [...(STORE().printLog || [])];
              // See the Salla handler: the durable check is the platform's own
              // order id against the persisted log, not a per-process cache.
              const zidRef = storefrontOrders.sourceOrderIdFrom('zid', parsed);
              if (storefrontOrders.alreadyRecorded(storeData.printLog, 'zid', zidRef)) {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: true, duplicate: true }));
                return;
              }
              // Zid's payload shape could NOT be confirmed by this audit — it
              // renders its webhook schema through a docs component that does
              // not come out as text, and its sample apps carry no fixture. So
              // the reader accepts the wrapper this code assumed AND an order
              // posted at the top level, and several spellings of the total,
              // rather than betting on the one that was never verified.
              const zidPrice = storefrontOrders.orderPriceFrom('zid', parsed);
              const newOrder = {
                id:      uniqueLanId('zid'),
                project: `Zid: ${storefrontOrders.orderTitleFrom('zid', parsed)}`,
                client:  storefrontOrders.customerNameFrom('zid', parsed),
                status:  'pending',
                date:    localDay(),
                price:   zidPrice === null ? 0 : zidPrice,
                notes:   storefrontOrders.noteFor('zid', zidRef),
                source:  'zid',
                sourceOrderId: zidRef || undefined
              };
              // The duplicate check is redone INSIDE the write. A provider retry
              // arriving while the first write is still in flight passes the check
              // above — the log it reads has not been updated yet — and both would
              // insert the same order.
              await updateStoreOnDisk((cur) => {
                const log = [...(cur.printLog || [])];
                if (storefrontOrders.alreadyRecorded(log, 'zid', zidRef)) return cur;
                log.unshift(newOrder);
                return { ...cur, printLog: log };
              });
              if (getMainWindow() && !getMainWindow().isDestroyed()) {
                getMainWindow().webContents.send('lan-order-updated', newOrder);
              }
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ ok: true }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        // ── Carrier shipping-status webhooks (SMSA / Aramex / SPL) ──
        } else if ((pathname === '/api/webhook/smsa' || pathname === '/api/webhook/aramex' || pathname === '/api/webhook/spl') && req.method === 'POST') {
          const carrierId = pathname.split('/').pop();
          let bodyBuf = Buffer.alloc(0);
          req.on('data', chunk => {
            if (bodyBuf.length + chunk.length > MAX_BODY) {
              res.writeHead(413, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: 'Request too large' }));
              req.socket.destroy();
              return;
            }
            bodyBuf = Buffer.concat([bodyBuf, chunk]);
          });
          req.on('end', async () => {
            try {
              if (isWebhookAuthLocked(carrierId)) {
                res.writeHead(429, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Too many attempts — try again in 1 minute' }));
                return;
              }
              const secret = STORE().settings?.shipping?.[carrierId]?.webhookSecret;
              if (!secret) {
                res.writeHead(403, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Carrier webhook secret not configured in Shipping settings' }));
                return;
              }
              const sigHeader = req.headers['x-khayt-signature'] || req.headers['x-signature'] || '';
              const expected = 'sha256=' + crypto.createHmac('sha256', secret).update(bodyBuf).digest('hex');
              if (!safeTokenEqual(sigHeader, expected)) {
                recordWebhookAuthFailure(carrierId);
                res.writeHead(401, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Invalid signature' }));
                return;
              }
              if (isReplayedWebhook(sigHeader)) {
                res.writeHead(409, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ error: 'Duplicate delivery ignored' }));
                return;
              }
              let carriersLib = null;
              try { carriersLib = require('../renderer/carriers.js'); } catch (_) { carriersLib = null; }
              const carrier = carriersLib ? carriersLib.getCarrier(carrierId) : null;
              const parsed = safeJsonParse(bodyBuf.toString('utf8'));
              const evt = carrier ? carrier.parseWebhook(parsed, req.headers, STORE().settings?.shipping?.[carrierId] || {}) : null;
              // AN UNREADABLE BODY AND AN UNKNOWN ORDER ARE DIFFERENT FACTS.
              //
              // Both used to answer 200 "ignored", on one comment about not
              // leaking existence. That reason is real — but it is about the
              // ORDER lookup below, not about this. Getting here means the HMAC
              // matched, so this genuinely is the carrier, sending something
              // Khayt cannot read: a payload shape nobody mapped, or a carrier
              // that changed one. Answering "received, handled" to that hides a
              // broken integration completely. The shop sees shipments that
              // never advance and no reason anywhere, which is exactly what a
              // carrier sending nothing at all looks like.
              //
              // 422 puts it in the carrier's own delivery dashboard, where a
              // misconfiguration belongs, and leaks nothing: it is said only to
              // a sender that already proved it holds the shared secret.
              if (!evt || !evt.trackingNumber || !evt.shippingStatus) {
                res.writeHead(422, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({
                  error: 'Signature valid, but this payload carried no tracking number and status Khayt could read.',
                  carrier: carrierId,
                }));
                return;
              }
              const storeData = { ...STORE() };
              storeData.printLog = [...(STORE().printLog || [])];
              const idx = storeData.printLog.findIndex(o => o && o.trackingNumber && String(o.trackingNumber) === String(evt.trackingNumber));
              // No such tracking number here. THIS is the case the
              // never-leak-existence rule is about, and it keeps its 200: a
              // shipment Khayt does not know about is not an error the carrier
              // can act on, and answering differently would confirm which
              // tracking numbers this shop holds.
              if (idx < 0) {
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ ok: true }));
                return;
              }
              const order = { ...storeData.printLog[idx] };
              const advanced = carriersLib.advanceShippingStatus(order.shippingStatus, evt.shippingStatus);
              if (advanced !== order.shippingStatus) {
                const at = evt.at || new Date().toISOString();
                order.shippingStatus = advanced;
                order.shippingHistory = [...(order.shippingHistory || []), { status: advanced, at, source: 'webhook', note: '' }];
                if (advanced === 'delivered' && order.status === 'completed' && !order.deliveredAt) order.deliveredAt = new Date().toISOString();
                // The advance is recomputed inside the write. Two carrier events
                // arriving together would otherwise each build their history from
                // the same base, and the one that lands last would drop the other's
                // entry — losing a step of the shipping trail rather than ordering it.
                await updateStoreOnDisk((cur) => {
                  const log = [...(cur.printLog || [])];
                  const i = log.findIndex(o => o && o.trackingNumber && String(o.trackingNumber) === String(evt.trackingNumber));
                  if (i === -1) return cur;
                  const now = log[i];
                  const step = carriersLib.advanceShippingStatus(now.shippingStatus, evt.shippingStatus);
                  if (step === now.shippingStatus) return cur;   // already past this event
                  const next = {
                    ...now,
                    shippingStatus: step,
                    shippingHistory: [...(now.shippingHistory || []), { status: step, at, source: 'webhook', note: '' }],
                  };
                  if (step === 'delivered' && next.status === 'completed' && !next.deliveredAt) next.deliveredAt = new Date().toISOString();
                  log[i] = next;
                  return { ...cur, printLog: log };
                });
                if (getMainWindow() && !getMainWindow().isDestroyed()) {
                  getMainWindow().webContents.send('lan-order-updated', order);
                }
              }
              res.writeHead(200, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ ok: true }));
            } catch (e) {
              res.writeHead(400, { 'Content-Type': 'application/json' });
              res.end(JSON.stringify({ error: String(e) }));
            }
          });

        } else {
          res.writeHead(404);
          res.end(JSON.stringify({ error: 'Not found', endpoints: ['/api/status','/api/orders','/api/queue','/api/machines','/api/inventory','/api/waiting-list','/api/clients','/api/webhook/printer/:machineId','/calendar.ics','/intake','/api/intake','/api/intake/estimate','/api/webhook/salla','/api/webhook/zid','/api/webhook/smsa','/api/webhook/aramex','/api/webhook/spl'] }));
        }
      });
      lanServer.listen(port, bindHost, () => {
        const localIp = bindHost === '127.0.0.1' ? '127.0.0.1' : pickLanIPv4(os.networkInterfaces());
        resolve({
          ok: true,
          url: `http://${localIp}:${port}`,
          localIp,
          port,
          loopbackOnly: bindHost === '127.0.0.1',
          intakeTokenGenerated,
          intakePinGenerated,
          calendarTokenGenerated,
          intakePin: intakePinValue, // plaintext — renderer shows it once, then masks
          intakeToken: intakeTokenValue,
          calendarToken: calendarTokenValue,
        });
      });
      lanServer.on('error', e => {
        console.error('LAN server failed to start:', e);
        if (getMainWindow() && !getMainWindow().isDestroyed()) {
          getMainWindow().webContents.send('lan-start-failed', { error: String(e) });
        }
        resolve({ ok: false, error: String(e) });
      });
    } catch(e) {
      console.error('LAN server failed to start:', e);
      if (getMainWindow() && !getMainWindow().isDestroyed()) {
        getMainWindow().webContents.send('lan-start-failed', { error: String(e) });
      }
      resolve({ ok: false, error: String(e) });
    }
  });
});

ipcMain.handle('hub:stop-lan-server', async () => {
  if (_tunnelInstance) {
    try { _tunnelInstance.close(); } catch {}
    _tunnelInstance = null;
    if (getMainWindow() && !getMainWindow().isDestroyed()) {
      getMainWindow().webContents.send('tunnel-status-changed', { active: false });
    }
  }
  if (lanServer) { lanServer.close(); lanServer = null; }
  return { ok: true };
});

ipcMain.handle('hub:get-lan-url', async () => {
  if (!lanServer?.listening) return { ok: false };
  syncLanServerStoreFromDisk();
  const addr = lanServer.address();
  const loopbackOnly = addr?.address === '127.0.0.1' || addr?.address === '::ffff:127.0.0.1';
  const localIp = loopbackOnly ? '127.0.0.1' : pickLanIPv4(os.networkInterfaces());
  const rawPin = STORE()?.settings?.lanApi?.intakePin || '';
  const intakePin = rawPin && !isStoreSecretMasked(rawPin) ? rawPin : '';
  const rawCal = STORE()?.settings?.lanApi?.calendarToken || '';
  const calendarToken = rawCal && !isStoreSecretMasked(rawCal) ? rawCal : '';
  return {
    ok: true,
    url: `http://${localIp}:${addr?.port || 3219}`,
    port: addr?.port,
    loopbackOnly,
    intakePin,
    calendarToken,
  };
});
}

module.exports = {
  registerLanServer,
  lanEscapeHtml,
  safeTokenEqual,
  normalizePrinterEvent,
  pickLanIPv4,
  tunnelClientIp,
  scriptSafeJson,
  uniqueLanId,
  pickLanSpoolFields,
  pickLanSpoolRead,
  sniffReceiptType,
  receiptFilename,
  LAN_SPOOL_READ_FIELDS,
  sanitizeLanHttpUrl,
  globalAuthThrottle,
  globalWindowGate,
  bumpFailure,
  isLockedOut,
  sweepFailedAttempts,
  weakTunnelPinWarning,
};
