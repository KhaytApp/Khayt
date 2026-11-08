'use strict';

/**
 * Two computers on one book must never give two jobs the same id.
 *
 * A job's id used to BE its readable number (`INV-2026-0042`), taken from a
 * counter in `settings` — and settings never travel through cloud sync. A Mac
 * and a Windows Khayt on one book therefore both made INV-2026-0042, and the
 * next pull (lib/sync.js `applyDeltas`) saw one id, kept one record, and threw
 * the other job away.
 *
 * Three things hold now, and each is pinned here:
 *   1. a new job's id carries a random tag, so it is unique without asking the
 *      other computer; the readable number is kept whole as `jobNumber`, and
 *      the invoice still prints exactly that number;
 *   2. the invoice and quote counters read the book, so a number the other
 *      computer issued (once its job has synced) is not issued again;
 *   3. a merge that meets two different jobs under one id — ids made before
 *      this, or by a computer not yet updated — keeps both.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');

require('../lib/pricing.js');
require('../lib/working-week.js');
require('../lib/calculator-cost.js');
const N = require('../lib/order-new.js');
const Doc = require('../lib/invoice-document.js');
const { applyDeltas } = require('../lib/sync.js');

const NOW = new Date('2026-09-04T09:15:00.000Z');
const CART = [{ name: 'a', material: 'PLA', baseCost: 100, printTime: 4, qty: 1 }];
const form = (over) => Object.assign({ parts: CART, project: 'Job', margin: 0 }, over || {});
const tokens = (id) => ({ tracking: new Uint8Array(16), quoteApproval: new Uint8Array(16), id });

/* ── 1. The id ─────────────────────────────────────────────────────────────── */

test('two computers with the same counter make two different ids', () => {
  // The exact shape of the bug: both computers' settings say "next is 42".
  const mac = { invNumNext: 42, invNumYear: 2026 };
  const win = { invNumNext: 42, invNumYear: 2026 };
  const a = N.newOrder(form(), { settings: mac, orders: [], now: NOW, tokens: tokens([1, 2, 3, 4]) });
  const b = N.newOrder(form(), { settings: win, orders: [], now: NOW, tokens: tokens([5, 6, 7, 8]) });
  assert.notEqual(a.id, b.id, 'the key every other record points at must differ');
  assert.equal(a.jobNumber, 'INV-2026-0042');
  assert.equal(b.jobNumber, 'INV-2026-0042');
  assert.equal(a.id, 'INV-2026-0042-1234');
  assert.equal(b.id, 'INV-2026-0042-5678');
});

test('the readable number stays at the front of the id', () => {
  // Every list, label and status page shows the id. They still show the
  // number the shop knows, with four characters after it.
  const s = { invPrefix: 'ATH', invNumNext: 7, invNumYear: 2026 };
  const o = N.newOrder(form(), { settings: s, orders: [], now: NOW, tokens: tokens([31, 30, 29, 28]) });
  assert.ok(o.id.startsWith('ATH-2026-0007-'));
  assert.match(o.id, /^ATH-2026-0007-[0-9a-z]{4}$/);
  assert.equal(o.jobNumber, 'ATH-2026-0007');
});

test('without random bytes the tag is still random', () => {
  const ids = new Set();
  for (let k = 0; k < 200; k++) ids.add(N.mintOrderId('INV-2026-0001'));
  assert.ok(ids.size > 190, `only ${ids.size} distinct ids from 200`);
});

test('a quote gets a tagged id too, and keeps its own number', () => {
  const s = { quoteNumNext: 3, quoteNumYear: 2026 };
  const q = N.newOrder(form({ asQuote: true }), { settings: s, orders: [], now: NOW, tokens: tokens([0, 0, 0, 1]) });
  assert.equal(q.id, 'QUO-2026-0003-0001');
  assert.equal(q.jobNumber, 'QUO-2026-0003');
  assert.equal(N.beganAsQuote(q, {}), true, 'still recognised as a quote by its prefix');
});

/* ── What the paper prints ─────────────────────────────────────────────────── */

test('an invoice prints the number, never the tag', () => {
  const s = { invNumNext: 42, invNumYear: 2026 };
  const o = N.newOrder(form(), { settings: s, orders: [], now: NOW, tokens: tokens([9, 9, 9, 9]) });
  assert.equal(Doc.documentNumber(o, {}), 'INV-2026-0042');
});

