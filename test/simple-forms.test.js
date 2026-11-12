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
    'sm.lib_drive_sub', 'sm.lib_in_use', 'sm.lib_connect', 'sm.lib_manage', 'sm.lib_bucket', 'sm.lib_bucket_sub'];
  for (const lang of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const src = require('fs').readFileSync(require('path').join(__dirname, '..', 'renderer', 'locales', lang + '.js'), 'utf8');
    for (const k of keys) assert.ok(src.includes(`"${k}":`), `${lang} ${k}`);
    assert.ok(src.includes('{n}'), lang);
  }
});
