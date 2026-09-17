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
  require('../lib/cost-trends.js');  // globalThis.KhaytCostTrends
  require('../lib/cycle-time.js');   // globalThis.KhaytCycleTime
  require('../lib/waste-trend.js');  // globalThis.KhaytWasteTrend
  require('../lib/on-time.js');      // globalThis.KhaytOnTime
  require('../lib/client-value.js'); // globalThis.KhaytClientValue
  // The machine charts ask it whether a job is finished — both spellings.
  require('../lib/order-status.js'); // globalThis.KhaytOrderStatus
  require('../lib/capacity.js');     // globalThis.KhaytCapacity
  require('../lib/quote-funnel.js'); // globalThis.KhaytQuoteFunnel
  require('../lib/product-profit.js'); // globalThis.KhaytProductProfit
  require('../lib/calculator-cost.js'); // partTotalCost, which product profit costs with
  require('../lib/customer-mix.js'); // globalThis.KhaytCustomerMix
  require('../lib/throughput.js');   // globalThis.KhaytThroughput
  require('../lib/working-week.js'); // globalThis.KhaytWorkingWeek, which it reads the open days from
  require('../lib/supplier-prices.js'); // globalThis.KhaytSupplierPrices
  require('../lib/maintenance-cost.js'); // globalThis.KhaytMaintenanceCost
  require('../lib/rating-trend.js'); // globalThis.KhaytRatingTrend
  // Both are reached only once a book has an expense in it, which is why they
  // were missing here until a test seeded one.
  require('../lib/expense-categories.js'); // globalThis.KhaytExpenseCategories
  require('../lib/pnl-report.js'); // globalThis.KhaytPnl
  // The category chart labels its slices with the expenses screen's helper,
  // which is a plain global in the app.
  require('../renderer/expenses.js'); // expCatLabel
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

test('renderSupplierPriceHistory: a material bought in two units draws two cards', () => {
  loadAnalyticsStack();
  dom.seedState({
    settings: { currency: 'SAR', fixedCosts: [] },
    suppliers: [{
      name: 'Acme',
      purchases: [
        { materialType: 'PLA', unit: 'spool', unitPrice: 75, date: '2026-01-01' },
        { materialType: 'PLA', unit: 'kg', unitPrice: 22, date: '2026-02-01' },
        { materialType: 'PLA', unit: 'g', unitPrice: 0.02, date: '2026-03-01' },
      ],
    }],
  });
  global.renderSupplierPriceHistory();
  const html = $('#supplierPriceHistoryChart').innerHTML;

  // Two comparable sets, so two sparkline cards and two table rows.
  assert.equal(html.match(/<svg /g).length, 2, 'one sparkline per unit family');
  assert.equal(html.match(/<tr>/g).length, 2, 'one best-price row per unit family');

  // The by-the-gram purchase is shown as what it is per kilogram, beside the
  // kilogram purchase it can actually be compared with.
  assert.ok(html.includes('20.00/kg'), 'the gram price is converted, not plotted raw');
  assert.ok(!html.includes('0.02'), 'and never shown against a per-spool price');

  // The move from 22/kg to 20/kg is a 9.1% fall. Before the split it was read
  // as 22 → 0.02 and badged as the price collapsing.
  assert.ok(html.includes('9.1%'), 'the trend badge compares like with like');
  assert.ok(!html.includes('99.9%'), 'and no longer reports a unit change as a price change');

  // The spool stands alone: in its own row it is both the best and the worst,
  // so it can never be undercut by a supplier that merely sells smaller.
  const spoolRow = html.match(/<tr>(?:(?!<\/tr>)[\s\S])*\/spool[\s\S]*?<\/tr>/)[0];
  assert.equal(spoolRow.match(/75\.00/g).length, 2, 'the spool is its own best and worst');
  assert.ok(!spoolRow.includes('20.00'), 'the per-kilogram price is not in the spool row');
});

test('renderMaintenanceCostChart: draws the services the shop actually logged', () => {
  loadAnalyticsStack();
  const year = new Date().getFullYear();
  dom.seedState({
    settings: { currency: 'SAR', fixedCosts: [] },
    machines: [{ id: 'm1', name: 'U1' }, { id: 'm2', name: 'CORE One' }],
    // The book's own list, keyed by machineId — where the machine screen
    // writes a service, and what the chart used to miss entirely.
    machMaintLog: [
      { id: 'a', machineId: 'm1', date: `${year}-02-10`, note: 'nozzle', cost: 40 },
      { id: 'b', machineId: 'm2', date: `${year}-03-04`, note: 'PTFE', cost: 90 },
      { id: 'c', machineId: 'm2', date: `${year - 1}-11-02`, note: 'last year', cost: 500 },
    ],
  });
  global.renderMaintenanceCostChart();
  const html = $('#maintenanceCostChart').innerHTML;

  assert.ok(!html.includes('No data yet'), 'the chart is no longer empty for a shop that logs services');
  assert.equal(html.match(/<rect /g).length, 2, 'a bar per machine with spending');
  assert.ok(html.includes('CORE One'), 'the bigger spender is drawn');
  assert.ok(html.includes('U1'));
  assert.ok(!html.includes('500'), 'last year is not counted against this one');
});