test('a shop with its own prefix prints what it always printed', () => {
  // `invPrefix` is ATH, the invoice counter's `invNumPrefix` is the default.
  // A plain job has always printed its id — ATH-… — and still prints ATH-….
  const s = { invPrefix: 'ATH', invNumNext: 12, invNumYear: 2026 };
  const o = N.newOrder(form(), { settings: s, orders: [], now: NOW, tokens: tokens([1, 1, 1, 1]) });
  assert.equal(o.invoiceNumber, 'INV-2026-0012');
  assert.equal(Doc.documentNumber(o, s), 'ATH-2026-0012');
});

test('a quote prints its number; once approved it prints its invoice number', () => {
  const s = { quoteNumNext: 5, quoteNumYear: 2026, invNumNext: 20, invNumYear: 2026 };
  const q = N.newOrder(form({ asQuote: true }), { settings: s, orders: [], now: NOW, tokens: tokens([2, 2, 2, 2]) });
  assert.equal(Doc.documentNumber(q, s), 'QUO-2026-0005');
  q.status = 'pending';
  q.quoteAcceptedAt = '2026-09-05';
  N.ensureInvoiceNumber(q, s, 2026, [q]);
  assert.equal(Doc.documentNumber(q, s), 'INV-2026-0020');
});

test('a job made before this prints exactly what it printed before', () => {
  const old = { id: 'INV-2026-0042', invoiceNumber: 'INV-2026-0042', status: 'pending' };
  assert.equal(Doc.documentNumber(old, {}), 'INV-2026-0042');
  const phone = { id: 'INV-2026-1762263000000-3fa2', status: 'pending' };
  assert.equal(Doc.documentNumber(phone, {}), 'INV-2026-1762263000000-3fa2');
});

/* ── 2. The counters read the book ─────────────────────────────────────────── */

test('a number the other computer issued is not issued again', () => {
  // This computer's counter still says 42; the other computer's 42 and 43
  // have synced into the book.
  const s = { invNumNext: 42, invNumYear: 2026 };
  const book = [
    { id: 'INV-2026-0042-ab12', jobNumber: 'INV-2026-0042', invoiceNumber: 'INV-2026-0042' },
    { id: 'INV-2026-0043-cd34', jobNumber: 'INV-2026-0043', invoiceNumber: 'INV-2026-0043' },
  ];
  const o = N.newOrder(form(), { settings: s, orders: book, now: NOW, tokens: tokens([3, 3, 3, 3]) });
  assert.equal(o.invoiceNumber, 'INV-2026-0044');
  assert.equal(o.jobNumber, 'INV-2026-0044');
  assert.equal(s.invNumNext, 45);
});

test('an old-shaped id counts too, and an older year does not', () => {
  const s = { invNumNext: 1, invNumYear: 2026 };
  const n = N.allocateInvoiceNumber(s, 2026, [
    { id: 'INV-2026-0009' },                  // a job made before ids were tagged
    { id: 'INV-2025-0300', invoiceNumber: 'INV-2025-0300' },
  ]);
  assert.equal(n, 'INV-2026-0010');
});

test('a phone- or LAN-made id never drags the counter into the trillions', () => {
  const s = { invNumNext: 5, invNumYear: 2026 };
  const n = N.allocateInvoiceNumber(s, 2026, [{ id: 'INV-2026-1762263000000-3fa2' }]);
  assert.equal(n, 'INV-2026-0005');
});

test('the counter never goes backwards', () => {
  const s = { invNumNext: 90, invNumYear: 2026 };
  assert.equal(N.allocateInvoiceNumber(s, 2026, [{ invoiceNumber: 'INV-2026-0004' }]), 'INV-2026-0090');
});

test('a shop format without the year counts every year: it is one series', () => {
  // INV-0400 was printed last December; with no year in the number, a fresh
  // January count would print INV-0004 … INV-0400 a second time.
  const s = { invNumNext: 1, invNumYear: 2026, invNumFormat: '{prefix}-{seq4}' };
  const n = N.allocateInvoiceNumber(s, 2026, [
    { invoiceNumber: 'INV-0400', date: '2025-12-30' },
    { invoiceNumber: 'INV-0003', date: '2026-01-04' },
  ]);
  assert.equal(n, 'INV-0401');
});

test('without the book the counter behaves as it always did', () => {
  const s = { invNumNext: 7, invNumYear: 2026 };
  assert.equal(N.allocateInvoiceNumber(s, 2026), 'INV-2026-0007');
  assert.equal(s.invNumNext, 8);
});

