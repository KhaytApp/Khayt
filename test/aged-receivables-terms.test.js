/**
 * The desktop's Aged Receivables screen with payment terms (lib/payment-terms.js).
 *
 * A customer on net 30 invoiced last week owes money but is not late. The
 * module says so (`overdue: false`, `due`). The screen used to draw such a row
 * as "0" days in the 0–30 bucket, which reads as just-overdue. This runs the
 * real renderAgedReceivables from renderer/analytics.js against a stub DOM.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

require('../lib/payment-terms.js');
const Rec = require('../lib/receivables.js');

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');
const body = src.slice(src.indexOf('function renderAgedReceivables()'), src.indexOf('function renderSurveyAnalytics()'));

function render(printLog, clients, now) {
  const el = { innerHTML: '', querySelector: () => null };
  const t = (k, p) => k + (p ? JSON.stringify(p) : '');
  const realAged = Rec.aged;
  const R = { ...Rec, aged: (o, ctx) => realAged(o, { ...ctx, now }) };
  const fn = new Function('$', 't', 'escapeHtml', 'fmtPrice', 'printLog', 'settings', 'clients', 'CURRENCIES', 'globalThis', 'require',
    body + '\nreturn renderAgedReceivables;')(
    () => el, t, (s) => String(s), (n) => n.toFixed(2), printLog, {}, clients, null, { KhaytReceivables: R }, require);
  fn();
  return el.innerHTML;
}

test('a net-30 invoice from last week says "Not yet due", with its due date, and the total is split', () => {
  const now = new Date(2026, 9, 30);
  const clients = [{ id: 'C1', nameEn: 'Acme', paymentTermsDays: 30 }, { id: 'C2', nameEn: 'Walk-in' }];
  const html = render([
    { id: 'A', date: '2026-10-23', price: 100, paidAmount: 0, clientId: 'C1', invoiceNumber: 'INV-1' },
    { id: 'B', date: '2026-10-10', price: 50, paidAmount: 0, clientId: 'C2', invoiceNumber: 'INV-2' },
  ], clients, now);
  assert.match(html, /an\.aged_col_due/);
  assert.match(html, /2026-11-22/, 'net 30 from Oct 23 is due Nov 22');
  assert.match(html, /an\.aged_overdue 50\.00 · an\.aged_not_yet_due 100\.00/);
  // The walk-in, due on receipt, is 20 days overdue and shown as a number.
  assert.match(html, />20<\/td>/);
  // The bucket header is translated, not a hard-coded "DAYS — n order(s)".
  assert.doesNotMatch(html, / DAYS — /);
  assert.match(html, /an\.aged_bucket_days\{"label":"0–30"\}/);
});

test('with nothing on terms, no split line is drawn', () => {
  const html = render([{ id: 'B', date: '2026-10-10', price: 50, paidAmount: 0, clientId: 'C2' }],
    [{ id: 'C2', nameEn: 'Walk-in' }], new Date(2026, 9, 30));
  assert.doesNotMatch(html, /an\.aged_not_yet_due/);
});
