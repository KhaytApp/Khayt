'use strict';
/**
 * A PAIRED SLICER PLUGIN (Khayt for OrcaSlicer) ON WINDOWS/LINUX: the
 * `/api/connectors/*` routes, status for status and rule for rule as the
 * native Mac's `LanServer+Connector` and its pairing routes (docs/LAN_API.md
 * "POST /api/connectors/pair" and "The connector's own routes"). Wired into
 * lib/lan-server.js; this module only reads requests and answers them.
 *
 *   POST   /api/connectors/pair                  commit (v2), no PIN, no signature
 *   POST   /api/connectors/pair/{id}/reveal      the plugin's key and nonce
 *   GET    /api/connectors/pair/{id}             how the person answered
 *   GET    /api/connectors/self                  who am I, the shop's name, the limits
 *   DELETE /api/connectors/self                  unpair from the plugin's side
 *   POST   /api/connectors/slices                announce a capture (sealed, ≤ 64 KB)
 *   PUT    /api/connectors/slices/{id}/file      the G-code, judged at its head
 *   GET    /api/connectors/slices/{id}           that slice's state
 *   GET    /api/connectors/queue                 the redacted queue, sealed, ETag
 *   POST   /api/connectors/price                 the shop's price for a slice, sealed
 *
 * Every other `/api/connectors/*` path is 404 for every verb: no pause,
 * resume or stop, and no print is ever started from here.
 *
 * DARK WHILE "PAIR A SLICER" IS OFF: every path here, the pairing included,
 * answers the ordinary 404 (main's KHAYT_CONNECTOR_PAIRING=1 turns it on).
 *
 * A CONNECTOR'S KEY OPENS THESE ROUTES AND NOTHING ELSE: `refusal` answers
 * 403 `connector-scope` on any other path to a request whose x-khayt-device
 * names a connector, signed or not. And these routes take only a connector's
 * signed request: unsigned 401, a phone's key, the PIN or an API token 403
 * `connector-only`.
 *
 * SIGNED BACK: every answer to a verified request carries x-khayt-reply-mac
 * (lib/lan-devices.js replyMac), so a device on the Wi-Fi cannot forge "in
 * the inbox". The capture, the queue and the price are SEALED (AES-256-GCM
 * under HKDF(K, "khayt-connector-seal-v1", connectorId), AAD "METHOD path").
 * The G-code goes in clear ON THE LAN ONLY, bound by the hash the sealed
 * capture declared and the signed head repeats.
 *
 * INBOX-FIRST: a file lands in "From slicer" (lib/main/slicer-inbox.js) and
 * nothing in the book is written.
 *
 * Main process only (node:crypto).
 */
const crypto = require('crypto');
const nodePath = require('path');
const fsDefault = require('fs');
const LanDevices = require('../lan-devices.js');
const { hostIsLocal, pinTooShort } = require('../lan-auth.js');
const ConnectorSlice = require('../connector-slice.js');
const ConnectorQueue = require('../connector-queue.js');
// The calculator's own code, which priceSlice reaches by its globals.
for (const m of ['tax', 'pricing', 'order-money', 'print-rates', 'calculator-cost', 'spool-edit', 'loaded-colours', 'spool-match']) {
  try { require('../' + m + '.js'); } catch (_) { /* priceSlice says which is missing */ }
}
const ConnectorPrice = require('../connector-price.js');
const LanPages = require('../lan-pages.js');
const ConnectorPairing = require('./connector-pairing.js');
const Slices = require('./connector-slices.js');
const { InboxFull, InboxDuplicate } = require('./slicer-inbox.js');

const PREFIX = LanDevices.CONNECTOR_PREFIX;              // '/api/connectors/'
const PAIR_PATH = '/api/connectors/pair';
const MAX_META_BYTES = 64 * 1024;
const MAX_SEALED_BYTES = 96 * 1024;
const PRICE_MAX_BYTES = 8 * 1024;
const PRICE_MAX_SEALED_BYTES = 12 * 1024;
const MAX_FILE_BYTES = 1 << 30;
const MAX_UPLOADS = 2;
const DISK_SPARE = 512 * 1024 * 1024;
const SEAL_SALT = 'khayt-connector-seal-v1';
const ETAG_SALT = 'khayt-connector-etag-v1';
const HASH_HEADER = 'x-khayt-content-sha256';
/** Per connector, by bucket: {limit, window seconds}. */
const RATES = Object.freeze({
  all: { limit: 600, window: 3600 },
  announce: { limit: 30, window: 3600 },
  file: { limit: 30, window: 3600 },
  queue: { limit: 1, window: 10 },
  price: { limit: 120, window: 3600 },
});
/** An allow-list: a key the rule adds later is not passed on until somebody decides who may see it. */
const PRICE_KEYS = ['currency', 'qty', 'unit', 'total', 'rounded', 'basis'];
const COST_INNER_KEYS = ['unit', 'total'];
const MARGIN_KEYS = ['pct', 'pctOnCost', 'amount'];

