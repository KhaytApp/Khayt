'use strict';
/**
 * `lib/top-lists.js` must be renderer/analytics.js's two rollups, exactly.
 *
 * Who the shop's biggest customer is, and what it is asked for most, were
 * written out four times in that file — the client rollup at line 216 and again
 * at 376, each with its own slice, and the product rollup beside them. The Mac
 * app needed both, and a second opinion about who a shop's best customer is is
 * the kind of disagreement nobody notices until two people are looking at two
 * screens and one of them is making a decision.
 *
 * So the originals are copied in here VERBATIM and both are run over thousands
 * of generated books. Any difference at all — a name, a count, an order, a
 * riyal — fails.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');

const T = require('../lib/top-lists.js');
const OrderMoney = require('../lib/order-money.js');
const Languages = require('../lib/content-languages.js');
const Scope = require('../lib/business-scope.js');
const { CURRENCIES } = require('../lib/currencies.js');

/* ------------------------------------------------------------------
 * THE ORIGINALS, copied out of renderer/analytics.js.
 *
 * The globals they close over are supplied as arguments instead — that is the
 * whole of the difference, and it is what makes them runnable here at all.
 * ------------------------------------------------------------------ */

function originalTopClients(completed, { clients, settings, language }) {
  const localName = (obj) => Languages.read(obj, 'name', language, settings);
  const orderNetRevenueBase = (o) =>
    OrderMoney.orderNetRevenueBase(o, { settings, clients }, CURRENCIES);

  const clientAgg = {};
  completed.forEach(o => {
    if (!o.clientId) return;
    clientAgg[o.clientId] = clientAgg[o.clientId] || { count: 0, revenue: 0 };
    clientAgg[o.clientId].count++;
    clientAgg[o.clientId].revenue += orderNetRevenueBase(o);
  });
  return Object.entries(clientAgg)
    .map(([id, agg]) => {
      const c = clients.find(x => x.id === id);
      const name = c ? (localName(c)) : id;
      return { name, ...agg };
    })
    .sort((a, b) => b.revenue - a.revenue)
    .slice(0, 5);
}

function originalTopProducts(orders, { products, clients, settings, language }) {
  const localName = (obj) => Languages.read(obj, 'name', language, settings);
  const orderNetRevenueBase = (o) =>
    OrderMoney.orderNetRevenueBase(o, { settings, clients }, CURRENCIES);
  const _countsForBusiness = (o) => Scope.countsForBusiness(o);

  const productAgg = {};
  orders.forEach(o => {
    if (!o.productId) return;
    productAgg[o.productId] = productAgg[o.productId] || { count: 0, revenue: 0 };
    productAgg[o.productId].count++;
    // DELIBERATE CHANGE, on both sides (2026-09-16): a legacy `delivered` row
    // is finished, billed work. The renderer counted `completed` only.
    if ((o.status === 'completed' || o.status === 'delivered') && !o.voidedAt && _countsForBusiness(o)) productAgg[o.productId].revenue += orderNetRevenueBase(o);
  });
  return Object.entries(productAgg)
    .map(([id, agg]) => {
      const p = products.find(x => x.id === id);
      const name = p ? (localName(p)) : id;
      return { name, ...agg };
    })
    .sort((a, b) => b.count - a.count)
    .slice(0, 5);
}

/* ------------------------------------------------------------------ */

/** A deterministic generator, so a failure names a seed that reproduces it. */
function rng(seed) {
  let s = seed >>> 0;
  return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; };
}

const STATUSES = ['quote', 'printing', 'completed', 'cancelled', 'delivered'];

function book(seed) {
  const r = rng(seed);
  const pick = (a) => a[Math.floor(r() * a.length)];
  const clientCount = 1 + Math.floor(r() * 7);
  const productCount = 1 + Math.floor(r() * 7);
  const clients = Array.from({ length: clientCount }, (_, i) => ({
    id: `C-${i}`,
    nameEn: r() < 0.85 ? `Client ${i}` : '',
    nameAr: r() < 0.5 ? `عميل ${i}` : '',
    currency: r() < 0.2 ? pick(['USD', 'EUR', 'SAR']) : undefined,
  }));
  const products = Array.from({ length: productCount }, (_, i) => ({
    id: `P-${i}`,
    nameEn: r() < 0.85 ? `Product ${i}` : '',
    nameAr: r() < 0.5 ? `منتج ${i}` : '',
  }));
  const orders = Array.from({ length: Math.floor(r() * 40) }, (_, i) => ({
    id: `O-${i}`,
    // An unknown id on purpose: a deleted client still has orders, and the list
    // has to show something rather than throw.
    clientId: r() < 0.1 ? (r() < 0.5 ? '' : 'C-GONE') : `C-${Math.floor(r() * clientCount)}`,
    productId: r() < 0.15 ? (r() < 0.5 ? undefined : 'P-GONE') : `P-${Math.floor(r() * productCount)}`,
    status: pick(STATUSES),
    voidedAt: r() < 0.08 ? '2026-01-01' : undefined,
    nonBusiness: r() < 0.1 ? true : undefined,
    price: Math.round(r() * 5000),
    paidAmount: Math.round(r() * 5000),
    giftCardDiscount: r() < 0.1 ? Math.round(r() * 200) : 0,
    creditNotes: r() < 0.1 ? [{ amount: Math.round(r() * 300) }] : undefined,
    currency: r() < 0.15 ? pick(['USD', 'EUR', 'SAR']) : undefined,
  }));
  const settings = {
    currency: pick(['SAR', 'USD', 'EUR']),
    contentLanguages: r() < 0.5 ? ['en', 'ar'] : ['en'],
    fxRates: { USD: 3.75, EUR: 4.1 },
  };
  return { clients, products, orders, settings, language: r() < 0.5 ? 'ar' : 'en' };
}

