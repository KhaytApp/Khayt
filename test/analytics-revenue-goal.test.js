'use strict';
// The monthly revenue goal (Settings › Business) was settable and shown
// nowhere: its only reader was the original dashboard, which every built-in
// design replaces. It is drawn on Analytics now, in both modes.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'analytics.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

function fnSource(name) {
  const i = src.indexOf(`function ${name}(`);
  assert.ok(i >= 0, name);
  let depth = 0, j = src.indexOf('{', i);
  for (let k = j; k < src.length; k++) {
    if (src[k] === '{') depth++;
    else if (src[k] === '}' && --depth === 0) return src.slice(i, k + 1);
  }
  throw new Error('unterminated ' + name);
}

// The real shared rule: the bar reads `KhaytKpiRows.tradeRevenue`, which the
// Mac's goal reads too.
require('../lib/business-scope.js');
require('../lib/tax.js');
require('../lib/order-money.js');
const KpiRows = require('../lib/kpi-rows.js');

function harness(settings, orders) {
  const ctx = {
    settings, printLog: orders, clients: [],
    KhaytKpiRows: KpiRows,
    localMonthStr: (d) => d.toISOString().slice(0, 7),
    localeTag: () => 'en',
    t: (k) => ({ 'dash.goal': 'Revenue Goal', 'dash.forecast': 'Forecast:', 'dash.forecast_tip': 'tip' })[k] || k,
    escapeHtml: (s) => String(s),
    fmtPrice: (n) => `${(+n).toFixed(2)} SAR`,
    KhaytTiers: { showsBusiness: (m) => m !== 'enthusiast' },
  };
  vm.createContext(ctx);
  vm.runInContext(fnSource('monthTradeRevenue') + '\n' + fnSource('prevMonthTradeRevenue') + '\n' + fnSource('monthGoalHtml'), ctx);
  return ctx;
}

test('the goal bar counts this month\'s trade, forecasts month-end, and hides without a goal', () => {
  const now = new Date(2026, 10, 10, 12); // 10 Nov 2026: day 10 of 30
  const orders = [
    { status: 'completed', date: '2026-11-02', price: 1000 },
    { status: 'completed', date: '2026-11-08', price: 500, voidedAt: '2026-11-09' }, // voided: no
    { status: 'completed', date: '2026-11-08', price: 700, nonBusiness: true },       // own print: no
    { status: 'pending',   date: '2026-11-08', price: 900 },                           // not finished
    { status: 'completed', date: '2026-10-30', price: 4000 },                          // last month
  ];
  const c = harness({ monthlyGoal: 4000, mode: 'professional' }, orders);
  assert.equal(c.monthTradeRevenue(now), 1000);
  const h = c.monthGoalHtml(now);
  assert.match(h, /1000\.00 SAR<\/bdi> \/ <bdi>4000\.00 SAR/);
  assert.match(h, /<bdi>25%<\/bdi>/);
  assert.match(h, /Forecast: <bdi>3000\.00 SAR/); // 1000 over 10 days × 30
  assert.match(h, /aria-valuenow="25"/);
  assert.equal(harness({ monthlyGoal: 0, mode: 'professional' }, orders).monthGoalHtml(now), '');
  assert.equal(harness({ monthlyGoal: 4000, mode: 'enthusiast' }, orders).monthGoalHtml(now), '');
  // Last day of the month: no forecast, the month is what it is.
  assert.doesNotMatch(harness({ monthlyGoal: 4000, mode: 'simple' }, orders).monthGoalHtml(new Date(2026, 10, 30, 12)), /Forecast/);
});

test('both Analytics screens draw it', () => {
  assert.match(html, /<div id="analyticsGoalWrap"><\/div>/);
  assert.match(src, /\$\('#analyticsGoalWrap'\);\n\s*if \(goalWrap\) goalWrap\.innerHTML = monthGoalHtml\(\);/);
  assert.match(fnSource('renderSimpleReports'), /\$\{monthGoalHtml\(\)\}/);
});

test('the bar is net of VAT and says how the month compares with the last', () => {
  const now = new Date(2026, 10, 10, 12);
  const orders = [
    { status: 'completed', date: '2026-11-02', price: 1150 },  // 1000 + 15% inclusive
    { status: 'completed', date: '2026-10-12', price: 575 },   // last month: 500 net
  ];
  const settings = { monthlyGoal: 4000, mode: 'professional', enableVat: true, vatRate: 15,
    tax: { country: 'SA', name: 'VAT', mode: 'inclusive', rates: [{ id: 'vat', label: 'VAT', percent: 15 }] } };
  const c = harness(settings, orders);
  assert.equal(c.monthTradeRevenue(now), 1000);
  assert.equal(c.prevMonthTradeRevenue(now), 500);
  assert.match(c.monthGoalHtml(now), /\u25b2 100%/);
});
