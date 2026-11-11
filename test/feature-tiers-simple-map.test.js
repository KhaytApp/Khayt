'use strict';
/**
 * S4 (Nov 11 2026): the Simple capability map in lib/feature-tiers.js is the
 * one table the desktop, the Mac and the iPhone will read. This keeps its
 * shape honest while it is under review, and pins the decisions already made.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { SIMPLE_MAP, GATE_ROWS, PRO_FEATURES, simpleDecision } = require('../lib/feature-tiers.js');

const APPS = ['desktop', 'mac', 'ios'];

test('every row is well formed and keys are unique', () => {
  const seen = new Set();
  for (const r of SIMPLE_MAP) {
    assert.ok(r.key && !seen.has(r.key), `duplicate or empty key ${r.key}`); seen.add(r.key);
    assert.ok(['work', 'shop', 'money', 'team', 'tools', 'online', 'shell'].includes(r.area), `${r.key}: area ${r.area}`);
    assert.ok(['show', 'reduced', 'pro'].includes(r.simple), `${r.key}: simple ${r.simple}`);
    assert.ok(r.today && APPS.every((a) => typeof r.today[a] === 'string'), `${r.key}: today names for every app`);
    assert.ok(APPS.some((a) => r.today[a]), `${r.key}: lives in at least one app`);
    if (r.simple === 'reduced') assert.ok(r.simpleShows && r.proAdds, `${r.key}: a reduced row says what Simple shows and what Pro adds`);
    for (const k of ['afterS2', 'simpleNow']) if (r[k]) for (const a of Object.keys(r[k])) assert.ok(APPS.includes(a), `${r.key}: ${k}.${a}`);
  }
});

test('the five gates the apps read each belong to one row', () => {
  assert.deepEqual(Object.keys(GATE_ROWS).sort(), ['analytics', 'expenses', 'maintenance', 'purchasing', 'zatca']);
  for (const [gate, key] of Object.entries(GATE_ROWS)) {
    const row = SIMPLE_MAP.find((r) => r.key === key);
    assert.ok(row && row.gate === gate, `${gate} → ${key}`);
  }
  // money and expenses become reduced (Dev Hub, Nov 11), not hidden.
  assert.equal(simpleDecision(GATE_ROWS.analytics), 'reduced');
  assert.equal(simpleDecision(GATE_ROWS.expenses), 'reduced');
  assert.equal(simpleDecision(GATE_ROWS.maintenance), 'pro');
  assert.equal(simpleDecision(GATE_ROWS.zatca), 'pro');
});

test('the decisions already made', () => {
  // Turki, Nov 11: loyalty in Simple as up to 3 tiers by completed orders; connectors stay visible.
  assert.equal(simpleDecision('loyalty'), 'reduced');
  assert.match(SIMPLE_MAP.find((r) => r.key === 'loyalty').simpleShows, /up to 3 tiers by completed orders/);
  assert.equal(simpleDecision('connectors'), 'show');
  // After S2 it is its own pane under Connected (Mac frame 95:605).
  assert.equal(SIMPLE_MAP.find((r) => r.key === 'connectors').afterS2.mac, 'Connectors');
  for (const r of SIMPLE_MAP) if (r.afterS2) for (const v of Object.values(r.afterS2)) assert.ok(!v.includes('?'), `${r.key}: afterS2 is decided`);
  // The simplified-invoice QR always prints; ZATCA Phase 2 is Pro.
  assert.equal(simpleDecision('invoices'), 'show');
  assert.match(SIMPLE_MAP.find((r) => r.key === 'invoices').simpleShows, /simplified-invoice QR always prints/);
  for (const k of ['team', 'staffPins', 'sites', 'assignment', 'zatca', 'proforma', 'paymentPlans', 'ai', 'developer', 'schedule', 'kiosk', 'campaigns', 'machineUpkeep']) {
    assert.equal(simpleDecision(k), 'pro', k);
  }
  for (const k of ['queue', 'quote', 'customers', 'inventory', 'money', 'expenses', 'vatReturns']) assert.equal(simpleDecision(k), 'reduced', k);
  assert.equal(simpleDecision('nope'), undefined);
  // Every Pro feature in the comparison is covered by some row.
  assert.ok(PRO_FEATURES.length > 0);
});