test('the quote counter reads the book the same way', () => {
  const s = { quoteNumNext: 2, quoteNumYear: 2026 };
  const seq = N.allocateQuoteSeq(s, 2026, [
    { id: 'QUO-2026-0011' }, { id: 'QUO-2026-0014-zz99' }, { id: 'QUO-2026-1762263000000-0abc' },
  ]);
  assert.equal(seq, '0015');
  assert.equal(s.quoteNumNext, 16);
});

/* ── 3. The merge keeps two different jobs that share an id ────────────────── */

const job = (id, timestamp, project, rev) => ({ id, timestamp, project, rev: rev || 1, updatedAt: timestamp });

test('two different jobs under one id: both are kept, and it is reported', () => {
  const mine = job('INV-2026-0042', '2026-09-04T09:00:00.000Z', 'Mac job', 1);
  const theirs = job('INV-2026-0042', '2026-09-04T10:30:00.000Z', 'Windows job', 2);
  const book = { printLog: [mine] };
  const r = applyDeltas(book, { deltas: [{ collection: 'printLog', record: theirs }] });
  assert.equal(book.printLog.length, 2, 'the higher rev used to replace the Mac job outright');
  assert.equal(book.printLog[0], mine, 'the local job is untouched — everything points at its id');
  const kept = book.printLog[1];
  assert.equal(kept.project, 'Windows job');
  assert.equal(kept.collidedId, 'INV-2026-0042');
  assert.notEqual(kept.id, 'INV-2026-0042');
  assert.equal(r.conflicts.length, 1);
  assert.equal(r.conflicts[0].kind, 'id_collision');
  assert.equal(r.conflicts[0].storedAs, kept.id);
});

test('every computer files the other job under the same collision id', () => {
  const theirs = job('INV-2026-0042', '2026-09-04T10:30:00.000Z', 'Windows job', 2);
  const one = { printLog: [job('INV-2026-0042', '2026-09-04T09:00:00.000Z', 'Mac job')] };
  const two = { printLog: [job('INV-2026-0042', '2026-09-04T08:00:00.000Z', 'iMac job')] };
  applyDeltas(one, { deltas: [{ collection: 'printLog', record: theirs }] });
  applyDeltas(two, { deltas: [{ collection: 'printLog', record: theirs }] });
  assert.equal(one.printLog[1].id, two.printLog[1].id);
});

test('the same pair again is an update of the kept copy, not a third job', () => {
  const book = { printLog: [job('INV-2026-0042', '2026-09-04T09:00:00.000Z', 'Mac job')] };
  const v1 = job('INV-2026-0042', '2026-09-04T10:30:00.000Z', 'Windows job', 2);
  applyDeltas(book, { deltas: [{ collection: 'printLog', record: v1 }] });
  const v2 = Object.assign({}, v1, { project: 'Windows job, edited', rev: 3, updatedAt: '2026-09-05T00:00:00.000Z' });
  const r = applyDeltas(book, { deltas: [{ collection: 'printLog', record: v2 }] });
  assert.equal(book.printLog.length, 2);
  assert.equal(book.printLog[1].project, 'Windows job, edited');
  assert.equal(r.conflicts.filter((c) => c.kind === 'id_collision').length, 0, 'reported once, not on every pull');
});

test('our own job coming back under another computer\'s collision id is not listed twice', () => {
  // The Windows machine kept OUR job beside its own and may push that copy.
  const mine = job('INV-2026-0042', '2026-09-04T09:00:00.000Z', 'Mac job');
  const book = { printLog: [mine] };
  const echo = Object.assign({}, mine, { id: 'INV-2026-0042~xyz', collidedId: 'INV-2026-0042' });
  const r = applyDeltas(book, { deltas: [{ collection: 'printLog', record: echo }] });
  assert.equal(book.printLog.length, 1);
  assert.equal(r.skipped, 1);
});

test('one job edited elsewhere is still one job — however its stamp is spelled', () => {
  const mine = job('INV-2026-0042', '2026-09-04T09:00:00.000Z', 'Mac job', 1);
  const edited = job('INV-2026-0042', '2026-09-04T09:00:00Z', 'Mac job, edited', 2);
  const book = { printLog: [mine] };
  applyDeltas(book, { deltas: [{ collection: 'printLog', record: edited }] });
  assert.equal(book.printLog.length, 1);
  assert.equal(book.printLog[0].project, 'Mac job, edited');
});

