'use strict';
(function () {

/**
 * Marketing campaigns — pure customer segmentation + message merge. Side-effect
 * free (inject orders + now) so it can be unit-tested and reused. The renderer
 * resolves the channel transport (email / SMS) and loops with throttling.
 *
 * A customer is reachable for a channel only if they have the contact field AND
 * have not opted out of marketing (client.marketingOptOut).
 */

const DAY = 86400000;

/** Per-client rollup from the order log (completed orders only). */
function clientStats(clientId, orders) {
  let completedCount = 0;
  let totalSpend = 0;
  let lastOrderDate = '';
  for (const o of Array.isArray(orders) ? orders : []) {
    if (!o || o.clientId !== clientId) continue;
    const d = o.date || '';
    if (d > lastOrderDate) lastOrderDate = d;
    // Finished by either spelling: a legacy `delivered` row is money the customer spent.
    if (o.status === 'completed' || o.status === 'delivered') { completedCount++; totalSpend += +o.price || 0; }
  }
  return { completedCount, totalSpend: Math.round(totalSpend * 100) / 100, lastOrderDate };
}

/** Days since the client's most recent order (Infinity if they've never ordered). */
function daysSinceLastOrder(stats, now) {
  if (!stats.lastOrderDate) return Infinity;
  const t = Date.parse(stats.lastOrderDate);
  if (Number.isNaN(t)) return Infinity;
  return Math.floor((now - t) / DAY);
}

/**
 * Does a client match the segment criteria?
 *   minSpend / maxSpend  — lifetime completed-order spend bounds
 *   noOrderDays          — last order is at least this many days ago (incl. never)
 *   activeWithinDays     — ordered within this many days
 *   tag                  — client.tags includes this tag
 *   tier                 — opts.tierOf(clientId) === tier (renderer supplies tierOf)
 */
function matchesSegment(client, stats, criteria, now, opts) {
  criteria = criteria || {};
  opts = opts || {};
  if (criteria.minSpend != null && stats.totalSpend < +criteria.minSpend) return false;
  if (criteria.maxSpend != null && stats.totalSpend > +criteria.maxSpend) return false;
  if (criteria.noOrderDays != null && daysSinceLastOrder(stats, now) < +criteria.noOrderDays) return false;
  if (criteria.activeWithinDays != null && daysSinceLastOrder(stats, now) > +criteria.activeWithinDays) return false;
  if (criteria.tag) {
    const tags = Array.isArray(client.tags) ? client.tags.map((x) => String(x).toLowerCase()) : [];
    if (!tags.includes(String(criteria.tag).toLowerCase())) return false;
  }
  if (criteria.tier && typeof opts.tierOf === 'function' && opts.tierOf(client.id) !== criteria.tier) return false;
  return true;
}

/** The contact value for a channel, or '' if the client can't be reached there. */
function channelContact(client, channel) {
  if (!client || client.marketingOptOut) return '';
  if (channel === 'email') return String(client.email || '').trim();
  return String(client.phone || '').trim(); // sms / whatsapp
}

/**
 * Build the recipient list for a campaign: clients matching the segment who are
 * reachable on the channel (and not opted out). → [{ client, stats, contact }].
 */
function segmentRecipients(clients, orders, criteria, channel, now, opts) {
  const out = [];
  for (const c of Array.isArray(clients) ? clients : []) {
    if (!c) continue;
    const stats = clientStats(c.id, orders);
    if (!matchesSegment(c, stats, criteria, now, opts)) continue;
    const contact = channelContact(c, channel);
    if (!contact) continue;
    out.push({ client: c, stats, contact });
  }
  return out;
}

/**
 * The content-language model, however this file was loaded.
 *
 * Script tag in the renderer, `require` in a test — and it has to resolve in
 * both, because the value it produces is SENT TO A CUSTOMER.
 */
const CL = (typeof KhaytContentLanguages !== 'undefined') ? KhaytContentLanguages
  : (typeof require === 'function' ? require('./content-languages.js') : null);

/** Fill merge fields in a message body for one recipient. */
function fillTemplate(text, recipient, fmtMoney, settings) {
  const c = (recipient && recipient.client) || {};
  const s = (recipient && recipient.stats) || {};
  /* `{{name}}` goes out in a message a real customer reads.
   *
   * `c.nameEn || c.nameAr` is empty for a shop writing German or Turkish, so
   * the campaign it sent opened "Hi ," — with the greeting intact and the name
   * missing, to every client on the list. */
  const resolved = CL
    ? CL.read(c, 'name', (settings && settings.lang) || null, settings || null)
    // Module absent (a bare unit test): the two original keys, checked as a list
    // rather than as an English-or-Arabic pair, which is the bug above.
    : (['nameEn', 'nameAr'].map((k) => c[k]).find((v) => v && String(v).trim()) || '');
  const name = (c.name || resolved || '').trim();
  const spend = typeof fmtMoney === 'function' ? fmtMoney(s.totalSpend || 0) : String(s.totalSpend || 0);
  return String(text == null ? '' : text)
    .replace(/\{\{\s*name\s*\}\}/gi, name)
    .replace(/\{\{\s*orders\s*\}\}/gi, String(s.completedCount || 0))
    .replace(/\{\{\s*spend\s*\}\}/gi, spend)
    .replace(/\{\{\s*last_order\s*\}\}/gi, s.lastOrderDate || '');
}

const api = { clientStats, daysSinceLastOrder, matchesSegment, channelContact, segmentRecipients, fillTemplate };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytCampaigns = api;

})();
