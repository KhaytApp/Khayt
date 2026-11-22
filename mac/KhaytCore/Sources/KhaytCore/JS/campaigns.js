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

/**
 * The phone rule WhatsApp sends by, however this file was loaded (the same
 * script-tag-or-require resolution as `CL` below). Looked up when asked,
 * not at load, so the order of the script tags does not decide it.
 */
const waApi = () => (typeof KhaytWhatsappMessage !== 'undefined') ? KhaytWhatsappMessage
  : (typeof require === 'function' ? require('./whatsapp-message.js') : null);

/**
 * Whether the customer agreed to OFFERS on WhatsApp.
 *
 * Its own field, apart from `whatsappOptIn`: that one is agreeing to hear
 * about your order, and an offer is not your order. `whatsappMarketingOptIn:
 * { at, how }` — when, and how it was given (`asked`, `form`,
 * `customer_wrote`, `other`), the same shape — and removing the field is
 * withdrawing it. A shop's WhatsApp Business account writes first, so Meta
 * holds it to having asked; this is the record that it did.
 */
const OFFERS_HOW = ['asked', 'form', 'customer_wrote', 'other'];
function whatsappOffersOptedIn(client) {
  const o = client && client.whatsappMarketingOptIn;
  return !!(o && typeof o === 'object' && String(o.at || '').trim());
}

/**
 * The contact value for a channel, or '' if the client can't be reached there.
 *
 * `whatsapp_business` is the shop's own WhatsApp Business account: an
 * approved template to a customer who agreed to offers there, at a number
 * WhatsApp can dial (digits, country code first). A number that can't be
 * made into one is not guessed at — an offer to a stranger is worse than none.
 */
function channelContact(client, channel) {
  if (!client || client.marketingOptOut) return '';
  if (channel === 'email') return String(client.email || '').trim();
  if (channel === 'whatsapp_business') {
    const WA = waApi();
    if (!whatsappOffersOptedIn(client) || !WA) return '';
    const n = WA.normalizePhone(client.phone);
    return n.ok ? n.digits : '';
  }
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

/** Escape a merge VALUE for an HTML body. The shop's own text is not touched. */
function escapeHtml(v) {
  return String(v == null ? '' : v)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/**
 * Fill merge fields in a message body for one recipient.
 *
 * `opts.html` — the result goes into an HTML email. The VALUES are escaped
 * then (a customer's name is data, and data holds whatever somebody once
 * pasted into it — `<img src=x onerror=…>` included); the shop's own body is
 * left as it wrote it. Off by default, because the same fill feeds WhatsApp
 * and SMS, where `&amp;` would be printed literally.
 *
 * Every replacement is a FUNCTION, not a string: a string replacement reads
 * `$&`, `$1` and `$$` in the value as patterns, so a client called `A$&B`
 * came out as `A{{name}}B`.
 */
function fillTemplate(text, recipient, fmtMoney, settings, opts) {
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
  const name = String(c.name || resolved || '').trim();
  const spend = typeof fmtMoney === 'function' ? fmtMoney(s.totalSpend || 0) : String(s.totalSpend || 0);
  const out = (opts && opts.html) ? escapeHtml : (v) => String(v);
  return String(text == null ? '' : text)
    .replace(/\{\{\s*name\s*\}\}/gi, () => out(name))
    .replace(/\{\{\s*orders\s*\}\}/gi, () => out(String(s.completedCount || 0)))
    .replace(/\{\{\s*spend\s*\}\}/gi, () => out(spend))
    .replace(/\{\{\s*last_order\s*\}\}/gi, () => out(s.lastOrderDate || ''));
}

/**
 * The values for an approved template's numbered slots, one per line of what
 * the shop wrote: line 1 fills {{1}}, line 2 fills {{2}}. Each line takes the
 * same merge fields as a message, so `{{name}}` on line 1 is the customer's
 * name in slot 1. Blank lines are dropped — a template has no empty slot.
 */
function templateValues(text, recipient, fmtMoney, settings) {
  return String(text == null ? '' : text).split(/\r?\n/)
    .map((line) => fillTemplate(line, recipient, fmtMoney, settings).trim())
    .filter(Boolean);
}

const api = { clientStats, daysSinceLastOrder, matchesSegment, channelContact, segmentRecipients, fillTemplate,
  OFFERS_HOW, whatsappOffersOptedIn, templateValues };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytCampaigns = api;

})();
