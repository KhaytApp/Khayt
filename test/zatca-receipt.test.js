'use strict';

/**
 * Reading a supplier's ZATCA QR back: the decoder refuses a stranger's bytes
 * with a reason, round-trips the builder, and turns a receipt into an expense
 * draft a person reviews — never files one by itself.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const Z = require('../lib/zatca-qr.js');
const B = require('../lib/expense-book.js');

const VAT = '310122393500003';
const receipt = (over = {}) => Object.assign({
  sellerName: 'مؤسسة الخيط للطباعة',
  vatNumber: VAT,
  timestamp: '2026-10-09T14:30:00Z',
  total: '115.00',
  vatAmount: '15.00',
}, over);

/** TLV bytes → base64, for hand-built (hostile) inputs. */
function pack(fields) {
  const bytes = [];
  for (const [tag, value] of fields) {
    const v = Array.isArray(value) ? value : Z.utf8(value);
    if (v.length > 255) bytes.push(tag, 0x82, (v.length >> 8) & 0xff, v.length & 0xff);
    else if (v.length > 127) bytes.push(tag, 0x81, v.length);
    else bytes.push(tag, v.length);
    bytes.push(...v);
  }
  return Z.base64(bytes);
}
const five = (over = {}) => {
  const r = receipt(over);
  return [[1, r.sellerName], [2, r.vatNumber], [3, r.timestamp], [4, r.total], [5, r.vatAmount]];
};

test('a code the builder writes is read back exactly, Arabic seller included', () => {
  const qr = Z.buildTLV(receipt());
  const out = Z.decodeTLV(qr);
  assert.equal(out.ok, true, JSON.stringify(out));
  assert.deepEqual(out.receipt, {
    sellerName: 'مؤسسة الخيط للطباعة', vatNumber: VAT, timestamp: '2026-10-09T14:30:00Z',
    total: 115, vatAmount: 15, phase2: false,
  });
});

test('a long seller name uses the two-byte length forms and still reads', () => {
  const long = 'شركة '.repeat(40);   // > 127 and > 255 UTF-8 bytes
  const out = Z.decodeTLV(Z.buildTLV(receipt({ sellerName: long })));
  assert.equal(out.ok, true);
  assert.equal(out.receipt.sellerName, long.trim());
});

test('a Phase 2 code (tags 6–9) is read, and its extra tags are skipped', () => {
  const qr = pack([...five(), [6, Array(32).fill(7)], [7, Array(72).fill(9)], [8, Array(88).fill(1)], [9, Array(70).fill(2)]]);
  const out = Z.decodeTLV(qr);
  assert.equal(out.ok, true, JSON.stringify(out));
  assert.equal(out.receipt.phase2, true);
  assert.equal(out.receipt.total, 115);
});