test('a job with no creation stamp merges by id, as before', () => {
  const book = { printLog: [{ id: 'X', project: 'old', rev: 1 }] };
  applyDeltas(book, { deltas: [{ collection: 'printLog', record: { id: 'X', project: 'new', rev: 2, timestamp: '2026-09-04T09:00:00.000Z' } }] });
  assert.equal(book.printLog.length, 1);
  assert.equal(book.printLog[0].project, 'new');
});

test('other collections are untouched by the rule', () => {
  const book = { clients: [{ id: 'C1', timestamp: '2026-01-01T00:00:00Z', name: 'a', rev: 1 }] };
  applyDeltas(book, { deltas: [{ collection: 'clients', record: { id: 'C1', timestamp: '2026-02-01T00:00:00Z', name: 'b', rev: 2 } }] });
  assert.equal(book.clients.length, 1);
  assert.equal(book.clients[0].name, 'b');
});

/* ── 4. Two papers with one number are found, and one is renumbered ───────── */

test('two invoices printing one number are named, oldest first', () => {
  const book = [
    { id: 'INV-2026-0042-ab12', jobNumber: 'INV-2026-0042', invoiceNumber: 'INV-2026-0042', status: 'pending',
      date: '2026-09-04', timestamp: '2026-09-04T11:00:00.000Z', project: 'Windows job' },
    { id: 'INV-2026-0042-cd34', jobNumber: 'INV-2026-0042', invoiceNumber: 'INV-2026-0042', status: 'completed',
      date: '2026-09-04', timestamp: '2026-09-04T09:00:00.000Z', project: 'Mac job' },
    { id: 'INV-2026-0043-ef56', jobNumber: 'INV-2026-0043', invoiceNumber: 'INV-2026-0043', status: 'pending', date: '2026-09-05' },
  ];
  const dups = Doc.duplicateNumbers(book, {});
  assert.equal(dups.length, 1);
  assert.equal(dups[0].number, 'INV-2026-0042');
  assert.equal(dups[0].kind, 'invoice');
  assert.deepEqual(dups[0].jobs.map((j) => j.project), ['Mac job', 'Windows job']);
  assert.deepEqual(dups[0].jobs.map((j) => j.ref), ['INV-2026-0042', 'INV-2026-0042']);
});

test('a quote and an invoice, or two years, are not duplicates of each other', () => {
  const book = [
    { id: 'Q1', jobNumber: 'X-0001', status: 'quote', date: '2026-01-02' },
    { id: 'J1', jobNumber: 'X-0001', status: 'pending', date: '2026-01-02' },
    { id: 'J2', jobNumber: 'Y-0001', status: 'pending', date: '2025-12-30' },
    { id: 'J3', jobNumber: 'Y-0001', status: 'pending', date: '2026-01-03' },
  ];
  assert.deepEqual(Doc.duplicateNumbers(book, {}), []);
});

test('an older book with unique ids has no duplicates', () => {
  const book = [{ id: 'INV-2026-0001', status: 'pending' }, { id: 'INV-2026-0002', status: 'pending' }];
  assert.deepEqual(Doc.duplicateNumbers(book, {}), []);
});

test('renumbering gives the newer job the next free number and keeps its id', () => {
  const s = { invNumNext: 42, invNumYear: 2026 };
  const num = 'INV-2026-0042';
  const older = { id: `${num}-cd34`, jobNumber: num, invoiceNumber: num, invoiceNum: num, status: 'pending', date: '2026-09-04' };
  const newer = { id: `${num}-ab12`, jobNumber: num, invoiceNumber: num, invoiceNum: num, status: 'pending', date: '2026-09-04' };
  const other = { id: 'INV-2026-0043-ef56', jobNumber: 'INV-2026-0043', invoiceNumber: 'INV-2026-0043', status: 'pending', date: '2026-09-05' };
  const book = [older, newer, other];
  const given = N.renumber(newer, s, book, 2026);
  assert.equal(given, 'INV-2026-0044', 'past every number the book holds');
  assert.equal(newer.id, `${num}-ab12`, 'the id is the key — it never moves');
  assert.equal(newer.jobNumber, 'INV-2026-0044');
  assert.equal(newer.invoiceNumber, 'INV-2026-0044');
  assert.equal(newer.invoiceNum, 'INV-2026-0044');
  assert.equal(newer.renumberedFrom, num);
  assert.equal(Doc.documentNumber(newer, s), 'INV-2026-0044');
  assert.deepEqual(Doc.duplicateNumbers(book, s), [], 'and the pair is gone');
  assert.equal(s.invNumNext, 45);
});