test('renderAnalytics: a delivered job is finished revenue, like a completed one', () => {
  // `delivered` is the other spelling of finished. The revenue bar chart, the
  // client-source split and the machine charts counted only `completed`, so a
  // shop that marked its work delivered saw part of its own takings vanish.
  const month = `${new Date().getFullYear()}-${String(new Date().getMonth() + 1).padStart(2, '0')}`;
  const book = status => ({
    settings: { currency: 'SAR', fixedCosts: [] },
    printLog: [
      { id: 'a', status: 'completed', date: `${month}-02`, price: 100, printTime: 1, clientId: null },
      { id: 'b', status, date: `${month}-03`, price: 300, printTime: 2, clientId: null },
    ],
  });

  loadAnalyticsStack();
  dom.seedState(book('delivered'));
  global.renderAnalytics();
  const withDelivered = $('#revenueChartWrap').innerHTML;

  loadAnalyticsStack();
  dom.seedState(book('completed'));
  global.renderAnalytics();
  const withCompleted = $('#revenueChartWrap').innerHTML;

  assert.equal(withDelivered, withCompleted,
    'the revenue chart must not care which spelling of finished a job carries');

  // And an unfinished job is still not revenue.
  loadAnalyticsStack();
  dom.seedState(book('printing'));
  global.renderAnalytics();
  assert.notEqual($('#revenueChartWrap').innerHTML, withCompleted,
    'a job still on the printer has not earned anything yet');
});

test('renderAnalytics: the "Net profit" KPI is net of expenses, like the P&L below it', () => {
  // It used to be `revenue - partTotalCost`: a gross margin under the words
  // "Net profit", bigger than the net profit in the P&L section on the same
  // screen by exactly the expenses it ignored.
  loadAnalyticsStack();
  const month = `${new Date().getFullYear()}-${String(new Date().getMonth() + 1).padStart(2, '0')}`;
  const seed = expenses => {
    dom.seedState({
      settings: { currency: 'SAR', mode: 'professional', fixedCosts: [] },
      // A real range, not 'all' — otherwise nothing is ever out of it.
      analyticsRange: 'year',
      printLog: [{
        id: 'a', status: 'completed', date: `${month}-02`, price: 1000, printTime: 1,
        clientId: null, parts: [{ qty: 1, filamentCost: 200 }],
      }],
      expenses,
    });
    // The KPI row only renders on the redesigned screen for a professional shop.
    document.body.classList.add('bedready-ui');
    global.renderAnalytics();
    return $('#analyticsHandoffWrap').innerHTML;
  };

  const withNoExpenses = seed([]);
  assert.ok(withNoExpenses.length > 0, 'the KPI row should render for a professional shop');

  const withExpenses = seed([
    { id: 'e1', date: `${month}-05`, amount: 300, category: 'Rent' },
  ]);
  assert.notEqual(withExpenses, withNoExpenses,
    'recording an expense must move the net profit figure');

  // And an expense outside the range must not.
  const lastYear = seed([
    { id: 'e2', date: `${new Date().getFullYear() - 1}-05-05`, amount: 300, category: 'Rent' },
  ]);
  assert.equal(lastYear, withNoExpenses,
    'an expense outside the selected range is not this period\'s cost');
});

test('renderNpsTrendChart: the caption describes the six months drawn above it', () => {
  loadAnalyticsStack();
  const now = new Date();
  const m = back => {
    const d = new Date(now.getFullYear(), now.getMonth() - back, 15, 12);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  };
  const rated = (month, rating) => ({
    id: `O${month}${rating}`, status: 'completed', date: `${month}-15`,
    completedAt: `${month}-15T12:00:00.000Z`, survey: { rating }, printTime: 1, price: 10,
  });

  dom.seedState({
    settings: { currency: 'SAR', fixedCosts: [] },
    printLog: [
      // Two years ago, when the shop was worse. Off the left of the chart.
      rated('2024-03', 1), rated('2024-04', 1), rated('2024-05', 1),
      // The window: three fives.
      rated(m(0), 5), rated(m(1), 5), rated(m(2), 5),
    ],
  });
  global.renderNpsTrendChart();
  const html = $('#npsTrendChart').innerHTML;

  assert.ok(html.includes('5.0 / 5'),
    'the average under a line of 5.0 dots must be 5.0, not the all-time 3.0');
  assert.ok(html.includes('>3 '), 'three responses fall in the window, not six');
  assert.ok(!html.includes('3.0 / 5'));
});

test('renderNpsTrendChart: a rating on a job with no completedAt still counts', () => {
  loadAnalyticsStack();
  const now = new Date();
  const month = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
  dom.seedState({
    settings: { currency: 'SAR', fixedCosts: [] },
    printLog: [1, 2, 3].map(i => ({
      // A legacy delivered job: rated, and carrying no completedAt at all.
      id: `L${i}`, status: 'delivered', date: `${month}-0${i}`,
      survey: { rating: 4 }, printTime: 1, price: 10,
    })),
  });
  global.renderNpsTrendChart();
  const html = $('#npsTrendChart').innerHTML;
  assert.ok(!html.includes('No data yet'), 'three real ratings were being thrown away');
  assert.ok(html.includes('4.0 / 5'));
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
