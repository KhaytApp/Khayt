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
 * computer does not carry them. A PIN change removes every device enrolled
 * with the PIN (one paired by code stays, below). The file
 * keeps a keyed tag of the PIN it was enrolled under rather than relying on
 * the settings screen to tell us, so a PIN changed anywhere (on this
 * computer, or synced from the Mac) revokes them all the same.
 *
 * One phone can be signed out on its own (Settings → LAN, "Paired phones").
 * Its id is remembered, the newest 256, so its next request is answered
 * `device-revoked` rather than `device-unknown`: the phone then drops the PIN
 * it kept as well and asks for it again, instead of quietly enrolling anew.
 *
 * SIGNED ANSWERS (as the Mac, #2640 and #2643). Some answers a phone must be
 * able to trust carry `x-khayt-reply-mac` = replyMac(key, request nonce,
 * status, body): `/api/status`'s `network` block, and the `device-revoked`
 * refusal. The verdict carries the key and nonce to sign with as
 * NON-ENUMERABLE properties (`replyKey`, `replyNonce`), so they are never
 * logged or serialised with it. A signed-out phone's old key is kept, the
 * newest MAX_REVOKED, for that refusal alone: a request it signs is answered
 * `device-revoked`, signed, and it opens nothing.
 *
 * PAIRED BY CODE, WITH A ROLE (C1 + C9, as the Mac's LanDevices). A phone a
 * person approved by its check number (lib/main/phone-pairing.js) is admitted
 * with `admitPhone`: it carries `role`, `rolesVersion: 1` and `codePaired:
 * true`, and no tie to the PIN, so a PIN change does not sign it out (D-P7);
 * Remove does. A phone enrolled with the PIN carries none of the three and is
 * the owner, as it always was (lib/device-roles.js roleOf). `rulesRecord`
 * hands the rule exactly what is stored, and a code-paired record always
 * carries `rolesVersion`, so one whose role was lost or garbled can never read
 * as the pre-roles owner.
 *
 * A SLICER PLUGIN (kind `connector`, as the Mac's LanDevices.kindConnector).
 * Paired through lib/main/connector-pairing.js and admitted with
 * `admitConnector`. It is tied to the PIN like a PIN-paired phone (a PIN
 * change signs it out, `device-unknown`), carries `kind: "connector"` and an
 * optional `priceGrant` (`price` or `cost`), and its key opens
 * `/api/connectors/*` only (lib/main/connector-routes.js `refusal`). Any kind
 * this build does not know is restricted the same way (`isRestricted`).
 * 32 of each kind at most: a full store makes room within the SAME kind.
 *
 * Main process only (node:crypto).
 */
const crypto = require('crypto');

const SEALED_MAGIC = 'khayt-sealed:';
const HKDF_SALT = 'khayt-device-v1';
const ENROL_PREFIX = 'khayt-enrol:';
const REQ_PREFIX = 'khayt-req-v1';
const REPLY_PREFIX = 'khayt-reply-v1';
const MAX_DEVICES = 32;
// What `rolesVersion` is written as (the Mac's LanDevices.rolesVersion).
const ROLES_VERSION = 1;
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
const KIND_CONNECTOR = 'connector';
const CONNECTOR_PREFIX = '/api/connectors/';
const PRICE_GRANTS = ['price', 'cost'];
/** A device of any kind but a phone (none) opens only its own routes. */
const isRestricted = (kind) => kind !== undefined && kind !== null;
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

/**
 * The canonical string a request's MAC covers. `body` is a Buffer or absent.
 * `bodyHash` (lower-case hex) stands in for the body's own hash when the body
 * is not read yet: a connector's file upload, judged at its head against the
 * hash its capture declared (docs/connector-routes.vectors.json `request`).
 */
function canonicalRequest(method, target, time, nonce, body, bodyHash) {
  const hash = typeof bodyHash === 'string' ? bodyHash : crypto.createHash('sha256').update(body || Buffer.alloc(0)).digest('hex');
  return [REQ_PREFIX, String(method).toUpperCase(), target, time, nonce, hash].join('\n');
}

function requestMac(key, canonical) {
  return crypto.createHmac('sha256', key).update(canonical, 'utf8').digest('base64');
}

/**
 * The MAC on an answer: HMAC-SHA256(key, "khayt-reply-v1\n" + nonce + "\n" +
 * status + "\n" + hex sha256(body)), base64. The connector's and the Mac's
 * (docs/connector-routes.vectors.json `reply`).
 */
function replyMac(key, nonce, status, body) {
  const hash = crypto.createHash('sha256').update(body == null ? Buffer.alloc(0) : body).digest('hex');
  return crypto.createHmac('sha256', key).update(`${REPLY_PREFIX}\n${nonce}\n${status}\n${hash}`, 'utf8').digest('base64');
}

/** A verdict with the key and nonce to sign its answer, kept off its enumerable shape. */
/** Paired by a code a person approved, not by the PIN: kept across a PIN change. */
function isCodePaired(d) { return !!d && d.codePaired === true; }

function withReply(verdict, key, nonce) {
  Object.defineProperty(verdict, 'replyKey', { value: key, enumerable: false });
  Object.defineProperty(verdict, 'replyNonce', { value: nonce, enumerable: false });
  return verdict;
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
  let state = null;          // { pinSalt, pinTag, devices: [{deviceId,name,key,createdAt,lastSeenAt}], revoked: {deviceId: iso}, revokedKeys: {deviceId: key} }
  let persistedAt = 0;
  const nonces = new Map();  // deviceId -> Map(nonce -> expiresAt)

  function load() {
    if (state) return state;
    let raw = null;
    try { raw = fs.readFileSync(keyPath, 'utf8'); }
    catch (e) { if (!e || e.code !== 'ENOENT') throw e; }
    if (raw == null) {
      state = { pinSalt: crypto.randomBytes(32).toString('base64'), pinTag: '', devices: [], revoked: {}, revokedKeys: {} };
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
      // A signed-out phone's old key, for its signed device-revoked only.
      revokedKeys: parsed.revokedKeys && typeof parsed.revokedKeys === 'object' && !Array.isArray(parsed.revokedKeys)
        ? Object.fromEntries(Object.entries(parsed.revokedKeys).filter(([id, k]) => DEVICE_ID_RE.test(id) && b64Raw32(k)))
        : {},
    };
    return state;
  }

  function save() {
    const out = JSON.stringify({ v: 1, pinSalt: state.pinSalt, pinTag: state.pinTag, devices: state.devices, revoked: state.revoked, revokedKeys: state.revokedKeys });
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

  // Enrolled under a different PIN, or under none: every device that enrolled
  // with the PIN goes. A phone paired by code holds no PIN and stays (D-P7).
  function enforcePin(pin) {
    const tag = pin ? pinTagFor(pin) : '';
    if (state.pinTag === tag) return;
    const before = state.devices.length;
    state.devices = state.devices.filter(isCodePaired);
    const had = state.devices.length !== before;
    state.pinTag = tag;
    nonces.clear();
    if (had) save();
  }

  /**
   * A phone a person approved by its check number (lib/main/phone-pairing.js),
   * with the role they chose. The key is derived from the X25519 key drawn for
   * that offer and the key the phone revealed. No PIN tag: a PIN change does
   * not sign it out. `pin` is the PIN in force, so devices enrolled under
   * another are cleared first, as every enrolment does.
   * Returns { deviceId } or { error }.
   */
  function admitPhone({ serverPrivate, phonePublic, deviceId, name, role, pin }) {
    const phoneRaw = b64Raw32(phonePublic);
    if (!phoneRaw || !DEVICE_ID_RE.test(String(deviceId || ''))) return { error: 'publicKey' };
    if (typeof role !== 'string' || !role || role.length > 32) return { error: 'role' };
    load();
    enforcePin(pin);
    if (state.revoked[deviceId]) return { error: 'deviceId' };
    let shared;
    try { shared = crypto.diffieHellman({ privateKey: serverPrivate, publicKey: x25519Public(phoneRaw) }); }
    catch (_) { return { error: 'publicKey' }; }
    if (shared.every(b => b === 0)) return { error: 'publicKey' };
    const at = new Date(now()).toISOString();
    state.devices = state.devices.filter(d => d.deviceId !== deviceId);
    state.devices.push({
      deviceId,
      name: String(name == null ? '' : name).trim().slice(0, NAME_MAX),
      key: deriveDeviceKey(shared, deviceId).toString('base64'),
      createdAt: at,
      lastSeenAt: at,
      role,
      rolesVersion: ROLES_VERSION,
      codePaired: true,
    });
    trim();
    save();
    return { deviceId };
  }

  // The 33rd of a kind replaces the one of THAT kind seen longest ago: a
  // connector never pushes out a phone, nor a phone a connector (as the Mac).
  function trim() {
    const kinds = new Set(state.devices.map(d => d.kind == null ? '' : String(d.kind)));
    for (const k of kinds) {
      const same = state.devices.filter(d => (d.kind == null ? '' : String(d.kind)) === k);
      if (same.length <= MAX_DEVICES) continue;
      same.sort((a, b) => String(a.lastSeenAt).localeCompare(String(b.lastSeenAt)));
      const gone = new Set(same.slice(0, same.length - MAX_DEVICES));
      state.devices = state.devices.filter(d => !gone.has(d));
      for (const g of gone) nonces.delete(g.deviceId);
    }
  }

  /**
   * A slicer plugin a person approved by its check number
   * (lib/main/connector-pairing.js), as kind `connector`, under the PIN in
   * force now: a PIN change signs it out with the phones. Returns
   * { deviceId } or { error }.
   */
  function admitConnector({ serverPrivate, pluginPublic, deviceId, name, pin }) {
    const raw = b64Raw32(pluginPublic);
    if (!raw || !DEVICE_ID_RE.test(String(deviceId || ''))) return { error: 'publicKey' };
    load();
    enforcePin(pin);
    if (state.revoked[deviceId]) return { error: 'deviceId' };
    let shared;
    try { shared = crypto.diffieHellman({ privateKey: serverPrivate, publicKey: x25519Public(raw) }); }
    catch (_) { return { error: 'publicKey' }; }
    if (shared.every(b => b === 0)) return { error: 'publicKey' };
    const at = new Date(now()).toISOString();
    state.devices = state.devices.filter(d => d.deviceId !== deviceId);
    state.devices.push({
      deviceId,
      name: String(name == null ? '' : name).trim().slice(0, NAME_MAX),
      key: deriveDeviceKey(shared, deviceId).toString('base64'),
      createdAt: at,
      lastSeenAt: at,
      kind: KIND_CONNECTOR,
    });
    trim();
    save();
    return { deviceId };
  }

  /** The kind of an enrolled device by id: undefined for a phone or an id not enrolled. */
  function kindOf(deviceId) {
    try { load(); } catch (_) { return undefined; }
    const d = state.devices.find(x => x.deviceId === deviceId);
    return d && d.kind != null ? d.kind : undefined;
  }

  /** An enrolled CONNECTOR's key (Buffer) and name; null for a phone or nobody. */
  function connector(deviceId) {
    load();
    const d = state.devices.find(x => x.deviceId === deviceId);
    if (!d || d.kind !== KIND_CONNECTOR) return null;
    return { key: Buffer.from(d.key, 'base64'), name: d.name };
  }

  /** A connector's price grant: null (none), 'price' or 'cost'. */
  function priceGrant(deviceId) {
    load();
    const d = state.devices.find(x => x.deviceId === deviceId);
    if (!d || d.kind !== KIND_CONNECTOR || !PRICE_GRANTS.includes(d.priceGrant)) return null;
    return d.priceGrant;
  }

  /** Set (or, with null, take away) a connector's price grant. A phone, or a grant not known, changes nothing. */
  function setPriceGrant(deviceId, grant) {
    load();
    const d = state.devices.find(x => x.deviceId === deviceId);
    if (!d || d.kind !== KIND_CONNECTOR) return false;
    if (grant != null && !PRICE_GRANTS.includes(grant)) return false;
    if (grant == null) delete d.priceGrant; else d.priceGrant = grant;
    save();
    return true;
  }

  /**
   * What the shared rule (lib/device-roles.js roleOf) is asked about a device:
   * its role and rolesVersion exactly as stored, `{}` for a phone enrolled with
   * the PIN (the owner). A code-paired record always carries rolesVersion,
   * whatever the file says, so a lost role reads as the least, never the owner.
   * Null for a device that is not paired.
   */
  function rulesRecord(deviceId) {
    load();
    const d = state.devices.find(x => x.deviceId === deviceId);
    if (!d) return null;
    const out = {};
    if (d.kind !== undefined && d.kind !== null) out.kind = d.kind;
    if (d.role !== undefined && d.role !== null) out.role = d.role;
    if (d.rolesVersion !== undefined && d.rolesVersion !== null) out.rolesVersion = d.rolesVersion;
    if (d.codePaired !== undefined && d.codePaired !== null && d.codePaired !== false) out.rolesVersion = out.rolesVersion != null ? out.rolesVersion : ROLES_VERSION;
    return out;
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
    trim();
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
  function verify({ headers, method, target, body, pin, bodyHash }) {
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
    if (!dev) {
      if (!state.revoked[deviceId]) return { ok: false, reason: 'device-unknown' };
      const refused = { ok: false, reason: 'device-revoked' };
      // Signed only when the request's own MAC verifies under the key the
      // phone had, inside the clock skew (#2643): a forged request naming its
      // id gets the same refusal, unsigned.
      const oldKey = state.revokedKeys[deviceId] ? Buffer.from(state.revokedKeys[deviceId], 'base64') : null;
      if (!oldKey) return refused;
      const wantOld = Buffer.from(requestMac(oldKey, canonicalRequest(method, target, time, nonce, body, bodyHash)), 'base64');
      if (!crypto.timingSafeEqual(wantOld, given)) return refused;
      if (Math.abs(Math.floor(now() / 1000) - Number(time)) > CLOCK_SKEW_S) return refused;
      // No nonce is recorded here, on purpose (as the Mac): a replay inside
      // the skew only earns the same signed refusal for a nonce whose answer
      // was already given, and the phone takes a reply only over the nonce it
      // just sent. Nothing here can ever answer ok.
      return withReply(refused, oldKey, nonce);
    }
    const devKey = Buffer.from(dev.key, 'base64');
    const want = Buffer.from(requestMac(devKey, canonicalRequest(method, target, time, nonce, body, bodyHash)), 'base64');
    if (!crypto.timingSafeEqual(want, given)) return { ok: false, reason: 'device-auth' };
    const t = now();
    const nowS = Math.floor(t / 1000);
    if (Math.abs(nowS - Number(time)) > CLOCK_SKEW_S) return { ok: false, reason: 'device-clock', now: nowS };
    if (seenNonce(deviceId, nonce, t)) return { ok: false, reason: 'device-replay' };
    dev.lastSeenAt = new Date(t).toISOString();
    if (t - persistedAt > LAST_SEEN_PERSIST_MS) { try { save(); } catch (_) { /* next time */ } }
    return withReply({ ok: true, deviceId }, devKey, nonce);
  }

  /** Name, dates, id and how it paired per device, the one seen most recently first; never the key. */
  function list() {
    load();
    return state.devices
      .map(({ deviceId, name, createdAt, lastSeenAt, role, codePaired, kind, priceGrant: grant }) => Object.assign(
        { deviceId, name, createdAt, lastSeenAt, codePaired: isCodePaired({ codePaired }) },
        typeof role === 'string' ? { role } : {},
        kind != null ? { kind } : {},
        kind === KIND_CONNECTOR ? { priceGrant: PRICE_GRANTS.includes(grant) ? grant : null } : {}))
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
    const [gone] = state.devices.splice(at, 1);
    nonces.delete(deviceId);
    state.revoked[deviceId] = new Date(now()).toISOString();
    state.revokedKeys[deviceId] = gone.key;
    const ids = Object.keys(state.revoked);
    if (ids.length > MAX_REVOKED) {
      ids.sort((a, b) => state.revoked[a].localeCompare(state.revoked[b]));
      for (const id of ids.slice(0, ids.length - MAX_REVOKED)) { delete state.revoked[id]; delete state.revokedKeys[id]; }
    }
    for (const id of Object.keys(state.revokedKeys)) if (!state.revoked[id]) delete state.revokedKeys[id];
    save();
    return true;
  }

  /**
   * The owner changes a code-paired phone's role (frame P5, signed off Nov 22).
   * A PIN-paired phone is always the owner (it holds the PIN), so it has no
   * role to change. Takes effect on the phone's next request; nothing is
   * re-keyed. Returns whether it changed.
   */
  function setRole(deviceId, role) {
    if (!['owner', 'manager', 'operator', 'viewer'].includes(role)) return false;
    load();
    const dev = state.devices.find(d => d.deviceId === deviceId);
    if (!dev || !isCodePaired(dev)) return false;
    if (dev.role === role) return true;
    dev.role = role;
    save();
    return true;
  }

  return { enrol, admitPhone, admitConnector, rulesRecord, verify, list, remove, setRole, kindOf, connector, priceGrant, setPriceGrant };
}

module.exports = {
  createLanDevices, deriveDeviceKey, enrolMessage, canonicalRequest, requestMac, replyMac,
  MAX_DEVICES, MAX_REVOKED, ROLES_VERSION, CLOCK_SKEW_S, NONCE_TTL_MS, ENROL_PREFIX,
  KIND_CONNECTOR, CONNECTOR_PREFIX, PRICE_GRANTS, isRestricted,
};
