'use strict';
/**
 * S4 cards 6–8: the rules behind Simple's reduced screens.
 *   lib/order-status.js simpleStageOf — the four-column board
 *   renderer/simple-forms.js        — the five-field customer, the library places
 */
const test = require('node:test');
const assert = require('node:assert');

const OS = require('../lib/order-status.js');
const SS = require('../renderer/simple-forms.js');

test('the Simple board files every stage into Quote · Queued · Printing · Ready', () => {
  assert.deepStrictEqual(OS.SIMPLE_COLUMNS, ['quote', 'queued', 'printing', 'ready']);
  const want = {
    quote: ['quote', null], pending: ['queued', null], split: ['queued', null], on_hold: ['queued', 'on_hold'],
    printing: ['printing', null], post: ['printing', 'post'], qc: ['printing', 'qc'], completed: ['ready', null],
  };
  for (const [status, [column, note]] of Object.entries(want)) {
    const r = OS.simpleStageOf({ status });
    assert.deepStrictEqual([r.column, r.note, r.stage], [column, note, status], status);
  }
  // shipped / delivered are stamps on a completed job (stageOf), shown as a note.
  assert.deepStrictEqual(OS.simpleStageOf({ status: 'completed', shippedAt: 'x' }), { column: 'ready', note: 'shipped', stage: 'shipped' });
  assert.deepStrictEqual(OS.simpleStageOf({ status: 'completed', shippedAt: 'x', deliveredAt: 'y' }), { column: 'ready', note: 'delivered', stage: 'delivered' });
  for (const status of ['cancelled', 'failed', 'whatever', undefined]) assert.strictEqual(OS.simpleStageOf({ status }), null, String(status));
  assert.strictEqual(OS.simpleStageOf(null), null);
});

test('every column simpleStageOf names is one of the four', () => {
  for (const status of ['quote', 'pending', 'split', 'on_hold', 'printing', 'post', 'qc', 'completed']) {
    assert.ok(OS.SIMPLE_COLUMNS.includes(OS.simpleStageOf({ status }).column), status);
  }
});

test('a job on hold says when it was paused mid-print', () => {
  assert.strictEqual(OS.simpleStageOf({ status: 'on_hold' }).midPrint, false);
  for (const extra of [{ printingStartedAt: '2026-11-01T10:00:00Z' }, { timerStart: '2026-11-01T10:00:00Z' }, { startedAt: 'x' },
    { statusHistory: [{ status: 'pending', at: 'a' }, { status: 'printing', at: 'b' }, { status: 'on_hold', at: 'c' }] }]) {
    assert.strictEqual(OS.simpleStageOf({ status: 'on_hold', ...extra }).midPrint, true, JSON.stringify(extra));
  }
  assert.strictEqual(OS.simpleStageOf({ status: 'on_hold', statusHistory: [{ status: 'pending' }] }).midPrint, false);
  assert.strictEqual('midPrint' in OS.simpleStageOf({ status: 'pending', printingStartedAt: 'x' }), false, 'only on hold carries it');
});

test('Ready is capped and keeps the NEWEST (the Mac\'s beta.34 rule)', () => {
  assert.strictEqual(OS.SIMPLE_COLUMN_CAP, 120);
  const day = (n) => new Date(Date.UTC(2026, 0, 1) + n * 86400000).toISOString();
  // 130 finished jobs, oldest first, as a book lists them; some shipped or delivered later.
  const orders = Array.from({ length: 130 }, (_, i) => ({ id: 'J' + i, status: 'completed', completedAt: day(i) }));
  orders[3].deliveredAt = day(500);    // an old job delivered last of all is the newest
  orders[5].shippedAt = day(499);
  orders.push({ id: 'P', status: 'pending', date: day(600) }, { id: 'H', status: 'on_hold' });
  const before = orders.map((o) => o.id).join();
  const r = OS.simpleColumnJobs(orders, 'ready');
  assert.strictEqual(r.jobs.length, 120);
  assert.strictEqual(r.more, 10);
  assert.deepStrictEqual(r.jobs.slice(0, 4).map((o) => o.id), ['J3', 'J5', 'J129', 'J128'], 'newest first');
  assert.ok(r.jobs.some((o) => o.id === 'J129') && !r.jobs.some((o) => o.id === 'J0'), 'the newest survive, the oldest are cut');
  assert.strictEqual(orders.map((o) => o.id).join(), before, 'the input is not reordered');
  const small = OS.simpleColumnJobs(orders, 'ready', { cap: 2 });
  assert.deepStrictEqual([small.jobs.map((o) => o.id), small.more], [['J3', 'J5'], 128]);
  // A job with no readable time sorts last, and ties keep the book's order.
  const tie = OS.simpleColumnJobs([{ id: 'a', status: 'completed' }, { id: 'b', status: 'completed', completedAt: day(1) }, { id: 'c', status: 'completed' }], 'ready');
  assert.deepStrictEqual(tie.jobs.map((o) => o.id), ['b', 'a', 'c']);
  // The intake date never outranks a finish stamp: a job taken in today but
  // finished in January is older than one finished yesterday.
  const intake = OS.simpleColumnJobs([
    { id: 'jan', status: 'completed', date: day(400), completedAt: day(10) },
    { id: 'yday', status: 'completed', date: day(300), completedAt: day(399) },
    { id: 'nostamp', status: 'completed', date: day(200) },
  ], 'ready');
  assert.deepStrictEqual(intake.jobs.map((o) => o.id), ['yday', 'nostamp', 'jan']);
});

