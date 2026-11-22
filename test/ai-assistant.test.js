/**
 * AI shop-assistant core (lib/ai-assistant.js) — pure context building + prompts.
 * No network/key; the model call is injected via aiExtract in the app.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const A = require('../lib/ai-assistant.js');

const DAY = 86400000;
const NOW = Date.UTC(2026, 5, 20); // 2026-06-20
const iso = (daysAgo) => new Date(NOW - daysAgo * DAY).toISOString();

const COLLECTIONS = {
  settings: { lowStockThreshold: 200, bizEn: 'Acme 3D' },
  clients: [{ id: 'c1' }, { id: 'c2' }],
  inventory: [
    { id: 'pla', material: 'PLA', weight: 150 },         // low (≤200)
    { id: 'petg', material: 'PETG', weight: 4000 },
  ],
  printLog: [
    { id: 'o1', status: 'completed', price: 300, completedAt: iso(3), parts: [{ filamentId: 'pla', printWeight: 200, qty: 1 }] },
    { id: 'o2', status: 'delivered', price: 200, completedAt: iso(40), parts: [{ filamentId: 'petg', printWeight: 100, qty: 2 }] }, // last month
    { id: 'o3', status: 'printing', price: 500, paidAmount: 100, dueDate: '2026-06-10' }, // overdue + outstanding 400
    { id: 'o4', status: 'quote', price: 90 },
  ],
};

test('buildShopContext computes status counts, revenue split, outstanding, overdue, low stock', () => {
  const ctx = A.buildShopContext(COLLECTIONS, { now: NOW, currency: 'SAR' });
  assert.equal(ctx.counts.orders, 4);
  assert.equal(ctx.counts.clients, 2);
  assert.equal(ctx.counts.active, 1);          // o3
  assert.equal(ctx.counts.quotes, 1);          // o4
  assert.equal(ctx.revenueThisMonth, 300);     // o1 only (o2 is last month)
  assert.equal(ctx.revenueLastMonth, 200);     // o2
  assert.equal(ctx.outstanding, 400);          // o3: 500-100
  assert.equal(ctx.overdueCount, 1);
  assert.equal(ctx.overdue[0].id, 'o3');
  assert.ok(ctx.lowStock.some((l) => l.material === 'PLA'));
  assert.ok(!ctx.lowStock.some((l) => l.material === 'PETG'));
  assert.equal(ctx.topMaterials90d[0].material, 'PLA'); // 200g in last 90d (o2 is >90d? 40d → counts; PETG 200g)
});

test('system prompt sets language + forbids inventing', () => {
  assert.match(A.buildAssistantSystem({ shopName: 'Acme', lang: 'en' }), /only the JSON shop summary/i);
  assert.match(A.buildAssistantSystem({ lang: 'ar' }), /Arabic/);
});

test('request embeds the summary JSON + the question; pickAnswer extracts', () => {
  const ctx = A.buildShopContext(COLLECTIONS, { now: NOW });
  const req = A.buildAssistantRequest(ctx, 'How much is outstanding?');
  assert.match(req, /Shop summary \(JSON\)/);
  assert.match(req, /How much is outstanding\?/);
  assert.equal(A.pickAnswer({ answer: '  400 SAR ' }), '400 SAR');
  assert.equal(A.pickAnswer(null), '');
});

test('request includes prior conversation turns so follow-ups have context', () => {
  const ctx = A.buildShopContext(COLLECTIONS, { now: NOW });
  const history = [{ q: 'Revenue this month?', a: '1200 SAR' }];
  const req = A.buildAssistantRequest(ctx, 'And last month?', history);
  assert.match(req, /Conversation so far/);
  assert.match(req, /Revenue this month\?/);
  assert.match(req, /1200 SAR/);
  assert.match(req, /Question: And last month\?$/);
  // no history → no conversation block (backward compatible)
  assert.doesNotMatch(A.buildAssistantRequest(ctx, 'Hi', []), /Conversation so far/);
  assert.doesNotMatch(A.buildAssistantRequest(ctx, 'Hi'), /Conversation so far/);
});
