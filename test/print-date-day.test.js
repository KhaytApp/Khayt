'use strict';
// lib/print-date.js printDate: a bare day ("2026-11-05", how a job's date is
// stored) is that calendar day wherever the shop is. Parsed as an ISO string it
// was midnight UTC, the evening before west of Greenwich, so the Orders Log
// (which shows both a job's date and its completion through this one
// formatter since the Nov 11 review, X6) would print it a day early there.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { printDate } = require('../lib/print-date.js');

function inZone(tz, fn) {
  const was = process.env.TZ;
  process.env.TZ = tz;
  try { return fn(); } finally {
    if (was === undefined) delete process.env.TZ; else process.env.TZ = was;
  }
}

test('a bare day prints as that day in every time zone', () => {
  for (const tz of ['America/Los_Angeles', 'UTC', 'Asia/Riyadh', 'Pacific/Auckland']) {
    assert.equal(inZone(tz, () => printDate('2026-11-05', 'en-US')), 'Nov 05, 2026', tz);
  }
});

test('a timestamp still prints its local day', () => {
  assert.equal(inZone('Asia/Riyadh', () => printDate('2026-11-09T22:30:00.000Z', 'en-US')), 'Nov 10, 2026');
  assert.equal(inZone('America/Los_Angeles', () => printDate('2026-11-09T22:30:00.000Z', 'en-US')), 'Nov 09, 2026');
});

test('empty and unparseable values are unchanged', () => {
  assert.equal(printDate('', 'en-US'), '');
  assert.equal(printDate('soon', 'en-US'), 'soon');
  assert.equal(printDate('2026-13-45x', 'en-US'), '2026-13-45x');
});
