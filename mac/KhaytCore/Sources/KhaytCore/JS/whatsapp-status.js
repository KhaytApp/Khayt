'use strict';
/**
 * What Meta said happened to a WhatsApp message, applied to the customer's
 * communication log.
 *
 * The Mac sends through the shop's own WhatsApp Business account and stores
 * the `wamid…` the Cloud API answers on the commLog line (`messageId`). Meta
 * reports `sent`, `delivered`, `read` and `failed` to khayt-cloud, which keeps
 * them for 30 days; the Mac polls `GET /whatsapp-statuses` and hands the items
 * here (khayt-cloud docs/api-contract.md, "WhatsApp delivery reports").
 *
 * ── ONLY FORWARD ──────────────────────────────────────────────────────────
 *
 * `sent < delivered < read < failed`, the cloud's own order. A late or
 * repeated lower report never moves a line back: "read" then a delayed
 * "delivered" stays "read". `failed` is last because a message Meta gave up on
 * after it was sent is a failure whatever came before.
 *
 * Pure: no clock, no I/O. Returns new clients and leaves the input alone.
 */
(function (global) {
  const RANK = { sent: 1, delivered: 2, read: 3, failed: 4 };

  const str = (v) => String(v == null ? '' : v).trim();

  /**
   * `{ clients, changed, unmatched }`. `changed` counts lines that moved;
   * `unmatched` counts reports naming no line in this book — another Mac's
   * send not yet synced here, or one sent before the log was trimmed.
   */
  function apply(clients, items) {
    const latest = new Map();
    for (const it of Array.isArray(items) ? items : []) {
      const id = str(it && it.messageId);
      const rank = RANK[str(it && it.status)];
      if (!id || !rank) continue;
      const had = latest.get(id);
      if (!had || rank > RANK[had.status]) latest.set(id, it);
    }
    let changed = 0;
    const found = new Set();
    const out = (Array.isArray(clients) ? clients : []).map((c) => {
      if (!c || !Array.isArray(c.commLog)) return c;
      let touched = false;
      const log = c.commLog.map((e) => {
        const id = str(e && e.messageId);
        const it = id && latest.get(id);
        if (!it) return e;
        found.add(id);
        const now = RANK[str(e.status)] || 0;
        if (RANK[it.status] <= now) return e;
        touched = true;
        changed++;
        const next = Object.assign({}, e, { status: it.status, statusAt: str(it.at) || e.statusAt });
        if (it.status === 'failed') {
          if (it.errorCode != null) next.errorCode = it.errorCode;
          if (str(it.errorTitle)) next.errorTitle = str(it.errorTitle);
        }
        return next;
      });
      return touched ? Object.assign({}, c, { commLog: log }) : c;
    });
    let unmatched = 0;
    for (const id of latest.keys()) if (!found.has(id)) unmatched++;
    return { clients: out, changed, unmatched };
  }

  const api = { RANK, apply };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytWhatsappStatus = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
