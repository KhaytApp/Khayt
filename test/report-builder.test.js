'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildReport, reportToCsv, DEFAULT_FIELDS } = require('../lib/report-builder.js');
const { reportRecords } = require('../lib/report-records.js');
const money = require('../lib/order-money.js');
const payment = require('../lib/order-payment.js');

/** What reportRecords needs to turn orders into report rows. */
const DEPS = () => ({ money, payment, clients: [], machines: [], ctx: { settings: {}, clients: [] } });

const RECORDS = [
  { id: 'A', date: '2026-06-05', client: 'Acme', status: 'completed', price: 100, paymentStatus: 'paid', tags: ['rush', 'vip'] },
  { id: 'B', date: '2026-06-20', client: 'Beta', status: 'pending', price: 50, paymentStatus: 'unpaid', tags: [] },
  { id: 'C', date: '2026-07-01', client: 'Acme', status: 'completed', price: 80, paymentStatus: 'paid', tags: [] },
];

test('selects chosen fields in order + applies date range', () => {
  const r = buildReport(RECORDS, { fields: ['id', 'client', 'price'], from: '2026-06-01', to: '2026-06-30' });
  assert.deepEqual(r.headers, ['Order #', 'Client', 'Price']);
  assert.equal(r.count, 2); // A + B (C is in July)
  assert.deepEqual(r.rows[0], ['A', 'Acme', 100]);
});

test('status filter narrows rows; arrays are joined', () => {
  const r = buildReport(RECORDS, { fields: ['id', 'tags'], statusIn: ['completed'] });
  assert.equal(r.count, 2); // A + C
  assert.equal(r.rows[0][1], 'rush, vip');
});

test('unknown fields dropped; empty fields → defaults', () => {
  assert.deepEqual(buildReport(RECORDS, { fields: ['id', 'bogus'] }).keys, ['id']);
  assert.deepEqual(buildReport(RECORDS, {}).keys, DEFAULT_FIELDS);
});

test('reportToCsv is spreadsheet-safe', () => {
  const r = buildReport([{ id: '=cmd', date: '2026-06-01', client: 'a,b', status: 'completed', price: 5 }], { fields: ['id', 'client', 'price'] });
  const csv = reportToCsv(r).replace(/^﻿/, '');
  assert.match(csv, /"'=cmd"/);      // formula neutralized
  assert.match(csv, /"a,b"/);        // comma quoted
  assert.match(csv, /"5"/);
});

/* ------------------------------------------------------------------
   The report says what the board says.
   ------------------------------------------------------------------ */

test('a report reports the STAGE, not the raw status field', () => {
  // A handed-over job stays `status: 'completed'` and carries a deliveredAt; a
  // posted one carries a shippedAt. Reporting the raw field meant the custom
  // report's Delivered box matched NOTHING in a modern book, while its
  // Completed box quietly returned those jobs too.
  const orders = [
    { id: 'A', status: 'completed', date: '2026-06-01', price: 100, project: 'on the bench' },
    { id: 'B', status: 'completed', deliveredAt: '2026-06-05T00:00:00Z', date: '2026-06-01', price: 200, project: 'handed over' },
    { id: 'C', status: 'completed', shippedAt: '2026-06-04T00:00:00Z', date: '2026-06-01', price: 300, project: 'in the post' },
  ];
  assert.deepEqual(reportRecords(orders, DEPS()).map((r) => r.status),
    ['completed', 'delivered', 'shipped']);
  // The field they were reported from, so the assertion says what changed.
  assert.deepEqual(orders.map((o) => o.status), ['completed', 'completed', 'completed']);
});

test('each box in the report picker returns what its label says', () => {
  const orders = [
    { id: 'A', status: 'completed', date: '2026-06-01', price: 100, project: 'bench' },
    { id: 'B', status: 'completed', deliveredAt: 'X', date: '2026-06-01', price: 200, project: 'gone' },
    { id: 'C', status: 'completed', shippedAt: 'X', date: '2026-06-01', price: 300, project: 'posted' },
    { id: 'D', status: 'printing', date: '2026-06-01', price: 400, project: 'running' },
  ];
  const recs = reportRecords(orders, DEPS());
  const rowsFor = (stage) =>
    buildReport(recs, { fields: ['id'], statusIn: [stage] }).rows.map((r) => r[0]);

  assert.deepEqual(rowsFor('completed'), ['A'], 'Completed used to return all three finished jobs');
  assert.deepEqual(rowsFor('shipped'), ['C']);
  assert.deepEqual(rowsFor('delivered'), ['B'], 'Delivered used to return nothing at all');
  assert.deepEqual(rowsFor('printing'), ['D'], 'an ordinary status is unchanged');
});

test('the picker offers every stage a job can actually be reported in', () => {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');
  const m = src.match(/const STATUSES = \[([^\]]+)\]/);
  assert.ok(m, 'the report builder\'s stage list has moved');
  const offered = m[1].split(',').map((s) => s.trim().replace(/'/g, ''));
  for (const stage of ['quote', 'pending', 'on_hold', 'printing', 'post', 'qc',
                       'completed', 'shipped', 'delivered']) {
    assert.ok(offered.includes(stage), `the report picker cannot select ${stage}`);
  }
});
