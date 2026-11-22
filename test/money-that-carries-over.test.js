'use strict';
/**
 * Two money defects that persist past the job they belong to.
 *
 * Found by an audit of the quoting arithmetic. Both are unambiguous — there is
 * one correct answer and the rest of the codebase already implements it — which
 * is why they are fixed here while the modelling questions the same audit raised
 * (is packaging per order or per part? is the quote currency a label or a
 * conversion?) are left for a decision rather than guessed at.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');

test('the calculator is fed the spool SIZE, not what is left of it', () => {
  /* `item.weight` is REMAINING grams — the inventory editor calls it
   * "Remaining (g)" and every completed job decrements it. The calculator
   * computes `(spoolCost / spoolWeight) x grams`, so a partly-used spool valued
   * the material at whatever fraction remained:
   *
   *     1000 g left ->  9.00     250 g left -> 36.00     50 g left -> 180.00
   *
   * for the same 100 g part off the same SAR 90 kilo. */
  const build = read('renderer/build.js');
  const at = build.indexOf('function populateFilamentDropdown()');
  assert.ok(at > -1, 'populateFilamentDropdown is gone');
  const body = build.slice(at, at + 1800);
  assert.ok(!/data-weight="\$\{item\.weight\}"/.test(body),
    'the dropdown still carries the REMAINING weight, so every quote off a used spool over-charges');
  assert.match(body, /data-weight="\$\{Math\.max\(1, \+item\.spoolWeight \|\| 1000\)\}"/,
    'the dropdown no longer carries the spool size');
});

test('every other cost site already divides by the spool size', () => {
  // The reason the above has one right answer rather than two defensible ones.
  //
  // The drafting side of it now lives in `lib/reorder.js` (the renderer calls
  // `perGramPriceFor`) and the audit that hunts the old mistake still has its
  // own copy of the division, deliberately: it is checking what a price SHOULD
  // have been, and a shared helper it also fed would agree with itself.
  assert.match(read('lib/reorder.js'), /perSpool \/ Math\.max\(1, \+row\.spoolWeight \|\| 1000\)/);
  assert.match(read('lib/po-audit.js'), /perSpool \/ Math\.max\(1, \+item\.spoolWeight \|\| 1000\)/);

  // And the two agree on the figure, which is the property those two lines are
  // standing in for.
  const { perGramPriceFor } = require('../lib/reorder.js');
  const item = { material: 'PLA+', cost: 85, spoolWeight: 1000 };
  assert.equal(perGramPriceFor(item, []).perG, 0.085);
});

test('the rush fee does not survive the job it was for', () => {
  /* Every other money field on the calculator is cleared after logging and this
   * one was not — nothing in the app ever unchecked it. One rush job left +25%
   * on every subsequent quote until somebody noticed the checkbox. */
  const src = read('renderer/order-flows.js');
  const at = src.indexOf("$('#discountPct').value = '0';");
  assert.ok(at > -1, 'the post-log reset moved — check the rush fee is still cleared');
  const reset = src.slice(at, at + 900);
  assert.match(reset, /#calcRushFee/,
    'the rush fee is not cleared with the other money fields, so it carries into the next quote');
  assert.match(reset, /rush\.checked = false/);
});
