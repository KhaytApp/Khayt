'use strict';
/**
 * A job's cost comes from ONE place, lib/order-money.js jobCost /
 * jobFixedCost (Dev Hub, Nov 19). This ratchet pins every remaining direct
 * read of the order-level cost fields (componentsCost, overheadCost,
 * labourCost, packagingCost), per file: the ones left are writers (newOrder,
 * the web store), copiers (reprint, duplicate), the calculator's own state,
 * and the edit pricer's overhead rescale. A new reader fails it: sum a job's
 * cost through jobCost instead. The count only shrinks.
 * Calls of the componentsCost() FUNCTION are not reads and are not counted.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const ALLOWED = {
  'lib/order-money.js': 4,      // jobFixedCost: the one reader
  'lib/order-new.js': 2,        // writes them
  'lib/store-order-job.js': 5,  // writes the web store job's componentsCost
  'lib/reprint.js': 6,          // copies a once-labour job's figures to its reprint
  'lib/order-edit.js': 13,      // applyParts rescales overheadCost with the hours; repriceFromParts (#2576) rebuilds newOrder's INPUT from the stored components, overhead, labour and packaging
  'lib/kpi-rows.js': 1,         // a comment saying why it does NOT add componentsCost
  'lib/quote-sheet.js': 1,      // q.packagingCost: a quote sheet's own input, not a job's
  'renderer/build.js': 6,       // the calculator's currentFixedCosts state, and its per-product groups (syncFixedCosts)
  'renderer/inventory.js': 8,   // catalogue → calculator: productJobParts' figures, kept as a group
  'renderer/order-flows.js': 14, // newOrder's input, and duplicate / reprint copies (one group)
  'renderer/logs.js': 1,         // jobCostForMargin's fallback where order-money is not loaded (the old formula)
};
const RE = /\.(componentsCost|overheadCost|labourCost|packagingCost)\b(?!\s*\()/g;

function files(dir) {
  const out = [];
  for (const e of fs.readdirSync(path.join(ROOT, dir), { withFileTypes: true })) {
    const rel = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== 'locales' && e.name !== 'vendor') out.push(...files(rel)); }
    else if (e.name.endsWith('.js')) out.push(rel);
  }
  return out;
}

test('a job\'s cost is summed through lib/order-money.js jobCost, not read field by field', () => {
  const found = {};
  for (const rel of files('renderer').concat(files('lib'), ['main.js'])) {
    const n = (fs.readFileSync(path.join(ROOT, rel), 'utf8').match(RE) || []).length;
    if (n) found[rel.split(path.sep).join('/')] = n;
  }
  assert.deepEqual(found, ALLOWED, 'a new direct read of componentsCost / overheadCost / labourCost / packagingCost: use KhaytOrderMoney.jobCost / jobFixedCost');
});
