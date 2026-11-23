'use strict';
/**
 * Pairing a phone by a code, with a role (C1): the window a person opens on
 * this computer for a phone to ask, and the commit-then-reveal state machine
 * behind POST /api/devices/pair. The native Mac's `LanConnectorPairing` with
 * the phone flavour, ported state for state, so the two answer the same:
 * docs/LAN_API.md "POST /api/devices/pair", vectors docs/phone-pair.vectors.json.
 *
 * WHY A COMMITMENT FIRST. The 6-digit check number is one in 10^6. A device in
 * the middle that saw every input could grind its own keys until both screens
 * showed the same number. So the phone first sends only a commitment (the
 * SHA-256 of its fresh X25519 key and a nonce); only then is our fresh key drawn
 * and sent, signed by the LAN identity; only then does the phone reveal, and we
 * check the reveal against the commitment in constant time. One side's number
 * is always a blind guess for anyone in the middle, and a window gives out at
 * most MAX_OFFERS offers, whatever became of them.
 *
 * ONE REQUEST AT A TIME. While one waits, another is told `pairing-busy`. A
 * stranger who asks first shows up under a name the person does not expect and
 * a number the phone does not show: Deny keeps the window open for the real one.
 *
 * Nothing is enrolled until a person approves the request they were shown
 * (its pairId AND its check number): `approve` hands the request to `enrol`,
 * which writes the device (lib/lan-devices.js admitPhone) with the role chosen.
 *
 * OFF BY DEFAULT: `enabled()` decides, and main wires it to a main-side flag
 * the window cannot set (main.js, KHAYT_PHONE_PAIRING_BY_CODE=1), as the Mac's
 * `phonePairingByCode` defaults switch. Off, the routes answer 404 and `open`
 * does nothing.
 *
 * Times are milliseconds on a MONOTONIC clock (performance.now), so a wall
 * clock moved by the person or NTP neither lengthens nor ends a window.
 *
 * Main process only (node:crypto).
 */
const crypto = require('crypto');

const LENGTH_MS = 120_000;
const MAX_OFFERS = 3;
const REVEAL_WITHIN_MS = 30_000;
const MIN_NONCE = 16;
const MAX_FIELD = 60;

const FLAVOR = Object.freeze({ commit: 'khayt-phone-commit-v1', offer: 'khayt-enrol-phone-v1', check: 'khayt-phone-check-v1' });

const X25519_SPKI = Buffer.from('302a300506032b656e032100', 'hex');
const sha256 = (s) => crypto.createHash('sha256').update(Buffer.from(String(s), 'utf8')).digest();

/** base64 SHA-256(prefix \n phonePublic \n nonce), as a Buffer. */
function commitment(phonePublic, nonce, flavor = FLAVOR) {
  return sha256([flavor.commit, phonePublic, nonce].join('\n'));
}
/** What the identity signs in the offer. */
function offerMessage(deviceId, serverPublic, commit, flavor = FLAVOR) {
  return `${flavor.offer}:${deviceId}:${serverPublic}:${commit}`;
}
/** The 6-digit number both screens show: first 4 bytes big-endian mod 10^6, zero-padded. */
function checkNumber(deviceId, identityPublic, serverPublic, phonePublic, nonce, flavor = FLAVOR) {
  const d = sha256([flavor.check, deviceId, identityPublic, serverPublic, phonePublic, nonce].join('\n'));
  return String(d.readUInt32BE(0) % 1_000_000).padStart(6, '0');
}

/** A name, app or version as sent: no control characters, trimmed, 60 at most. */
function field(text) {
  // eslint-disable-next-line no-control-regex
  return String(text == null ? '' : text).replace(/[\u0000-\u001f\u007f-\u009f]/g, '').trim().slice(0, MAX_FIELD);
}
const hashSecret = (s) => sha256(String(s == null ? '' : s));
function equalBytes(a, b) { return Buffer.isBuffer(a) && Buffer.isBuffer(b) && a.length === b.length && crypto.timingSafeEqual(a, b); }

function freshSecret(n) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let out = '';
  while (out.length < n) {
    // Rejection sampling: 252 is the largest multiple of 36 under 256.
    for (const b of crypto.randomBytes(n * 2)) { if (b < 252 && out.length < n) out += alphabet[b % 36]; }
  }
  return out;
}
function freshDeviceId() {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let out = '';
  while (out.length < 20) {
    for (const b of crypto.randomBytes(40)) { if (b < 248 && out.length < 20) out += alphabet[b % 62]; }
  }
  return 'dev_' + out;
}
/** A pair id as freshSecret(12) makes it: the routes take nothing else. */
const plausiblePairId = (id) => typeof id === 'string' && /^[a-z0-9]{12}$/.test(id);

