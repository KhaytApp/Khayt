'use strict';
/**
 * Two money loops over printLog had no business gate.
 *
 * 1. clientLoyaltyPoints checked `status === 'completed'` and NOTHING ELSE. A
 *    voided order earned points. So did a print the shop marked as not
 *    business, and so did an order refunded in full by a credit note, because
 *    the loop read the GROSS PRICE. Points are a liability the shop honours, so
 *    it was granting a discount on money it never kept. On a client with one
 *    kept sale, one void, one personal print and one refund:
 *
 *        points awarded today  : 3476
 *        points actually earned:  869
 *
 *    It also summed prices from different currencies into one total.
 *
 * 2. The margin-by-month report was the one other money loop over printLog with
 *    no `countsForBusiness` — a personal print with a cost basis appeared in it
 *    while being excluded from every other revenue figure.
 *
 * Both found by sweeping for loops over the order book that touch a money field
 * and never mention the gate, rather than by reading them one at a time.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const KhaytTax = require('../lib/tax.js');
const KhaytLoyalty = require('../lib/loyalty.js');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

/** clientLoyaltyPoints, lifted from the shipped source and given what it reads. */
function loadPoints(printLog) {
  const src = read('renderer/clients.js');
  const at = src.indexOf('function clientLoyaltyPoints(');
  assert.ok(at > 0, 'clientLoyaltyPoints is gone');
  const body = src.slice(at, src.indexOf('\n}', at) + 2);

  // business-scope and currency first — the chokepoint gates on both, and a
  // sandbox missing them would skip the gates and pass while the app did not.
  const sandbox = { globalThis: null, window: {}, module: { exports: {} }, console };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(read('lib/business-scope.js'), sandbox, { filename: 'business-scope.js' });
  sandbox.module = { exports: {} };
  // order-money.js first: currency.js's rules moved there so the Mac app
  // could share them, and it delegates through the global. In a sandbox
  // there is no require, so the dependency has to be run in here too.
  vm.runInContext(read('lib/order-money.js'), sandbox, { filename: 'order-money.js' });
  vm.runInContext(read('renderer/currency.js'), sandbox, { filename: 'currency.js' });
  Object.assign(sandbox, {
    KhaytTax,
    KhaytLoyalty,
    printLog,
    settings: { loyaltyEnabled: true, loyaltyPointsPerUnit: 1, enableVat: true, vatRate: 15, currency: 'SAR' },
    getClientTier: () => null,
  });
  const fn = new vm.Script(`${body}; clientLoyaltyPoints`).runInContext(sandbox);
  return fn;
}

const sale = (over = {}) => ({ id: 'O', clientId: 'C-1', status: 'completed', price: 1000, ...over });

test('only a kept sale earns points', () => {
  const one = loadPoints([sale({ id: 'A' })])('C-1');
  assert.ok(one > 0, 'setup: a plain sale must earn something');

  const all = loadPoints([
    sale({ id: 'A' }),
    sale({ id: 'B', voidedAt: '2026-08-01' }),
    sale({ id: 'C', nonBusiness: true }),
    sale({ id: 'D', creditNotes: [{ amount: 1000 }] }),
  ])('C-1');
  assert.equal(all, one, `three non-sales earned points (${all} vs ${one})`);
});

test('a voided order earns nothing', () => {
  assert.equal(loadPoints([sale({ voidedAt: '2026-08-01' })])('C-1'), 0);
});

test('a print marked not-business earns nothing', () => {
  assert.equal(loadPoints([sale({ nonBusiness: true })])('C-1'), 0);
});

test('a full refund earns nothing, and a partial one earns less', () => {
  assert.equal(loadPoints([sale({ creditNotes: [{ amount: 1000 }] })])('C-1'), 0);
  const part = loadPoints([sale({ creditNotes: [{ amount: 400 }] })])('C-1');
  const full = loadPoints([sale()])('C-1');
  assert.ok(part > 0 && part < full, `a partial refund earned ${part} against ${full}`);
});

test('a parent replaced by its split earns nothing — its children do', () => {
  assert.equal(loadPoints([sale({ status: 'split', splitInto: ['a'] })])('C-1'), 0,
    'a split parent is not a completed sale');
});

test('another client\'s orders are not counted', () => {
  assert.equal(loadPoints([sale({ clientId: 'C-2' })])('C-1'), 0);
});

test('the margin report excludes a personal print', () => {
  // The margin is the P&L rule's now (lib/pnl-report.js, 2026-09-16), and the
  // P&L's own guard covers the trade gate for every figure it produces; what
  // is pinned here is that the renderer draws from it rather than looping
  // over the order book with a gate of its own to forget.
  const src = code('renderer/analytics.js');
  const at = src.indexOf('function renderProfitMarginChart');
  assert.ok(at > 0, 'the margin-by-month report is gone');
  const body = src.slice(at, at + 1600);
  assert.match(body, /KhaytPnl\.pnlByPeriod\(/, 'the margin report asks the P&L rule');
  assert.doesNotMatch(body, /for \(const o of printLog\)/, 'and keeps no money loop of its own');
});

test('no money loop over the order book is left ungated', () => {
  // The sweep that found both, kept as a guard so the next one is caught here.
  const files = fs.readdirSync(path.join(ROOT, 'renderer')).filter((f) => f.endsWith('.js'));
  const offenders = [];
  for (const f of files) {
    const src = code(path.join('renderer', f));
    for (const m of src.matchAll(/for \(const (\w+) of (printLog|pl)\)\s*\{/g)) {
      const v = m[1];
      let depth = 1; let i = m.index + m[0].length;
      while (i < src.length && depth) { if (src[i] === '{') depth++; else if (src[i] === '}') depth--; i++; }
      const body = src.slice(m.index + m[0].length, i);
      if (body.length > 3000) continue;
      const touchesMoney = new RegExp(`\\+${v}\\.price|${v}\\.price \\|\\|`).test(body);
      const gated = /countsForBusiness|nonBusiness|orderNetRevenueBase|orderOwedBase/.test(body);
      if (touchesMoney && !gated) offenders.push(`renderer/${f}`);
    }
  }
  assert.deepEqual(offenders, [],
    'a loop over the order book reads a price without excluding non-business prints');
});
