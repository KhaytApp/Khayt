const { test } = require('node:test');
const assert = require('node:assert/strict');
const Q = require('../lib/connector-queue');

// Sample data only. Every customer detail below must stay out of the snapshot.
const CLIENT = {
  id: 'c_1', name: 'Fatima Alharbi', nameAr: 'فاطمة الحربي', phone: '+966500000001',
  email: 'fatima@example.com', address: '12 Sample Street, Riyadh', city: 'Riyadh', vatNumber: '300000000000003',
};
const SECRETS = [CLIENT.name, 'Fatima', 'Alharbi', CLIENT.nameAr, 'فاطمة', CLIENT.phone, '500000001',
  CLIENT.email, 'example.com', CLIENT.address, 'Sample Street', CLIENT.vatNumber, 'Riyadh',
  '1234.50', '987.25', 'secret note', 'internal note', 'https://track.example', 'tok_abc'];

function book() {
  return {
    settings: { shopName: 'Sample Print Shop', currency: 'SAR' },
    clients: [CLIENT],
    machines: [
      { id: 'm_1', name: 'U1-01', status: 'printing', ip: '192.0.2.10', apiKey: 'tok_abc' },
      { id: 'm_2', name: 'Old Ender', status: 'retired' },
      { id: 'm_3', name: 'Bench P1S', isOffline: true },
    ],
    orders: [
      { id: 'J-1001-ab12', jobNumber: 'J-1001', status: 'pending', queuePos: 2, machineId: 'm_1',
        clientId: 'c_1', clientName: CLIENT.name, clientPhone: CLIENT.phone, clientEmail: CLIENT.email,
        title: 'Keychains for Fatima Alharbi', project: 'Fatima Alharbi wedding', notes: 'secret note',
        internalNotes: 'internal note', price: 1234.5, priceBeforeDiscount: 1234.5, cost: 987.25,
        shippingAddress: CLIENT.address, trackingUrl: 'https://track.example', portalToken: 'tok_abc',
        fromSlicer: { connectorId: 'dev_conn_A', name: 'Keychain_PLA.gcode', sha256: 'a'.repeat(64) } },
      { id: 'J-1002-cd34', jobNumber: 'J-1002', status: 'printing', queuePos: 1, machineId: 'm_1',
        clientName: CLIENT.name, title: 'Bracket for Fatima Alharbi',
        fromSlicer: { connectorId: 'dev_conn_B', name: 'Other_Connector.gcode' } },
      { id: 'J-1003-ef56', status: 'qc', machineId: 'm_gone', clientName: CLIENT.name },
      { id: 'J-1004', status: 'completed', clientName: CLIENT.name },
      { id: 'J-1005', status: 'delivered' },
      { id: 'J-1006', status: 'quote', title: 'Quote for Fatima Alharbi' },
      { id: 'J-1007', status: 'cancelled' },
      { id: 'J-1008', status: 'split', splitInto: ['J-1008a'] },
      { id: 'J-1009', status: 'on_hold', deletedAt: '2026-11-01T00:00:00Z' },
      { id: 'J-1010', status: 'post' },
    ],
  };
}

const snap = (b = book(), extra = {}) =>
  Q.snapshot(b, { connectorId: 'dev_conn_A', now: Date.UTC(2026, 10, 16, 9), shopName: 'Sample Print Shop', inboxWaiting: 3, ...extra });

test('no customer data anywhere in the snapshot: names, phones, emails, addresses, prices, notes, tokens', () => {
  const json = JSON.stringify(snap());
  for (const s of SECRETS) assert.ok(!json.includes(s), `leaked: ${s}`);
  assert.ok(!/title|project|client|price|cost|note|phone|email|address|token|ip|apiKey/i.test(Object.keys(snap().jobs[0]).join()),
    'no such key on a job');
});

