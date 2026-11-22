/**
 * Categories the iPhone saved before its expense sheet was fixed — `power`,
 * `rent`, `resin`, `parts` — are read as what they meant (lib/expense-book.js
 * `categoryOf`), by every reader: totals, budgets, the category chart, the P&L
 * and the accounting export. Nothing stored is rewritten.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Book = require('../lib/expense-book.js');
const { byCategory } = require('../lib/expense-categories.js');
const { computePnl } = require('../lib/pnl-report.js');
const { mapCategoryAccount } = require('../lib/accounting-export.js');

test('the map: power → electricity, parts → maintenance, rent and resin → other', () => {
  assert.deepEqual({ ...Book.CATEGORY_ALIASES },
    { power: 'electricity', parts: 'maintenance', rent: 'other', resin: 'other' });
  for (const meant of Object.values(Book.CATEGORY_ALIASES)) {
    assert.ok(Book.CATEGORIES.includes(meant), `${meant} is a category the book knows`);
  }
  assert.equal(Book.categoryOf({ category: 'power' }), 'electricity');
  assert.equal(Book.categoryOf({ category: 'parts' }), 'maintenance');
  assert.equal(Book.categoryOf({ category: 'rent' }), 'other');
  assert.equal(Book.categoryOf({ category: 'resin' }), 'other');
});

test('resin is never filament: filament is stock, resin is not tracked as stock', () => {
  assert.notEqual(Book.categoryOf({ category: 'resin' }), 'filament');
  assert.notEqual(Book.categoryOf({ category: ' RESIN ' }), 'filament');
});

test('case and surrounding spaces are ignored, for aliases and real categories alike', () => {
  assert.equal(Book.categoryOf({ category: ' Power ' }), 'electricity');
  assert.equal(Book.categoryOf({ category: 'PARTS\n' }), 'maintenance');
  assert.equal(Book.categoryOf({ category: 'Filament' }), 'filament');
  assert.equal(Book.categoryOf({ category: ' shipping ' }), 'shipping');
});

test('an unknown category is handed back exactly as it was, not turned into other', () => {
  assert.equal(Book.categoryOf({ category: 'Courier' }), 'Courier');
  assert.equal(Book.categoryOf({ category: '' }), '');
  assert.equal(Book.categoryOf({}), undefined);
  assert.equal(Book.categoryOf({ category: null }), null);
  assert.equal(Book.categoryOf({ category: 7 }), 7);
  assert.equal(Book.categoryOf(null), undefined);
  // Not an own key of the map: no prototype member leaks through.
  for (const k of ['constructor', '__proto__', 'toString', 'hasOwnProperty']) {
    assert.equal(Book.categoryOf({ category: k }), k);
  }
});

test('reading never writes: the stored expense keeps its category', () => {
  const e = { category: 'power', amount: 10 };
  Book.categoryOf(e);
  Book.totals([e]);
  Book.overBudget([e], 'electricity', '', { electricity: 1 });
  byCategory([e]);
  computePnl({ expenses: [e] });
  assert.equal(e.category, 'power');
});

test('totals: an old power expense counts as electricity', () => {
  const t = Book.totals([
    { category: 'power', amount: 100 },
    { category: 'electricity', amount: 50 },
    { category: 'parts', amount: 20 },
    { category: 'rent', amount: 1000 },
    { category: 'resin', amount: 80 },
    { category: 'Courier', amount: 5 },
  ]);
  assert.equal(t.total, 1255);
  assert.equal(t.byCategory.electricity, 150);
  assert.equal(t.byCategory.maintenance, 20);
  assert.equal(t.byCategory.other, 1080);
  assert.equal(t.byCategory.filament, 0, 'resin is not filament');
  assert.equal(t.byCategory.power, undefined);
  assert.equal(t.byCategory.Courier, 5, 'an unknown category keeps its own bucket, as before');
});

test('budgets: an old power expense is set against the electricity budget', () => {
  const expenses = [
    { category: 'power', amount: 300, date: '2026-10-02' },
    { category: 'electricity', amount: 250, date: '2026-10-09' },
  ];
  assert.deepEqual(Book.overBudget(expenses, 'electricity', '2026-10', { electricity: 500 }),
    { spent: 550, budget: 500 });
  // Asked by the old word, answered by what it means.
  assert.deepEqual(Book.overBudget(expenses, 'power', '2026-10', { electricity: 500 }),
    { spent: 550, budget: 500 });
  const progress = Book.budgetProgress(Book.totals(expenses).byCategory, { electricity: 1000 });
  assert.equal(progress.length, 1);
  assert.equal(progress[0].spent, 550);
});

test('the category chart draws an old power row in electricity\'s bar', () => {
  const r = byCategory([
    { category: 'power', amount: 100 },
    { category: 'electricity', amount: 50 },
    { category: 'resin', amount: 80 },
    { category: '', amount: 1 },
  ]);
  assert.deepEqual(r.rows.map((x) => [x.category, x.amount]),
    [['electricity', 150], ['other', 81]]);
});

test('P&L: an old power expense is an electricity operating expense', () => {
  const s = computePnl({ expenses: [{ category: 'power', amount: 100 }, { category: 'electricity', amount: 50 }] });
  assert.equal(s.expensesTotal, 150);
  assert.deepEqual(s.expensesByCategory, [{ category: 'electricity', amount: 150 }]);
});

test('P&L: an old resin expense stays in operating expenses, not filament stock', () => {
  const s = computePnl({ expenses: [
    { category: 'resin', amount: 80 },
    { category: 'filament', amount: 200 },
  ] });
  assert.equal(s.expensesTotal, 80, 'resin is an operating expense');
  assert.equal(s.inventoryPurchases, 200, 'only filament is stock');
  assert.deepEqual(s.expensesByCategory, [{ category: 'other', amount: 80 }]);
});

test('P&L: old parts and rent rows land in maintenance and other', () => {
  const s = computePnl({ expenses: [{ category: 'parts', amount: 30 }, { category: 'rent', amount: 900 }] });
  assert.equal(s.expensesTotal, 930);
  const by = Object.fromEntries(s.expensesByCategory.map((x) => [x.category, x.amount]));
  assert.deepEqual(by, { other: 900, maintenance: 30 });
});

test('a new expense or a recurrence writes what the alias means', () => {
  const made = Book.newExpense({ amount: 10, category: 'Power' }, { id: 'E1', today: '2026-10-16' });
  assert.equal(made.expense.category, 'electricity');
  assert.equal(Book.newExpense({ amount: 10, category: 'resin' }, { id: 'E2', today: '2026-10-16' }).expense.category, 'other');
  assert.equal(Book.newExpense({ amount: 10, category: 'Courier' }, { id: 'E3', today: '2026-10-16' }).expense.category, 'other');
  const old = { id: 'E0', category: 'power', amount: 120, recurring: 'monthly', nextDue: '2026-10-01' };
  assert.equal(Book.recurrence(old, { id: 'E4', today: '2026-10-16' }).category, 'electricity');
  assert.equal(old.category, 'power', 'the original is left as it was');
});

test('accounting export: power books to Utilities, rent keeps its Rent account', () => {
  assert.equal(mapCategoryAccount('power'), 'Utilities');
  assert.equal(mapCategoryAccount('Power'), 'Utilities');
  assert.equal(mapCategoryAccount('rent'), 'Rent');
  assert.equal(mapCategoryAccount('resin'), 'resin');
  assert.equal(mapCategoryAccount('Courier'), 'Courier');
});

test('the desktop page reads every category through the book', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'expenses.js'), 'utf8');
  // Totals, budgets and badge classes go through expCategory; labels through
  // expCatLabel, which normalises. No bucket is keyed on the raw field.
  assert.doesNotMatch(src, /byCategory\[e\.category\]/);
  assert.doesNotMatch(src, /cat-\$\{escapeHtml\(e\.category\)\}/);
  assert.match(src, /function expCatLabel\(cat\) \{\s*const c = ExpenseBook \? ExpenseBook\.normaliseCategory\(cat\)/);
});

test('every page that loads a reader loads the book', () => {
  for (const page of ['index.html', 'bedready.html']) {
    const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', page), 'utf8');
    const readers = ['pnl-report', 'expense-categories', 'accounting-export'].filter((m) => html.includes(`../lib/${m}.js`));
    if (readers.length) assert.ok(html.includes('../lib/expense-book.js'), `${page} loads ${readers.join(', ')} but not the book`);
  }
});
