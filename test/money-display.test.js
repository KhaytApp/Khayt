'use strict';
/**
 * Three money-display faults found in review (Nov 2026), all of them a job in
 * a client's currency since convert-at-save (#2148):
 *
 *  1. The ZATCA QR stated a EUR job's total and VAT as bare numbers, which a
 *     scanner reads as riyals. Tags 4 and 5 are SAR; the rate the job was
 *     converted at is now stored on it (`fxRate`) and the QR uses that, or
 *     refuses (lib/zatca-qr.js qrAmounts).
 *  2. (Mac only — the desktop draws no Owed meter.)
 *  3. The desktop put the SHOP's mark on a job's own-currency price in the
 *     orders log, the board and a customer's history (`fmtOrderPrice`).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
require('../lib/pricing.js');
const N = require('../lib/order-new.js');
const QR = require('../lib/zatca-qr.js');

const NOW = new Date('2026-09-04T09:15:00.000Z');
const TOKENS = { tracking: new Uint8Array(16).fill(0xab), quoteApproval: new Uint8Array(16).fill(0xcd) };
const shop = (extra) => Object.assign({
  currency: 'SAR', invNumNext: 5, invNumYear: 2026, quoteNumNext: 1, quoteNumYear: 2026,
  exchangeRates: { EUR: 4 },
}, extra || {});
const job = (input, settings, clients) => N.newOrder(Object.assign({
  parts: [{ name: 'p', material: 'PLA', baseCost: 100, printTime: 2, qty: 1 }],
  margin: 15,
}, input), { settings: settings || shop(), orders: [], now: NOW, tokens: TOKENS, clients: clients || [] });

/* ── 1. The rate is kept on the job ───────────────────────────────────────── */

test('a converted job keeps the rate it was converted at; an ordinary one does not', () => {
  const eur = job({ clientId: 'C1' }, shop(), [{ id: 'C1', currency: 'EUR' }]);
  assert.equal(eur.currency, 'EUR');
  assert.equal(eur.fxRate, 4);
  const sar = job({});
  assert.equal('fxRate' in sar, false, 'a job in the shop currency keeps its shape');
  // No rate in Settings: the job is stamped in the shop's currency, unconverted.
  const none = job({ clientId: 'C1' }, shop({ exchangeRates: {} }), [{ id: 'C1', currency: 'EUR' }]);
  assert.equal(none.currency, 'SAR');
  assert.equal('fxRate' in none, false);
});

/* ── 1. The QR states riyals ──────────────────────────────────────────────── */

test('qrAmounts: SAR passes, a foreign job converts at its STORED rate', () => {
  const s = { currency: 'SAR', exchangeRates: { EUR: 9 } };   // today's rate is NOT used
  assert.deepEqual(QR.qrAmounts({}, s, { total: 115, vatAmount: 15 }),
    { ok: true, total: 115, vatAmount: 15 });
  assert.deepEqual(QR.qrAmounts({ currency: 'SAR' }, s, { total: 115, vatAmount: 15 }),
    { ok: true, total: 115, vatAmount: 15 });
  assert.deepEqual(QR.qrAmounts({ currency: 'EUR', fxRate: 4 }, s, { total: 28.75, vatAmount: 3.75 }),
    { ok: true, total: 115, vatAmount: 15 });
});

test('qrAmounts: a foreign job with no stored rate gets no QR, and says why', () => {
  const s = { currency: 'SAR', exchangeRates: { EUR: 4 } };
  const r = QR.qrAmounts({ currency: 'EUR' }, s, { total: 28.75, vatAmount: 3.75 });
  assert.equal(r.ok, false);
  assert.deepEqual(r.missing, ['inv.qr_foreign_currency']);
  // A rate is shop-currency per unit; on a shop that is not in SAR it is no
  // riyal figure, so a foreign job there is refused too.
  assert.equal(QR.qrAmounts({ currency: 'EUR', fxRate: 1.1 }, { currency: 'USD' },
    { total: 10, vatAmount: 1 }).ok, false);
});

test('a EUR job saved today puts its riyal value in tags 4 and 5', () => {
  const eur = job({ clientId: 'C1' }, shop(), [{ id: 'C1', currency: 'EUR' }]);
  const vat = +(eur.price * 15 / 115).toFixed(2);
  const m = QR.qrAmounts(eur, shop(), { total: eur.price, vatAmount: vat });
  assert.equal(m.ok, true);
  const tlv = QR.buildTLV({ sellerName: 'Shop', vatNumber: '300000000000003',
    timestamp: eur.timestamp, total: m.total.toFixed(2), vatAmount: m.vatAmount.toFixed(2) }, {});
  const back = QR.decodeTLV(tlv);
  assert.equal(back.ok, true);
  assert.equal(back.receipt.total, 115);
  assert.equal(back.receipt.vatAmount, 15);
});

