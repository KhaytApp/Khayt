/**
 * Render-path regression tests.
 *
 * These exercise renderer functions that write into the real DOM (via the
 * jsdom harness loading renderer/index.html). They lock in fixes from the 2.7
 * QA pass that previously could only be verified by standalone scripts because
 * they live on the render path, not in pure-compute helpers.
 */
const { test, beforeEach, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { setupDom } = require('./helpers/dom.js');
const fs = require('node:fs');
const path = require('node:path');

let dom;
beforeEach(() => { dom = setupDom(); });
afterEach(() => { dom.teardown(); });

test('harness: $ / $$ resolve real index.html elements', () => {
  assert.ok($('#invoice-print-area'), '#invoice-print-area should exist in index.html');
  assert.ok($('#stat-revenue'), '#stat-revenue should exist in index.html');
  assert.ok($$('[data-i18n]').length > 0, '$$ should find translatable nodes');
});

test('renderInvoice: populates print area without throwing (C1 subtotalShown)', () => {
  dom.loadI18n();
  require('../renderer/format.js');
  require('../renderer/currency.js');
  require('../lib/tax.js');          // sets globalThis.KhaytTax — money paths need it
  require('../renderer/app-helpers.js');
  // Sets globalThis.KhaytInvoiceLanguage (dual-export). renderInvoice asks it
  // whether the document is bilingual, so without it every render throws — which
  // is how this test caught the missing <script> tag rather than the app doing it
  // in front of a user.
  require('../lib/invoice-language.js');
  const inv = require('../renderer/invoicing.js');

  global.settings = { currency: 'SAR', vatEnabled: true, vatRate: 15, businessName: 'Khayt' };
  global.clients = [];
  global.printLog = [];

  const order = {
    id: 'o1', orderName: 'Test', clientId: null, status: 'completed',
    date: '2026-06-01', price: 115, qty: 1, item: 'Widget',
  };

  assert.doesNotThrow(() => {
    inv.renderInvoice(order, {
      qrSvg: '', payQrSvg: '', total: 115, vatAmount: 15,
      subtotal: 100, subtotalShown: '100.00', vatRate: 15, shipping: 0,
    });
  });

  const area = $('#invoice-print-area');
  assert.ok(area.innerHTML.length > 0, 'print area should be populated');
  assert.ok(area.innerHTML.includes('100.00'), 'subtotalShown value should appear in the invoice');
});

function loadAnalyticsStack() {
  dom.loadI18n();
  require('../renderer/format.js');
  require('../renderer/currency.js');
  require('../lib/tax.js');          // sets globalThis.KhaytTax — money paths need it
  require('../renderer/app-helpers.js');
  // The shared modules the analytics screen reaches through globals. In the app
  // they are `<script>` tags; a missing one here throws from inside whichever
  // chart needs it — which is what this test is for, so they belong in the
  // stack rather than inside a try.
  require('../lib/break-even.js');   // globalThis.KhaytBreakEven
  require('../lib/cash-flow.js');    // globalThis.KhaytCashFlow
  require('../lib/client-value.js'); // globalThis.KhaytClientValue
  require('../lib/capacity.js');     // globalThis.KhaytCapacity
  require('../lib/quote-funnel.js'); // globalThis.KhaytQuoteFunnel
  require('../lib/product-profit.js'); // globalThis.KhaytProductProfit
  require('../lib/calculator-cost.js'); // partTotalCost, which product profit costs with
  require('../lib/customer-mix.js'); // globalThis.KhaytCustomerMix
  require('../renderer/dashboard.js'); // renderMaterialUsageChart / renderFilamentAnalytics
  require('../renderer/analytics.js');
}

test('renderAnalytics: renders the full analytics tree without throwing', () => {
  loadAnalyticsStack();
  dom.seedState({
    settings: { currency: 'SAR', fixedCosts: [] },
    printLog: [
      { id: 'a', status: 'completed', date: '2026-06-01', price: 115, printTime: 2.5, clientId: null },
      { id: 'b', status: 'printing', date: '2026-06-03', price: 50, printTime: 3, clientId: null },
    ],
  });
  // A regression that throws in any sub-renderer (PnL, SLA, charts, operator,
  // filament …) surfaces here — this guards the whole analytics render path.
  assert.doesNotThrow(() => global.renderAnalytics());
  assert.ok($('#pnlSection').innerHTML.length > 0, 'P&L section should render (M4)');
  assert.ok($('#slaSection').innerHTML.length > 0, 'SLA section should render (M5)');
});

test('renderAnalytics: hours sum spans all in-range orders, not just completed (H6)', () => {
  loadAnalyticsStack();
  dom.seedState({
    settings: { currency: 'SAR', fixedCosts: [] },
    printLog: [
      { id: 'a', status: 'completed', date: '2026-06-01', price: 115, printTime: 2.5, clientId: null },
      { id: 'b', status: 'printing', date: '2026-06-02', price: 200, printTime: 1.5, clientId: null },
      { id: 'c', status: 'pending', date: '2026-06-03', price: 50, printTime: 3, clientId: null },
    ],
  });
  global.renderAnalytics();
  // 2.5 + 1.5 + 3 = 7.0 — includes printing/pending, not just completed.
  assert.equal($('#stat-hours').textContent, '7.0');
});

test('renderAnalytics: quote conversion stays within the created cohort, never >100% (H7)', () => {
  loadAnalyticsStack();
  dom.seedState({
    settings: { currency: 'SAR', fixedCosts: [] },
    printLog: [
      // sent + accepted in range → counts as created AND converted
      { id: 'b', status: 'completed', date: '2026-06-02', price: 200, printTime: 1, clientId: null, quoteSentAt: '2026-05-20', quoteAcceptedAt: '2026-05-25' },
      // sent in range, not accepted → created, not converted
      { id: 'c', status: 'printing', date: '2026-06-03', price: 50, printTime: 1, clientId: null, quoteSentAt: '2026-05-21' },
      // accepted but NEVER sent → must NOT inflate the rate above 100%
      { id: 'd', status: 'completed', date: '2026-06-04', price: 80, printTime: 1, clientId: null, quoteAcceptedAt: '2026-05-26' },
    ],
  });
  global.renderAnalytics();
  assert.equal($('#stat-quotes-created').textContent, '2', 'only quotes with quoteSentAt count as created');
  assert.equal($('#stat-conv-rate').textContent, '50%', '1 of 2 created quotes converted; the unsent-but-accepted order is excluded');
});

// --- Arg-taking HTML builders -------------------------------------------------
// Self-contained render helpers that build HTML from explicit arguments — the
// same class as renderInvoice (where C1 lived). A render-path sweep across all
// 111 render functions (rich/empty/sparse state + edge args) found no crashes;
// these lock in the stable builders, asserting empty-guards and HTML escaping.

function loadBuilders() {
  dom.loadI18n();
  require('../renderer/format.js');
  require('../renderer/currency.js');
  require('../lib/tax.js');          // sets globalThis.KhaytTax — money paths need it
  require('../renderer/app-helpers.js'); // renderTagChips
  require('../renderer/expenses.js');    // renderAttachedFiles
  require('../renderer/invoicing.js');   // renderInvoice
  require('../renderer/order-flows.js'); // renderOeExtraLinesHtml
}

test('renderTagChips: empty/null → "", escapes tag text (XSS guard)', () => {
  loadBuilders();
  assert.equal(renderTagChips([]), '');
  assert.equal(renderTagChips(null), '');
  const html = renderTagChips(['<img src=x onerror=alert(1)>'], true);
  assert.ok(!html.includes('<img'), 'raw tag markup must be escaped');
  assert.ok(html.includes('&lt;img'), 'tag text should be HTML-escaped');
  assert.ok(html.includes('data-act="filter-tag"'), 'clickable chips carry the filter action');
});

test('renderAttachedFiles: empty → placeholder, escapes file names', () => {
  loadBuilders();
  const empty = renderAttachedFiles([]);
  assert.ok(empty.includes('<p'), 'empty list renders a placeholder paragraph');
  const html = renderAttachedFiles([{ originalName: '<b>r</b>.pdf', size: 2048 }]);
  assert.ok(!html.includes('<b>r</b>.pdf'), 'file name must be escaped');
  assert.ok(html.includes('&lt;b&gt;'), 'file name should be HTML-escaped');
  assert.ok(html.includes('2 KB'), 'file size is formatted');
});

test('contactLine: joins phone · email, empty → ""', () => {
  // The document's own rule now, not the renderer's. It moved because the Mac
  // app renders the same invoice and had no copy of it, so every invoice it
  // printed had a blank where the customer's phone and email belong.
  const { contactLine } = require('../lib/invoice-document.js');
  const esc = (x) => String(x);
  assert.equal(contactLine({}, esc), '');
  assert.equal(contactLine(null, esc), '', 'a job with no customer has no line');
  const html = contactLine({ phone: '050', email: 'a@b.c' }, esc);
  assert.ok(html.includes('050') && html.includes('a@b.c'));
  assert.ok(html.includes('·'), 'phone and email are separated by a middot');
});

test('the renderer has not grown its own copy of the contact line back', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'invoicing.js'), 'utf8');
  assert.ok(!/function renderClientSub/.test(src),
    'renderer/invoicing.js must not define renderClientSub — lib/invoice-document.js does');
  assert.ok(!/renderClientSub:/.test(src),
    'and it must not pass one in, or the Mac app and Khayt print different documents');
});