test('Quote, Queued and Printing are never cut', () => {
  const many = Array.from({ length: 200 }, (_, i) => ({ id: 'Q' + i, status: i % 2 ? 'pending' : 'on_hold' }));
  const r = OS.simpleColumnJobs(many, 'queued');
  assert.deepStrictEqual([r.jobs.length, r.more, r.jobs[0].id], [200, 0, 'Q0']);
  assert.deepStrictEqual(OS.simpleColumnJobs(null, 'ready'), { jobs: [], more: 0 });
});

test('the one Name field edits the name the customer has; the other is never touched', () => {
  assert.strictEqual(SS.nameKey({ nameEn: 'Layla', nameAr: '' }, 'ar'), 'nameEn');
  assert.strictEqual(SS.nameKey({ nameEn: '', nameAr: 'ليلى' }, 'en'), 'nameAr');
  assert.strictEqual(SS.nameKey({ nameEn: 'Layla', nameAr: 'ليلى' }, 'ar'), 'nameAr');
  assert.strictEqual(SS.nameKey({ nameEn: 'Layla', nameAr: 'ليلى' }, 'en'), 'nameEn');
  assert.strictEqual(SS.nameKey({}, 'ar'), 'nameAr');
  assert.strictEqual(SS.nameKey({}, 'de'), 'nameEn');
  assert.strictEqual(SS.nameKey(null, undefined), 'nameEn');
});

test('the one Address field writes the first plain row and keeps every other row', () => {
  const c = { addresses: [{ id: 'A1', label: 'Home', address: 'Old road' }, { id: 'A2', label: 'Work', address: 'Office' }] };
  assert.deepStrictEqual(SS.addressOf(c), { row: c.addresses[0], text: 'Old road', editable: true });
  SS.applyAddress(c, '  Prince Sultan Road, Riyadh ', () => 'X');
  assert.deepStrictEqual(c.addresses, [{ id: 'A1', label: 'Home', address: 'Prince Sultan Road, Riyadh' }, { id: 'A2', label: 'Work', address: 'Office' }]);

  const empty = {};
  SS.applyAddress(empty, '', () => 'X');
  assert.deepStrictEqual(empty.addresses, [], 'nothing typed, nothing added');
  SS.applyAddress(empty, 'Olaya', () => 'ADDR-1');
  assert.deepStrictEqual(empty.addresses, [{ id: 'ADDR-1', label: '', address: 'Olaya' }]);
});

test('a structured address (#2416) is shown, never flattened', () => {
  const row = { id: 'A1', label: 'Home', address: '1 Road', country: 'SA', buildingNumber: '1234' };
  const c = { addresses: [row] };
  const a = SS.addressOf(c);
  assert.strictEqual(a.editable, false);
  assert.strictEqual(a.text, '1 Road');
  SS.applyAddress(c, 'something else', () => 'X');
  assert.deepStrictEqual(c.addresses, [{ id: 'A1', label: 'Home', address: '1 Road', country: 'SA', buildingNumber: '1234' }]);
  assert.strictEqual(SS.isPlainAddress({ id: 'x', address: 'y' }), true);
  assert.strictEqual(SS.isPlainAddress(null), false);
  assert.strictEqual(SS.isPlainAddress([]), false);
});

test('library places: this computer, a folder, Google Drive; a bucket is "Set up in Professional"', () => {
  assert.strictEqual(SS.libraryPlace(undefined).place, 'computer');
  assert.strictEqual(SS.libraryPlace({ root: '  ' }).place, 'computer');
  const f = SS.libraryPlace({ root: '/Users/me/Dropbox/Models' });
  assert.deepStrictEqual([f.place, f.root, f.bucket], ['folder', '/Users/me/Dropbox/Models', false]);
  // Drive counts only once an account is connected.
  assert.strictEqual(SS.libraryPlace({ gdrive: { enabled: true, clientId: 'c' } }).place, 'computer');
  assert.strictEqual(SS.libraryPlace({ gdrive: { enabled: true, clientId: 'c' } }).driveSetUp, true);
  assert.strictEqual(SS.libraryPlace({ root: '/x', gdrive: { enabled: true, refreshToken: 't' } }).place, 'drive');
  assert.strictEqual(SS.libraryPlace({ s3: { enabled: true } }).bucket, true);
  assert.strictEqual(SS.libraryPlace({ tier: { enabled: true } }).bucket, true);
  assert.strictEqual(SS.libraryPlace({ tier: { enabled: true }, gdrive: { enabled: true, refreshToken: 't' } }).bucket, false, 'tiering to Drive is the Drive row');
  const v = SS.libraryPlace({ vault: { enabled: true }, s3: { enabled: true }, gdrive: { enabled: true, refreshToken: 't' } });
  assert.deepStrictEqual([v.vault, v.bucket, v.place], [true, false, 'computer']);
});

test('every new sm.* string is in all nine languages', () => {
  const keys = ['sm.col_quote', 'sm.col_queued', 'sm.col_ready', 'sm.cust_business', 'sm.cust_addr_structured', 'sm.cf_text_sub',
    'sm.cf_edit_title', 'sm.lib_hint', 'sm.lib_computer', 'sm.lib_computer_sub', 'sm.lib_folder', 'sm.lib_folder_sub', 'sm.lib_drive',
    'sm.lib_drive_sub', 'sm.lib_in_use', 'sm.lib_connect', 'sm.lib_manage', 'sm.lib_bucket', 'sm.lib_bucket_sub', 'sm.note_mid_print', 'sm.col_more'];
  for (const lang of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const src = require('fs').readFileSync(require('path').join(__dirname, '..', 'renderer', 'locales', lang + '.js'), 'utf8');
    for (const k of keys) assert.ok(src.includes(`"${k}":`), `${lang} ${k}`);
    assert.ok(src.includes('{n}'), lang);
  }
});