test('only allowlisted keys, at every level', () => {
  const s = snap();
  for (const k of Object.keys(s)) assert.ok(Q.TOP_KEYS.includes(k), `top key ${k}`);
  assert.deepEqual(Object.keys(s.shop), ['name']);
  assert.deepEqual(Object.keys(s.inbox), ['waiting']);
  for (const j of s.jobs) assert.deepEqual(Object.keys(j), Q.JOB_KEYS);
  for (const m of s.machines) assert.deepEqual(Object.keys(m), Q.MACHINE_KEYS);
});

test('open jobs only, running first, then by queue position; split, deleted and finished jobs are out', () => {
  const s = snap();
  assert.deepEqual(s.jobs.map((j) => j.id), ['J-1002-cd34', 'J-1010', 'J-1003-ef56', 'J-1001-ab12']);
  assert.deepEqual(s.jobs.map((j) => j.stage), ['printing', 'post', 'qc', 'pending']);
});

test('number is the jobNumber, else the id; machine is its name, or null when unknown', () => {
  const s = snap();
  const byId = Object.fromEntries(s.jobs.map((j) => [j.id, j]));
  assert.equal(byId['J-1001-ab12'].number, 'J-1001');
  assert.equal(byId['J-1003-ef56'].number, 'J-1003-ef56');
  assert.equal(byId['J-1001-ab12'].machine, 'U1-01');
  assert.equal(byId['J-1003-ef56'].machine, null);
});

test('file is only the name THIS connector sent; another connector sees null', () => {
  const a = Object.fromEntries(snap().jobs.map((j) => [j.id, j.file]));
  assert.equal(a['J-1001-ab12'], 'Keychain_PLA.gcode');
  assert.equal(a['J-1002-cd34'], null);
  const b = Object.fromEntries(snap(book(), { connectorId: 'dev_conn_B' }).jobs.map((j) => [j.id, j.file]));
  assert.equal(b['J-1001-ab12'], null);
  assert.equal(b['J-1002-cd34'], 'Other_Connector.gcode');
  const none = snap(book(), { connectorId: '' }).jobs.every((j) => j.file === null);
  assert.ok(none, 'no connector id, no file names');
});

test('machines: retired ones are left out, the rest carry only id, name and state', () => {
  assert.deepEqual(snap().machines, [
    { id: 'm_1', name: 'U1-01', state: 'active' },
    { id: 'm_3', name: 'Bench P1S', state: 'service' },
  ]);
});

test('the shop name and inbox count are the caller\'s; time is the injected clock', () => {
  const s = snap();
  assert.equal(s.v, 1);
  assert.equal(s.at, '2026-11-16T09:00:00.000Z');
  assert.equal(s.shop.name, 'Sample Print Shop');
  assert.equal(s.inbox.waiting, 3);
  assert.equal(snap(book(), { shopName: '', inboxWaiting: -1 }).shop.name, 'Khayt');
  assert.equal(snap(book(), { inboxWaiting: -1 }).inbox.waiting, 0);
});

test('strings are cut and stripped of control characters', () => {
  const b = { orders: [{ id: 'J-1', status: 'pending', jobNumber: 'J\u0000-1\u2028', fromSlicer: { connectorId: 'dev_conn_A', name: 'x'.repeat(500) } }] };
  const j = snap(b).jobs[0];
  assert.equal(j.number, 'J-1');
  assert.equal(j.file.length, Q.MAX_TEXT);
});

test('a huge queue is capped and says how many more', () => {
  const orders = Array.from({ length: Q.MAX_JOBS + 7 }, (_, i) => ({ id: `J-${i}`, status: 'pending', queuePos: i }));
  const s = snap({ orders });
  assert.equal(s.jobs.length, Q.MAX_JOBS);
  assert.equal(s.more, 7);
  assert.equal(snap().more, undefined);
});

test('a broken book gives an empty queue, not a throw', () => {
  for (const b of [null, undefined, 42, [], { orders: 'x', machines: {} }, { orders: [null, 1, 'x'] }]) {
    const s = Q.snapshot(b, {});
    assert.deepEqual(s.jobs, []);
    assert.deepEqual(s.machines, []);
  }
});
