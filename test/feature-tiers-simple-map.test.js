'use strict';
/**
 * S4 (Nov 11 2026): the Simple capability map in lib/feature-tiers.js is the
 * one table the desktop, the Mac and the iPhone will read. This keeps its
 * shape honest while it is under review, and pins the decisions already made.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SIMPLE_MAP, simpleDecision } = require('../lib/feature-tiers.js');

test('every row is well formed and keys are unique', () => {
  const seen = new Set();
  for (const r of SIMPLE_MAP) {
    assert.ok(r.key && !seen.has(r.key), `duplicate or empty key ${r.key}`); seen.add(r.key);
    assert.ok(['work', 'shop', 'money', 'team', 'tools', 'online', 'shell'].includes(r.area), `${r.key}: area ${r.area}`);
    assert.ok(['show', 'reduced', 'pro'].includes(r.simple), `${r.key}: simple ${r.simple}`);
    assert.ok(r.where && ['desktop', 'mac', 'ios'].every((a) => typeof r.where[a] === 'string'), `${r.key}: where for every app`);
    if (r.simple === 'reduced') assert.ok(r.simpleShows && r.proAdds, `${r.key}: a reduced row says what Simple shows and what Pro adds`);
    if (r.today) for (const a of Object.keys(r.today)) assert.ok(['desktop', 'mac', 'ios'].includes(a), `${r.key}: today.${a}`);
  }
});

test('the decisions already made', () => {
  assert.notEqual(simpleDecision('loyalty'), 'pro', 'loyalty is shown in Simple (Turki, Nov 10)');
  for (const k of ['team', 'sites', 'assignment', 'zatca', 'proforma', 'paymentPlans', 'ai', 'developer']) {
    assert.equal(simpleDecision(k), 'pro', k);
  }
  // Simple gets a short Expenses list and a Money page instead of losing both (Mac A10).
  assert.equal(simpleDecision('expenses'), 'reduced');
  assert.equal(simpleDecision('money'), 'reduced');
  assert.equal(simpleDecision('queue'), 'reduced');
  assert.equal(simpleDecision('nope'), undefined);
});
