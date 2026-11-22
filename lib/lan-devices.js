'use strict';
/**
 * Per-device keys for the LAN API: the PIN crosses the network once.
 *
 * The LAN is plain http, so a PIN sent with every request can be read by
 * anything on the shop's Wi-Fi. A phone that has paired with the PIN enrols
 * once (POST /api/devices, the last request that carries the PIN) and then
 * signs each request with a key only it and this computer hold. A captured
 * request cannot be replayed, and nothing in it leads back to the PIN.
 *
 * The wire format is docs/LAN_API.md, "POST /api/devices and signed
 * requests", and docs/lan-device-keys.vectors.json holds values the phone, the
 * Mac and this file must all reproduce:
 *
 *   enrol   X25519 between the phone's key and a fresh one of ours, then
 *           key = HKDF-SHA256(shared, salt "khayt-device-v1", info deviceId, 32).
 *           Our half is signed with the /api/identity key so the phone knows
 *           which computer it enrolled with. Our X25519 private key is dropped.
 *   request mac = HMAC-SHA256(key, "khayt-req-v1\nMETHOD\ntarget\ntime\nnonce\nhex sha256(body)")
 *
 * The keys live beside the identity key in userData, sealed with the keychain
 * where there is one: never in the book, so a backup or a synced second
 * computer does not carry them. A PIN change removes every device. The file
 * keeps a keyed tag of the PIN it was enrolled under rather than relying on
 * the settings screen to tell us, so a PIN changed anywhere (on this
 * computer, or synced from the Mac) revokes them all the same.
 *
 * One phone can be signed out on its own (Settings → LAN, "Paired phones").
 * Its id is remembered, the newest 256, so its next request is answered
 * `device-revoked` rather than `device-unknown`: the phone then drops the PIN
 * it kept as well and asks for it again, instead of quietly enrolling anew.
 *
 * Main process only (node:crypto).
 */
const crypto = require('crypto');

const SEALED_MAGIC = 'khayt-sealed:';
const HKDF_SALT = 'khayt-device-v1';
const ENROL_PREFIX = 'khayt-enrol:';
const REQ_PREFIX = 'khayt-req-v1';
const MAX_DEVICES = 32;
// Signed-out ids remembered; the oldest go first. An id is random, so one
// forgotten is only a phone told device-unknown instead.
const MAX_REVOKED = 256;
const CLOCK_SKEW_S = 120;
const NONCE_TTL_MS = 300_000;
const MAX_NONCES_PER_DEVICE = 10_000;
// How often a request's lastSeenAt is written to disk. In memory it is exact;
// on disk it only orders which device a 33rd replaces, and a write per request
// would be a keychain round trip per request.
const LAST_SEEN_PERSIST_MS = 3_600_000;
const NAME_MAX = 60;
const DEVICE_ID_RE = /^dev_[A-Za-z0-9_-]{12,40}$/;
const NONCE_RE = /^[0-9a-f]{32}$/;
const TIME_RE = /^-?\d{1,12}$/;

const X25519_SPKI = Buffer.from('302a300506032b656e032100', 'hex');

function x25519Public(raw) {
  return crypto.createPublicKey({ key: Buffer.concat([X25519_SPKI, raw]), format: 'der', type: 'spki' });
}
function rawPublic(keyObject) {
  const der = keyObject.export({ type: 'spki', format: 'der' });
  return der.subarray(der.length - 32);
}
function b64Raw32(s) {
  if (typeof s !== 'string' || !/^[A-Za-z0-9+/]{43}=$/.test(s)) return null;
  const buf = Buffer.from(s, 'base64');
  return buf.length === 32 ? buf : null;
}

/** HKDF-SHA256(shared, "khayt-device-v1", deviceId, 32). */
function deriveDeviceKey(shared, deviceId) {
  return Buffer.from(crypto.hkdfSync('sha256', shared, HKDF_SALT, String(deviceId), 32));
}

/** The enrolment message the identity key signs. */
function enrolMessage(deviceId, serverPublicB64, phonePublicB64) {
  return `${ENROL_PREFIX}${deviceId}:${serverPublicB64}:${phonePublicB64}`;
}

/** The canonical string a request's MAC covers. `body` is a Buffer or absent. */
function canonicalRequest(method, target, time, nonce, body) {
  const hash = crypto.createHash('sha256').update(body || Buffer.alloc(0)).digest('hex');
  return [REQ_PREFIX, String(method).toUpperCase(), target, time, nonce, hash].join('\n');
}

function requestMac(key, canonical) {
  return crypto.createHmac('sha256', key).update(canonical, 'utf8').digest('base64');
}

