'use strict';

/**
 * Khayt Vault share links, for the Electron main process.
 *
 * The JavaScript twin of `VaultLinks` in
 * mac/KhaytCore/Sources/KhaytCore/VaultLinks.swift: the same items, sealed the
 * same way, sent in the same batches. Every cipher operation is
 * lib/vault-crypto.js (docs/vault-format.md); nothing here touches a primitive.
 *
 * ── WHAT A LINK IS MADE OF ──────────────────────────────────────────────
 *
 * For each file, the head version's DK is unwrapped with the vault key and
 * wrapped again under a key derived from a fresh link secret (with the
 * password mixed in when there is one), and a link meta record is sealed under
 * the same key carrying the whole manifest. The manifest comes from the
 * version's OWN sealed record (`decryptVersionMeta`), never from the server's
 * listing.
 *
 * ── WHAT NEVER LEAVES THIS PROCESS ──────────────────────────────────────
 *
 * The link secret, the link key, the password and every DK. The cloud is sent
 * the grant id, the wraps, the sealed records and `password: true`. The secret
 * is returned to the caller once (`secretB64u`, `url`) and handed to the
 * optional `secrets` store; it is never logged here.
 *
 * ── A BIG SELECTION ─────────────────────────────────────────────────────
 *
 * A grant body is at most 500 items and 16 MiB. The grant is created with as
 * many items as fit, then grown with `PATCH {items}`. While a rest is still to
 * be sent the link is PENDING (the secret is offered to `secrets.save` with
 * `pendingSince`, and saved again whole once the last batch lands). If a later
 * batch fails the half-made link is revoked and its secret forgotten, so a
 * link is either whole or dead, never quietly partial.
 */

const VC = require('./vault-crypto.js');

const MAX_ITEMS = 500;
const MAX_BODY_BYTES = 16 * 1024 * 1024;
const MAX_LINK_META_BYTES = 256 * 1024;
const MAX_NOTE_BYTES = 16 * 1024;
const ID_ATTEMPTS = 3;
const NOTE_AAD = 'khayt-grant-note';
const TAG_BYTES = 16;

const b64 = (bytes) => Buffer.from(bytes).toString('base64');
const unb64 = (s) => {
  if (typeof s !== 'string' || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) throw new Error('not base64');
  return new Uint8Array(Buffer.from(s, 'base64'));
};
const jsonBytes = (o) => Buffer.byteLength(JSON.stringify(o), 'utf8');

function linkError(reason, message, extra) {
  const e = new Error(message);
  e.name = 'VaultLinkError';
  e.reason = reason;
  if (extra) Object.assign(e, extra);
  return e;
}

