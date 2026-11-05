'use strict';
/**
 * Khayt Vault share links on Windows/Linux — the Mac's VaultShareSheet and
 * VaultLinksSheet, over the shared rules in lib/vault-client.js and
 * lib/vault-links.js.
 *
 * ── WHAT IT CAN SHARE ───────────────────────────────────────────────────
 *
 * Files already in the shop's vault. Getting a model INTO the vault is the
 * library's backup, and on a library kept in the vault this app has no vault
 * upload yet (main.js printLibRemote) — so a model the Mac backed up can be
 * shared from here; one that has no vault copy is refused by name, as the Mac
 * refuses it.
 *
 * ── THE LINK SECRET ─────────────────────────────────────────────────────
 *
 * The part after `#` is what opens the files, and Khayt Cloud never sees it.
 * It is kept so Copy Link can be offered again later — on THIS computer only
 * (the Mac keeps its own in the Keychain): a file in userData, each secret
 * sealed with the OS key store (Electron safeStorage). Where the OS offers no
 * key store nothing is kept, and the link is shown once to copy. Never in the
 * book.
 */
const fs = require('fs');
const path = require('path');
const VaultClient = require('../vault-client.js');
const VaultLinks = require('../vault-links.js');
const VC = require('../vault-crypto.js');
const { itemDirName } = require('../print-library-location.js');

