const { test } = require('node:test');
const assert = require('node:assert/strict');

const CS = require('../lib/client-sources.js');

const finished = o => o.status === 'completed' || o.status === 'delivered';
const deps = extra => Object.assign({
  revenueOf: o => +o.price || 0,
  isFinished: finished,
  countsForBusiness: () => true,
}, extra || {});

/* ------------------------------------------------------------------
   The bug: a source the chart had never heard of.
   ------------------------------------------------------------------ */

test('the intake import\'s source is one of the list', () => {
  // `renderer/integrations.js` stamps `source: 'online'` when a shop imports an
  // order request. The chart iterated six values that did not include it.
  assert.ok(CS.SOURCES.includes('online'));
  assert.equal(CS.normalize('online'), 'online');
  assert.equal(CS.isKnown('online'), true);
});

test('a customer from the intake form is drawn, with their money', () => {
  const clients = [{ id: 'c1', source: 'online' }, { id: 'c2', source: 'instagram' }];
  const orders = [
    { clientId: 'c1', status: 'completed', price: 500 },
    { clientId: 'c2', status: 'completed', price: 100 },
  ];
  const { rows } = CS.byClient({ clients, orders }, deps());
  const online = rows.find(r => r.source === 'online');
  assert.ok(online, 'the intake customer must appear at all');
  assert.equal(online.count, 1);
  assert.equal(online.revenue, 500);
});

test('the old six dropped exactly that customer', () => {
  const SIX = ['instagram', 'referral', 'walk_in', 'website', 'exhibition', 'other'];
  const clients = [{ id: 'c1', source: 'online' }];
  const counts = {};
  for (const s of SIX) counts[s] = 0;
  for (const c of clients) counts[c.source || 'other'] = (counts[c.source || 'other'] || 0) + 1;
  // Counted into a bucket, then never read: the render loop walked SIX.
  assert.equal(counts.online, 1);
  assert.deepEqual(SIX.filter(s => counts[s] > 0), [], 'nothing was drawn');
});

/* ------------------------------------------------------------------
   Nothing is ever lost.
   ------------------------------------------------------------------ */

test('an unrecognised source is filed under other, not dropped', () => {
  const clients = [{ id: 'c1', source: 'tiktok' }, { id: 'c2', source: 'whatsapp' }];
  const orders = [{ clientId: 'c1', status: 'completed', price: 70 }];
  const { rows, totalClients } = CS.byClient({ clients, orders }, deps());
  assert.equal(totalClients, 2);
  const other = rows.find(r => r.source === 'other');
  assert.equal(other.count, 2, 'both are still counted');
  assert.equal(other.revenue, 70, 'and their money with them');
  assert.ok(!rows.some(r => r.source === 'tiktok'), 'no raw key reaches a label');
});

test('a client with no source at all is other', () => {
  assert.equal(CS.normalize(undefined), 'other');
  assert.equal(CS.normalize(''), 'other');
  assert.equal(CS.normalize('   '), 'other');
  assert.equal(CS.normalize(null), 'other');
  assert.equal(CS.isKnown(''), false);
  assert.equal(CS.isKnown('tiktok'), false);
});

test('the totals account for every client', () => {
  const clients = [
    { id: 'a', source: 'instagram' }, { id: 'b', source: 'online' },
    { id: 'c', source: 'nonsense' }, { id: 'd' },
  ];
  const { rows, totalClients } = CS.byClient({ clients, orders: [] }, deps());
  assert.equal(rows.reduce((s, r) => s + r.count, 0), totalClients);
  assert.equal(totalClients, 4);
});

/* ------------------------------------------------------------------
   The revenue counts what the rest of the screen counts.
   ------------------------------------------------------------------ */

test('a voided order is not revenue a source brought in', () => {
  const clients = [{ id: 'c1', source: 'referral' }];
  const orders = [
    { clientId: 'c1', status: 'completed', price: 100 },
    { clientId: 'c1', status: 'completed', price: 900, voidedAt: '2026-01-02' },
  ];
  const { rows, totalRevenue } = CS.byClient({ clients, orders }, deps());
  assert.equal(rows[0].revenue, 100);
  assert.equal(totalRevenue, 100);
});

