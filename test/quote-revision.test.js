'use strict';

/**
 * Revising a quote keeps what it said before (`lib/quote-revision.js`), in the
 * fields both apps read: `quoteRevisions[]` and `quoteVersion`.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const R = require('../lib/quote-revision.js');

test('revise keeps the current version and moves the quote on one', () => {
  const q = { id: 'Q1', status: 'quote', price: 120, notes: 'n', material: 'PLA', printTime: 3,
    parts: [{ name: 'A', qty: 1 }] };
  R.revise(q, Date.UTC(2026, 10, 5, 9));
  assert.equal(q.quoteVersion, 2);
  assert.deepEqual(q.quoteRevisions, [{
    version: 1, snapshotAt: '2026-11-05T09:00:00.000Z', price: 120,
    parts: [{ name: 'A', qty: 1 }], notes: 'n', material: 'PLA', printTime: 3,
  }]);
  // The kept parts are a copy: editing the quote afterwards leaves history alone.
  q.parts[0].qty = 9;
  assert.equal(q.quoteRevisions[0].parts[0].qty, 1);
  q.price = 150;
  R.revise(q, Date.UTC(2026, 10, 6));
  assert.equal(q.quoteVersion, 3);
  assert.deepEqual(R.history(q).map((r) => [r.version, r.price]), [[2, 150], [1, 120]]);
});

test('only a quote is revised', () => {
  const job = { id: 'J', status: 'pending', price: 10 };
  R.revise(job);
  assert.equal(job.quoteRevisions, undefined);
  assert.equal(job.quoteVersion, undefined);
  assert.equal(R.canRevise(job), false);
});

test('a quote never revised is on version 1 with no history', () => {
  assert.equal(R.currentVersion({ status: 'quote' }), 1);
  assert.deepEqual(R.history({ status: 'quote' }), []);
});

test('the desktop revises through the lib', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'invoicing.js'), 'utf8');
  assert.match(src, /KhaytQuoteRevision\.revise\(/);
  assert.match(src, /KhaytQuoteRevision\.history\(/);
  const page = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
  assert.ok(page.includes('<script src="../lib/quote-revision.js"></script>'));
});
