'use strict';
/**
 * Following a `khayt://plugin/install?id=…&version=…` link on the desktop
 * (main process only). lib/plugin-install-link.js reads the link; this decides
 * whether it may be followed and builds the offer the window shows as the
 * consent sheet. The Mac's half is PluginInstallLink.swift (#2622).
 *
 * What the link does, in order — each step a refusal when it fails:
 *   1. Who is asking (`gate`): connectors switched on, and the index fetch
 *      allowed (the connector-updates switch, the same gate the update check
 *      uses); somebody who may change settings (lib/rbac.js settings/edit, the
 *      role read the way lib/main/printer-permission.js reads it — under the
 *      lock with nobody signed in, nobody); a window that can save. Refused
 *      here, NOTHING is fetched.
 *   2. Khayt's own index (lib/main/connector-updates.js INDEX_URL), verified
 *      against Khayt's keys and checked by the shared rule
 *      (lib/plugin-update.js checkIndex: signed, current, well formed, and not
 *      older than the newest this book has verified).
 *   3. The index lists that id, at exactly that version, and has not
 *      withdrawn it.
 *   4. The manifest from where the index says: its bytes the ones the index
 *      promised, signed by Khayt (connector-updates verifiedManifest — the
 *      check a hand install passes), and its own id and version the link's.
 *
 * Nothing is written. The window is handed the manifest and opens the same
 * consent sheet as a hand install (renderer/plugins.js installPluginManifest),
 * which checks it with main again; only Install there stores it.
 */
const U = require('../plugin-update.js');
const Rbac = require('../rbac.js');
const C = require('./connector-updates.js');
const { activeRole } = require('./printer-permission.js');

/** Why a link was not put in front of the shop. The window's sentence is `plg.pil_<refusal>`. */
const REFUSALS = Object.freeze(['off', 'notAllowed', 'index', 'unlisted', 'otherVersion', 'withdrawn', 'manifest']);

/**
 * May this link be followed at all? null, or the refusal. Decided before
 * anything is fetched.
 * @param {{ connectorsOn: boolean, fetchOn: boolean, store: object, canWrite: boolean }} ctx
 */
function gate({ connectorsOn, fetchOn, store, canWrite } = {}) {
  if (!connectorsOn || !fetchOn) return 'off';
  if (!canWrite) return 'notAllowed';
  const { lock, role } = activeRole(store);
  if (lock && !role) return 'notAllowed';
  if (!Rbac.can(role, 'settings', 'edit', { lockEnabled: lock })) return 'notAllowed';
  return null;
}

/**
 * From an index already read: `{ ok: true, manifest }` or `{ ok: false, refusal }`.
 * `signedBy` is the key id the index's signature verified with, or null.
 * @param {{ id: string, version: string }} link
 * @param {{ fetchBytes: (url: string, max: number) => Promise<Buffer>, keys?: object[], nowMs?: number, lastSerial?: number|null }} deps
 */
async function offerFromIndex(link, index, signedBy, { fetchBytes, keys, nowMs, lastSerial } = {}) {
  const ctx = { signedBy, nowMs: typeof nowMs === 'number' ? nowMs : Date.now() };
  if (Number.isInteger(lastSerial)) ctx.lastSerial = lastSerial;
  if (!U.checkIndex(index, ctx).ok) return { ok: false, refusal: 'index' };
  const row = U.rowFor(index, link.id, 'connector');
  if (!row) return { ok: false, refusal: 'unlisted' };
  if ((Array.isArray(row.revoked) ? row.revoked : []).some((x) => x && x.version === link.version)) return { ok: false, refusal: 'withdrawn' };
  if (row.version !== link.version) return { ok: false, refusal: 'otherVersion' };
  let manifest = null;
  try { manifest = C.verifiedManifest(await fetchBytes(row.url, C.MANIFEST_MAX_BYTES), row.sha256, keys); } catch (_) { manifest = null; }
  if (!manifest || manifest.id !== link.id || manifest.version !== link.version) return { ok: false, refusal: 'manifest' };
  return { ok: true, manifest };
}

/**
 * The whole of it: fetch Khayt's index, verify it, then `offerFromIndex`.
 * Call `gate` first; this fetches.
 */
async function offer(link, { fetchBytes, keys, nowMs, lastSerial, indexUrl = C.INDEX_URL } = {}) {
  let index;
  try { index = JSON.parse((await fetchBytes(indexUrl, C.INDEX_MAX_BYTES)).toString('utf8')); }
  catch (_) { return { ok: false, refusal: 'index' }; }
  return offerFromIndex(link, index, C.indexSignedBy(index, keys), { fetchBytes, keys, nowMs, lastSerial });
}

module.exports = { REFUSALS, gate, offer, offerFromIndex };
