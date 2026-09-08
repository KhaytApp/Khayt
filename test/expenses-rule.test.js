/**
 * lib/expense-book.js is the expense form's save, lifted out of renderer/expenses.js.
 *
 * THE PROOF: the record-building lines of the original `addExpense` are copied
 * below VERBATIM, with `uid()` and `localDateStr()` supplied from outside (the
 * id and the clock are the only things a pure rule cannot mint), and both are
 * run over thousands of generated forms. The two deliberate tightenings —
 * unknown category → other, unknown recurrence → none — are outside the
 * comparison, which only generates values the page's selects could offer, and
 * have their own tests.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const E = require('../lib/expense-book.js');

const ORIGINAL = `
  const amount = clampPositive($('#expAmount').value);
  if (amount <= 0) { return { refused: 'amount_required' }; }
  const dateVal = $('#expDate').value || localDateStr();
  const orderRef = ($('#expOrderRef')?.value || '').trim() || null;
  const recurringVal = $('#expRecurring')?.value || null;
  const nextDue = recurringVal ? calcNextDueDate(dateVal, recurringVal) : null;
  const expCat = $('#expCategory').value || 'other';
  return { expense: {
    id:          uid('EXP'),
    date:        dateVal,
    category:    expCat,
    amount,
    note:        $('#expNote').value.trim(),
    orderId:     orderRef,
    receiptPath: _expReceiptPath || null,
    recurring:   recurringVal || null,
    nextDue:     nextDue,
    locationId:  $('#exp_locationId')?.value || '',
  } };`;

/** The original calcNextDueDate, verbatim. */
const ORIGINAL_NEXT = `
function calcNextDueDate(fromDate, recurring) {
  if (!fromDate || !recurring) return null;
  const m = /^(\\d{4})-(\\d{2})-(\\d{2})$/.exec(String(fromDate).trim());
  if (!m) return null;
  const d = new Date(+m[1], +m[2] - 1, +m[3]);
  if (recurring === 'monthly') d.setMonth(d.getMonth() + 1);
  else if (recurring === 'quarterly') d.setMonth(d.getMonth() + 3);
  else if (recurring === 'annually') d.setFullYear(d.getFullYear() + 1);
  else return null;
  return localDateStr(d);
}
return calcNextDueDate;`;

const localDateStr = (d = new Date()) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const originalNext = new Function('localDateStr', ORIGINAL_NEXT)(localDateStr);

function runOriginal(form, ctx) {
  const els = {
    '#expAmount': { value: form.amount }, '#expDate': { value: form.date },
    '#expCategory': { value: form.category }, '#expNote': { value: form.note },
  };
  if (form.orderId !== undefined) els['#expOrderRef'] = { value: form.orderId };
  if (form.recurring !== undefined) els['#expRecurring'] = { value: form.recurring };
  if (form.locationId !== undefined) els['#exp_locationId'] = { value: form.locationId };
  const scope = {
    $: (sel) => els[sel] || null,
    clampPositive: (v) => { const n = parseFloat(v); return Math.max(0, Number.isFinite(n) ? n : 0); },
    localDateStr: () => ctx.today,
    calcNextDueDate: originalNext,
    uid: () => ctx.id,
    _expReceiptPath: form.receiptPath || null,
  };
  return new Function(...Object.keys(scope), ORIGINAL)(...Object.values(scope));
}

function rng(seed) {
  let x = seed >>> 0 || 1;
  return () => { x ^= x << 13; x >>>= 0; x ^= x >>> 17; x ^= x << 5; x >>>= 0; return x / 4294967296; };
}
const pick = (r, list) => list[Math.floor(r() * list.length)];

test('the module and the original agree over 4000 generated expense forms', () => {
  const r = rng(4242);
  for (let i = 0; i < 4000; i++) {
    const form = {
      amount: pick(r, ['', '0', '-3', '12.5', ' 7 ', 'abc', '1e2', '250']),
      date: pick(r, ['', '2026-09-04', '2026-01-31', '2025-12-15']),
      category: pick(r, ['', ...E.CATEGORIES]),
      note: pick(r, ['', '  spools ', 'x']),
      orderId: pick(r, [undefined, '', ' ORD-1 ', 'ORD-2']),
      recurring: pick(r, [undefined, '', ...E.RECURRING]),
      receiptPath: pick(r, [null, '', '/tmp/r.pdf']),
      locationId: pick(r, [undefined, '', 'L1']),
    };
    const ctx = { id: 'EXP-' + i, today: '2026-09-04' };
    const mine = E.newExpense(form, ctx);
    const theirs = runOriginal(form, ctx);

    // `vatAmount` IS NEW AND THE ORIGINAL HAS NO OPINION ABOUT IT. None of
    // these forms carries one, so every record must come out with zero — an
    // expense that says nothing about tax reclaims nothing, which is what every
    // expense written before the field existed does. Removing it and comparing
    // the rest keeps the parity proof for all seven fields that were there
    // before; editing the ORIGINAL to add the field would prove nothing.
    if (mine.expense) {
      assert.equal(mine.expense.vatAmount, 0,
                   `a form with no tax on it: ${JSON.stringify(form)}`);
      const { vatAmount, ...rest } = mine.expense;
      assert.deepEqual({ ...mine, expense: rest }, theirs, JSON.stringify(form));
    } else {
      assert.deepEqual(mine, theirs, JSON.stringify(form));
    }
  }
});