test('a job outside the shop\'s business is not counted either', () => {
  const clients = [{ id: 'c1', source: 'referral' }];
  const orders = [
    { clientId: 'c1', status: 'completed', price: 100 },
    { clientId: 'c1', status: 'completed', price: 40, personal: true },
  ];
  const { rows } = CS.byClient({ clients, orders }, deps({
    countsForBusiness: o => !o.personal,
  }));
  assert.equal(rows[0].revenue, 100);
});

test('both spellings of finished count, and nothing else does', () => {
  const clients = [{ id: 'c1', source: 'website' }];
  const orders = [
    { clientId: 'c1', status: 'completed', price: 10 },
    { clientId: 'c1', status: 'delivered', price: 20 },
    { clientId: 'c1', status: 'printing', price: 500 },
    { clientId: 'c1', status: 'quote', price: 900 },
  ];
  const { rows } = CS.byClient({ clients, orders }, deps());
  assert.equal(rows[0].revenue, 30);
});

test('an order whose customer is gone belongs to no source', () => {
  // Filing it under "Other" would claim a source brought in money it did not.
  const clients = [{ id: 'c1', source: 'referral' }];
  const orders = [
    { clientId: 'c1', status: 'completed', price: 100 },
    { clientId: 'deleted', status: 'completed', price: 999 },
  ];
  const { rows, totalRevenue } = CS.byClient({ clients, orders }, deps());
  assert.equal(totalRevenue, 100);
  assert.equal(rows.length, 1);
});

test('an order with no customer at all is skipped', () => {
  const { totalRevenue } = CS.byClient({
    clients: [{ id: 'c1', source: 'referral' }],
    orders: [{ status: 'completed', price: 999 }],
  }, deps());
  assert.equal(totalRevenue, 0);
});

/* ------------------------------------------------------------------
   Shape and order.
   ------------------------------------------------------------------ */

test('only sources somebody carries are returned, biggest first', () => {
  const clients = [
    { id: 'a', source: 'instagram' }, { id: 'b', source: 'instagram' },
    { id: 'c', source: 'referral' },
  ];
  const { rows } = CS.byClient({ clients, orders: [] }, deps());
  assert.deepEqual(rows.map(r => r.source), ['instagram', 'referral']);
});

test('a tie keeps the list\'s own order, so two renders agree', () => {
  const clients = [{ id: 'a', source: 'exhibition' }, { id: 'b', source: 'referral' }];
  const first = CS.byClient({ clients, orders: [] }, deps()).rows.map(r => r.source);
  const reversed = CS.byClient({ clients: clients.slice().reverse(), orders: [] }, deps()).rows.map(r => r.source);
  assert.deepEqual(first, ['referral', 'exhibition']);
  assert.deepEqual(reversed, first);
});

test('a host that wires nothing gets zeroes, not a throw', () => {
  const clients = [{ id: 'a', source: 'referral' }];
  const orders = [{ clientId: 'a', status: 'completed', price: 100 }];
  const { rows } = CS.byClient({ clients, orders }, {});
  assert.equal(rows[0].count, 1);
  assert.equal(rows[0].revenue, 0, 'no revenue function means no revenue, not a wrong figure');
});

test('an empty book yields nothing to draw', () => {
  assert.deepEqual(CS.byClient({ clients: [], orders: [] }, deps()).rows, []);
  assert.deepEqual(CS.byClient({}, deps()).rows, []);
  assert.deepEqual(CS.byClient(undefined, undefined).rows, []);
});

test('other is last in the list, because it is the fallback', () => {
  assert.equal(CS.SOURCES[CS.SOURCES.length - 1], 'other');
  assert.equal(CS.DEFAULT_SOURCE, 'other');
});