// ── Pure helpers (shared with the plugin through the vectors) ───────────────

/** HKDF-SHA256(K, salt "khayt-connector-seal-v1", info connectorId), 32 bytes. */
function sealKey(key, connectorId) {
  return Buffer.from(crypto.hkdfSync('sha256', key, SEAL_SALT, String(connectorId), 32));
}
/** What a sealed body is bound to: METHOD + " " + path. */
const sealAad = (method, path) => Buffer.from(String(method).toUpperCase() + ' ' + path, 'utf8');

/** `{"v":1,"alg":"A256GCM","nonce":b64(12),"ct":b64(ciphertext ‖ tag)}`. */
function seal(plain, key, aad, nonce = crypto.randomBytes(12)) {
  const c = crypto.createCipheriv('aes-256-gcm', key, nonce);
  c.setAAD(aad);
  const ct = Buffer.concat([c.update(plain), c.final(), c.getAuthTag()]);
  return Buffer.from(JSON.stringify({ v: 1, alg: 'A256GCM', nonce: nonce.toString('base64'), ct: ct.toString('base64') }), 'utf8');
}
/** The plain bytes of a sealed body, or null when anything about it is off. */
function unseal(sealed, key, aad) {
  let e;
  try { e = JSON.parse(Buffer.isBuffer(sealed) ? sealed.toString('utf8') : String(sealed)); } catch (_) { return null; }
  if (!e || typeof e !== 'object' || e.v !== 1 || e.alg !== 'A256GCM' || typeof e.nonce !== 'string' || typeof e.ct !== 'string') return null;
  const b64 = /^[A-Za-z0-9+/]*={0,2}$/;
  if (!b64.test(e.nonce) || !b64.test(e.ct)) return null;
  const nonce = Buffer.from(e.nonce, 'base64');
  const ct = Buffer.from(e.ct, 'base64');
  if (nonce.length !== 12 || ct.length < 16) return null;
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', key, nonce);
    d.setAAD(aad);
    d.setAuthTag(ct.subarray(ct.length - 16));
    return Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
  } catch (_) { return null; }
}
/** The queue's ETag: HMAC-SHA256(HKDF(K, "khayt-connector-etag-v1", connectorId), content), 32 hex, quoted. */
function queueEtag(content, key, connectorId) {
  const k = Buffer.from(crypto.hkdfSync('sha256', key, ETAG_SALT, String(connectorId), 32));
  return '"' + crypto.createHmac('sha256', k).update(String(content), 'utf8').digest('hex').slice(0, 32) + '"';
}
const onlyNumbers = (keys, o) => {
  const out = {};
  for (const k of keys) if (typeof o[k] === 'number' && Number.isFinite(o[k])) out[k] = o[k];
  return out;
};
/** What one grant sees of the rule's answer: `{"prices":"on", ...}` (the Mac's priceAnswer, #2617). */
function priceAnswer(priced, grant) {
  const out = { prices: 'on' };
  const p = priced && typeof priced === 'object' ? priced : {};
  if (p.unpriced !== undefined) { out.unpriced = p.unpriced; return out; }
  for (const k of PRICE_KEYS) if (p[k] !== undefined) out[k] = p[k];
  if (p.rounded === true && p.round && typeof p.round === 'object' && typeof p.round.step === 'number'
    && Number.isFinite(p.round.step) && p.round.step > 0) out.round = { step: p.round.step };
  if (grant === 'cost') {
    if (p.cost && typeof p.cost === 'object' && !Array.isArray(p.cost)) out.cost = onlyNumbers(COST_INNER_KEYS, p.cost);
    if (p.margin && typeof p.margin === 'object' && !Array.isArray(p.margin)) out.margin = onlyNumbers(MARGIN_KEYS, p.margin);
  }
  return out;
}

