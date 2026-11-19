'use strict';
/**
 * Every place that costs a job's part again, counted per file (money review
 * of #2581). A part from a product that charges its labour and packaging ONCE
 * carries `orderLevelCosts: true`, and lib/calculator-cost.js leaves both out
 * of it, so costing a part is safe. What is NOT safe is summing a job's parts
 * and stopping there: the order's labourCost / packagingCost then go missing
 * (break-even, the profitability card and the dashboard's cost of goods each
 * did). A new reference here fails this test: where it sums a JOB, add
 * KhaytOrderMoney.jobFixedCost(order, …) as the readers beside it do, then
 * raise the count. A removed one must be lowered, so the list only shrinks.
 * References, not calls: `partCostOf: partTotalCost` hands it on.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');

const ALLOWED = {
  // References, comments included (a reference in a comment is cheap to count
  // and costs one edit to move).
  'lib/ai-quote.js': 1,
  'lib/break-even.js': 1, // + jobFixedCost (once labour and packaging)
  'lib/depreciation.js': 1,
  'lib/kpi-rows.js': 3, // orderCost: + the once packaging
  'lib/lan-library.js': 1, // a library quote: one part, no job
  'lib/lan-rest.js': 2, // the LAN quote route: one part, no job
  'lib/lan-server.js': 4,
  'lib/location-pl.js': 1,
  'lib/pnl-report.js': 2, // stockShare: + the once packaging (pnlByPeriod)
  'lib/print-energy.js': 1,
  'lib/print-rates.js': 1,
  'lib/product-pricing.js': 9, // the catalogue itself
  'lib/public-quote.js': 2, // a public quote: one part, no job
  'lib/reprint.js': 2, // a copy keeps labourCost / packagingCost
  'lib/store-order-job.js': 3, // a store order: no product rates
  'renderer/analytics.js': 8, // COGS + once packaging; partCostOf handed to product profit / break-even, which add it
  'renderer/build.js': 4, // the cart: + onceFixedCost() × costedShare
  'renderer/color-planner.js': 3,
  'renderer/expenses.js': 2, // profitability card: + jobFixedCost
  'renderer/integrations.js': 1,
  'renderer/inventory.js': 2, // a product without its own rates
  'renderer/job-sheet.js': 2, // costed(): marks the part on a once-job
  'renderer/operations-extras.js': 1,
  'renderer/order-flows.js': 4, // duplicate / reprint: keep the once-costs
};

function files(dir) {
  const out = [];
  for (const e of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
    const rel = path.join(dir, e.name);
    if (e.isDirectory()) { if (!['locales', 'vendor', 'themes'].includes(e.name)) out.push(...files(rel)); }
    else if (e.name.endsWith('.js')) out.push(rel);
  }
  return out;
}

test('every place a job\'s part is costed again is counted (and sums the order\'s once-costs)', () => {
  const re = /(?<!function\s)\b(partTotalCost|computePartBaseCost|computePartBreakdown)\b(?!\s*[:,]\s*\w+\s*[,}])/g;
  const found = {};
  for (const f of files('renderer').concat(files('lib'), ['main.js'])) {
    if (f === 'lib/calculator-cost.js') continue;
    const n = (fs.readFileSync(path.join(ROOT, f), 'utf8').match(re) || []).length;
    if (n) found[f.split(path.sep).join('/')] = n;
  }
  assert.deepEqual(found, ALLOWED, 'a new place costs a job\'s part again: if it sums a job, add KhaytOrderMoney.jobFixedCost (see the header)');
});
