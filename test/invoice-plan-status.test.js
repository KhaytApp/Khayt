'use strict';
/**
 * The invoice's payment schedule says paid or pending by lib/payment-plan.js
 * allocate, the plan's one rule (money review follow-up, Nov 18): a row only
 * COVERED whose money was later corrected away stays stored `paid: true`,
 * but is owed again, so the invoice must say pending; a row covered by money
 * already received says paid.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { render } = require('./helpers/invoice-harness.js');
const { SHOP, ORDER } = require('./helpers/invoice-cases.js');

const statuses = (html) => {
  const body = html.slice(html.lastIndexOf('<tbody>'), html.lastIndexOf('</tbody>'));
  return [...body.matchAll(/<td[^>]*text-align:center[^>]*>([^<]*)<\/td>/g)].map((m) => m[1].trim());
};

test('a reopened row (stored paid, money corrected away) reads pending; a covered row reads paid', () => {
  const plan = (paid, rows) => Object.assign({}, ORDER, { price: 2120, paidAmount: paid, instalmentBase: 1000, instalments: rows });
  const A = { id: 'A', amount: 373.34, dueDate: '2026-12-18', paid: true, paidAt: '2026-11-18', recorded: true, covered: true };
  const B = { id: 'B', amount: 373.33, dueDate: '2027-01-18', paid: false };
  const reopened = statuses(render(plan(1000, [A, B]), { settings: SHOP }));
  const kept = statuses(render(plan(1373.34, [A, B]), { settings: SHOP }));
  assert.equal(reopened.length, 2);
  assert.notEqual(reopened[0], kept[0], 'A reads differently once the money behind it is gone');
  assert.equal(reopened[0], reopened[1], 'reopened A reads like the unpaid B (pending)');
  // Covered by money already received (A unstamped, 373.34 outside the plan): paid.
  const covered = statuses(render(plan(1373.34, [Object.assign({}, A, { paid: false, recorded: undefined, covered: undefined }), B]), { settings: SHOP }));
  assert.equal(covered[0], kept[0], 'a covered row reads paid');
  assert.equal(covered[1], reopened[1], 'B still pending');
});
