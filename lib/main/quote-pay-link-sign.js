'use strict';
/**
 * The quote pay link on the desktop: the one step lib/quote-pay-link.js leaves
 * to the device (the HMAC), and the shop's secret that step needs.
 *
 * Everything that decides WHAT is signed — the lines, the reasons a link may
 * not be offered, the claims, the token, the address — is the shared rule, so
 * the Mac and the desktop cannot disagree about a price. This file only:
 *
 *   - keeps the secret. It is set and removed here, through the book on disk,
 *     where store-io seals it with safeStorage (store-secret-paths
 *     SECRET_PATHS) and never sends it anywhere (PER_DEVICE_PATHS). The window
 *     never holds it: it sees the mask, and a save from the window cannot
 *     write or erase it (store-io keepMainOwnedPayLinkSecret).
 *   - signs. The window names a job; the job, the customer and the settings
 *     are read from the book main holds, not taken from the window, so a
 *     window cannot ask for a link to a price the book does not say.
 *
 * Node `crypto` does the HMAC-SHA256, with the secret's UTF-8 bytes as the
 * key, over `signingInput(claims)`.
 */
const PayLink = require('../quote-pay-link.js');

/** The customer's name as the shop keeps it: the record's, else what the job says. */
function customerNameOf(order, clients, locale) {
  const client = order && order.clientId && Array.isArray(clients)
    ? clients.find((c) => c && c.id === order.clientId) : null;
  if (client) {
    const en = String(client.nameEn || client.name || '').trim();
    const ar = String(client.nameAr || '').trim();
    const english = String(locale || '').toLowerCase().indexOf('en') === 0;
    return (english ? (en || ar) : (ar || en)) || String(order.client || '').trim();
  }
  return String((order && order.client) || '').trim();
}

/** The two fee names a customer reads, cut to what a title may hold. */
function cleanWords(words) {
  const w = words && typeof words === 'object' ? words : {};
  const one = (v) => (typeof v === 'string' ? v.slice(0, 200) : '');
  return { rush: one(w.rush), extra: one(w.extra) };
}

/**
 * Sign the link for one job. Pure apart from `crypto`.
 *
 * `{ store, orderId, secret, locale, words, nowSeconds, crypto }` →
 *   `{ ok: true, url, record }` or `{ ok: false, blockers }` / `{ ok: false, error }`.
 */
function signQuotePayLink({ store, orderId, secret, locale, words, nowSeconds, crypto }) {
  const book = store && typeof store === 'object' ? store : {};
  const settings = book.settings || {};
  const q = settings.quotePayLink || {};
  const order = (Array.isArray(book.printLog) ? book.printLog : []).find((o) => o && o.id === orderId);
  if (!order) return { ok: false, error: 'no_job' };
  const hasSecret = PayLink.secretIsUsable(secret);
  const config = { storeUrl: q.storeUrl, hasSecret };
  const ctx = {
    settings, clients: book.clients || [], config,
    nowSeconds, lastIssuedAt: order.payLink && order.payLink.issuedAt,
    words: cleanWords(words),
    customerName: customerNameOf(order, book.clients, locale),
  };
  const blockers = PayLink.blockers(order, ctx);
  if (blockers.length) return { ok: false, blockers };
  const claims = PayLink.claimsFor(order, ctx);
  if (!claims) return { ok: false, error: 'no_claims' };
  const input = PayLink.signingInput(claims);
  const mac = crypto.createHmac('sha256', Buffer.from(secret, 'utf8')).update(input, 'utf8').digest();
  const token = PayLink.tokenFrom(input, Array.from(mac));
  const url = PayLink.urlFor(q.storeUrl, locale, token);
  if (!token || !url) return { ok: false, error: 'no_token' };
  return { ok: true, url, record: PayLink.recordOf(claims, { locale, sentAt: new Date(nowSeconds * 1000).toISOString() }) };
}

/**
 * The IPC the window uses. It never answers with the secret: `set` says when
 * it was set, `sign` answers with the link.
 *
 * deps: `ipcMain`, `crypto`, `readBook()` (the book main holds, decrypted),
 * `updateStoreOnDisk(mutate)`, `now()` in ms.
 */
function registerQuotePayLink({ ipcMain, crypto, readBook, updateStoreOnDisk, now = () => Date.now() }) {
  const secretOf = (book) => {
    const s = book && book.settings && book.settings.quotePayLink && book.settings.quotePayLink.secret;
    return typeof s === 'string' && !s.startsWith('__enc__') ? s : '';
  };

  ipcMain.handle('hub:quote-pay-link-set-secret', async (_e, secret) => {
    if (!PayLink.secretIsUsable(secret)) return { ok: false, error: 'short' };
    const setAt = new Date(now()).toISOString();
    try {
      await updateStoreOnDisk((cur) => {
        const settings = { ...((cur && cur.settings) || {}) };
        settings.quotePayLink = { ...(settings.quotePayLink || {}), secret, secretSetAt: setAt };
        return { ...cur, settings };
      });
      return { ok: true, setAt };
    } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
  });

  ipcMain.handle('hub:quote-pay-link-remove-secret', async () => {
    try {
      await updateStoreOnDisk((cur) => {
        const settings = { ...((cur && cur.settings) || {}) };
        const q = { ...(settings.quotePayLink || {}) };
        delete q.secret; delete q.secretSetAt;
        settings.quotePayLink = q;
        return { ...cur, settings };
      });
      return { ok: true };
    } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
  });

  ipcMain.handle('hub:quote-pay-link-sign', async (_e, { orderId, locale, words } = {}) => {
    try {
      const book = readBook();
      return signQuotePayLink({
        store: book, orderId: String(orderId || ''), secret: secretOf(book),
        locale: String(locale || 'ar'), words, nowSeconds: Math.floor(now() / 1000), crypto,
      });
    } catch (e) { return { ok: false, error: String((e && e.message) || e) }; }
  });
}

module.exports = { signQuotePayLink, registerQuotePayLink, customerNameOf };