test('a past year\'s pair is renumbered inside that year, and this year\'s counter does not move', () => {
  // This year's counter is at 12. The duplicate pair is from 2025, whose
  // highest number in the book is 0300.
  const s = { invNumNext: 12, invNumYear: 2026, quoteNumNext: 4, quoteNumYear: 2026 };
  const num = 'INV-2025-0299';
  const a = { id: `${num}-aaaa`, jobNumber: num, invoiceNumber: num, invoiceNum: num, status: 'completed', date: '2025-12-20' };
  const b = { id: `${num}-bbbb`, jobNumber: num, invoiceNumber: num, invoiceNum: num, status: 'completed', date: '2025-12-21' };
  const top = { id: 'INV-2025-0300', invoiceNumber: 'INV-2025-0300', status: 'completed', date: '2025-12-30' };
  const now = { id: 'INV-2026-0011-cccc', jobNumber: 'INV-2026-0011', invoiceNumber: 'INV-2026-0011', status: 'pending', date: '2026-01-05' };
  const book = [a, b, top, now];
  const given = N.renumber(b, s, book, 2025);
  assert.equal(given, 'INV-2025-0301', 'the highest 2025 number in the book, plus one');
  assert.equal(b.invoiceNumber, 'INV-2025-0301');
  assert.deepEqual(s, { invNumNext: 12, invNumYear: 2026, quoteNumNext: 4, quoteNumYear: 2026 },
    'this year\'s counters are exactly as they were');
  const q = { id: 'QUO-2025-0007-dddd', jobNumber: 'QUO-2025-0007', status: 'quote', date: '2025-11-02' };
  assert.equal(N.renumber(q, s, [q], 2025), 'QUO-2025-0008');
  assert.equal(s.quoteNumNext, 4, 'nor the quote counter');
});

test('a renumber can be undone, and the counter comes back only if nothing used it since', () => {
  const s = { invNumNext: 42, invNumYear: 2026 };
  const num = 'INV-2026-0042';
  const job = { id: `${num}-ab12`, jobNumber: num, invoiceNumber: num, invoiceNum: num, status: 'pending', date: '2026-09-04' };
  const twin = { id: `${num}-cd34`, jobNumber: num, invoiceNumber: num, invoiceNum: num, status: 'pending', date: '2026-09-04' };
  const before = N.renumberSnapshot(job, s);
  N.renumber(job, s, [job, twin], 2026);
  const after = N.renumberSnapshot(job, s);
  assert.equal(job.jobNumber, 'INV-2026-0043');
  N.undoRenumber(job, s, before, after);
  assert.equal(job.jobNumber, num);
  assert.equal(job.invoiceNumber, num);
  assert.equal('renumberedFrom' in job, false, 'no trace of a renumber that was taken back');
  assert.equal(s.invNumNext, 42, 'the number it used is free again');

  // Something else took a number in between: that one is kept, and so is the counter.
  const before2 = N.renumberSnapshot(job, s);
  N.renumber(job, s, [job, twin], 2026);
  const after2 = N.renumberSnapshot(job, s);
  N.allocateInvoiceNumber(s, 2026);
  N.undoRenumber(job, s, before2, after2);
  assert.equal(job.jobNumber, num);
  assert.equal(s.invNumNext, 45, 'never rolled back under a number another job now has');
});

test('renumbering a quote moves its quote number; an approved quote its invoice number', () => {
  const s = { quoteNumNext: 3, quoteNumYear: 2026, invNumNext: 10, invNumYear: 2026 };
  const q = { id: 'QUO-2026-0003-aaaa', jobNumber: 'QUO-2026-0003', status: 'quote', date: '2026-09-04' };
  assert.equal(N.renumber(q, s, [q], 2026), 'QUO-2026-0004');
  assert.equal(q.jobNumber, 'QUO-2026-0004');
  const approved = { id: 'QUO-2026-0001', status: 'pending', quoteAcceptedAt: '2026-09-01',
    invoiceNumber: 'INV-2026-0009', invoiceNum: 'INV-2026-0009', date: '2026-09-01' };
  assert.equal(N.renumber(approved, s, [approved], 2026), 'INV-2026-0010');
  assert.equal(approved.id, 'QUO-2026-0001');
  assert.equal(Doc.documentNumber(approved, s), 'INV-2026-0010');
});
