const { test } = require('node:test');
const assert = require('node:assert/strict');
// renderer/util.js registers localDateStr() and friends as globals. These
// modules format dates with it — in the browser util.js is loaded first by
// index.html; under node the test has to establish the same contract.
require('../renderer/util.js');

test('calcNextDueDate advances monthly recurring date', () => {
  const { calcNextDueDate } = require('../renderer/expenses.js');
  assert.equal(calcNextDueDate('2026-01-15', 'monthly'), '2026-02-15');
});

test('monthly recurring stays on its anchor day across cycles (no drift to today)', () => {
  const { calcNextDueDate } = require('../renderer/expenses.js');
  // Roll-forward anchors on the existing nextDue, not on "today". Simulate a
  // user who clicks Add/Skip days after the due date — the schedule must keep
  // landing on the 15th, not drift to the click date.
  let nextDue = '2026-01-15';
  nextDue = calcNextDueDate(nextDue, 'monthly');
  assert.equal(nextDue, '2026-02-15');
  nextDue = calcNextDueDate(nextDue, 'monthly');
  assert.equal(nextDue, '2026-03-15');
  nextDue = calcNextDueDate(nextDue, 'monthly');
  assert.equal(nextDue, '2026-04-15');
  // Day-of-month is preserved across many cycles regardless of when processed.
  for (let i = 0; i < 8; i++) nextDue = calcNextDueDate(nextDue, 'monthly');
  assert.equal(nextDue.slice(8), '15');
});

test('KhaytExpenses and KhaytWaste export tab helpers', () => {
  const expenses = require('../renderer/expenses.js');
  const waste = require('../renderer/waste.js');
  assert.equal(typeof expenses.renderExpenses, 'function');
  assert.equal(typeof expenses.buildProfitabilityHtml, 'function');
  assert.equal(typeof waste.renderWasteLog, 'function');
});
