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

  // `equipment` is something BOUGHT to keep — a printer, a laser, a dryer.
  // lib/pnl-report.js leaves one out of operating expenses only when it
  // matches a machine whose depreciation already carries it (A MACHINE IS
  // PAID FOR ONCE); any other equipment purchase is an ordinary expense.
  const CATEGORIES = ['filament', 'electricity', 'maintenance', 'tools', 'equipment', 'shipping', 'other'];
  const RECURRING = ['monthly', 'quarterly', 'annually'];

  /* ── CATEGORIES A BOOK HOLDS THAT THIS LIST NEVER HAD ─────────────────────
   *
   * The iPhone's expense sheet offered `power`, `rent`, `resin` and `parts`
   * until it was fixed, and saved them as typed. None of them is in
   * CATEGORIES, so every reader grouped such a row under its own unknown key:
   * it counted in the total and matched no picker, no budget and no chart
   * bucket — a phone's electricity bill was never set against the
   * electricity budget.
   *
   * They are read as what they meant, not rewritten: a row on disk keeps what
   * it was saved with, and every reader asks `categoryOf` instead of reading
   * `.category`. So a book synced from the phone reads right the first time
   * it is opened, and nothing about a store changes by opening it.
   *
   * `resin` is NOT filament. Filament is stock (lib/pnl-report.js FILAMENT IS
   * COUNTED WHEN IT IS USED): it is left out of operating expenses and costed
   * as a job uses it. Resin is not tracked as stock anywhere, so reading it as
   * filament would take it out of the P&L and never put it back. It is an
   * ordinary expense, `other`, where it already counted. `rent` likewise has
   * no category of its own, and `parts` are what a printer is maintained with.
   *
   * Mirrored by mac/KhaytCore ExpenseCategory.swift; a test holds the two
   * maps to each other. */
  const CATEGORY_ALIASES = Object.freeze({
    power: 'electricity',
    parts: 'maintenance',
    rent: 'other',
    resin: 'other',
  });

  /**
   * What a stored category MEANS: one of CATEGORIES when it is one (in any
   * case, with any surrounding spaces) or an alias of one. Anything else is
   * handed back exactly as it was — not `other` — because that is how every
   * reader has always treated a category it does not know (its own bucket,
   * or the reader's own fallback for an empty one), and that is not this
   * rule's to change.
   */
  function normaliseCategory(raw) {
    if (typeof raw !== 'string') return raw;
    const key = raw.trim().toLowerCase();
    if (CATEGORIES.includes(key)) return key;
    if (Object.prototype.hasOwnProperty.call(CATEGORY_ALIASES, key)) return CATEGORY_ALIASES[key];
    return raw;
  }

  /** An expense's category, as every reader should read it. */
  function categoryOf(expense) {
    return normaliseCategory(expense == null ? undefined : expense.category);
  }

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
    // An alias is written as what it means, so a picker that still offers
    // one writes a category every report knows.
    const asked = normaliseCategory(i.category);
    const category = CATEGORIES.includes(asked) ? asked : 'other';
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
        // Which supplier receipt this was filed from, when it was read off the
        // receipt's ZATCA QR (lib/zatca-qr.js `receiptRef`): how the same
        // receipt scanned twice is caught instead of filed twice.
        receiptRef: trim(i.receiptRef) || null,
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
      // A new row, so it is written as what the old one meant: a phone's
      // monthly `power` bill comes round as electricity. The original is
      // left as it is.
      category: categoryOf(expense),
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
    const cat = normaliseCategory(category);
    const budget = num((budgets || {})[cat]);
    if (budget <= 0) return null;
    const spent = (expenses || [])
      .filter((e) => e && categoryOf(e) === cat && String(e.date || '').startsWith(month))
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
      const cat = categoryOf(e);
      byCategory[cat] = (byCategory[cat] || 0) + amt;
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

  const api = { CATEGORIES, CATEGORY_ALIASES, RECURRING, normaliseCategory, categoryOf, nextDueDate, newExpense, recurrence, due, overBudget, totals, budgetProgress };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  // The file is named for the global it assigns, which is the rule KhaytCore's
  // loader checks. Both this and the Expenses TAB wanted the obvious name, and
  // two modules assigning one global is a silent overwrite decided by script
  // order — so the rule is the book and the screen is the tab.
  global.KhaytExpenseBook = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
