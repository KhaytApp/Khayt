/**
 * The desktop's "Add from receipt": a Saudi tax invoice's QR, found in a
 * picture (lib/receipt-qr-image.js + jsQR, as main.js runs them) and read
 * into the Add Expense form (renderer/expenses.js over lib/zatca-qr.js).
 *
 * The picture is drawn here from the `qrcode` package's module matrix, so the
 * test needs no Electron and no image files: the bitmap is BGRA, the way
 * nativeImage.toBitmap() hands it over.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const QRCode = require('qrcode');
const jsQR = require('jsqr');
const Find = require('../lib/receipt-qr-image.js');
const Qr = require('../lib/zatca-qr.js');

const RECEIPT = {
  sellerName: 'مؤسسة الخيط للتجارة', vatNumber: '310122393500003',
  timestamp: '2026-10-09T14:30:00Z', total: '115.00', vatAmount: '15.00',
};
const PAYLOAD = Qr.buildTLV(RECEIPT);

/** A white BGRA canvas with the code drawn at (left, top), `scale` px a module. */
function picture(text, { width, height, left = 40, top = 40, scale = 6 }) {
  const qr = QRCode.create(text, { errorCorrectionLevel: 'M' });
  const n = qr.modules.size;
  const px = Buffer.alloc(width * height * 4, 255);
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      if (!qr.modules.get(y, x)) continue;
      for (let dy = 0; dy < scale; dy++) {
        for (let dx = 0; dx < scale; dx++) {
          const i = ((top + y * scale + dy) * width + (left + x * scale + dx)) * 4;
          px[i] = 0; px[i + 1] = 0; px[i + 2] = 0;   // B G R; alpha stays 255
        }
      }
    }
  }
  return px;
}

test('the code is found in a BGRA bitmap and decodes as the receipt it was drawn from', () => {
  const w = 600, h = 500;
  const code = Find.findCode(Find.bgraToRgba(picture(PAYLOAD, { width: w, height: h })), w, h, jsQR);
  assert.equal(code, PAYLOAD);
  const read = Qr.decodeTLV(code);
  assert.equal(read.ok, true);
  assert.equal(read.receipt.vatNumber, RECEIPT.vatNumber);
  assert.equal(read.receipt.total, 115);
  assert.equal(read.receipt.vatAmount, 15);
});

test('a picture with no code finds nothing, and a broken decoder is not a crash', () => {
  const w = 200, h = 200;
  const blank = Find.bgraToRgba(Buffer.alloc(w * h * 4, 255));
  assert.equal(Find.findCode(blank, w, h, jsQR), '');
  assert.equal(Find.findCode(blank, w, h, () => { throw new Error('boom'); }), '');
  assert.equal(Find.findCode(blank, w, h, null), '');
  assert.equal(Find.findCode(blank.subarray(0, 10), w, h, jsQR), '', 'a short buffer is refused, not read past');
});

test('bgraToRgba swaps red and blue and copies', () => {
  const src = Buffer.from([1, 2, 3, 4, 5, 6, 7, 8]);
  assert.deepEqual([...Find.bgraToRgba(src)], [3, 2, 1, 4, 7, 6, 5, 8]);
  assert.deepEqual([...src], [1, 2, 3, 4, 5, 6, 7, 8]);
});

test('sizes tried: as taken first, then smaller only; nothing for a pixel bomb', () => {
  assert.deepEqual(Find.edgesToTry(4032, 3024), [0, 2400, 1600, 1000]);
  assert.deepEqual(Find.edgesToTry(1200, 900), [0, 1000]);
  assert.deepEqual(Find.edgesToTry(800, 600), [0]);
  assert.deepEqual(Find.edgesToTry(20000, 20000), []);
  assert.deepEqual(Find.edgesToTry(0, 100), []);
});

/* ── The renderer half ──────────────────────────────────────────────────── */

function loadRenderer() {
  require('../lib/tax.js');
  require('../lib/expense-book.js');
  require('../lib/accounting-rows.js');
  global.KhaytZatcaQr = Qr;
  global.t = (k, v) => (v ? k + ' ' + JSON.stringify(v) : k);
  return require('../renderer/expenses.js');
}