test('the tax on a receipt is kept, clamped, and never invented', () => {
  const ctx = { id: 'EXP-1', today: '2026-09-04' };
  const of = (form) => E.newExpense({ amount: 100, ...form }, ctx).expense.vatAmount;
  assert.equal(of({}), 0, 'absent is nothing, not a guess');
  assert.equal(of({ vatAmount: 13.04 }), 13.04, 'what the supplier invoice says');
  assert.equal(of({ vatAmount: '13.04' }), 13.04, 'typed into a form, so a string');
  assert.equal(of({ vatAmount: 500 }), 100, 'never more tax than the receipt cost');
  assert.equal(of({ vatAmount: -5 }), 0);
  assert.equal(of({ vatAmount: 'abc' }), 0);
  // And a bad tax figure must not stop somebody recording what they spent.
  assert.equal(E.newExpense({ amount: 100, vatAmount: 'abc' }, ctx).refused, undefined);
});

test('nextDueDate agrees with the original across every month of four years', () => {
  for (let y = 2024; y <= 2027; y++) for (let m = 1; m <= 12; m++) for (const d of [1, 15, 28, 29, 30, 31]) {
    const from = `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
    for (const rec of [...E.RECURRING, 'weekly', '', null]) {
      assert.equal(E.nextDueDate(from, rec), originalNext(from, rec), `${from} ${rec}`);
    }
  }
  assert.equal(E.nextDueDate('nonsense', 'monthly'), null);
});

test('a category the book does not know becomes other; a recurrence it does not know is none', () => {
  const out = E.newExpense({ amount: 5, category: 'crypto', recurring: 'weekly' }, { id: 'E', today: '2026-09-04' }).expense;
  assert.equal(out.category, 'other');
  assert.equal(out.recurring, null);
  assert.equal(out.nextDue, null, 'and no due date is invented for it');
});

test('a recurring expense comes round as a copy that is not itself recurring', () => {
  const parent = E.newExpense({ amount: 90, category: 'tools', recurring: 'monthly', date: '2026-08-04', note: 'rent' },
                              { id: 'P', today: '2026-08-04' }).expense;
  assert.equal(parent.nextDue, '2026-09-04');
  assert.deepEqual(E.due([parent], '2026-09-04'), [parent], 'due on the day');
  assert.deepEqual(E.due([parent], '2026-09-03'), [], 'not the day before');
  const copy = E.recurrence(parent, { id: 'C', today: '2026-09-04' });
  assert.equal(copy.recurring, null);
  assert.equal(copy.amount, 90);
  assert.equal(copy.note, 'rent');
  assert.equal(copy.orderId, null);
});

test('over budget is judged after the expense is in, on the shop\'s month', () => {
  const book = [
    { category: 'filament', amount: 300, date: '2026-09-01' },
    { category: 'filament', amount: 250, date: '2026-09-03' },
    { category: 'filament', amount: 900, date: '2026-08-30' },   // last month
    { category: 'tools', amount: 5000, date: '2026-09-02' },      // another category
  ];
  assert.deepEqual(E.overBudget(book, 'filament', '2026-09', { filament: 500 }), { spent: 550, budget: 500 });
  assert.equal(E.overBudget(book, 'filament', '2026-09', { filament: 600 }), null);
  assert.equal(E.overBudget(book, 'filament', '2026-09', {}), null, 'no budget, no complaint');
});

test('totals and budget progress', () => {
  const { total, byCategory } = E.totals([{ category: 'filament', amount: '10' }, { category: 'filament', amount: 5 }, { category: 'other', amount: 1 }]);
  assert.equal(total, 16);
  assert.equal(byCategory.filament, 15);
  assert.equal(byCategory.shipping, 0, 'every category is present, at zero');
  const rows = E.budgetProgress(byCategory, { filament: 10, shipping: 100 });
  assert.deepEqual(rows.map((x) => x.category), ['filament', 'shipping']);
  assert.equal(rows[0].over, true);
  assert.equal(rows[0].pct, 100, 'capped for the bar');
  assert.equal(rows[1].remaining, 100);
});
