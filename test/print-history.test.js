'use strict';
/**
 * Times printed and last printed, read off the jobs (lib/print-history.js).
 *
 * The record's own counter was only ever written by the desktop's "log a
 * print" button, so a shop that works in jobs — and every Mac shop — saw its
 * whole library as never printed.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const H = require('../lib/print-history.js');
const LanLibrary = require('../lib/lan-library.js');

const job = (over) => ({
  id: 'J1', status: 'completed', date: '2026-09-01', completedAt: '2026-09-03T10:00:00.000Z',
  parts: [{ printFileId: 'PF-a', qty: 1 }], ...over,
});

test('a completed job is a print of the model its part names', () => {
  const h = H.byFile([job()]);
  assert.deepEqual(h['PF-a'], {
    timesPrinted: 1, copies: 1, timesFailed: 0,
    lastPrinted: '2026-09-03T10:00:00.000Z', lastJobId: 'J1',
  });
});

test('open, quoted, cancelled and voided jobs have not printed', () => {
  const h = H.byFile([
    job({ id: 'a', status: 'pending' }), job({ id: 'b', status: 'printing' }),
    job({ id: 'c', status: 'quote' }), job({ id: 'd', status: 'cancelled' }),
    job({ id: 'e', voidedAt: '2026-09-05T00:00:00Z' }),
  ]);
  assert.deepEqual(h, {});
});

test('a legacy delivered status counts; shipped/delivered stamps change nothing', () => {
  const h = H.byFile([
    job({ id: 'old', status: 'delivered', completedAt: undefined, deliveredAt: '2026-09-04T09:00:00Z' }),
    job({ id: 'new', deliveredAt: '2026-09-09T09:00:00Z', shippedAt: '2026-09-08T09:00:00Z' }),
  ]);
  assert.equal(h['PF-a'].timesPrinted, 2);
  // The newest COMPLETION, not the newest stamp of any kind.
  assert.equal(h['PF-a'].lastPrinted, '2026-09-04T09:00:00Z');
  assert.equal(h['PF-a'].lastJobId, 'old');
});

test('one job is one print: quantity and repeated parts are copies', () => {
  const h = H.byFile([job({
    parts: [{ printFileId: 'PF-a', qty: 3 }, { printFileId: 'PF-a', qty: '2' },
      { printFileId: 'PF-b' }, { printFileId: 'PF-c', qty: 0 }, { printFileId: '' }, null, { qty: 4 }],
  })]);
  assert.equal(h['PF-a'].timesPrinted, 1);
  assert.equal(h['PF-a'].copies, 5);
  assert.equal(h['PF-b'].copies, 1);
  assert.equal(h['PF-c'].copies, 1);
  assert.deepEqual(Object.keys(h).sort(), ['PF-a', 'PF-b', 'PF-c']);
});

test('the newest finish wins, and the stored text is returned as written', () => {
  const h = H.byFile([
    job({ id: 'x', completedAt: '2026-10-01T08:00:00+03:00' }),
    job({ id: 'y', completedAt: '2026-09-30T23:00:00Z' }),
    job({ id: 'z', completedAt: 'not a date', date: '2026-08-01' }),
  ]);
  assert.equal(h['PF-a'].timesPrinted, 3);
  // 08:00 +03:00 is 05:00Z on the 1st — later than 23:00Z on the 30th.
  assert.equal(h['PF-a'].lastPrinted, '2026-10-01T08:00:00+03:00');
  assert.equal(h['PF-a'].lastJobId, 'x');
});

test('a finished job with no readable date still counts, with no last printed', () => {
  const h = H.byFile([job({ completedAt: null, date: '' })]);
  assert.equal(h['PF-a'].timesPrinted, 1);
  assert.equal(h['PF-a'].lastPrinted, null);
});

test('failed inspections are counted on open jobs too', () => {
  const h = H.byFile([
    job({ id: 'f1', status: 'pending', qcStatus: 'fail', defects: [{ type: 'warping' }, { type: 'other' }] }),
    job({ id: 'f2', status: 'pending', qcFailedAt: '2026-09-02T00:00:00Z' }),
    job({ id: 'p', qcStatus: 'pass', defects: [{ type: 'stringing' }] }),
  ]);
  assert.equal(h['PF-a'].timesFailed, 4);
  assert.equal(h['PF-a'].timesPrinted, 1);
  assert.equal(h['PF-a'].lastJobId, 'p');
});

test('nonsense in the book is skipped, not thrown on', () => {
  assert.deepEqual(H.byFile(null), {});
  assert.deepEqual(H.byFile([null, 3, 'x', [], { parts: 'no' }, { status: 'completed', parts: [{ printFileId: 7 }] }]), {});
});

test('an id that names an Object.prototype member is just an id', () => {
  const h = H.byFile([job({ parts: [{ printFileId: '__proto__' }, { printFileId: 'constructor' }] })]);
  assert.equal(h.__proto__.timesPrinted, 1);
  assert.equal(h.constructor.timesPrinted, 1);
});

test('merge keeps the larger count, so a desktop log is never lost or doubled', () => {
  const entry = H.byFile([job()])['PF-a'];
  assert.deepEqual(H.merge({ timesPrinted: 5, lastPrinted: '2026-01-01T00:00:00Z' }, entry),
    { timesPrinted: 5, timesFailed: 0, lastPrinted: '2026-09-03T10:00:00.000Z' });
  assert.deepEqual(H.merge({ timesPrinted: 0, timesFailed: 2, lastPrinted: '2026-12-01T00:00:00Z' }, entry),
    { timesPrinted: 1, timesFailed: 2, lastPrinted: '2026-12-01T00:00:00Z' });
  assert.deepEqual(H.merge({ lastPrinted: 'garbage' }, entry).lastPrinted, '2026-09-03T10:00:00.000Z');
  assert.deepEqual(H.merge({ timesPrinted: 2.7, lastPrinted: 'garbage' }, undefined),
    { timesPrinted: 2, timesFailed: 0, lastPrinted: 'garbage' });
  assert.deepEqual(H.merge(null, null), { timesPrinted: 0, timesFailed: 0, lastPrinted: null });
  assert.equal(H.merge({ timesPrinted: '9' }, null).timesPrinted, 0);
});

test('the phone library carries the jobs’ figures, and leaves an unjobbed record as it was', () => {
  const files = [
    { id: 'PF-a', name: 'A', timesPrinted: 0 },
    { id: 'PF-b', name: 'B', timesPrinted: 4, lastPrinted: '2026-02-02T00:00:00Z' },
    { id: 'PF-c', name: 'C' },
  ];
  const page = LanLibrary.list(files, { orders: [job(), job({ id: 'J2', parts: [{ printFileId: 'PF-b' }] })] });
  const by = Object.fromEntries(page.items.map((i) => [i.id, i]));
  assert.equal(by['PF-a'].timesPrinted, 1);
  assert.equal(by['PF-a'].lastPrinted, '2026-09-03T10:00:00.000Z');
  assert.equal(by['PF-b'].timesPrinted, 4);
  assert.equal(by['PF-b'].lastPrinted, '2026-09-03T10:00:00.000Z');
  assert.equal('timesPrinted' in by['PF-c'], false);
  // No orders given: exactly the record's own fields, as before.
  const bare = Object.fromEntries(LanLibrary.list(files).items.map((i) => [i.id, i]));
  assert.equal(bare['PF-a'].timesPrinted, 0);
  assert.equal('lastPrinted' in bare['PF-a'], false);
});