test('a read receipt proposes the expense, matches a supplier by VAT number, and flags a duplicate', () => {
  const exp = loadRenderer();
  global.settings = { currency: 'SAR', enableVat: true, vatRate: 15 };
  global.suppliers = [{ id: 'sup1', name: 'Al Khayt Trading', vat: RECEIPT.vatNumber }];
  global.expenses = [];

  const got = exp.readReceiptCode(PAYLOAD);
  assert.equal(got.ok, true);
  assert.equal(got.read.draft.amount, 115);
  assert.equal(got.read.draft.vatAmount, 15);
  assert.equal(got.read.draft.date, Qr.receiptDay(RECEIPT.timestamp));
  assert.deepEqual(got.read.supplier, { id: 'sup1', name: 'Al Khayt Trading' });
  assert.equal(got.read.duplicateOf, null);

  global.expenses = [{ id: 'EXP-1', receiptRef: got.read.draft.receiptRef }];
  assert.equal(exp.readReceiptCode(PAYLOAD).read.duplicateOf, 'EXP-1');
});

test('a shop that is not VAT-registered reclaims nothing from the receipt', () => {
  const exp = loadRenderer();
  global.settings = { currency: 'SAR', enableVat: false };
  global.suppliers = [];
  global.expenses = [];
  const got = exp.readReceiptCode(PAYLOAD);
  assert.equal(got.read.draft.amount, 115);
  assert.equal(got.read.draft.vatAmount, 0);
  assert.deepEqual(got.read.newSupplier, { name: RECEIPT.sellerName, vatNumber: RECEIPT.vatNumber });
});

test('a code that is not a tax invoice says why, in the shop\'s words', () => {
  const exp = loadRenderer();
  global.settings = { currency: 'SAR' };
  global.suppliers = [];
  global.expenses = [];
  assert.equal(exp.readReceiptCode('https://example.com/pay').problem, 'exp.receipt_not_invoice');
  assert.equal(exp.readReceiptCode('').problem, 'exp.receipt_none_found');
  const badVat = Qr.buildTLV({ ...RECEIPT, vatNumber: '123' });
  assert.equal(exp.readReceiptCode(badVat).problem, 'exp.receipt_bad_vat_number');
  assert.equal(exp.readReceiptCode(PAYLOAD.slice(0, 20)).problem, 'exp.receipt_damaged');
});

/* ── Wiring ──────────────────────────────────────────────────────────────── */

const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

test('the button, the IPC call and the main-process reader are connected', () => {
  assert.match(read('renderer/index.html'), /id="btnExpFromReceipt"/);
  assert.match(read('renderer/wire-events.js'), /#btnExpFromReceipt'\)\?\.addEventListener\('click', \(\) => openReceiptQr\(\)\)/);
  assert.match(read('preload.js'), /readReceiptQr: \(\) => ipcRenderer\.invoke\('hub:read-receipt-qr'\)/);
  const main = read('main.js');
  assert.match(main, /ipcMain\.handle\('hub:read-receipt-qr'/);
  assert.match(main, /require\('\.\/lib\/receipt-qr-image\.js'\)/);
  const pkg = JSON.parse(read('package.json'));
  assert.ok(pkg.dependencies.jsqr, 'jsqr is a runtime dependency, so the packaged app has it');
});

// expenses.js wraps itself in a function. It used to declare expRangeFilter
// and _expReceiptPath a second time inside it, so wire-events.js wrote the
// window's copy and this file read its own: the range filter never applied,
// and an attached receipt was never saved with its expense.
test('the expense page reads the same filter and receipt the controls set', () => {
  const src = read('renderer/expenses.js');
  for (const name of ['expRangeFilter', '_expReceiptPath', 'EXP_CATEGORIES']) {
    const decls = src.match(new RegExp(`^\\s*(?:let|const|var) ${name}\\b`, 'gm')) || [];
    assert.equal(decls.length, 1, `${name} is declared ${decls.length} times`);
  }
  // …and the declaration is the top-level one, outside the wrapper.
  assert.ok(src.indexOf('let _expReceiptPath') < src.indexOf('(function (global)'));
  const wire = read('renderer/wire-events.js');
  assert.ok(!/_expReceiptPath\s*=/.test(wire), 'the attach button goes through setExpenseReceipt');
});

test('addExpense files the receipt reference and refuses the same receipt twice', () => {
  const src = read('renderer/expenses.js');
  assert.match(src, /receiptRef:\s+_expReceiptRef,/);
  assert.match(src, /expenses\.some\(\(e\) => e && e\.receiptRef === made\.expense\.receiptRef\)/);
});
