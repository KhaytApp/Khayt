'use strict';
/**
 * The expense book: what one expense IS, when a recurring one comes round
 * again, and whether a month has overspent its budget.
 *
 * Lifted from renderer/expenses.js, where the record was built inline from
 * seven form controls — which is why only the Electron window could record an
 * expense. Both apps write the same record by the same rule now.
 *
 * PURE: no DOM, no clock. The id and today's date are passed in.
 *
 * TWO DELIBERATE TIGHTENINGS over the original, each closing a hole the form
 * happened to cover: a category the book does not know becomes `other`, and a
 * recurrence that is not monthly, quarterly or annually is not a recurrence.
 * The page's selects only ever offered those values, so nothing a shop has
 * recorded changes; a second app with a typo in a picker cannot write a
 * category no report will ever total.
 */
(function (global) {

  const CATEGORIES = ['filament', 'electricity', 'maintenance', 'tools', 'shipping', 'other'];
  const RECURRING = ['monthly', 'quarterly', 'annually'];

  const pad = (n) => String(n).padStart(2, '0');
  const localDay = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const num = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : 0; };
  const trim = (v) => String(v == null ? '' : v).trim();

  /**
   * When a recurring expense is next due.
   *
   * Built, advanced and read on the SAME calendar. This used to construct the
   * date in UTC, advance it in UTC, then format it locally — and west of UTC
   * those disagree by a day, so every cycle lost one: an expense anchored on
   * the 15th went 14th, 13th, 12th. Invisible in CI, which runs in UTC.
   */
  function nextDueDate(fromDate, recurring) {
    if (!fromDate || !recurring) return null;
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(fromDate).trim());
    if (!m) return null;
    const d = new Date(+m[1], +m[2] - 1, +m[3]);
    if (recurring === 'monthly') d.setMonth(d.getMonth() + 1);
    else if (recurring === 'quarterly') d.setMonth(d.getMonth() + 3);
    else if (recurring === 'annually') d.setFullYear(d.getFullYear() + 1);
    else return null;
    return localDay(d);
  }

  /**
   * One expense, as the book records it.
   *
   * `input`: `{ amount, date, category, note, orderId, recurring, receiptPath, locationId }`
   * `ctx`:   `{ id, today }` — today as `YYYY-MM-DD`.
   * Returns `{ expense }`, or `{ refused: 'amount_required' }` for an amount
   * that is not positive — the one thing the form refuses.
   */
  function newExpense(input, ctx) {
    const i = input || {};
    const c = ctx || {};
    const amount = Math.max(0, num(i.amount));
    if (amount <= 0) return { refused: 'amount_required' };
    // THE TAX ON THE RECEIPT, as the supplier's invoice states it.
    //
    // An amount and not a rate: rates differ line by line, an import or an
    // exempt purchase carries none, and a receipt with two rates on it has no
    // single percentage to type. A shop copies the figure in front of it.
    //
    // Never more than was paid and never negative — a clamp rather than a
    // refusal, because a mistyped tax must not stop somebody recording what
    // they spent. Absent is zero, which is what every expense written before
    // this field existed carries, and it reclaims nothing.
    const vatAmount = Math.min(amount, Math.max(0, num(i.vatAmount)));
    const date = i.date || c.today;
    const recurring = RECURRING.includes(i.recurring) ? i.recurring : null;
    const category = CATEGORIES.includes(i.category) ? i.category : 'other';
    return {
      expense: {
        id: c.id,
        date,
        category,
        amount,
        vatAmount,
        note: trim(i.note),
        orderId: trim(i.orderId) || null,
        receiptPath: i.receiptPath || null,
        recurring,
        nextDue: recurring ? nextDueDate(date, recurring) : null,
        locationId: i.locationId || '',
      },
    };
  }

  /**
   * The copy a recurring expense spawns when it comes round: today's date, the
   * same amount and note, and NOT itself recurring — the original keeps the
   * schedule. Returns the copy; the caller advances the original's `nextDue`.
   */
  function recurrence(expense, ctx) {
    const c = ctx || {};
    return {
      id: c.id,
      date: c.today,
      category: expense.category,
      amount: expense.amount,
      note: expense.note || '',
      recurring: null,
      orderId: null,
    };
  }

  /** The recurring expenses due on or before today. */
  function due(expenses, today) {
    return (expenses || []).filter((e) => e && e.recurring && e.nextDue && e.nextDue <= today);
  }

  /**
   * Whether a category is over its monthly budget, AFTER the expense is in.
   *
   * `month` is the shop's calendar month, `YYYY-MM`, in local time — expense
   * dates are written locally, and a UTC month mismatches for the first hours
   * of the 1st east of London: a Riyadh shop logging 200 at 01:00 on the 1st
   * was told it had blown a 5,000 budget, because the sum was still counting
   * last month. Returns `{ spent, budget }` when over, null otherwise.
   */
  function overBudget(expenses, category, month, budgets) {
    const budget = num((budgets || {})[category]);
    if (budget <= 0) return null;
    const spent = (expenses || [])
      .filter((e) => e && e.category === category && String(e.date || '').startsWith(month))
      .reduce((s, e) => s + num(e.amount), 0);
    return spent > budget ? { spent, budget } : null;
  }

  /** What a list of expenses comes to, in total and by category. */
  function totals(expenses) {
    const byCategory = {};
    CATEGORIES.forEach((c) => { byCategory[c] = 0; });
    let total = 0;
    for (const e of expenses || []) {
      if (!e) continue;
      const amt = num(e.amount);
      byCategory[e.category] = (byCategory[e.category] || 0) + amt;
      total += amt;
    }
    return { total, byCategory };
  }

  /**
   * Budget against actual, one row per category that has a budget.
   * `pct` is capped at 100 for a bar; `over` says whether it went past.
   */
  function budgetProgress(byCategory, budgets) {
    const b = budgets || {};
    return CATEGORIES.filter((c) => num(b[c]) > 0).map((c) => {
      const budget = num(b[c]);
      const spent = num((byCategory || {})[c]);
      return {
        category: c, budget, spent,
        remaining: budget - spent,
        pct: Math.min(100, (spent / budget) * 100),
        over: spent > budget,
      };
    });
  }

  const api = { CATEGORIES, RECURRING, nextDueDate, newExpense, recurrence, due, overBudget, totals, budgetProgress };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  // The file is named for the global it assigns, which is the rule KhaytCore's
  // loader checks. Both this and the Expenses TAB wanted the obvious name, and
  // two modules assigning one global is a silent overwrite decided by script
  // order — so the rule is the book and the screen is the tab.
  global.KhaytExpenseBook = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
