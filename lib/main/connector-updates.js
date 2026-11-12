'use strict';
/**
 * Connector updates on the desktop (main process only).
 *
 * lib/plugin-update.js decides; this is the part it leaves to the platform:
 * the signatures, the downloads, and the one place the result is written.
 *
 *   - THE INDEX: its ed25519 signature must verify against
 *     lib/plugin-manifest.js SIGNING_KEYS over `indexSigningMessage(index)`
 *     (the "khayt-index-v1\n" context prefix — a manifest signature can never
 *     pass for it), and the key that verifies must be the one the index names.
 *     No verified signer → `signedBy: null` → the lib changes nothing.
 *   - EVERY MANIFEST: sha256 of the downloaded BYTES against the index row,
 *     then the manifest's own signature (lib/main/plugin-send.js checkInstall,
 *     the very check a hand install passes). Either fails → not handed over;
 *     the lib treats it as a download that did not arrive.
 *   - WHERE IT IS WRITTEN: `settings.connectorUpdates` is main's alone (a
 *     window save keeps the disk's copy — lib/store-io.js
 *     keepConnectorUpdatesFromDisk), so the shop's Agree / Revert / switch
 *     on a withdrawn connector are applied here, to the store on disk.
 *
 * A connector's keys go only where they were entered for: when an update the
 * shop agrees to (or a revert) sends a key to a different set of hosts, that
 * key is not carried over (keysWhereEntered, the rule the Mac keeps too).
 */
const crypto = require('crypto');
const M = require('../plugin-manifest.js');
require('../plugin-host.js');
const U = require('../plugin-update.js');
const SecretDestination = require('../secret-destination.js');
const pluginSend = require('./plugin-send.js');

const INDEX_URL = 'https://khaytapp.com/connectors/index.json';
const INDEX_MAX_BYTES = 512 * 1024;
const MANIFEST_MAX_BYTES = 256 * 1024;  // the hand-install limit (renderer/plugins.js)
const SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex');

function publicKeyOf(b64) {
  return crypto.createPublicKey({ key: Buffer.concat([SPKI_PREFIX, Buffer.from(b64, 'base64')]), format: 'der', type: 'spki' });
}

/** The id of the Khayt key that signed this index — and that it says signed it — or null. */
function indexSignedBy(index, keys) {
  const s = index && index.signature;
  if (!s || typeof s !== 'object' || typeof s.sig !== 'string' || typeof s.keyId !== 'string') return null;
  let msg, sig;
  try {
    msg = Buffer.from(U.indexSigningMessage(index), 'utf8');
    sig = Buffer.from(s.sig, 'base64');
  } catch (_) { return null; }
  if (sig.length !== 64) return null;
  for (const k of (keys || M.SIGNING_KEYS)) {
    if (k.id !== s.keyId) continue;
    try { if (crypto.verify(null, msg, publicKeyOf(k.key), sig)) return k.id; } catch (_) { /* a bad key verifies nothing */ }
  }
  return null;
}

/**
 * The manifest in these bytes, when they are the bytes the index promised
 * (sha256) AND the manifest is valid and signed by Khayt; else null.
 */
function verifiedManifest(bytes, sha256, keys) {
  if (!Buffer.isBuffer(bytes) || bytes.length > MANIFEST_MAX_BYTES) return null;
  const got = crypto.createHash('sha256').update(bytes).digest('hex');
  if (typeof sha256 !== 'string' || got !== sha256.toLowerCase()) return null;
  let manifest;
  try { manifest = JSON.parse(bytes.toString('utf8')); } catch (_) { return null; }
  const check = pluginSend.checkInstall(manifest, keys);
  return check && check.ok ? manifest : null;
}

/**
 * One whole check against `settings`. `fetchBytes(url, maxBytes)` → Buffer
 * (throws on failure). Returns plugin-update's applyIndex result; on an
 * index that cannot be fetched, read or trusted, `settings` comes back as the
 * very same object.
 */
async function check(settings, deps = {}) {
  return applyPrepared(settings, await prepare(settings, deps));
}

/**
 * The network half of a check: the index and every VERIFIED manifest it
 * points this book to. `null` when the index cannot be fetched or read.
 */
