'use strict';
/**
 * Backing library models up into the Khayt Vault from Windows/Linux — the
 * Mac's CloudLibrary.ensureInBucket → VaultRemote.put → VaultSync.putFile →
 * VaultUpload.run, so a model backed up here is the SAME vault object a Mac
 * backup would make.
 *
 * THE RULES, from the Mac (VaultSync.swift, VaultUpload.swift, VaultApply.swift):
 *
 *  - The KEY is the identity: `print-files/<itemDirName(record.id)>/<filename>`
 *    (vault prefix ""). The folder name is how the Mac's VaultApply finds the
 *    record, so it must be lib/print-library-location.js itemDirName exactly.
 *  - Meta: name = the key's last segment, path = "", kind = the name's
 *    extension lower-cased, key; NO recordId (the backup passes none).
 *  - A new VERSION when the key already maps to a live file: fileId, its
 *    head as baseVersion, its seq as lastSeq. Otherwise a new file.
 *  - NOTHING is written to the book record here. vaultFileId and the rest are
 *    VaultApply's (the Mac's, from the feed). What this keeps is per computer:
 *    `vault-state.<shopId>.json` in userData — the feed's rev, key → fileId,
 *    and per file its seq, head and sha256 — the Mac's VaultSyncState.
 *  - A 409 duplicate is "adopted": nothing is uploaded, and the key now maps
 *    to the file the shop already has.
 */
const fs = require('fs');
const path = require('path');
const VaultClient = require('../vault-client.js');
const VaultLinks = require('../vault-links.js');
const { uploadFile } = require('../vault-upload.js');
const VC = require('../vault-crypto.js');
const { itemDirName } = require('../print-library-location.js');

function keyFor(recordId, filename) {
  return 'print-files/' + itemDirName(recordId) + '/' + String(filename);
}
function kindOf(name) {
  const m = /\.([^./\\]+)$/.exec(String(name));
  return m ? m[1].toLowerCase() : '';
}

function createVaultBackup({ app, readBook, getDek, cloudToken, isVaultOn, itemDir, isModelFile, deviceId, log = console }) {
  const stateFile = (shopId) => path.join(app.getPath('userData'), `vault-state.${String(shopId).replace(/[^A-Za-z0-9_-]/g, '_')}.json`);
  const load = (shopId) => {
    try { const s = JSON.parse(fs.readFileSync(stateFile(shopId), 'utf8')); return { rev: s.rev || 0, keys: s.keys || {}, files: s.files || {} }; }
    catch (_) { return { rev: 0, keys: {}, files: {} }; }
  };
  const save = (shopId, s) => { const f = stateFile(shopId); fs.writeFileSync(f + '.tmp', JSON.stringify(s)); fs.renameSync(f + '.tmp', f); };

  function context() {
    const book = readBook() || {};
    const c = (book.settings && book.settings.cloud) || {};
    if (!(c.enabled && c.shopId && c.url)) return { reason: 'signin' };
    if (!isVaultOn()) return { reason: 'vault-off' };
    const dek = getDek();
    if (!dek) return { reason: 'locked' };
    return { dek, shopId: c.shopId, book, client: VaultClient.createVaultClient({ baseUrl: c.url, shopId: c.shopId, token: cloudToken(c.token, c.url) }) };
  }

  /** Pull the feed since the last rev and update key → fileId (VaultSync's pull). */
  async function refresh(ctx) {
    const s = load(ctx.shopId);
    const vk = await VC.deriveVaultKey(ctx.dek);
    const { rev, files } = await ctx.client.files({ since: s.rev });
    for (const row of files || []) {
      const fid = row.fileId;
      if (row.purged) {
        delete s.files[fid];
        for (const k of Object.keys(s.keys)) if (s.keys[k] === fid) delete s.keys[k];
        continue;
      }
      let meta = null;
      try { meta = await VaultLinks.openShopMeta(vk, row); } catch (_) { meta = null; }
      const prev = s.files[fid] || {};
      s.files[fid] = {
        seq: Math.max(prev.seq || 0, (meta && meta.seq) || 0),
        head: row.head, sha256: (meta && meta.sha256) || prev.sha256 || '',
        trashed: !!row.trashedAt,
      };
      if (meta && typeof meta.key === 'string' && meta.key) s.keys[meta.key] = fid;
    }
    if (Number.isFinite(rev)) s.rev = rev;
    save(ctx.shopId, s);
    return s;
  }

  /** One file of one record into the vault (VaultSync.putFile). */
  async function putFile(ctx, recordId, filename, srcPath, s) {
    const key = keyFor(recordId, filename);
    const st = await fs.promises.stat(srcPath);
    const fid = s.keys[key];
    const entry = fid ? s.files[fid] : null;
    const live = entry && !entry.trashed;
    const fd = await fs.promises.open(srcPath, 'r');
    try {
      const out = await uploadFile({
        dek: ctx.dek, size: st.size, name: filename, path: '', kind: kindOf(filename), key,
        readChunk: async (offset, len) => {
          const buf = Buffer.alloc(len);
          const { bytesRead } = await fd.read(buf, 0, len, offset);
          return buf.subarray(0, bytesRead);
        },
        fileId: live ? fid : undefined, baseVersion: live ? entry.head : undefined,
        lastSeq: live ? entry.seq : undefined, deviceId, client: ctx.client,
      });
      s.keys[key] = out.fileId;
      const prev = s.files[out.fileId] || {};
      s.files[out.fileId] = {
        seq: out.meta && out.meta.seq ? Math.max(prev.seq || 0, out.meta.seq) : (prev.seq || 0),
        head: out.duplicate ? (prev.head ?? out.version) : (out.conflict ? prev.head : out.version),
        sha256: out.sha256 || prev.sha256 || '', trashed: false,
      };
      save(ctx.shopId, s);
      return { key, fileId: out.fileId, duplicate: !!out.duplicate, conflict: !!out.conflict };
    } finally { await fd.close(); }
  }

  /** Every model file of these records. Failures are reported, never undone. */
  async function backUp(recordIds) {
    const ctx = context();
    if (!ctx.client) return { ok: false, reason: ctx.reason };
    let s;
    try { s = await refresh(ctx); } catch (e) { return { ok: false, reason: e.reason || '', error: String(e.message || e) }; }
    const done = []; const failed = [];
    for (const id of recordIds || []) {
      const dir = itemDir(id);
      let names = [];
      try { names = (await fs.promises.readdir(dir)).filter((n) => isModelFile(n) && !n.startsWith('.')); } catch (_) { names = []; }
      for (const n of names) {
        try { done.push({ id, ...(await putFile(ctx, id, n, path.join(dir, n), s)) }); }
        catch (e) {
          failed.push({ id, name: n, reason: (e && e.reason) || '', error: String((e && e.message) || e) });
          log.warn && log.warn('vault backup failed for a model:', (e && e.reason) || 'error');
        }
      }
    }
    return { ok: failed.length === 0, done, failed };
  }

  return { context, refresh, putFile, backUp, keyFor, kindOf };
}

module.exports = { createVaultBackup, keyFor, kindOf };
