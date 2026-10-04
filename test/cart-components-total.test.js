'use strict';

/**
 * A product's components are in the calculator's total, the way the saved job
 * prices them (lib/order-new.js since #1745). Found by the Mac lane's review:
 * the cart showed 144.49 and the job was saved at 153.49.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');

test('the cart adds the components to its costed base, by the job\'s own rule', () => {
  const b = read('renderer/build.js');
  const at = b.indexOf('function updateGrandTotal');
  const body = b.slice(at, at + 12000);
  assert.match(body, /KhaytOrderNew\.componentsCost\(currentComponents, currentAssemblyQty,/);
  assert.match(body, /totalBase \+= componentsBase;\n\s+totalCost \+= componentsBase;/);
  // Added before quoteTotal, so the margin applies to it exactly as newOrder does.
  assert.ok(body.indexOf('totalBase += componentsBase') < body.indexOf('KhaytPricing.quoteTotal('));
  for (const page of ['renderer/index.html', 'renderer/bedready.html']) assert.match(read(page), /id="calcComponentsLine"/, page);
  const n = read('lib/order-new.js');
  assert.match(n, /const costedBase = parts\.reduce\([^\n]*\) \+ compCost;/, 'the job adds them to the same costed half');
});