/** ISO 8601 without fractional seconds, as the Swift's `VaultLinks.iso`. */
function iso(d) {
  const date = d instanceof Date ? d : new Date(d);
  if (Number.isNaN(date.getTime())) throw new Error('not a date');
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** The share page's origin for a cloud API address (`VaultLink.origin(forAPI:)`). */
function originForApi(api) {
  try {
    const u = new URL(String(api));
    if (!u.protocol || !u.host) throw new Error();
    return u.protocol + '//' + u.host;
  } catch { return 'https://cloud.khaytapp.com'; }
}

/** `{origin}/s/{grantId}#{base64url(secret)}` (`VaultLink.url`). */
function linkUrl(origin, grantId, secret) {
  return String(origin).replace(/\/+$/, '') + '/s/' + grantId + '#' + VC.b64url(secret);
}

/** The head version of a feed row, or null. */
function headVersion(row) {
  const vs = Array.isArray(row.versions) ? row.versions : [];
  return vs.find((v) => v && v.version === row.head) || null;
}

/**
 * Open a feed row's shop meta (`VaultMeta.open`): it is sealed for the upload
 * that was the head when it was written, so each version is tried, the head
 * first, then newest first. The record must name the upload it was sealed for.
 */
async function openShopMeta(vaultKey, row) {
  if (typeof row.meta !== 'string') throw new Error('file has no meta record');
  const sealed = unb64(row.meta);
  const order = (row.versions || []).slice().sort((a, b) => {
    const ah = a.version === row.head ? 1 : 0, bh = b.version === row.head ? 1 : 0;
    return ah !== bh ? bh - ah : b.version - a.version;
  });
  for (const v of order) {
    let m;
    try { m = await VC.decryptMeta(vaultKey, row.fileId, v.uploadId, sealed, null); } catch { continue; }
    if (m.uploadId !== v.uploadId || typeof m.name !== 'string') {
      throw new Error('meta record is not a Khayt client record');
    }
    return m;
  }
  throw new Error('vault: the meta record would not open');
}

/**
 * Prepare one feed row for sharing (`VaultLinks.prepare`). Throws
 * reason 'not-shareable' when the file cannot be shared as it stands.
 */
async function prepareOne(vaultKey, row, lastSeenSeq) {
  const fid = row.fileId;
  const refuse = (why) => linkError('not-shareable', `${fid} cannot be shared: ${why}.`, { fileId: fid, why });
  if (row.purged || row.trashedAt) throw refuse('in the Trash');
  const v = headVersion(row);
  if (!v) throw refuse('no current version');
  if (typeof v.versionMeta !== 'string' || !v.versionMeta) throw refuse('no version record');
  // The manifest is the version's own sealed record, as a download pins it.
  const vm = await VC.decryptVersionMeta(vaultKey, fid, v.uploadId, unb64(v.versionMeta),
    lastSeenSeq == null ? null : lastSeenSeq);
  if (vm.chunkHashes.length !== v.chunks || vm.size !== v.bytes - v.chunks * TAG_BYTES) {
    throw refuse("the cloud's listing disagrees with the record");
  }
  const meta = await openShopMeta(vaultKey, row);
  const dk = await VC.unwrapDkForShop(vaultKey, unb64(v.wrappedKey), fid, v.uploadId);
  const kind = typeof meta.kind === 'string' ? meta.kind : '';
  const linkMeta = {
    uploadId: v.uploadId,
    manifest: { v: VC.VERSION, chunkBytes: vm.chunkBytes, size: vm.size, chunks: vm.chunkHashes },
    manifestHash: vm.manifestHash,
    name: meta.name,
    size: vm.size,
    kind,
  };
  return { fileId: fid, version: v.version, uploadId: v.uploadId, dk, linkMeta,
    name: meta.name, size: vm.size, kind, versionMeta: vm, meta };
}

/**
 * What sharing each chosen file needs, worked out once.
 *
 * @param {Uint8Array} dek          the shop's DEK (the vault key is derived from it)
 * @param {object[]} feedFiles      rows of the delta feed, as the cloud sent them
 * @param {string[]} fileIds        the files chosen
 * @param {object} [opts]
 * @param {Object<string,number>} [opts.lastSeenSeq]  fileId → seq this device last saw
 * @returns {Promise<object[]>}  one per file: { fileId, version, uploadId, dk,
 *   linkMeta, name, size, kind, versionMeta, meta }. Throws reason
 *   'not-shareable' with `.fileIds` listing every chosen file that has no live
 *   vault copy (unknown, purged, trashed or without a head) before any
 *   decrypting is done.
 */
async function prepareItems(dek, feedFiles, fileIds, opts = {}) {
  const ids = [...new Set(Array.isArray(fileIds) ? fileIds : [])];
  if (!ids.length) throw linkError('nothing-to-share', 'Nothing to share.');
  const rows = new Map();
  for (const f of Array.isArray(feedFiles) ? feedFiles : []) if (f && typeof f.fileId === 'string') rows.set(f.fileId, f);
  const missing = ids.filter((id) => {
    const r = rows.get(id);
    return !r || r.purged || r.trashedAt || !headVersion(r);
  });
  if (missing.length) {
    throw linkError('not-shareable', `${missing.length} file(s) have no vault copy to share.`, { fileIds: missing });
  }
  const vaultKey = opts.vaultKey || await VC.deriveVaultKey(dek);
  const seen = opts.lastSeenSeq || {};
  const out = [];
  for (const id of ids) out.push(await prepareOne(vaultKey, rows.get(id), seen[id]));
  return out;
}

/** Seal prepared files for one grant under its link key (`VaultLinks.seal`). Wire form. */
async function seal(prepared, grantId, linkKey) {
  const items = [];
  for (const p of prepared) {
    const wrapped = await VC.wrapDkForGrant(linkKey, p.dk, grantId, p.fileId, p.uploadId);
    const lm = await VC.encryptLinkMeta(linkKey, grantId, p.fileId, p.linkMeta);
    const lm64 = b64(lm);
    if (Buffer.byteLength(lm64) > MAX_LINK_META_BYTES) {
      throw linkError('too-big', `${p.fileId} is too large to add to a link.`, { fileId: p.fileId });
    }
    items.push({ fileId: p.fileId, version: p.version, wrappedKey: b64(wrapped), linkMeta: lm64 });
  }
  return items;
}

/**
 * Split items into request batches (`VaultLinks.batches`): the first under
 * `firstEnvelope` (the POST body with no items), the rest under
 * `restEnvelope` (`{"items":[]}`). At most `maxItems` per batch, and each body
 * at most `maxBytes`: the empty body plus each item's JSON and one comma
 * between items, which is how JSON.stringify lays an array out.
 */
function batches(items, firstEnvelope, restEnvelope, maxItems = MAX_ITEMS, maxBytes = MAX_BODY_BYTES) {
  const out = [];
  let cur = [];
  let size = firstEnvelope;
  for (const item of items) {
    const n = jsonBytes(item);
    const envelope = out.length ? restEnvelope : firstEnvelope;
    if (envelope + n > maxBytes || restEnvelope + n > maxBytes) {
      throw linkError('too-big', `${item.fileId} is too large to add to a link.`, { fileId: item.fileId });
    }
    const extra = n + (cur.length ? 1 : 0);
    if (cur.length && (cur.length >= maxItems || size + extra > maxBytes)) {
      out.push(cur); cur = [item]; size = restEnvelope + n;
      continue;
    }
    cur.push(item); size += extra;
  }
  if (cur.length) out.push(cur);
  return out;
}

const PATCH_ENVELOPE = jsonBytes({ items: [] });

/** The grant's limits as the contract names them (`Options.limits`). Empty → null. */
function limitsFrom(o) {
  const l = {};
  if (o.maxDownloads != null) l.maxDownloads = o.maxDownloads;
  if (o.perFile && o.maxDownloads != null) l.perFile = true;
  if (o.expiresAt != null) l.expiresAt = iso(o.expiresAt);
  if (o.validForSec != null) l.validForSec = o.validForSec;
  if (o.maxDevices != null) l.maxDevices = o.maxDevices;
  return Object.keys(l).length ? l : null;
}

/** POST /vault/grants body (`VaultClient.createBody`). */
function createBody(grantId, items, limits, password, ownerNote) {
  const body = { grantId, items };
  if (limits) body.limits = limits;
  if (password) body.password = true;
  if (ownerNote) body.ownerNote = ownerNote;
  return body;
}

/** True when this build of vault-crypto can seal an owner note. */
const noteSupported = () => typeof VC.encryptGrantNote === 'function';

/** The owner's note, sealed under the vault key (`VaultLinks.sealNote`):
 *  lib/vault-crypto.js `encryptGrantNote`, already base64 for `ownerNote`. */
async function sealNote(text, vaultKey, grantId) {
  if (!noteSupported()) throw linkError('note-unsupported', 'A link note cannot be sealed by this build.');
  return VC.encryptGrantNote(vaultKey, grantId, text);
}

/**
 * Make a link to these files (`VaultLinks.create`).
 *
 * @param {object} a
 * @param {Uint8Array} a.dek
 * @param {object[]} a.files        feed rows
 * @param {string[]} a.fileIds      the files chosen
 * @param {object} [a.options]      { maxDownloads, perFile, expiresAt (Date|ISO),
 *                                    validForSec, maxDevices, password (string|null), note }
 * @param {object} a.client         a lib/vault-client.js client
 * @param {string} [a.origin]       the share page's origin; defaults from client.baseUrl
 * @param {object} [a.secrets]      optional { save(grantId, {secret, linkKey, pendingSince}), forget(grantId) }
 * @param {Object<string,number>} [a.lastSeenSeq]
 * @param {object} [a.seams]        TESTS ONLY: { scrypt, newGrantId, maxItems, maxBodyBytes, now }
 * @returns {Promise<{grantId, url, secretB64u, createdAt, itemCount, requests, secretKept}>}
 */
async function createLink(a = {}) {
  const { dek, files, fileIds, client, secrets } = a;
  const options = a.options || {};
  const seams = a.seams || {};
  if (!client) throw new Error('createLink needs a vault client');
  const password = typeof options.password === 'string' && options.password.length ? options.password : null;
  if (password !== null && !VC.linkPasswordOk(password)) {
    throw linkError('weak-password', `A link password needs at least ${VC.LINK_PASSWORD_MIN} characters.`);
  }
  const note = typeof options.note === 'string' && options.note.trim() ? options.note : null;
  if (note && !noteSupported()) throw linkError('note-unsupported', 'A link note cannot be sealed by this build.');
  const limits = limitsFrom(options);
  const vaultKey = await VC.deriveVaultKey(dek);
  const prepared = await prepareItems(dek, files, fileIds, { vaultKey, lastSeenSeq: a.lastSeenSeq });
  const origin = a.origin || originForApi(client.baseUrl);
  const newGrantId = seams.newGrantId || VC.newGrantId;
  const maxItems = seams.maxItems || MAX_ITEMS;
  const maxBodyBytes = seams.maxBodyBytes || MAX_BODY_BYTES;
  const now = seams.now || (() => new Date());
  const kdfOpts = seams.scrypt ? { scrypt: seams.scrypt } : {};

  for (let attempt = 0; attempt < ID_ATTEMPTS; attempt++) {
    const grantId = newGrantId();
    const secret = VC.newLinkSecret();
    const linkKey = await VC.deriveLinkKey(secret, grantId, password, kdfOpts);
    let ownerNote = null;
    if (note) {
      ownerNote = await sealNote(note, vaultKey, grantId);
      if (Buffer.byteLength(ownerNote) > MAX_NOTE_BYTES) throw linkError('note-too-long', 'The note is too long.');
    }
    const items = await seal(prepared, grantId, linkKey);
    const first = jsonBytes(createBody(grantId, [], limits, password !== null, ownerNote));
    const parts = batches(items, first, PATCH_ENVELOPE, maxItems, maxBodyBytes);
    let reply;
    try {
      reply = await client.createGrant(createBody(grantId, parts[0], limits, password !== null, ownerNote));
    } catch (e) {
      // Someone, somewhere, has this id: a new id, a new secret, all sealed again.
      if (e && e.reason === 'grant-exists') continue;
      throw e;
    }
    const createdAt = (reply && typeof reply.createdAt === 'string') ? reply.createdAt : '';
    // Kept BEFORE the rest is sent, marked pending while there is a rest.
    const record = (pendingSince) => ({ secret, linkKey, pendingSince });
    let kept = false;
    if (secrets && typeof secrets.save === 'function') {
      kept = !!(await secrets.save(grantId, record(parts.length > 1 ? now() : null)));
    }
    let sent = parts[0].length;
    for (const batch of parts.slice(1)) {
      try {
        await client.patchGrant(grantId, { items: batch });
        sent += batch.length;
      } catch (err) {
        let revoked = false;
        try { await client.patchGrant(grantId, { revoke: true }); revoked = true; } catch { /* left pending */ }
        // Forgotten only once it is dead; a failed revoke leaves the pending record.
        if (revoked && secrets && typeof secrets.forget === 'function') await secrets.forget(grantId);
        throw linkError('incomplete',
          `The link ${grantId} got ${sent} of ${items.length} files (${err && err.message})${revoked ? '; it was revoked' : ''}.`,
          { grantId, sent, total: items.length, revoked, cause: err });
      }
    }
    if (parts.length > 1 && secrets && typeof secrets.save === 'function') {
      kept = !!(await secrets.save(grantId, record(null)));
    }
    return { grantId, url: linkUrl(origin, grantId, secret), secretB64u: VC.b64url(secret), createdAt,
      itemCount: items.length, requests: parts.length, secretKept: kept };
  }
  throw linkError('no-free-grant-id', 'No free link id could be found.');
}

/** Revoke a link: PATCH {revoke: true}. The grant afterwards. */
function revokeLink(client, grantId) {
  return client.patchGrant(grantId, { revoke: true });
}

/** A new end date (Date or ISO), or none (null): PATCH {expiresAt}. */
function extendLink(client, grantId, expiresAt) {
  return client.patchGrant(grantId, { expiresAt: expiresAt == null ? null : iso(expiresAt) });
}

/** More downloads: PATCH {addDownloads: n}, n a positive integer. */
async function addDownloads(client, grantId, n) {
  if (!Number.isInteger(n) || n <= 0) throw new Error('addDownloads must be a positive integer');
  return client.patchGrant(grantId, { addDownloads: n });
}

module.exports = {
  headVersion, openShopMeta,
  MAX_ITEMS, MAX_BODY_BYTES, MAX_LINK_META_BYTES, MAX_NOTE_BYTES, NOTE_AAD,
  prepareItems, createLink, revokeLink, extendLink, addDownloads,
  seal, batches, limitsFrom, createBody, linkUrl, originForApi, iso, noteSupported,
};
