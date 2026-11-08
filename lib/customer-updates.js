'use strict';
/**
 * The desktop's half of the customer's automatic order updates.
 *
 * The RULE is `lib/whatsapp-message.js` (`cloudMessage`, `isUnreachable`,
 * `commEntry`, `sentAt`) and the delivery reports are `lib/whatsapp-status.js`
 * — both shared with the Mac, which has sent these since alpha. This module is
 * only what the Electron window needs around them that the Mac does in Swift
 * (`WhatsAppCloud.swift`, `WhatsAppReports.swift`):
 *
 *   - `beforeOf` — the job as it was before a move. The Mac holds the row it
 *     read before writing; the window's `runStatusEffects` is handed the job
 *     already moved, so the step it took is read back from the job's own
 *     `statusHistory`, which every move (`lib/order-status.js` `apply`,
 *     `markShipped`, `markDelivered`) has just appended to.
 *   - `appendComm` — the customer's log, appended and kept to the NEWEST two
 *     hundred, as `Shop.addCommunication` keeps it.
 *   - `jobLines` — the lines a job's own updates wrote, for the job editor.
 *   - `keep` / `seq` — this device's memory of the reports, as the Mac keeps
 *     them in its preferences.
 *
 * Desktop-only (not in the Mac's bundle). Pure: no clock, no DOM, no I/O.
 */
(function (global) {

  /** The milestone a history entry stands for, as a `before` row. */
  function rowFor(entry) {
    const s = String((entry && entry.status) || '');
    if (!s) return null;
    if (s === 'shipped') return { status: 'completed', shippedAt: String(entry.at || '1') };
    if (s === 'delivered') return { status: 'completed', deliveredAt: String(entry.at || '1') };
    return { status: s };
  }

  /**
   * The job as it stood before the move that just wrote its last history
   * line, or null when that cannot be known (no line before it).
   *
   * Null is the cautious answer and the caller treats it as "not a step":
   * the Mac sends only for a step FORWARD into a milestone, and a job whose
   * last stage is unknown cannot be shown to have taken one. Such a job is
   * still offered the update in its editor (`canSendNow`).
   */
  function beforeOf(order) {
    const h = order && Array.isArray(order.statusHistory) ? order.statusHistory : [];
    if (h.length < 2) return null;
    return rowFor(h[h.length - 2]);
  }

  /** `log` with `entry` appended, the newest 200 kept. A new array. */
  const LOG_MAX = 200;
  function appendComm(log, entry) {
    const out = (Array.isArray(log) ? log : []).concat([entry]);
    return out.length > LOG_MAX ? out.slice(out.length - LOG_MAX) : out;
  }

  /**
   * The lines this job's customer updates wrote — WhatsApp (opened or sent
   * for the shop) and SMS — newest first.
   */
  function jobLines(client, orderId) {
    const log = client && Array.isArray(client.commLog) ? client.commLog : [];
    const id = String(orderId || '');
    if (!id) return [];
    return log.filter((e) => {
      if (!e || e.orderId !== id) return false;
      const kind = e.type || e.channel;
      return kind === 'whatsapp' || kind === 'wa' || kind === 'sms';
    }).sort((a, b) => String(b.at || '').localeCompare(String(a.at || '')));
  }

  /** A delivery state worth showing, or '' (`lib/whatsapp-status.js` RANK). */
  const STATES = ['sent', 'delivered', 'read', 'failed'];
  function deliveryOf(line) {
    const s = String((line && line.status) || '');
    return STATES.indexOf(s) !== -1 ? s : '';
  }

  // ── WHAT THIS DEVICE HAS BEEN TOLD ──────────────────────────────────────
  //
  // `WhatsAppReports.keep` on the Mac. A report is written into the book
  // UNSTAMPED, so it never wins a merge over a person's edit on another
  // device; what a merge then brings back is the other copy without it. So the
  // reports are kept here too, the highest per message, and laid over the
  // book again on every poll (`apply` only moves forward, so twice is once).

  const KEPT_MAX = 5000;
  const RANK = { sent: 1, delivered: 2, read: 3, failed: 4 };

  /** Only what `KhaytWhatsappStatus.apply` reads; nothing else is kept. */
  function slim(it) {
    if (!it || typeof it !== 'object') return null;
    const out = {};
    for (const k of ['messageId', 'status', 'at']) if (typeof it[k] === 'string') out[k] = it[k];
    if (typeof it.errorCode === 'number' && Number.isFinite(it.errorCode)) out.errorCode = it.errorCode;
    if (typeof it.errorTitle === 'string') out.errorTitle = it.errorTitle.slice(0, 200);
    return out;
  }

  /** `kept` with `items` folded in: the highest report per message, the newest `KEPT_MAX`. */
  function keep(kept, items) {
    const latest = new Map();
    for (const raw of (Array.isArray(kept) ? kept : []).concat(Array.isArray(items) ? items : [])) {
      const it = slim(raw);
      if (!it || !it.messageId || !RANK[it.status]) continue;
      const had = latest.get(it.messageId);
      if (had && RANK[had.status] >= RANK[it.status]) continue;
      latest.set(it.messageId, it);
    }
    return Array.from(latest.values())
      .sort((a, b) => String(b.at || '').localeCompare(String(a.at || '')))
      .slice(0, KEPT_MAX);
  }

  /** The cloud's `nextSince` as a whole number, or null. */
  function seq(v) {
    const n = typeof v === 'string' && v.trim() !== '' ? Number(v) : v;
    return typeof n === 'number' && Number.isSafeInteger(n) ? n : null;
  }

  /** How often the reports are read: the Mac's two minutes. */
  const POLL_MS = 120 * 1000;

  const api = { beforeOf, appendComm, jobLines, deliveryOf, keep, seq, POLL_MS, LOG_MAX, KEPT_MAX };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytCustomerUpdates = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