async function prepare(settings, { fetchBytes, ctx, keys, indexUrl = INDEX_URL } = {}) {
  let index;
  try { index = JSON.parse((await fetchBytes(indexUrl, INDEX_MAX_BYTES)).toString('utf8')); }
  catch (_) { return null; }
  const c = Object.assign({}, ctx, { signedBy: indexSignedBy(index, keys) });
  const fetched = {};
  for (const f of U.fetchesFor(settings, index, c)) {
    try {
      const m = verifiedManifest(await fetchBytes(f.url, MANIFEST_MAX_BYTES), f.sha256, keys);
      if (m) fetched[f.id] = m;
    } catch (_) { /* tried again next time */ }
  }
  return { index, ctx: c, fetched };
}

/** The pure half: synchronous, so it can run inside the store's write chain. */
function applyPrepared(settings, prepared) {
  if (!prepared) return { ok: false, reason: 'unreadable', settings, changed: false, notes: [] };
  return U.applyIndex(settings, prepared.index, prepared.ctx, prepared.fetched);
}

/** The hosts a grant sends this key to ("host secret:name" routes), as one string. */
function secretHosts(granted, name) {
  const out = new Set();
  for (const r of granted.routes) {
    const s = String(r);
    const i = s.indexOf(' secret:');
    if (i > 0 && s.slice(i + 8) === name) out.add(s.slice(0, i));
  }
  return Array.from(out).sort().join(',');
}

/**
 * The entry with only the keys whose hosts did not move (the rule the Mac
 * keeps too). Per key: the set of hosts the grant's `routes` send it to,
 * before and after; a key whose set changed is dropped, to be entered again.
 * A grant without `routes` (from before pairs were kept) says only its hosts:
 * any change in them counts as a move for every key.
 */
function keysWhereEntered(before, after) {
  if (!after || !after.secrets || typeof after.secrets !== 'object') return after;
  const gB = before && before.granted && typeof before.granted === 'object' ? before.granted : {};
  const gA = after.granted && typeof after.granted === 'object' ? after.granted : {};
  let keep;
  if (!Array.isArray(gB.routes) || !Array.isArray(gA.routes)) {
    const same = !!before && SecretDestination.pluginKey(before) === SecretDestination.pluginKey(after);
    keep = () => same;
  } else {
    keep = (name) => secretHosts(gB, name) === secretHosts(gA, name);
  }
  const secrets = {};
  for (const [name, v] of Object.entries(after.secrets)) if (keep(name)) secrets[name] = v;
  const out = Object.assign({}, after);
  if (Object.keys(secrets).length) out.secrets = secrets; else delete out.secrets;
  return out;
}

/**
 * The shop's word on one connector, applied to the whole store: `op` is
 * `agree`, `revert` or `switch` (with `enabled`). Returns `{ ok, store }`;
 * `store` is the very object passed in when nothing applies.
 */
function applyOp(store, { op, id, enabled, nowMs } = {}) {
  const s0 = store && typeof store === 'object' ? store : {};
  const settings = s0.settings && typeof s0.settings === 'object' ? s0.settings : {};
  let r;
  if (op === 'agree') r = U.agree(settings, id, { nowMs: typeof nowMs === 'number' ? nowMs : Date.now() });
  else if (op === 'revert') r = U.revert(settings, id);
  else if (op === 'switch') r = U.setSwitch(settings, id, !!enabled);
  else return { ok: false, store: s0 };
  if (!r.ok) return { ok: false, store: s0 };
  const before = (settings.plugins || []).find((p) => p && p.id === id);
  const plugins = (r.settings.plugins || []).map((p) => (p && p.id === id ? keysWhereEntered(before, p) : p));
  return { ok: true, store: Object.assign({}, s0, { settings: Object.assign({}, r.settings, { plugins }) }) };
}

/** What the window is handed back: the connectors (keys masked) and the state. */
function forWindow(settings, mask) {
  const s = settings && typeof settings === 'object' ? settings : {};
  const plugins = (Array.isArray(s.plugins) ? s.plugins : []).map((p) => {
    if (!p || !p.secrets || typeof p.secrets !== 'object') return p;
    const secrets = {};
    for (const k of Object.keys(p.secrets)) if (p.secrets[k]) secrets[k] = mask;
    return Object.assign({}, p, { secrets });
  });
  return { plugins, connectorUpdates: s.connectorUpdates || null };
}

module.exports = { INDEX_URL, indexSignedBy, verifiedManifest, check, prepare, applyPrepared, applyOp, forWindow, keysWhereEntered };
