const { test } = require('node:test');
const assert = require('node:assert/strict');
// The shared modules analytics.js reaches through globals. In the app they are
// `<script>` tags in index.html; here they have to be loaded by hand, and a
// missing one shows up as `ReferenceError: KhaytX is not defined` from inside
// whichever function needs it.
require('../lib/break-even.js');
const analytics = require('../renderer/analytics.js');

test('KhaytAnalytics exports analytics tab entry points', () => {
  for (const name of [
    'renderAnalytics',
    'renderSimpleReports',
    'renderRevenueChart',
    'renderPnLSection',
    'renderClientSourceChart',
    'renderClientRetention',
    'renderCapacityGauge',
    'computeBreakEven',
    'exportAnalyticsReport',
  ]) {
    assert.equal(typeof analytics[name], 'function', name);
  }
});

test('computeBreakEven returns null when no fixed costs', () => {
  const prev = global.settings;
  global.settings = { fixedCosts: [] };
  assert.equal(analytics.computeBreakEven(), null);
  global.settings = prev;
});

/**
 * THE FIXTURE HERE CHANGED WITH THE ARITHMETIC, AND THAT IS THE POINT.
 *
 * It used to give the part a `filamentId` and price it off `inventory`, which
 * is what the inline rule did — and that rule SKIPPED any part with no
 * `filamentId`, so an unlinked part cost nothing, the margin came out too high
 * and the break-even target came out too LOW. A shop was told to bill less than
 * it must, on a figure whose whole job is to be a floor.
 *
 * `lib/break-even.js` costs a part through `calculator-cost`, which prices from
 * the spool carried ON the part. So the fixture carries one.
 */
test('computeBreakEven estimates revenue target from recent margin', () => {
  require('../renderer/util.js');
  require('../renderer/format.js');
  require('../renderer/currency.js');
  require('../lib/calculator-cost.js');
  require('../lib/order-money.js');
  const prev = {
    settings: global.settings,
    printLog: global.printLog,
    inventory: global.inventory,
    clients: global.clients,
  };
  global.settings = { currency: 'SAR', fixedCosts: [{ amount: 1000 }] };
  global.clients = [];
  global.inventory = [{ id: 'f1', cost: 50, weight: 1000 }];
  global.printLog = [{
    status: 'completed',
    date: new Date().toISOString().slice(0, 10),
    price: 200,
    // 1000 g of spool at 50 → 5 for the 100 g this part used.
    parts: [{ filamentId: 'f1', printWeight: 100, spoolCost: 50, spoolWeight: 1000, qty: 1 }],
  }];
  const result = analytics.computeBreakEven();
  assert.ok(result);
  assert.equal(result.totalFixed, 1000);
  assert.ok(result.avgRevPerOrder > 0);
  assert.ok(result.breakEvenRevenue > result.totalFixed,
    'the target must exceed the fixed costs, because making the work costs something');
  assert.ok(result.avgMarginPct < 1,
    'a margin of exactly 1 means the work was costed as free — the bug this replaced');
  global.settings = prev.settings;
  global.printLog = prev.printLog;
  global.inventory = prev.inventory;
  global.clients = prev.clients;
});