test('both apps build the QR from qrAmounts, not from the job-currency figures', () => {
  const inv = read('renderer/invoicing.js');
  assert.match(inv, /ZatcaQr\(\)\.qrAmounts\(order, settings, \{ total: _tax\.total, vatAmount: vatAmt \}\)/);
  assert.match(inv, /total: fmtMoney\(qrMoney\.total\), vatAmount: fmtMoney\(qrMoney\.vatAmount\)/);
  const mac = read('mac/KhaytCore/Sources/KhaytApp/Invoice.swift');
  assert.match(mac, /engine\.zatcaAmounts\(/);
  assert.match(mac, /total: Self\.amount\(total\),\s+vatAmount: Self\.amount\(vat\)\)/);
  assert.match(read('mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift'), /KhaytZatcaQr\.qrAmounts\(ARG0, ARG1/);
});

test('the refusal reads in every desktop language', () => {
  const dir = path.join(ROOT, 'renderer', 'locales');
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) {
    assert.match(read(path.join('renderer', 'locales', f)), /"inv\.qr_foreign_currency": "[^"]+"/, f);
  }
});

/* ── 3. A job's price wears the job's currency ────────────────────────────── */

test('fmtOrderPrice: the shop currency is unchanged, a foreign job carries its own mark', () => {
  require('../renderer/format.js');
  const { fmtOrderPrice, fmtPrice } = require('../renderer/currency.js');
  global.settings = { currency: 'SAR', exchangeRates: { EUR: 4 } };
  global.clients = [{ id: 'C1', currency: 'EUR' }];
  assert.equal(fmtOrderPrice(115, {}), fmtPrice(115));
  assert.equal(fmtOrderPrice(115, { currency: 'SAR' }), fmtPrice(115));
  const eur = fmtOrderPrice(28.75, { currency: 'EUR' });
  assert.match(eur, /28\.75/);
  assert.match(eur, /€/);
  assert.doesNotMatch(eur, /SAR|⃁|ر\.س/);
});

test('the job lists format a job price through fmtOrderPrice', () => {
  const sites = {
    'renderer/logs.js': /fmtOrderPrice\(log\.price, log\)/,
    'renderer/kanban.js': /fmtOrderPrice\(log\.price, log\)/,
    'renderer/clients.js': /fmtOrderPrice\(o\.price, o\)/,
    'renderer/dashboard.js': /fmtOrderPrice\(o\.price, o\)/,
    'renderer/expenses.js': /fmtOrderPrice\(order\.price, order\)/,
  };
  for (const [file, re] of Object.entries(sites)) {
    const src = read(file);
    assert.match(src, re, file);
    assert.doesNotMatch(src, /fmtPrice\((o|log|q)\.price\)/, `${file} still puts the shop's mark on a job price`);
  }
});

/* ── Follow-ups: the rest of the duplicates ────────────────────────────────── */

const M = require('../lib/order-money.js');

test('ONE rate everywhere: an order converts at its saved rate, a legacy one at today\'s', () => {
  const ctx = { settings: { currency: 'SAR', exchangeRates: { EUR: 9 } }, clients: [{ id: 'C1', currency: 'EUR' }] };
  const done = { status: 'completed' };
  const saved = Object.assign({ price: 25, currency: 'EUR', fxRate: 4, paidAmount: 5,
    creditNotes: [{ amount: 5 }] }, done);
  assert.equal(M.orderToBase(25, saved, ctx), 100);          // not 225 at today's 9
  assert.equal(M.orderRevenueBase(saved, ctx), 100);
  assert.equal(M.orderCreditedBase(saved, ctx), 20);
  assert.equal(M.orderNetRevenueBase(saved, ctx), 80);
  assert.equal(M.orderOwedBase(saved, ctx), 60);               // (25 − 5 − 5) × 4
  // A job saved before rates were kept falls back to today's, as reports did.
  const legacy = Object.assign({ price: 25, currency: 'EUR' }, done);
  assert.equal(M.orderRevenueBase(legacy, ctx), 225);
  // So does one whose currency comes from the client rather than the record:
  // the stored rate belongs to the stored code only.
  assert.equal(M.orderRevenueBase(Object.assign({ price: 25, clientId: 'C1', fxRate: 4 }, done), ctx), 225);
  // The shop's own currency is never touched.
  assert.equal(M.orderToBase(50, Object.assign({ fxRate: 4 }, done), ctx), 50);
});

test('a column total is the reports\' figure, legacy jobs included', () => {
  const ctx = { settings: { currency: 'SAR', exchangeRates: { EUR: 9 } }, clients: [] };
  const done = { status: 'completed' };
  const jobs = [
    Object.assign({ price: 100 }, done),
    Object.assign({ price: 25, currency: 'EUR', fxRate: 4 }, done),       // 100
    Object.assign({ price: 50, currency: 'SAR', creditNotes: [{ amount: 10 }] }, done),   // 40
    Object.assign({ price: 10, currency: 'EUR' }, done),                  // legacy: 90
  ];
  assert.equal(M.earnedTotalBase(jobs, ctx), 330);
  assert.equal(M.earnedTotalBase(jobs, ctx),
    jobs.reduce((s, o) => s + M.orderNetRevenueBase(o, ctx), 0));
});