/** The route's own spelling: no trailing slash, `/v1` as `/api`. */
function routePath(raw) {
  let p = String(raw || '');
  if (p.length > 1 && p.endsWith('/')) p = p.slice(0, -1);
  if (p === '/v1' || p.startsWith('/v1/')) p = '/api' + p.slice(3);
  return p;
}
/** Exact shapes only, never a prefix match. Null when not a connector path. */
function connectorPath(path) {
  if (!String(path).startsWith(PREFIX)) return null;
  const rest = path.slice(PREFIX.length);
  if (rest === 'pair' || rest.startsWith('pair/')) return { kind: 'pair' };
  if (rest === 'self') return { kind: 'me' };
  if (rest === 'slices') return { kind: 'slices' };
  if (rest === 'queue') return { kind: 'queue' };
  if (rest === 'price') return { kind: 'price' };
  const parts = rest.split('/');
  if (parts.length === 2 && parts[0] === 'slices' && Slices.plausibleSliceId(parts[1])) return { kind: 'slice', id: parts[1] };
  if (parts.length === 3 && parts[0] === 'slices' && Slices.plausibleSliceId(parts[1]) && parts[2] === 'file') return { kind: 'sliceFile', id: parts[1] };
  return { kind: 'unknown' };
}
function pathOfUrl(rawUrl) {
  const u = String(rawUrl || '');
  const q = u.indexOf('?');
  return q < 0 ? u : u.slice(0, q);
}

/**
 * @param {object} d
 * @param {object} d.devices        lib/lan-devices.js
 * @param {object} d.pairing        lib/main/connector-pairing.js window
 * @param {object} d.identity       lib/lan-identity.js
 * @param {object} d.inbox          lib/main/slicer-inbox.js
 * @param {object} d.slices         lib/main/connector-slices.js
 * @param {object} d.uploads        { active } shared with the OctoPrint path
 * @param {function} d.enabled      () => bool: "Pair a slicer" is on
 * @param {function} d.pricesOn     () => bool: "Show prices in OrcaSlicer"
 * @param {function} d.getStore     () => the book
 * @param {function} d.pin          () => the PIN the server runs with
 * @param {function} [d.viaTunnel]  (req) => bool
 * @param {function} [d.rateClock]  seconds, monotonic (tests inject)
 * @param {function} [d.now]        wall ms
 * @param {function} [d.notFoundBody] () => string
 * @param {function} [d.priceContext] (store) => ctx for connector-price.js, or null
 * @param {function} [d.onDuplicate] (name) => void: the same bytes were already waiting
 * @param {object}   [d.fs]
 */