function b64Raw(s, len) {
  if (typeof s !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(s) || s.length % 4 !== 0) return null;
  const buf = Buffer.from(s, 'base64');
  if (buf.toString('base64') !== s) return null;
  return len == null || buf.length === len ? buf : null;
}
function rawPublic(keyObject) {
  const pub = keyObject.type === 'public' ? keyObject : crypto.createPublicKey(keyObject);
  const der = pub.export({ type: 'spki', format: 'der' });
  return der.subarray(der.length - 32).toString('base64');
}
/** The X25519 shared secret, or null for a key that cannot be used or gives all zeroes. */
function sharedSecret(serverPrivate, phonePublicB64) {
  const raw = b64Raw(phonePublicB64, 32);
  if (!raw) return null;
  try {
    const pub = crypto.createPublicKey({ key: Buffer.concat([X25519_SPKI, raw]), format: 'der', type: 'spki' });
    const s = crypto.diffieHellman({ privateKey: serverPrivate, publicKey: pub });
    return s.every((b) => b === 0) ? null : s;
  } catch (_) { return null; }
}

const monotonic = () => (typeof performance !== 'undefined' ? performance.now() : Number(process.hrtime.bigint() / 1_000_000n));

/**
 * @param {object} [o]
 * @param {function} [o.clock]        monotonic ms
 * @param {function} [o.enabled]      () => boolean: pairing by code switched on
 * @param {function} [o.newKeyPair]   tests: a fixed X25519 pair
 * @param {function} [o.newDeviceId]  tests: a fixed id
 * @param {function} [o.newSecret]    tests: (n) => string
 * @param {object}   [o.flavor]       the three prefixes: the phone's (default) or a
 *                                    connector's (lib/main/connector-pairing.js)
 */
