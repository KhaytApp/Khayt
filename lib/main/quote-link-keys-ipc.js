'use strict';
/**
 * Pay link v2: the window's view of this computer's signing key and the
 * shop's keys (Settings › Online Store › Pay links). Main process only.
 *
 * Switched off unless KHAYT_PAYLINK_V2=1: with it off every handler answers
 * `{ ok: true, enabled: false }` and nothing is read or sent.
 *
 * The Khayt Cloud address, shop id and token are read from the book on disk
 * here, never taken from the window, and the key's seed never leaves main:
 * the window gets kids (short), statuses and device labels only.
 *
 * deps: `ipcMain`, `readBook()` (decrypted), `updateStoreOnDisk(mutate)`,
 * `transportFor(url, token)` (lib/cloud-client.js httpTransport),
 * `deviceName()`, `enabled()`.
 */
const Cloud = require('./quote-link-keys-cloud.js');

const short = (kid) => (kid ? `${String(kid).slice(0, 4)}…${String(kid).slice(-4)}` : '');

function cloudOf(book) {
  const c = (book && book.settings && book.settings.cloud) || {};
  const url = String(c.url || '').trim();
  const shopId = String(c.shopId || '').trim();
  const token = typeof c.token === 'string' && !c.token.startsWith('__enc__') ? c.token : '';
  return url && shopId && token ? { url, shopId, token, role: String(c.role || '') } : null;
}

const recordOf = (book) => {
  const r = book && book.settings && book.settings.quoteLinkKey;
  return r && typeof r === 'object' ? r : null;
};

/** What the window may see of a chain: no seed (the chain never has one), labels and short kids. */
function viewOf(chain, record, pending) {
  const mine = record ? record.kid : '';
  const keys = (chain && Array.isArray(chain.keys) ? chain.keys : [])
    .filter((k) => k && k.status !== 'revoked')
    .map((k) => ({ kid: k.kid, short: short(k.kid), status: k.status, created: k.created || '', device: k.device || '', mine: k.kid === mine }));
  let state = 'none';
  if (record) {
    const s = Cloud.statusIn(chain, record.kid);
    state = s === 'unpublished' ? (record.status === 'pending' ? 'pending' : 'unpublished') : s;
  }
  return {
    state, mine: record ? { kid: record.kid, short: short(record.kid), createdAt: record.createdAt || '', requestedAt: record.requestedAt || '' } : null,
    keys, pending: (pending || []).map((p) => ({ kid: p.kid, short: short(p.kid), device: p.device || '', requested: p.requested || '' })),
  };
}

function registerQuoteLinkKeys({ ipcMain, readBook, updateStoreOnDisk, transportFor, deviceName = () => '', enabled = () => process.env.KHAYT_PAYLINK_V2 === '1' }) {
  const off = { ok: true, enabled: false };
  const ctx = () => {
    const book = readBook();
    const cloud = cloudOf(book);
    return { book, cloud, record: recordOf(book), call: cloud ? transportFor(cloud.url, cloud.token) : null };
  };
  const store = (record) => updateStoreOnDisk((cur) => {
    const settings = { ...((cur && cur.settings) || {}) };
    if (record) settings.quoteLinkKey = record; else delete settings.quoteLinkKey;
    return { ...cur, settings };
  });
  const guard = (fn) => async (_e, args) => {
    if (!enabled()) return off;
    try { return await fn(args || {}); } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
  };

  ipcMain.handle('hub:qlk-status', guard(async () => {
    const { cloud, record, call } = ctx();
    if (!cloud) return { ok: true, enabled: true, cloud: false };
    const got = await Cloud.getChain(call, cloud.shopId);
    if (!got.ok) return { ok: false, enabled: true, cloud: true, error: got.error };
    let pending = [];
    if (record && Cloud.canSign(got.chain, record)) {
      const p = await Cloud.listPending(call, cloud.shopId);
      if (p.ok) pending = p.pending;
    }
    return { ok: true, enabled: true, cloud: true, ...viewOf(got.chain, record, pending) };
  }));

  ipcMain.handle('hub:qlk-setup', guard(async () => {
    const { cloud, record, call } = ctx();
    if (!cloud) return { ok: false, error: 'no-cloud' };
    if (record) return { ok: false, error: 'has-key' };
    const r = await Cloud.setUp(call, cloud.shopId, { device: deviceName() });
    if (!r.ok) return r;
    await store(r.record);
    return { ok: true, state: r.state };
  }));

  ipcMain.handle('hub:qlk-cancel', guard(async () => {
    const { cloud, record, call } = ctx();
    if (!record || record.status !== 'pending') return { ok: false, error: 'not-pending' };
    if (cloud) await Cloud.decline(call, cloud.shopId, record.kid);
    await store(null);
    return { ok: true };
  }));

  ipcMain.handle('hub:qlk-approve', guard(async ({ kid }) => {
    const { cloud, record, call } = ctx();
    if (!cloud || !record) return { ok: false, error: 'no-key' };
    const list = await Cloud.listPending(call, cloud.shopId);
    if (!list.ok) return list;
    const waiting = list.pending.find((p) => p.kid === kid);
    if (!waiting) return { ok: false, error: 'not-waiting' };
    return Cloud.approve(call, cloud.shopId, record, waiting);
  }));

  ipcMain.handle('hub:qlk-decline', guard(async ({ kid }) => {
    const { cloud, call } = ctx();
    if (!cloud) return { ok: false, error: 'no-cloud' };
    return Cloud.decline(call, cloud.shopId, String(kid || ''));
  }));

  ipcMain.handle('hub:qlk-rotate', guard(async () => {
    const { cloud, record, call } = ctx();
    if (!cloud || !record) return { ok: false, error: 'no-key' };
    const r = await Cloud.rotate(call, cloud.shopId, record);
    if (!r.ok) return r;
    await store(r.record);
    return { ok: true };
  }));

  ipcMain.handle('hub:qlk-revoke', guard(async ({ kid, code }) => {
    const { cloud, record, call } = ctx();
    if (!cloud) return { ok: false, error: 'no-cloud' };
    const r = await Cloud.revoke(call, cloud.shopId, String(kid || ''), code);
    if (r.ok && !r.codeSent && record && record.kid === kid) await store(null);
    return r;
  }));

  ipcMain.handle('hub:qlk-reset', guard(async ({ code }) => {
    const { cloud, call } = ctx();
    if (!cloud) return { ok: false, error: 'no-cloud' };
    const r = await Cloud.reset(call, cloud.shopId, code);
    if (r.ok && !r.codeSent) await store(null);
    return r;
  }));
}

module.exports = { registerQuoteLinkKeys, viewOf, cloudOf, short };
