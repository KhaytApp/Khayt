'use strict';
(function () {

/**
 * AI shop assistant — answer questions grounded in the shop's own data.
 *
 * Like lib/ai-quote.js + lib/ai-reply.js: pure + transport-injected. This module
 * builds a COMPACT, curated summary of the shop (aggregates + small top-N lists,
 * not the raw store) and the prompts; the model call goes through the app's
 * aiExtract IPC (the owner's Anthropic key). The system prompt forbids inventing
 * facts — the model must answer only from the provided summary.
 */

const DAY = 86400000;
const ACTIVE = new Set(['pending', 'printing', 'post', 'qc', 'on_hold']);
const DONE = new Set(['completed', 'delivered']);

const ASSISTANT_SCHEMA = {
  type: 'object',
  required: ['answer'],
  properties: { answer: { type: 'string' }, grounded: { type: 'boolean' } },
};

function monthKey(ms) { const d = new Date(ms); return d.getUTCFullYear() * 12 + d.getUTCMonth(); }
function orderMs(o) { const t = Date.parse(o.completedAt || o.date || ''); return Number.isNaN(t) ? null : t; }
function partGrams(p) { return ((+p.printWeight || 0) + (+p.supportWeight || 0)) * (+p.qty || 1); }

/** Build a compact, privacy-curated summary of the shop for the model. */
function buildShopContext(collections, opts) {
  opts = opts || {};
  const now = opts.now || 0;
  const orders = Array.isArray(collections.printLog) ? collections.printLog : [];
  const inventory = Array.isArray(collections.inventory) ? collections.inventory : [];
  const clients = Array.isArray(collections.clients) ? collections.clients : [];
  const settings = collections.settings || {};
  const todayMid = now;
  const thisMonth = monthKey(now);

  const byStatus = {};
  let revenueThisMonth = 0, revenueLastMonth = 0, outstanding = 0;
  const overdue = [];
  const gramsByItem = {};
  for (const o of orders) {
    if (!o) continue;
    byStatus[o.status] = (byStatus[o.status] || 0) + 1;
    const price = +o.price || 0;
    const oms = orderMs(o);
    if (DONE.has(o.status) && oms != null) {
      const mk = monthKey(oms);
      if (mk === thisMonth) revenueThisMonth += price;
      else if (mk === thisMonth - 1) revenueLastMonth += price;
    }
    if (!DONE.has(o.status) && o.status !== 'quote' && o.status !== 'split') {
      const paid = +o.paidAmount || 0;
      if (price - paid > 0) outstanding += price - paid;
      if (o.dueDate) { const due = Date.parse(o.dueDate); if (!Number.isNaN(due) && due < todayMid) overdue.push({ id: o.id, project: o.project || '', dueDate: o.dueDate }); }
    }
    // material usage from completed orders (last 90 days)
    if (DONE.has(o.status) && oms != null && now - oms < 90 * DAY) {
      for (const p of (o.parts || [])) {
        const key = p && (p.spoolId || p.filamentId);
        if (key) gramsByItem[key] = (gramsByItem[key] || 0) + partGrams(p);
      }
    }
  }
  const invById = {};
  for (const i of inventory) if (i && i.id) invById[i.id] = i;
  const topMaterials = Object.entries(gramsByItem)
    .map(([id, g]) => ({ material: (invById[id] && (invById[id].material || invById[id].name)) || id, grams: Math.round(g) }))
    .sort((a, b) => b.grams - a.grams).slice(0, 5);
  const lowStock = inventory
    .filter((i) => (+i.weight || 0) <= (i.reorderPoint != null ? i.reorderPoint : (settings.lowStockThreshold != null ? settings.lowStockThreshold : 200)))
    .map((i) => ({ material: i.material || i.name || '—', grams: Math.round(+i.weight || 0) })).slice(0, 10);

  return {
    currency: opts.currency || '',
    counts: { orders: orders.length, clients: clients.length, active: orders.filter((o) => ACTIVE.has(o.status)).length, quotes: (byStatus.quote || 0) },
    ordersByStatus: byStatus,
    revenueThisMonth: Math.round(revenueThisMonth),
    revenueLastMonth: Math.round(revenueLastMonth),
    outstanding: Math.round(outstanding),
    overdue: overdue.slice(0, 10),
    overdueCount: overdue.length,
    topMaterials90d: topMaterials,
    lowStock,
  };
}

function buildAssistantSystem(opts) {
  opts = opts || {};
  const lang = opts.lang === 'ar' ? 'Arabic' : 'English';
  return [
    `You are a concise analyst for ${opts.shopName || 'a 3D-printing shop'}.`,
    `Answer in ${lang}.`,
    'Use ONLY the JSON shop summary provided — never invent numbers, orders, or trends not present in it.',
    'If the summary lacks what was asked, say so plainly and suggest what to check in the app.',
    'Prefer specific figures from the data; keep answers to a few sentences. Amounts are in the given currency.',
  ].join(' ');
}

/** Assemble the model request: the shop summary, any prior conversation, and the
 *  new question. `history` is an optional [{ q, a }] of earlier turns so the model
 *  can resolve follow-ups ("and last month?") in context. */
function buildAssistantRequest(context, question, history) {
  let s = 'Shop summary (JSON):\n' + JSON.stringify(context);
  const turns = Array.isArray(history) ? history.filter((h) => h && (h.q || h.a)) : [];
  if (turns.length) {
    s += '\n\nConversation so far:\n' + turns
      .map((h) => 'Q: ' + String(h.q || '').trim() + '\nA: ' + String(h.a || '').trim())
      .join('\n');
  }
  return s + '\n\nQuestion: ' + String(question || '').trim();
}

function pickAnswer(result) {
  if (!result) return '';
  const a = typeof result === 'string' ? result : result.answer;
  return String(a == null ? '' : a).trim();
}

const api = { ASSISTANT_SCHEMA, buildShopContext, buildAssistantSystem, buildAssistantRequest, pickAnswer };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytAiAssistant = api;

})();