test('URL-safe base64 and line breaks are accepted', () => {
  const qr = Z.buildTLV(receipt()).replace(/\+/g, '-').replace(/\//g, '_');
  assert.equal(Z.decodeTLV(qr.slice(0, 20) + '\n' + qr.slice(20)).ok, true);
});

test('every refusal has a reason', () => {
  const cases = [
    ['', 'empty'],
    ['A'.repeat(20000), 'too_long'],
    ['not base64 at all!', 'not_base64'],
    [Z.base64([1, 50, 65]), 'truncated'],                          // length past the buffer
    [Z.base64([1]), 'truncated'],                                   // a tag and no length
    [Z.base64([1, 0x83, 0, 0, 1]), 'too_long'],                     // a huge length form
    [pack([...five(), [1, 'again']]), 'bad_tag'],                   // the same tag twice
    [pack([...five(), [42, 'x']]), 'bad_tag'],                      // a tag nobody defines
    [pack([[1, [0xc3, 0x28]], ...five().slice(1)]), 'not_utf8'],    // invalid UTF-8
    [pack([[1, [0xe0, 0x80, 0xaf]], ...five().slice(1)]), 'not_utf8'], // overlong form
    [pack(five().slice(0, 4)), 'missing_tag'],
    [pack(five({ vatNumber: '123456789012345' })), 'bad_vat_number'],
    [pack(five({ vatNumber: '31012239350000' })), 'bad_vat_number'],
    [pack(five({ total: '-5' })), 'bad_amount'],
    [pack(five({ total: '1e3' })), 'bad_amount'],
    [pack(five({ total: 'NaN' })), 'bad_amount'],
    [pack(five({ vatAmount: '200' })), 'vat_over_total'],
    [pack(five({ timestamp: 'yesterday' })), 'bad_timestamp'],
  ];
  for (const [text, reason] of cases) {
    const out = Z.decodeTLV(text);
    assert.equal(out.ok, false, `accepted: ${reason}`);
    assert.equal(out.reason, reason, `${reason}: got ${out.reason}`);
  }
});

test('repetition does not run away: thousands of tiny TLVs are refused quickly', () => {
  const bytes = [];
  for (let i = 0; i < 4000; i++) bytes.push(6, 0);   // valid-looking empty Phase 2 tags
  const started = Date.now();
  const out = Z.decodeTLV(Z.base64(bytes));
  assert.equal(out.ok, false);
  assert.ok(Date.now() - started < 500);
});

test('the draft: total paid, the VAT a registered shop reclaims, the local day, no category', () => {
  const r = Z.decodeTLV(Z.buildTLV(receipt())).receipt;
  const { draft, supplier, duplicateOf } = Z.receiptToExpenseDraft(r, { suppliers: [], expenses: [], reclaimsTax: true });
  assert.equal(draft.amount, 115);
  assert.equal(draft.vatAmount, 15);
  assert.match(draft.date, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(draft.note, 'مؤسسة الخيط للطباعة · VAT ' + VAT);
  assert.equal(draft.receiptRef, `zatca:${VAT}:2026-10-09T14:30:00Z:115`);
  assert.equal(draft.category, undefined, 'a receipt does not say what the money was for');
  assert.equal(supplier, null);
  assert.equal(duplicateOf, null);
});

test('a shop that is not VAT-registered reclaims nothing: the whole total is its cost', () => {
  const r = Z.decodeTLV(Z.buildTLV(receipt())).receipt;
  assert.equal(Z.receiptToExpenseDraft(r, { reclaimsTax: false }).draft.vatAmount, 0);
});

test('a supplier is matched by VAT number first, then by name', () => {
  const r = Z.decodeTLV(Z.buildTLV(receipt({ sellerName: 'Riyadh Filament Co.' }))).receipt;
  const suppliers = [
    { id: 'S1', name: 'riyadh filament co' },
    { id: 'S2', name: 'Something else', vat: VAT },
  ];
  assert.equal(Z.receiptToExpenseDraft(r, { suppliers }).supplier.id, 'S2', 'the VAT number outranks the name');
  assert.equal(Z.receiptToExpenseDraft(r, { suppliers: [suppliers[0]] }).supplier.id, 'S1');
  assert.equal(Z.receiptToExpenseDraft(r, { suppliers: [suppliers[0]] }).draft.note.startsWith('riyadh filament co'), true);
});

test('the same receipt scanned twice is flagged, not filed twice — and the book keeps the reference', () => {
  const r = Z.decodeTLV(Z.buildTLV(receipt())).receipt;
  const { draft } = Z.receiptToExpenseDraft(r, {});
  const { expense } = B.newExpense({ ...draft, category: 'filament' }, { id: 'E1', today: '2026-10-10' });
  assert.equal(expense.receiptRef, draft.receiptRef, 'expense-book dropped the receipt reference');
  assert.equal(Z.receiptToExpenseDraft(r, { expenses: [expense] }).duplicateOf, 'E1');
  // A typed expense carries none.
  assert.equal(B.newExpense({ amount: 5 }, { id: 'E2', today: '2026-10-10' }).expense.receiptRef, null);
});

test('a bare day stays that day; a stamp with a zone is read on the local calendar', () => {
  assert.equal(Z.receiptDay('2026-10-09'), '2026-10-09');
  assert.match(Z.receiptDay('2026-10-09T23:30:00Z'), /^2026-10-(09|10)$/);
  assert.equal(Z.receiptDay('2026-10-09T23:30:00'), '2026-10-09', 'no zone: the day as written');
  assert.equal(Z.receiptDay('garbage'), '');
});

test('an unknown seller comes back as a new supplier, with its VAT number; a matched one does not', () => {
  const r = Z.decodeTLV(Z.buildTLV(receipt())).receipt;
  const fresh = Z.receiptToExpenseDraft(r, { suppliers: [] });
  assert.deepEqual(fresh.newSupplier, { name: 'مؤسسة الخيط للطباعة', vatNumber: VAT });
  assert.equal(fresh.sellerName, 'مؤسسة الخيط للطباعة');
  assert.equal(fresh.vatNumber, VAT);
  // Added with the number under `vat` (the key the Mac's supplier sheet
  // writes), the next receipt matches — spaces in a typed number or all.
  const added = Z.receiptToExpenseDraft(r, { suppliers: [{ id: 'S9', name: 'Other name', vat: '310 1223 9350 0003' }] });
  assert.equal(added.supplier.id, 'S9');
  assert.equal(added.newSupplier, null);
  assert.equal(added.sellerName, 'مؤسسة الخيط للطباعة', 'the receipt\'s own seller, apart from the book\'s name');
});

test('a seller name is stripped of control and bidi-override characters and capped at 200', () => {
  const hostile = 'Evil‮3.99‬ Co\u0000\u0007\n⁦x⁩';
  const out = Z.decodeTLV(Z.buildTLV(receipt({ sellerName: hostile })));
  assert.equal(out.ok, true, JSON.stringify(out));
  assert.equal(out.receipt.sellerName, 'Evil 3.99 Co x');
  assert.doesNotMatch(Z.receiptToExpenseDraft(out.receipt, {}).draft.note, /[‪-‮⁦-⁩\u0000-\u001F]/);
  const long = Z.decodeTLV(Z.buildTLV(receipt({ sellerName: 'م'.repeat(600) })));
  assert.equal(long.ok, true);
  assert.equal(Array.from(long.receipt.sellerName).length, 200);
  // Nothing but overrides is no seller at all.
  assert.equal(Z.decodeTLV(Z.buildTLV(receipt({ sellerName: '‮‬' }))).reason, 'missing_tag');
});

test('the draft is to the halala, however many decimals the code writes', () => {
  const r = Z.decodeTLV(Z.buildTLV(receipt({ total: '115.004999', vatAmount: '15.005001' }))).receipt;
  const { draft } = Z.receiptToExpenseDraft(r, { reclaimsTax: true });
  assert.equal(draft.amount, 115);
  assert.equal(draft.vatAmount, 15.01);
  assert.equal(draft.receiptRef, `zatca:${VAT}:2026-10-09T14:30:00Z:115.004999`, 'the reference is the code\'s own figure');
});
