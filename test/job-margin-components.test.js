'use strict';

/**
 * A job's margin counts the components frozen on it (lib/order-new.js
 * componentsCost), as the Mac ledger does. The P&L does not: buying them is
 * already an expense (Mac lane, #1751).
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

test('jobCostForMargin is the parts plus componentsCost', () => {
  const src = read('renderer/logs.js');
  const at = src.indexOf('function jobCostForMargin');
  const fn = src.slice(at, src.indexOf('\n}\n', at) + 2);
  const ctx = vm.createContext({});
  vm.runInContext(fn + '\nthis.f = jobCostForMargin;', ctx);
  assert.equal(ctx.f({ parts: [{ baseCost: 10 }, { baseCost: 5 }], componentsCost: 6 }), 21);
  assert.equal(ctx.f({ parts: [{ baseCost: 10 }] }), 10, 'no components: unchanged');
  assert.equal(ctx.f(null), 0);
});

test('the badge, the margin sort and the AI price assist use it', () => {
  const l = read('renderer/logs.js');
  assert.match(l, /const partsCost = jobCostForMargin\(log\);/);
  assert.match(l, /const costA = jobCostForMargin\(a\);/);
  const b = read('renderer/build.js');
  assert.match(b, /: calculateLivePartCost\(\) \* qty\) \+ compCost;/);
});