function registerVaultLinks({ app, ipcMain, safeStorage, readBook, getDek, cloudToken, isVaultOn, log = console }) {
  const secretsFile = (shopId) => path.join(app.getPath('userData'), `vault-links.${String(shopId).replace(/[^A-Za-z0-9_-]/g, '_')}.json`);
  const readSecrets = (shopId) => { try { return JSON.parse(fs.readFileSync(secretsFile(shopId), 'utf8')) || {}; } catch (_) { return {}; } };
  const writeSecrets = (shopId, all) => {
    const f = secretsFile(shopId); const tmp = f + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(all)); fs.renameSync(tmp, f);
  };
  const canKeep = () => { try { return safeStorage.isEncryptionAvailable(); } catch (_) { return false; } };

  /** The secret store lib/vault-links.js asks for, sealed per entry. */
  function secretsFor(shopId) {
    return {
      async save(grantId, rec) {
        if (!canKeep()) return false;
        const all = readSecrets(shopId);
        all[grantId] = {
          s: safeStorage.encryptString(Buffer.from(rec.secret).toString('base64')).toString('base64'),
          pendingSince: rec.pendingSince ? new Date(rec.pendingSince).toISOString() : null,
        };
        writeSecrets(shopId, all);
        return true;
      },
      async forget(grantId) {
        const all = readSecrets(shopId);
        if (all[grantId]) { delete all[grantId]; writeSecrets(shopId, all); }
      },
      read(grantId) {
        const e = readSecrets(shopId)[grantId];
        if (!e || !canKeep()) return null;
        try { return Buffer.from(safeStorage.decryptString(Buffer.from(e.s, 'base64')), 'base64'); } catch (_) { return null; }
      },
    };
  }

  /** Signed in, unlocked, and on a vault library — or why not, as a reason code. */
  function context() {
    const book = readBook() || {};
    const c = (book.settings && book.settings.cloud) || {};
    if (!(c.enabled && c.shopId && c.url)) return { reason: 'signin' };
    if (!isVaultOn()) return { reason: 'vault-off' };
    const dek = getDek();
    if (!dek) return { reason: 'locked' };
    const client = VaultClient.createVaultClient({ baseUrl: c.url, shopId: c.shopId, token: cloudToken(c.token, c.url) });
    return { client, dek, shopId: c.shopId, book };
  }
  const fail = (e) => ({ ok: false, reason: (e && e.reason) || '', status: (e && e.status) || 0, limit: e && e.limit, fileIds: e && e.fileIds, error: String((e && e.message) || e) });

  ipcMain.handle('hub:vault-links-status', async () => {
    const ctx = context();
    if (!ctx.client) return { ok: true, available: false, reason: ctx.reason };
    try {
      const usage = await ctx.client.usage();
      return { ok: true, available: true, usage };
    } catch (e) { return { ...fail(e), available: false }; }
  });

  /** Share library records by link. `recordIds` are printFiles ids. */
  ipcMain.handle('hub:vault-share', async (_e, { recordIds, options } = {}) => {
    const ctx = context();
    if (!ctx.client) return { ok: false, reason: ctx.reason };
    try {
      const records = ((ctx.book && ctx.book.printFiles) || []).filter((r) => r && (recordIds || []).includes(r.id));
      const { files } = await ctx.client.files({ since: 0 });
      // A record's vault copy: its vaultFileId when the Mac's VaultApply has
      // written one, else the live file whose key is in the record's folder
      // (print-files/<itemDirName(id)>/…) — the folder IS the record, as the
      // Mac matches it. The model's own file first, when the record names it.
      const byKey = new Map();
      const vk = await VC.deriveVaultKey(ctx.dek);
      for (const row of files || []) {
        if (!row || row.purged || row.trashedAt) continue;
        try { const m = await VaultLinks.openShopMeta(vk, row); if (m && m.key) byKey.set(m.key, row.fileId); } catch (_) { /* not one of ours */ }
      }
      const findFor = (r) => {
        if (r.vaultFileId) return r.vaultFileId;
        const prefix = 'print-files/' + itemDirName(r.id) + '/';
        const own = r.sourceFile && r.sourceFile.filename ? String(r.sourceFile.filename).toLowerCase() : null;
        let any = null;
        for (const [k, fid] of byKey) {
          if (!k.startsWith(prefix)) continue;
          if (own && k.slice(prefix.length).toLowerCase() === own) return fid;
          if (!any) any = fid;
        }
        return any;
      };
      const fileIds = []; const missing = [];
      for (const r of records) { const f = findFor(r); if (f) fileIds.push(f); else missing.push(r.name || r.id); }
      if (missing.length || !fileIds.length) return { ok: false, reason: 'not-in-vault', names: missing };
      const out = await VaultLinks.createLink({
        dek: ctx.dek, files, fileIds, client: ctx.client, options: options || {},
        secrets: secretsFor(ctx.shopId),
      });
      return { ok: true, url: out.url, grantId: out.grantId, itemCount: out.itemCount, kept: out.secretKept };
    } catch (e) {
      log.warn && log.warn('vault share failed:', (e && e.reason) || 'error');
      return fail(e);
    }
  });

  /** The shop's links, with which ones this computer can copy again. */
  ipcMain.handle('hub:vault-links', async () => {
    const ctx = context();
    if (!ctx.client) return { ok: false, reason: ctx.reason };
    try {
      const r = await ctx.client.listGrants();
      const kept = readSecrets(ctx.shopId);
      const names = new Map();
      for (const f of (ctx.book.printFiles || [])) if (f && f.vaultFileId) names.set(f.vaultFileId, f.name || f.originalName || '');
      const grants = (r.grants || r || []).map((g) => ({
        ...g, copyable: !!kept[g.grantId],
        names: (g.items || []).map((it) => names.get(it.fileId) || '').filter(Boolean),
      }));
      return { ok: true, grants };
    } catch (e) { return fail(e); }
  });

  ipcMain.handle('hub:vault-link-url', async (_e, { grantId } = {}) => {
    const ctx = context();
    if (!ctx.client) return { ok: false, reason: ctx.reason };
    const secret = secretsFor(ctx.shopId).read(String(grantId || ''));
    if (!secret) return { ok: false, reason: 'not-kept' };
    return { ok: true, url: VaultLinks.linkUrl(VaultLinks.originForApi(ctx.client.baseUrl), grantId, secret) };
  });

  ipcMain.handle('hub:vault-link-change', async (_e, { grantId, action, value } = {}) => {
    const ctx = context();
    if (!ctx.client) return { ok: false, reason: ctx.reason };
    try {
      const id = String(grantId || '');
      if (action === 'revoke') {
        await VaultLinks.revokeLink(ctx.client, id);
        await secretsFor(ctx.shopId).forget(id);
      } else if (action === 'extend') {
        await VaultLinks.extendLink(ctx.client, id, value == null ? null : new Date(value));
      } else if (action === 'add') {
        await VaultLinks.addDownloads(ctx.client, id, Math.max(1, Math.floor(Number(value) || 0)));
      } else return { ok: false, reason: 'unknown-action' };
      return { ok: true };
    } catch (e) { return fail(e); }
  });
}

module.exports = { registerVaultLinks };