function createConnectorRoutes(d) {
  const fs = d.fs || fsDefault;
  const rateClock = d.rateClock || (() => (typeof performance !== 'undefined' ? performance.now() / 1000 : Date.now() / 1000));
  const now = d.now || Date.now;
  const viaTunnel = d.viaTunnel || (() => false);
  const notFoundBody = d.notFoundBody || (() => JSON.stringify({ error: 'Not found' }));
  const maxFileBytes = Math.min(d.maxFileBytes || MAX_FILE_BYTES, MAX_FILE_BYTES);
  const hits = new Map();       // connectorId -> { bucket: [seconds] }
  const isOn = () => { try { return d.enabled() === true; } catch (_) { return false; } };

  const send = (res, status, body, headers = {}) => {
    const buf = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body), 'utf8');
    res.writeHead(status, Object.assign({ 'Content-Type': 'application/json' }, headers));
    res.end(buf);
  };
  /** The answer, signed for the caller (x-khayt-reply-mac, no-store). */
  const signed = (res, caller, status, body, headers = {}) => {
    const buf = Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body), 'utf8');
    const h = Object.assign({}, headers, {
      'x-khayt-reply-mac': LanDevices.replyMac(caller.key, caller.nonce, status, buf),
      'Cache-Control': 'no-store',
    });
    if (status === 304) { res.writeHead(304, h); res.end(); return; }
    send(res, status, buf, h);
  };
  const notFound = (res) => send(res, 404, notFoundBody());

  /** Who is asking, or the refusal {status, body}. `verdict` is lan-devices verify's. */
  function gate(headers, req, verdict) {
    if (!hostIsLocal(headers.host) || viaTunnel(req)) return { refused: [421, { error: 'host-not-local' }] };
    const only = [403, { ok: false, reason: 'connector-only' }];
    if (headers['x-khayt-device'] == null) {
      const other = headers['x-khayt-pin'] != null || headers.authorization != null;
      return { refused: other ? only : [401, { reason: 'device-auth' }] };
    }
    const pin = String(d.pin() || '');
    if (!pin || pinTooShort(pin)) return { refused: [401, { reason: 'device-unknown' }] };
    const v = verdict || { ok: false, reason: 'device-auth' };
    if (v.ok !== true) {
      const body = { reason: v.reason };
      if (v.now != null) body.now = v.now;
      return { refused: [401, body] };
    }
    const id = String(headers['x-khayt-device']);
    const known = d.devices.connector(id);
    if (!known) return { refused: only };
    return { caller: { id, name: known.name, key: known.key, nonce: String(headers['x-khayt-nonce'] || '') } };
  }

  /** One step of a per-connector limit: null when allowed (and counted), else [429, body, headers]. */
  function rate(id, bucket) {
    const rule = RATES[bucket];
    if (!rule) return null;
    const t = rateClock();
    const mine = hits.get(id) || {};
    const list = (mine[bucket] || []).filter((x) => t - x < rule.window);
    if (list.length >= rule.limit) {
      mine[bucket] = list;
      hits.set(id, mine);
      const wait = Math.max(1, Math.ceil(list[0] + rule.window - t));
      return [429, { ok: false, reason: 'rate', retryAfter: wait }, { 'Retry-After': String(wait) }];
    }
    list.push(t);
    mine[bucket] = list;
    hits.set(id, mine);
    if (hits.size > 4 * LanDevices.MAX_DEVICES) {
      for (const [k, v] of hits) {
        if (!Object.values(v).some((xs) => xs.length && t - xs[xs.length - 1] < 3600)) hits.delete(k);
      }
    }
    return null;
  }

  /** 403 connector-scope for a connector's key anywhere but its own routes; null otherwise. */
  function refusal(headers, path) {
    const id = headers['x-khayt-device'];
    if (id == null) return null;
    let kind;
    try { kind = d.devices.kindOf(String(id)); } catch (_) { kind = undefined; }
    if (!LanDevices.isRestricted(kind)) return null;
    if (String(path).startsWith(PREFIX) && !path.includes('/../') && !path.endsWith('/..')) return null;
    return { status: 403, body: { ok: false, reason: 'connector-scope' } };
  }

  // ── What a connector may see ─────────────────────────────────────────────
  function grantOf(id) {
    let on = false;
    try { on = d.pricesOn() === true; } catch (_) { on = false; }
    if (!on || typeof d.priceContext !== 'function') return null;
    return d.devices.priceGrant(id);
  }
  function scopesOf(id) {
    const scopes = ['slices:send', 'queue:read'];
    const g = grantOf(id);
    if (g) { scopes.push('price:read'); if (g === 'cost') scopes.push('cost:read'); }
    return scopes;
  }
  const shopName = () => {
    const s = d.getStore() || {};
    try { return LanPages.shopNameOf(s.settings); } catch (_) { return 'Khayt'; }
  };
  const inboxItems = () => { try { return d.inbox.list(); } catch (_) { return []; } };
  const isoTime = (ms) => new Date(Math.floor(ms / 1000) * 1000).toISOString().replace('.000Z', 'Z');

  // ── The pairing routes (no PIN, no signature) ───────────────────────────
  function readJson(req, body, max, done) {
    const finish = (buf) => {
      if (buf == null) { done(undefined); return; }
      let parsed = null;
      try { parsed = JSON.parse(buf.toString('utf8')); } catch (_) { parsed = null; }
      done(parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null);
    };
    if (Buffer.isBuffer(body)) { finish(body.length > max ? null : body); return; }
    const chunks = [];
    let size = 0, tooBig = false;
    req.on('data', (c) => { if (tooBig) return; size += c.length; if (size > max) { tooBig = true; chunks.length = 0; return; } chunks.push(c); });
    req.on('error', () => {});
    req.on('end', () => finish(tooBig ? null : Buffer.concat(chunks)));
  }

  function pairRoute(req, res, path, body) {
    const local = () => hostIsLocal(req.headers.host) && !viaTunnel(req);
    if (path === PAIR_PATH) {
      if (req.method !== 'POST') { notFound(res); return; }
      if (!local()) { send(res, 421, { error: 'host-not-local' }); return; }
      if (!d.pairing.isOpen()) { send(res, 403, ConnectorPairing.CLOSED_BODY); return; }
      readJson(req, body, 4096, (asked) => {
        if (!asked) { send(res, 400, { error: 'commit' }); return; }
        if (asked.v !== 2 || typeof asked.commit !== 'string') { send(res, 400, ConnectorPairing.UPGRADE_BODY); return; }
        let identityPublic;
        try { identityPublic = d.identity.identity().publicKey; } catch (_) { send(res, 503, { error: 'no_identity' }); return; }
        const text = (k) => (typeof asked[k] === 'string' ? asked[k] : '');
        const out = d.pairing.request({
          commit: asked.commit, name: text('name'), app: text('app'), version: text('version'),
          address: String((req.socket && req.socket.remoteAddress) || ''),
          identity: { publicKey: identityPublic, sign: (m) => d.identity.signConnectorOffer(m) },
        });
        if (out.offer) { send(res, 200, out.offer); return; }
        if (out.refusal === 'closed') { send(res, 403, ConnectorPairing.CLOSED_BODY); return; }
        if (out.refusal === 'busy') { send(res, 409, ConnectorPairing.BUSY_BODY); return; }
        if (out.refusal === 'identity') { send(res, 503, { error: 'no_identity' }); return; }
        send(res, 400, { error: 'commit' });
      });
      return;
    }
    const rest = path.slice(PAIR_PATH.length + 1).split('/');
    const pairId = rest[0];
    const secret = String(req.headers['x-khayt-poll'] || '');
    if (rest.length === 2 && rest[1] === 'reveal' && req.method === 'POST' && ConnectorPairing.plausiblePairId(pairId)) {
      if (!local()) { send(res, 421, { error: 'host-not-local' }); return; }
      readJson(req, body, 4096, (shown) => {
        const publicKey = shown && typeof shown.publicKey === 'string' ? shown.publicKey : '';
        const nonce = shown && typeof shown.nonce === 'string' ? shown.nonce : '';
        const r = d.pairing.reveal(pairId, secret, publicKey, nonce);
        if (r === 'accepted') send(res, 200, { state: 'waiting' });
        else if (r === 'already') send(res, 409, { reason: 'already-revealed' });
        else if (r === 'refused') send(res, 403, { state: 'expired', reason: 'bad-reveal' });
        else send(res, 404, { state: 'unknown' });
      });
      return;
    }
    if (rest.length === 1 && (req.method === 'GET' || req.method === 'HEAD') && ConnectorPairing.plausiblePairId(pairId)) {
      const outcome = d.pairing.poll(pairId, secret);
      if (!outcome) { send(res, 404, { state: 'unknown' }); return; }
      send(res, 200, { state: outcome });
      return;
    }
    notFound(res);
  }

  // ── The connector's own routes ──────────────────────────────────────────
  /**
   * Answer a request whose path (already `/v1`→`/api`, no trailing slash) is
   * a connector path. Returns false when it is not one. `verdict` is
   * lan-devices verify's for this request (null when unsigned); `body` the
   * bytes it was verified over (null when nobody read them yet).
   */
  function handle(req, res, path, verdict, body) {
    const shape = connectorPath(path);
    if (!shape) return false;
    if (!isOn()) { notFound(res); return true; }
    if (shape.kind === 'pair') { pairRoute(req, res, path, body); return true; }
    if (shape.kind === 'unknown') { notFound(res); return true; }
    const method = req.method === 'HEAD' ? 'GET' : req.method;
    const allowed = { me: ['GET', 'DELETE'], slices: ['POST'], slice: ['GET'], sliceFile: ['PUT'], queue: ['GET'], price: ['POST'] }[shape.kind];
    if (!allowed.includes(method)) { send(res, 405, { ok: false, reason: 'method' }, { Allow: allowed.join(', ') }); return true; }
    // The file is the head-judged path (`fileUpload`), reached before any body is read.
    if (shape.kind === 'sliceFile') { notFound(res); return true; }
    const g = gate(req.headers, req, verdict);
    if (g.refused) { send(res, g.refused[0], g.refused[1]); return true; }
    const caller = g.caller;
    const limited = rate(caller.id, 'all');
    if (limited) { signed(res, caller, limited[0], limited[1], limited[2]); return true; }
    const reply = (status, b, h) => signed(res, caller, status, b, h);
    const withBody = (fn) => {
      if (Buffer.isBuffer(body)) { fn(body); return; }
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('error', () => {});
      req.on('end', () => fn(Buffer.concat(chunks)));
    };
    try {
      if (shape.kind === 'me' && method === 'GET') {
        reply(200, {
          connectorId: caller.id, name: caller.name, shop: { name: shopName() },
          limits: { maxFileBytes, maxMetaBytes: MAX_META_BYTES }, scopes: scopesOf(caller.id),
        });
      } else if (shape.kind === 'me') {
        d.slices.removeConnector(caller.id);
        hits.delete(caller.id);
        d.devices.remove(caller.id);
        reply(200, { ok: true });
      } else if (shape.kind === 'slices') {
        const l = rate(caller.id, 'announce');
        if (l) { reply(l[0], l[1], l[2]); return true; }
        withBody((b) => { const [s, o] = announce(b, path, caller); reply(s, o); });
      } else if (shape.kind === 'slice') {
        const [s, o] = sliceState(shape.id, caller);
        reply(s, o);
      } else if (shape.kind === 'queue') {
        const l = rate(caller.id, 'queue');
        if (l) { reply(l[0], l[1], l[2]); return true; }
        queue(req, path, caller, reply);
      } else if (shape.kind === 'price') {
        const l = rate(caller.id, 'price');
        if (l) { reply(l[0], l[1], l[2]); return true; }
        withBody((b) => price(b, path, caller, reply));
      }
    } catch (_) {
      if (!res.headersSent) reply(500, { ok: false, reason: 'internal' });
    }
    return true;
  }

  function sliceState(id, caller) {
    const s = d.slices.own(id, caller.id);
    if (!s) return [404, { ok: false, reason: 'unknown-slice' }];
    let state = s.state === 'receiving' ? 'awaiting-file' : s.state;
    if (state === 'in-inbox' && s.inboxId && !inboxItems().some((i) => i.id === s.inboxId)) {
      state = 'left-inbox';
      d.slices.setState(id, 'left-inbox');
    }
    return [200, { sliceId: id, state }];
  }

  /** POST /api/connectors/slices: open the capture, check it with the shared rule, say where to send the file. */
  function announce(body, path, caller) {
    if (body.length > MAX_SEALED_BYTES) return [413, { ok: false, reason: 'too-large' }];
    const plain = unseal(body, sealKey(caller.key, caller.id), sealAad('POST', path));
    if (!plain) return [400, { ok: false, reason: 'seal' }];
    if (plain.length > MAX_META_BYTES) return [413, { ok: false, reason: 'too-large' }];
    let input;
    try { input = JSON.parse(plain.toString('utf8')); } catch (_) { return [400, { ok: false, reason: 'not-json' }]; }
    const checked = ConnectorSlice.check(input, { maxFileBytes });
    const cap = checked && checked.ok === true ? checked.capture : null;
    if (!cap || !cap.file || typeof cap.file.name !== 'string') {
      const refused = { ok: false, reason: (checked && checked.reason) || 'capture' };
      if (checked && checked.field !== undefined) refused.field = checked.field;
      return [422, refused];
    }
    const { name, bytes, sha256: sha } = cap.file;
    const suggested = cap.suggested || { intent: 'inbox' };
    const slots = cap.filaments !== undefined ? cap.filaments : null;
    const dropped = checked.dropped || [];
    d.slices.prune();
    const t = now();
    const held = inboxItems().find((i) => i.sha256 === sha);
    if (held) {
      if (typeof d.onDuplicate === 'function') { try { d.onDuplicate(name); } catch (_) { /* a notice */ } }
      const mine = d.slices.values().find((s) => s.connectorId === caller.id && s.inboxId === held.id);
      const sliceId = mine ? mine.id : Slices.freshSliceId();
      if (!mine) {
        d.slices.put({ id: sliceId, connectorId: caller.id, name, bytes, sha256: sha, suggested, slots,
          uploadBy: t, state: 'in-inbox', attempts: 0, inboxId: held.id, changedAt: t });
      }
      return [200, { sliceId, state: 'in-inbox', duplicate: true }];
    }
    const waiting = d.slices.values().find((s) => s.connectorId === caller.id && s.sha256 === sha
      && (s.state === 'awaiting-file' || s.state === 'receiving'));
    if (waiting) return [200, { sliceId: waiting.id, state: 'awaiting-file', uploadBy: isoTime(waiting.uploadBy) }];
    if (inboxItems().length >= d.inbox.maxWaiting) return [409, { ok: false, reason: 'inbox-full' }];
    let sliceId = Slices.freshSliceId();
    while (d.slices.get(sliceId)) sliceId = Slices.freshSliceId();
    const uploadBy = t + Slices.AWAIT_MS;
    d.slices.put({ id: sliceId, connectorId: caller.id, name, bytes, sha256: sha, suggested, slots,
      uploadBy, state: 'awaiting-file', attempts: 0, inboxId: null, changedAt: t });
    const answer = { sliceId, state: 'awaiting-file', uploadBy: isoTime(uploadBy), dropped };
    // Asked, and not done: v1 never starts a print, or makes a job.
    if (suggested && suggested.intent !== 'inbox') answer.intentHonoured = false;
    return [201, answer];
  }

  /** GET /api/connectors/queue: the redacted queue, sealed, with a keyed ETag over everything but its time. */
  function queue(req, path, caller, reply) {
    const store = d.getStore() || {};
    let snap;
    try {
      snap = ConnectorQueue.snapshot(store, { connectorId: caller.id, now: now(), shopName: shopName(), inboxWaiting: inboxItems().length });
    } catch (_) { reply(500, { ok: false, reason: 'queue' }); return; }
    const content = Object.assign({}, snap);
    delete content.at;
    const etag = queueEtag(JSON.stringify(content), caller.key, caller.id);
    const asked = req.headers['if-none-match'];
    if (asked && String(asked).split(',').map((x) => x.trim()).includes(etag)) { reply(304, Buffer.alloc(0), { ETag: etag }); return; }
    const sealed = seal(Buffer.from(JSON.stringify(snap), 'utf8'), sealKey(caller.key, caller.id), sealAad('GET', path));
    reply(200, sealed, { ETag: etag });
  }

  /** POST /api/connectors/price: the shop's price for a sliced plate, sealed both ways. Nothing is stored. */
  function price(body, path, caller, reply) {
    if (body.length > PRICE_MAX_SEALED_BYTES) { reply(413, { ok: false, reason: 'too-large' }); return; }
    const key = sealKey(caller.key, caller.id);
    const aad = sealAad('POST', path);
    const plain = unseal(body, key, aad);
    if (!plain) { reply(400, { ok: false, reason: 'seal' }); return; }
    if (plain.length > PRICE_MAX_BYTES) { reply(413, { ok: false, reason: 'too-large' }); return; }
    let facts;
    try { facts = JSON.parse(plain.toString('utf8')); } catch (_) { reply(400, { ok: false, reason: 'not-json' }); return; }
    let answer = { prices: 'off' };
    const grant = grantOf(caller.id);
    if (grant) {
      let priced;
      try {
        const ctx = d.priceContext(d.getStore() || {});
        priced = ctx ? ConnectorPrice.priceSlice(facts, ctx) : null;
      } catch (_) { priced = null; }
      if (!priced || typeof priced !== 'object') { reply(500, { ok: false, reason: 'price' }); return; }
      answer = priceAnswer(priced, grant);
    }
    reply(200, seal(Buffer.from(JSON.stringify(answer), 'utf8'), key, aad));
  }

  // ── The file, judged from its head (before withSignedBody reads a byte) ──
  function isFileUpload(method, rawUrl) {
    if (String(method).toUpperCase() !== 'PUT') return false;
    const s = connectorPath(routePath(pathOfUrl(rawUrl)));
    return !!s && s.kind === 'sliceFile';
  }

  /**
   * PUT /api/connectors/slices/{id}/file. Every question is answered from
   * the head before ONE byte of body is read; then `100 Continue` and the
   * body is spooled under the inbox and hashed as it lands.
   * `expectContinue`: Node held the 100 for us (server 'checkContinue').
   */
  function fileUpload(req, res, { expectContinue = false } = {}) {
    let pathname;
    try { pathname = routePath(new URL(req.url, 'http://localhost').pathname); } catch (_) { pathname = ''; }
    const shape = connectorPath(pathname);
    // Answered without the body: say so and close, rather than read a gigabyte.
    const refuse = (fn) => {
      res.setHeader('Connection', 'close');
      res.on('finish', () => setTimeout(() => { try { req.socket.destroy(); } catch (_) { /* gone */ } }, 1000).unref());
      req.on('error', () => {});
      fn();
    };
    if (!isOn() || !shape || shape.kind !== 'sliceFile') { refuse(() => notFound(res)); return; }
    const declared = String(req.headers[HASH_HEADER] || '').toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(declared)) { refuse(() => send(res, 400, { ok: false, reason: 'no-hash' })); return; }
    let verdict = null;
    const pinNow = String(d.pin() || '');
    if (req.headers['x-khayt-device'] != null && pinNow && !pinTooShort(pinNow)) {
      try {
        verdict = d.devices.verify({ headers: req.headers, method: req.method, target: req.url, body: null, pin: pinNow, bodyHash: declared });
      } catch (_) { verdict = { ok: false, reason: 'device-unknown' }; }
    }
    const g = gate(req.headers, req, verdict);
    if (g.refused) { refuse(() => send(res, g.refused[0], g.refused[1])); return; }
    const caller = g.caller;
    const no = (status, body, h) => refuse(() => signed(res, caller, status, body, h));
    const limited = rate(caller.id, 'all') || rate(caller.id, 'file');
    if (limited) { no(limited[0], limited[1], limited[2]); return; }
    const slice = d.slices.own(shape.id, caller.id);
    if (!slice || slice.state === 'expired') { no(404, { ok: false, reason: 'unknown-slice' }); return; }
    if (slice.state !== 'awaiting-file') { no(409, { ok: false, reason: 'not-awaiting-file' }); return; }
    if (declared !== slice.sha256) { no(409, { ok: false, reason: 'hash-not-declared' }); return; }
    const lenHeader = req.headers['content-length'];
    const length = /^\d{1,16}$/.test(String(lenHeader || '')) ? Number(lenHeader) : -1;
    if (length > maxFileBytes) { no(413, { ok: false, reason: 'too-large' }); return; }
    if (length !== slice.bytes) { no(400, { ok: false, reason: 'length-mismatch' }); return; }
    if (d.uploads.active >= MAX_UPLOADS) { no(503, { ok: false, reason: 'busy' }); return; }
    const free = d.inbox.freeBytes();
    if (free != null && free < length * 2 + DISK_SPARE) { no(507, { ok: false, reason: 'disk' }); return; }

    d.uploads.active += 1;
    d.slices.setState(slice.id, 'receiving');
    let released = false;
    const release = () => { if (!released) { released = true; d.uploads.active -= 1; } };
    let spool;
    try { spool = d.inbox.spoolPath(slice.name); } catch (_) {
      release(); d.slices.setState(slice.id, 'awaiting-file');
      no(500, { ok: false, reason: 'store' }); return;
    }
    const spoolDir = nodePath.dirname(spool);
    const cleanup = () => { try { fs.rmSync(spoolDir, { recursive: true, force: true }); } catch (_) { /* scratch */ } };
    const out = fs.createWriteStream(spool, { mode: 0o600 });
    const hasher = crypto.createHash('sha256');
    let got = 0, failed = false;
    const fail = () => {
      if (failed) return;
      failed = true;
      release();
      out.destroy();
      cleanup();
      // The client went or stalled: the slice may be sent again.
      const s = d.slices.get(slice.id);
      if (s && s.state === 'receiving') d.slices.setState(slice.id, 'awaiting-file');
    };
    req.on('data', (c) => {
      if (failed) return;
      const take = got + c.length > length ? c.subarray(0, length - got) : c;
      got += take.length;
      hasher.update(take);
      if (!out.write(take)) { req.pause(); out.once('drain', () => req.resume()); }
    });
    req.on('aborted', fail);
    req.on('error', fail);
    out.on('error', () => { fail(); if (!res.headersSent) signed(res, caller, 500, { ok: false, reason: 'store' }); });
    req.on('end', () => {
      if (failed) return;
      if (got !== length) { fail(); return; }
      out.once('close', () => {
        if (failed) return;
        release();
        const sha = hasher.digest('hex');
        const [status, body] = arrived(slice.id, spool, sha, caller);
        cleanup();
        signed(res, caller, status, body);
      });
      out.end();
    });
    if (expectContinue) res.writeContinue();
  }

  /** The file is on disk and hashed: file it, or say why not. */
  function arrived(sliceId, file, sha, caller) {
    const slice = d.slices.get(sliceId);
    if (!slice || slice.connectorId !== caller.id || slice.state !== 'receiving') return [404, { ok: false, reason: 'unknown-slice' }];
    if (sha !== slice.sha256) {
      const attempts = (slice.attempts || 0) + 1;
      const retry = attempts < Slices.MAX_ATTEMPTS;
      d.slices.update(sliceId, { attempts, state: retry ? 'awaiting-file' : 'expired', changedAt: now() });
      return [422, { ok: false, reason: 'hash-mismatch', retry }];
    }
    const origin = { connectorId: caller.id, connectorName: caller.name, sliceId, suggested: slice.suggested, slots: slice.slots };
    try {
      const item = d.inbox.file(file, slice.name, { sha256: sha, origin });
      d.slices.update(sliceId, { state: 'in-inbox', inboxId: item.id, changedAt: now() });
      return [201, { sliceId, state: 'in-inbox' }];
    } catch (e) {
      if (e instanceof InboxDuplicate) {
        d.slices.update(sliceId, { state: 'in-inbox', inboxId: e.item.id, changedAt: now() });
        if (typeof d.onDuplicate === 'function') { try { d.onDuplicate(slice.name); } catch (_) { /* a notice */ } }
        return [200, { sliceId, state: 'in-inbox', duplicate: true }];
      }
      d.slices.setState(sliceId, 'awaiting-file');
      if (e instanceof InboxFull) return [409, { ok: false, reason: 'inbox-full' }];
      return [500, { ok: false, reason: 'store' }];
    }
  }

  return { handle, refusal, isFileUpload, fileUpload, connectorPath, gate, rate, scopesOf };
}

module.exports = {
  createConnectorRoutes, sealKey, sealAad, seal, unseal, queueEtag, priceAnswer, connectorPath, routePath,
  RATES, PRICE_KEYS, COST_INNER_KEYS, MARGIN_KEYS, MAX_META_BYTES, MAX_SEALED_BYTES, MAX_FILE_BYTES, MAX_UPLOADS,
  SEAL_SALT, ETAG_SALT, HASH_HEADER,
};