test('topClients is the renderer rollup, over 2,000 generated books', () => {
  for (let seed = 1; seed <= 2000; seed++) {
    const b = book(seed);
    const completed = b.orders.filter(
      (o) => o.status === 'completed' && !o.voidedAt && Scope.countsForBusiness(o));
    const ctx = { settings: b.settings, clients: b.clients, currencies: CURRENCIES, language: b.language };

    const mine = T.topClients(completed, ctx, { limit: 5 }).map(({ name, count, revenue }) => ({ name, count, revenue }));
    const theirs = originalTopClients(completed, b);
    assert.deepEqual(mine, theirs, `seed ${seed}`);
  }
});

test('topProducts is the renderer rollup, over 2,000 generated books', () => {
  for (let seed = 1; seed <= 2000; seed++) {
    const b = book(seed);
    const ctx = {
      settings: b.settings, clients: b.clients, products: b.products,
      currencies: CURRENCIES, language: b.language,
    };
    const mine = T.topProducts(b.orders, ctx, { limit: 5 }).map(({ name, count, revenue }) => ({ name, count, revenue }));
    const theirs = originalTopProducts(b.orders, b);
    assert.deepEqual(mine, theirs, `seed ${seed}`);
  }
});

test('the id carries the row, which the renderer lists never had', () => {
  // The only addition. The renderer builds an <li> and throws the id away; a
  // table a person can click needs it, and a name is not a key — two customers
  // called "Ahmed" are two customers.
  const ctx = { settings: {}, clients: [{ id: 'C-1', nameEn: 'Ahmed' }, { id: 'C-2', nameEn: 'Ahmed' }] };
  const rows = T.topClients(
    [{ clientId: 'C-1', status: 'completed', price: 10, paidAmount: 10 },
     { clientId: 'C-2', status: 'completed', price: 20, paidAmount: 20 }], ctx, { limit: 5 });
  assert.deepEqual(rows.map((r) => r.id), ['C-2', 'C-1']);
  assert.deepEqual(rows.map((r) => r.name), ['Ahmed', 'Ahmed']);
});

test('a limit of its own, because the two screens wanted different ones', () => {
  // Eight on the executive overview, five on the simple one — the reason the
  // same rollup existed twice.
  const orders = Array.from({ length: 12 }, (_, i) => ({
    clientId: `C-${i}`, status: 'completed', price: (i + 1) * 10, paidAmount: (i + 1) * 10,
  }));
  const ctx = { settings: {}, clients: [] };
  assert.equal(T.topClients(orders, ctx, { limit: 8 }).length, 8);
  assert.equal(T.topClients(orders, ctx).length, 5, 'five by default, as the simple screen shows');
  assert.equal(T.topClients(orders, ctx, { limit: 0 }).length, 0);
});

test('an empty book is an empty list, not a throw', () => {
  const ctx = { settings: {}, clients: [], products: [] };
  assert.deepEqual(T.topClients([], ctx), []);
  assert.deepEqual(T.topProducts(undefined, ctx), []);
  assert.deepEqual(T.topClients(null, ctx), []);
});

test('a legacy `delivered` row is billed work, in the products revenue as in the count', () => {
  // order-status keeps a handed-over job at `completed` + deliveredAt; older
  // books hold `status: 'delivered'` outright. Both are finished.
  const ctx = { settings: {}, clients: [], products: [{ id: 'P1', name: 'Bracket' }], currencies: CURRENCIES, language: 'en' };
  const rows = T.topProducts([
    { productId: 'P1', status: 'completed', price: 100, paidAmount: 100 },
    { productId: 'P1', status: 'delivered', price: 50, paidAmount: 50 },
    { productId: 'P1', status: 'delivered', price: 999, paidAmount: 0, voidedAt: 'x' },
  ], ctx, { limit: 5 });
  assert.equal(rows[0].count, 3);
  assert.equal(rows[0].revenue, 150, 'the delivered row counts; the voided one still does not');
});