test('the board totals go through the shared rule; no partial key is left behind', () => {
  const kan = read('renderer/kanban.js');
  assert.match(kan, /const totalValFoot = fmtJobsTotal\(sorted\);/);
  assert.match(kan, /const totalVal = fmtJobsTotal\(sorted\);/);
  const dir = path.join(ROOT, 'renderer', 'locales');
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.js'))) {
    const s = read(path.join('renderer', 'locales', f));
    assert.doesNotMatch(s, /kan\.total_partial/, f);
    assert.match(s, /"inv\.qr_phase2_foreign_currency": "[^"]+"/, f);
  }
  require('../renderer/format.js');
  const C = require('../renderer/currency.js');
  global.settings = { currency: 'SAR', exchangeRates: { EUR: 9 } };
  global.clients = [];
  assert.equal(C.fmtJobsTotal([{ price: 25, currency: 'EUR', fxRate: 4, status: 'completed' }]), C.fmtPrice(100));
});

test('fmtMoneyIn joins with a narrow no-break space, as fmtPrice does', () => {
  require('../renderer/format.js');
  const C = require('../renderer/currency.js');
  global.settings = { currency: 'SAR' };
  assert.doesNotMatch(C.fmtMoneyIn(100, 'EUR'), / /);
  assert.match(C.fmtMoneyIn(100, 'EUR'), / /);
});

test('every per-order conversion goes through orderToBase', () => {
  for (const f of ['lib/pnl-report.js', 'lib/receivables.js', 'lib/report-records.js',
                   'renderer/invoicing.js', 'renderer/expenses.js']) {
    assert.doesNotMatch(read(f), /convertToBase\([^)]*orderCurrency\(o/, f);
    assert.doesNotMatch(read(f), /convertToBase\([^)]*curOf\(o\)/, f);
  }
  assert.match(read('lib/accounting-rows.js'), /toBase\(price, cur, o\)/);
  const eng = read('mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift');
  assert.match(eng, /billed: M\.orderToBase\(/);
  assert.match(eng, /rateById\[String\(o\.id\)\] = M\.orderToBase\(1, o, ctx/);
});

test('Phase 2 refuses a job that is not in SAR; SAR passes', () => {
  assert.deepEqual(QR.phase2Currency({}, { currency: 'SAR' }), { ok: true, missing: [] });
  assert.deepEqual(QR.phase2Currency({ currency: 'SAR' }, { currency: 'SAR' }), { ok: true, missing: [] });
  // A stored rate does NOT make it safe: the signed XML would still carry euros.
  assert.deepEqual(QR.phase2Currency({ currency: 'EUR', fxRate: 4 }, { currency: 'SAR' }),
    { ok: false, missing: ['inv.qr_phase2_foreign_currency'] });
  const inv = read('renderer/invoicing.js');
  assert.match(inv, /const z2cur = z2on \? ZatcaQr\(\)\.phase2Currency\(order, settings\)/);
  // The refusal joins the readiness check that throws before the Phase 2 build.
  const at = inv.indexOf('const z2cur');
  assert.ok(at > 0 && at < inv.indexOf("throw new Error('zatca-qr-not-ready')"));
});

test('the reminder, the credit-note reference and the change-price dialog wear the job currency', () => {
  const inv = read('renderer/invoicing.js');
  assert.match(inv, /amount: fmtOrderPrice\(order\.price, order\)/);
  assert.match(inv, /<strong>\$\{escapeHtml\(order\.id\)\}<\/strong> · \$\{fmtOrderPrice\(order\.price, order\)\}\n/);
  assert.match(inv, /cn\.credit_amount'\)\)\} \(\$\{escapeHtml\(orderCurrencySymbol\(order\)\)\}\)/);
  assert.match(read('renderer/order-flows.js'), /Current Price:<\/strong> \$\{fmtOrderPrice\(order\.price, order\)\}/);
  assert.match(read('renderer/app-state.js'), /currency: \(typeof orderCurrencySymbol === 'function' \? orderCurrencySymbol\(order\)/);
  const mac = read('mac/KhaytCore/Sources/KhaytApp/WhatsApp.swift');
  assert.match(mac, /"currency": job\.currency\.isEmpty \? currency : job\.currency/);
  assert.match(read('mac/KhaytCore/Sources/KhaytApp/EditJobSheet.swift'),
    /Money\.text\(job\.price, job\.currency\.isEmpty \? shop\.currency : job\.currency\)/);
});

test('"Amount in SAR" on the invoice uses the saved rate, not today\'s', () => {
  const { render } = require('./helpers/invoice-harness.js');
  const settings = { currency: 'SAR', exchangeRates: { EUR: 9 } };
  const base = { id: 'INV-1', date: '2026-09-01', project: 'P', price: 100, currency: 'EUR', status: 'completed' };
  const saved = render(Object.assign({ fxRate: 4 }, base), { settings });
  assert.match(saved, /Amount in SAR/);
  assert.match(saved, /400\.00/);
  assert.doesNotMatch(saved, /900\.00/);
  const unsaved = render(base, { settings });
  assert.doesNotMatch(unsaved, /Amount in SAR/);
});