test('renderOeExtraLinesHtml: empty/null → "", renders label + amount', () => {
  loadBuilders();
  assert.equal(renderOeExtraLinesHtml([]), '');
  assert.equal(renderOeExtraLinesHtml(null), '');
  const html = renderOeExtraLinesHtml([{ label: 'Setup', amount: 20 }]);
  assert.ok(html.includes('Setup'), 'extra-line label appears');
  assert.ok(html.includes('data-oeli="0"'), 'extra-line row is indexed');
});

// --- RBAC tab gating (applyOperatorPermissions via the matrix) -----------------
test('RBAC: operator hides settings/analytics, owner sees all, lock-off unrestricted', () => {
  dom.loadI18n();
  require('../lib/rbac.js');               // sets globalThis.KhaytRbac (dual-export)
  require('../renderer/ops-locations.js'); // attaches applyOperatorPermissions

  const settingsBtn = $('[data-tab="settings-tab"]');
  const analyticsBtn = $('[data-tab="analytics-tab"]');
  const clientsBtn = $('[data-tab="clients-tab"]');
  assert.ok(settingsBtn && analyticsBtn && clientsBtn, 'tab buttons exist in index.html');

  // operator under lock → settings + analytics hidden, clients visible (matrix)
  dom.seedState({
    settings: { operatorLockEnabled: true, activeOperatorId: 'op1' },
    operators: [{ id: 'op1', name: 'Sam', roleKey: 'operator' }],
  });
  global.applyOperatorPermissions();
  assert.equal(settingsBtn.style.display, 'none', 'operator: settings hidden');
  assert.equal(analyticsBtn.style.display, 'none', 'operator: analytics hidden');
  assert.equal(clientsBtn.style.display, '', 'operator: clients visible');

  // owner under lock → everything visible
  dom.seedState({
    settings: { operatorLockEnabled: true, activeOperatorId: 'op2' },
    operators: [{ id: 'op2', name: 'Boss', roleKey: 'owner' }],
  });
  global.applyOperatorPermissions();
  assert.equal(settingsBtn.style.display, '', 'owner: settings visible');
  assert.equal(analyticsBtn.style.display, '', 'owner: analytics visible');

  // legacy free-text role 'admin' maps to owner → full access (backward compat)
  dom.seedState({
    settings: { operatorLockEnabled: true, activeOperatorId: 'op3' },
    operators: [{ id: 'op3', name: 'Legacy', role: 'Admin' }], // no roleKey
  });
  global.applyOperatorPermissions();
  assert.equal(settingsBtn.style.display, '', 'legacy admin → owner → settings visible');

  // lock off → unrestricted regardless of role
  dom.seedState({ settings: { operatorLockEnabled: false } });
  global.applyOperatorPermissions();
  assert.equal(settingsBtn.style.display, '', 'lock off: settings visible');
});