/**
 * @param {object} o
 * @param {object} o.fs
 * @param {string} o.keyPath       file the devices are kept in
 * @param {function} [o.seal]      string -> Buffer|null (null: no keychain, file is owner-only)
 * @param {function} [o.unseal]    Buffer -> string
 * @param {function} [o.now]       ms clock, for tests
 * @param {function} [o.newKeyPair]  tests: a fixed X25519 pair
 * @param {function} [o.newDeviceId] tests: a fixed id
 */
function createLanDevices({ fs, keyPath, seal = null, unseal = null, now = Date.now,
  newKeyPair = () => crypto.generateKeyPairSync('x25519'),
  newDeviceId = () => 'dev_' + crypto.randomBytes(12).toString('base64url') }) {
  let state = null;          // { pinSalt, pinTag, devices: [{deviceId,name,key,createdAt,lastSeenAt}], revoked: {deviceId: iso} }
  let persistedAt = 0;
  const nonces = new Map();  // deviceId -> Map(nonce -> expiresAt)

  function load() {
    if (state) return state;
    let raw = null;
    try { raw = fs.readFileSync(keyPath, 'utf8'); }
    catch (e) { if (!e || e.code !== 'ENOENT') throw e; }
    if (raw == null) {
      state = { pinSalt: crypto.randomBytes(32).toString('base64'), pinTag: '', devices: [], revoked: {} };
      return state;
    }
    // A file that is there but cannot be opened (keychain locked for a
    // moment) is not overwritten here: the request fails and the phone falls
    // back to the PIN until it can be read.
    const json = raw.startsWith(SEALED_MAGIC)
      ? (unseal ? unseal(Buffer.from(raw.slice(SEALED_MAGIC.length), 'base64')) : null)
      : raw;
    if (!json) throw new Error('LAN device keys are sealed and the keychain is unavailable');
    const parsed = JSON.parse(json);
    state = {
      pinSalt: String(parsed.pinSalt || crypto.randomBytes(32).toString('base64')),
      pinTag: String(parsed.pinTag || ''),
      devices: Array.isArray(parsed.devices) ? parsed.devices.filter(d => d && DEVICE_ID_RE.test(d.deviceId) && b64Raw32(d.key)) : [],
      // A file written before sign-out existed has none.
      revoked: parsed.revoked && typeof parsed.revoked === 'object' && !Array.isArray(parsed.revoked)
        ? Object.fromEntries(Object.entries(parsed.revoked).filter(([id, at]) => DEVICE_ID_RE.test(id) && typeof at === 'string'))
        : {},
    };
    return state;
  }

  function save() {
    const out = JSON.stringify({ v: 1, pinSalt: state.pinSalt, pinTag: state.pinTag, devices: state.devices, revoked: state.revoked });
    const sealed = seal ? seal(out) : null;
    const body = sealed ? SEALED_MAGIC + sealed.toString('base64') : out;
    const tmp = `${keyPath}.tmp`;
    fs.writeFileSync(tmp, body, { mode: 0o600 });
    fs.renameSync(tmp, keyPath);
    persistedAt = now();
  }

  function pinTagFor(pin) {
    return crypto.createHmac('sha256', Buffer.from(state.pinSalt, 'base64')).update(String(pin || ''), 'utf8').digest('base64');
  }

  // Enrolled under a different PIN, or under none: every device goes.
  function enforcePin(pin) {
    const tag = pin ? pinTagFor(pin) : '';
    if (state.pinTag === tag) return;
    const had = state.devices.length > 0;
    state.devices = [];
    state.pinTag = tag;
    nonces.clear();
    if (had) save();
  }

  /**
   * POST /api/devices, after the PIN gate. `sign(message)` is the identity
   * key's enrolment signer and may throw (keychain): the caller answers 503.
   * Returns { deviceId, publicKey, sig }, or { error } for a bad request.
   */
  function enrol({ publicKey, name, pin, sign }) {
    const phoneRaw = b64Raw32(publicKey);
    if (!phoneRaw) return { error: 'publicKey' };
    load();
    enforcePin(pin);
    const pair = newKeyPair();
    const serverPublic = rawPublic(pair.publicKey).toString('base64');
    let shared;
    try { shared = crypto.diffieHellman({ privateKey: pair.privateKey, publicKey: x25519Public(phoneRaw) }); }
    catch (_) { return { error: 'publicKey' }; }
    // A low-order point gives an all-zero secret; refuse it rather than key a device with it.
    if (shared.every(b => b === 0)) return { error: 'publicKey' };
    let deviceId = newDeviceId();
    while (state.devices.some(d => d.deviceId === deviceId) || state.revoked[deviceId]) deviceId = newDeviceId();
    const sig = sign(enrolMessage(deviceId, serverPublic, publicKey));
    const at = new Date(now()).toISOString();
    const rec = {
      deviceId,
      name: String(name == null ? '' : name).trim().slice(0, NAME_MAX),
      key: deriveDeviceKey(shared, deviceId).toString('base64'),
      createdAt: at,
      lastSeenAt: at,
    };
    state.devices.push(rec);
    if (state.devices.length > MAX_DEVICES) {
      // The 33rd replaces the one seen longest ago.
      state.devices.sort((a, b) => String(a.lastSeenAt).localeCompare(String(b.lastSeenAt)));
      const gone = state.devices.splice(0, state.devices.length - MAX_DEVICES);
      for (const g of gone) nonces.delete(g.deviceId);
    }
    save();
    return { deviceId, publicKey: serverPublic, sig };
  }

  function seenNonce(deviceId, nonce, t) {
    let m = nonces.get(deviceId);
    if (!m) { m = new Map(); nonces.set(deviceId, m); }
    for (const [n, exp] of m) { if (exp <= t) m.delete(n); else break; }
    if (m.has(nonce) && m.get(nonce) > t) return true;
    if (m.size >= MAX_NONCES_PER_DEVICE) m.delete(m.keys().next().value);
    m.set(nonce, t + NONCE_TTL_MS);
    return false;
  }

  /**
   * Judge a signed request. `headers` are Node's (lower-case names); `target`
   * is req.url as it came in; `body` the raw bytes. Returns { ok: true,
   * deviceId } or { ok: false, reason, now? } with the reasons LAN_API.md names.
   */
  function verify({ headers, method, target, body, pin }) {
    const deviceId = String(headers['x-khayt-device'] || '');
    const time = String(headers['x-khayt-time'] || '');
    const nonce = String(headers['x-khayt-nonce'] || '');
    const macB64 = String(headers['x-khayt-mac'] || '');
    if (!DEVICE_ID_RE.test(deviceId) || !TIME_RE.test(time) || !NONCE_RE.test(nonce)) {
      return { ok: false, reason: 'device-auth' };
    }
    const given = b64Raw32(macB64);
    if (!given) return { ok: false, reason: 'device-auth' };
    try { load(); } catch (_) { return { ok: false, reason: 'device-unknown' }; }
    enforcePin(pin);
    const dev = state.devices.find(d => d.deviceId === deviceId);
    if (!dev) return { ok: false, reason: state.revoked[deviceId] ? 'device-revoked' : 'device-unknown' };
    const want = Buffer.from(requestMac(Buffer.from(dev.key, 'base64'), canonicalRequest(method, target, time, nonce, body)), 'base64');
    if (!crypto.timingSafeEqual(want, given)) return { ok: false, reason: 'device-auth' };
    const t = now();
    const nowS = Math.floor(t / 1000);
    if (Math.abs(nowS - Number(time)) > CLOCK_SKEW_S) return { ok: false, reason: 'device-clock', now: nowS };
    if (seenNonce(deviceId, nonce, t)) return { ok: false, reason: 'device-replay' };
    dev.lastSeenAt = new Date(t).toISOString();
    if (t - persistedAt > LAST_SEEN_PERSIST_MS) { try { save(); } catch (_) { /* next time */ } }
    return { ok: true, deviceId };
  }

  /** Name, dates and id per device, the one seen most recently first; never the key. */
  function list() {
    load();
    return state.devices
      .map(({ deviceId, name, createdAt, lastSeenAt }) => ({ deviceId, name, createdAt, lastSeenAt }))
      .sort((a, b) => String(b.lastSeenAt).localeCompare(String(a.lastSeenAt)));
  }

  /**
   * Sign one phone out. Its key is forgotten and its id kept, so its next
   * request is refused device-revoked. The other phones keep theirs: until
   * this, changing the PIN was the only way to cut off a lost phone, and it
   * signed out every one. Returns whether it was paired.
   */
  function remove(deviceId) {
    load();
    const at = state.devices.findIndex(d => d.deviceId === deviceId);
    if (at < 0) return false;
    state.devices.splice(at, 1);
    nonces.delete(deviceId);
    state.revoked[deviceId] = new Date(now()).toISOString();
    const ids = Object.keys(state.revoked);
    if (ids.length > MAX_REVOKED) {
      ids.sort((a, b) => state.revoked[a].localeCompare(state.revoked[b]));
      for (const id of ids.slice(0, ids.length - MAX_REVOKED)) delete state.revoked[id];
    }
    save();
    return true;
  }

  return { enrol, verify, list, remove };
}

module.exports = {
  createLanDevices, deriveDeviceKey, enrolMessage, canonicalRequest, requestMac,
  MAX_DEVICES, MAX_REVOKED, CLOCK_SKEW_S, NONCE_TTL_MS, ENROL_PREFIX,
};