function createPhonePairing({ clock = monotonic, enabled = () => false,
  newKeyPair = () => crypto.generateKeyPairSync('x25519'),
  newDeviceId = freshDeviceId, newSecret = freshSecret, flavor = FLAVOR } = {}) {
  let deadline = null;
  let lastClosed = null;
  let pending = null;           // { pairId, pollHash, deviceId, serverPrivate, serverPublic, identityPublic, commit, offeredAt, name, app, version, address, phonePublic, check }
  let outcomes = new Map();     // pairId -> 'waiting'|'approved'|'denied'|'expired'
  let answeredHashes = new Map();
  let offersLeft = 0;

  const isEnabled = () => { try { return enabled() === true; } catch (_) { return false; } };

  function answer(request, outcome) {
    outcomes.set(request.pairId, outcome);
    answeredHashes.set(request.pairId, request.pollHash);
    pending = null;
    if (outcome !== 'approved' && offersLeft <= 0 && deadline != null) shut('offersUsed');
  }
  function shut(why) {
    if (pending) answer(pending, 'expired');
    deadline = null;
    lastClosed = why;
  }

  /** Open the window (120 s, 3 offers). Nothing when pairing by code is off. */
  function open() {
    if (!isEnabled()) return false;
    deadline = clock() + LENGTH_MS;
    pending = null;
    outcomes = new Map();
    answeredHashes = new Map();
    offersLeft = MAX_OFFERS;
    lastClosed = null;
    return true;
  }

  /** Whether a phone may ask now. Past the deadline this closes it; an unrevealed offer past 30 s expires here. */
  function isOpen() {
    if (deadline == null) return false;
    if (clock() >= deadline) { shut('timedOut'); return false; }
    if (pending && pending.check == null && clock() - pending.offeredAt > REVEAL_WITHIN_MS) answer(pending, 'expired');
    return deadline != null;
  }

  function remaining() {
    if (deadline == null) return null;
    const left = deadline - clock();
    return left > 0 ? left : null;
  }
  function close() { if (deadline != null) shut('byOwner'); }
  function serverStopped() { if (deadline != null) shut('serverStopped'); }
  function refuse(why) { if (deadline != null) shut(why); }

  /**
   * A phone asks with its commitment. Our X25519 key is drawn here, only
   * after a well-formed commitment arrived. Returns { offer } or { refusal:
   * 'closed'|'busy'|'badCommit' }. `identity` = { publicKey, sign(message) }.
   */
  function request({ commit, name, app, version, address, identity }) {
    if (!isOpen()) return { refusal: 'closed' };
    if (pending) return { refusal: 'busy' };
    const c = b64Raw(commit, 32);
    if (!c) return { refusal: 'badCommit' };
    const deviceId = newDeviceId();
    const pair = newKeyPair();
    let serverPublic;
    try { serverPublic = rawPublic(pair.publicKey || pair.privateKey); } catch (_) { return { refusal: 'identity' }; }
    let sig, identityPublic;
    try {
      identityPublic = identity.publicKey;
      sig = identity.sign(offerMessage(deviceId, serverPublic, commit, flavor));
    } catch (_) { return { refusal: 'identity' }; }
    const pairId = newSecret(12);
    const pollSecret = newSecret(32);
    offersLeft -= 1;
    pending = {
      pairId, pollHash: hashSecret(pollSecret), deviceId, serverPrivate: pair.privateKey, serverPublic, identityPublic,
      commit: c, offeredAt: clock(), name: field(name), app: field(app), version: field(version),
      address: String(address || ''), phonePublic: null, nonce: null, check: null,
    };
    outcomes.set(pairId, 'waiting');
    return { offer: { pairId, pollSecret, deviceId, publicKey: serverPublic, sig, identity: identityPublic } };
  }

  /**
   * The phone reveals the key and nonce it committed to:
   * 'accepted' | 'unknown' (no such request, or not its secret: spends nothing)
   * | 'already' | 'refused' (the offer expires; no number is ever worked out).
   */
  function reveal(pairId, secret, publicKey, nonce) {
    const req = pending;
    if (!req || req.pairId !== pairId) return 'unknown';
    if (!equalBytes(req.pollHash, hashSecret(secret))) return 'unknown';
    if (req.check != null) return 'already';
    if (!isOpen() || !pending || pending.pairId !== pairId) return 'refused';
    const n = b64Raw(nonce);
    const ok = typeof publicKey === 'string' && sharedSecret(req.serverPrivate, publicKey) !== null
      && n && n.length >= MIN_NONCE
      && equalBytes(req.commit, commitment(publicKey, nonce, flavor));
    if (!ok) { answer(req, 'expired'); return 'refused'; }
    req.phonePublic = publicKey;
    req.nonce = nonce;
    req.check = checkNumber(req.deviceId, req.identityPublic, req.serverPublic, publicKey, nonce, flavor);
    return 'accepted';
  }

  /** How the request went, or null for an id not given out here or the wrong secret. */
  function poll(pairId, secret) {
    isOpen();
    const outcome = outcomes.get(pairId);
    if (!outcome) return null;
    if (pending && pending.pairId === pairId) return equalBytes(pending.pollHash, hashSecret(secret)) ? outcome : null;
    const h = answeredHashes.get(pairId);
    return h && equalBytes(h, hashSecret(secret)) ? outcome : null;
  }

  /**
   * The phone gives its own request up, proved by its poll secret. The offer
   * stays counted; an answer already given is never undone.
   * Returns { state: 'cancelled' } | { answered: outcome } | null (unknown).
   */
  function cancel(pairId, secret) {
    isOpen();
    if (pending && pending.pairId === pairId) {
      if (!equalBytes(pending.pollHash, hashSecret(secret))) return null;
      answer(pending, 'expired');
      return { state: 'cancelled' };
    }
    const outcome = outcomes.get(pairId);
    const h = answeredHashes.get(pairId);
    if (!outcome || !h || !equalBytes(h, hashSecret(secret))) return null;
    return { answered: outcome };
  }

  /**
   * A person approved the request they were SHOWN: `pairId` and `check` must
   * be the one waiting now. `enrol(request)` writes the device and may throw:
   * then nothing changes and the request still waits. Returns whether it enrolled.
   */
  function approve({ pairId, check }, enrol) {
    if (!isOpen()) return false;
    const req = pending;
    if (!req || req.check == null || req.phonePublic == null) return false;
    if (req.pairId !== pairId || req.check !== check) return false;
    enrol({
      pairId: req.pairId, deviceId: req.deviceId, serverPrivate: req.serverPrivate, phonePublic: req.phonePublic,
      name: req.name, app: req.app, version: req.version, address: req.address,
    });
    answer(req, 'approved');
    shut('paired');
    return true;
  }

  /** The numbers do not match, or nobody knows the phone: that request is told so; the window stays open. */
  function deny() {
    if (!pending) return false;
    answer(pending, 'denied');
    return true;
  }

  /** For the (future) screen: never a key, a secret or a hash. */
  function snapshot() {
    const open = isOpen();
    const p = pending;
    return {
      enabled: isEnabled(),
      open,
      remainingMs: open ? remaining() : null,
      offersLeft: open ? offersLeft : 0,
      lastClosed,
      pending: p ? {
        pairId: p.pairId, name: p.name, app: p.app, version: p.version, address: p.address,
        revealed: p.check != null, check: p.check,
      } : null,
    };
  }

  return { open, isOpen, remaining, close, serverStopped, refuse, request, reveal, poll, cancel, approve, deny, snapshot, isEnabled };
}

const CLOSED_BODY = JSON.stringify({ reason: 'pairing-closed', error: 'On the computer, open Settings, LAN, and click Pair a phone' });
const BUSY_BODY = JSON.stringify({ reason: 'pairing-busy', error: 'Another phone is waiting for the shop to answer. Try again in a minute' });

module.exports = {
  createPhonePairing, commitment, offerMessage, checkNumber, sharedSecret, plausiblePairId, field,
  freshDeviceId, freshSecret, FLAVOR, LENGTH_MS, MAX_OFFERS, REVEAL_WITHIN_MS, MIN_NONCE, MAX_FIELD,
  CLOSED_BODY, BUSY_BODY,
};
