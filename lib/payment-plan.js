'use strict';
(function () {

/**
 * Payment-plan SCHEDULE math — pure arithmetic over an order's payment plan.
 *
 * Spec: docs/KHAYT-3.0-PAYMENTS-SPEC.md. This module builds and reasons about an
 * `order.paymentPlan.schedule[]` of dated amounts and returns the numbers the
 * renderer feeds into the existing money flow. It is intentionally side-effect
 * free (inject `now`, no fs/renderer imports) so it can be unit-tested in
 * isolation and reused anywhere.
 *
 * IMPORTANT — this module is NOT a second ledger. `payStatus(order)`
 * (renderer/app-helpers.js) remains the single source of truth for
 * paid/partial/unpaid, deriving from price/paidAmount/giftCardDiscount/
 * creditNotes[]. We do NOT duplicate or replace it. We only:
 *   - build a schedule that sums EXACTLY to `total` (2-dp money), and
 *   - sum/inspect that schedule (scheduled/collected/remaining/nextDue/due).
 * The renderer maps a collected schedule onto `paidAmount`; `payStatus`/
 * `orderOwedBase` react as they already do.
 *
 * Money model: SAR, VAT-inclusive, rounded to 2 decimal places. The deposit (if
 * any) is installment 0, due immediately; the remainder is split evenly across
 * `installments`, with the LAST regular installment absorbing the rounding so the
 * schedule sums to `total` to the cent — no money is created or lost.
 */

const DAY_MS = 86400000;

/** Round a number to 2 decimal places (money), avoiding binary float drift. */
function round2(n) {
  return Math.round((Number(n) || 0) * 100) / 100;
}

/** Coerce to a finite, non-negative number (0 on garbage). */
function pos(n) {
  const v = Number(n);
  return Number.isFinite(v) && v > 0 ? v : 0;
}

/** Normalize a date input to an ISO 'YYYY-MM-DD' day string. */
/**
 * The calendar day a Date falls on IN THE USER'S OWN TIMEZONE.
 *
 * toISOString() converts to UTC first, which shifts the day backwards for any timezone
 * ahead of UTC. Riyadh is UTC+3, so a plan built between 00:00 and 03:00 local dated its
 * deposit and first installment YESTERDAY — instantly overdue the moment it was created.
 */
function localIsoDay(d) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function toIsoDay(input) {
  if (!input) return null;
  if (input instanceof Date) return localIsoDay(input);
  const s = String(input);
  // Already a 'YYYY-MM-DD' (or longer ISO) string — keep the day part.
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : localIsoDay(d);
}

/** Add `days` to an ISO day string, returning a new ISO day string. */
function addDays(isoDay, days) {
  const base = isoDay ? new Date(`${toIsoDay(isoDay)}T00:00:00.000Z`) : new Date();
  return new Date(base.getTime() + (Number(days) || 0) * DAY_MS).toISOString().slice(0, 10);
}

/**
 * Build a payment-plan schedule.
 *
 * @param {object} opts
 * @param {number} opts.total            Plan total (SAR, VAT-inclusive).
 * @param {number} [opts.depositAmount]  Up-front deposit; becomes installment 0,
 *                                        due immediately, when > 0.
 * @param {number} opts.installments     How many regular installments split the
 *                                        remainder (after the deposit).
 * @param {string|Date} [opts.firstDueDate] Due date of the first regular
 *                                        installment (ISO day or Date). Defaults
 *                                        to today (the injected/system date).
 * @param {number} [opts.intervalDays]   Days between regular installments.
 * @returns {Array<{dueDate:string, amount:number, paidAt:null}>}
 *   A schedule whose amounts sum EXACTLY to `total` (to the cent). The deposit,
 *   when present, is the first entry (dueDate = today). The last regular entry
 *   absorbs any rounding remainder.
 */
function buildSchedule({ total, depositAmount = 0, installments, firstDueDate, intervalDays } = {}) {
  const grandTotal = round2(pos(total));
  const deposit = Math.min(round2(pos(depositAmount)), grandTotal);
  const count = Math.max(0, Math.trunc(Number(installments) || 0));
  const interval = Number(intervalDays) || 0;
  const today = toIsoDay(new Date());

  const schedule = [];

  // Deposit is installment 0 — due immediately — when > 0.
  if (deposit > 0) {
    schedule.push({ dueDate: today, amount: deposit, paidAt: null });
  }

  const remainder = round2(grandTotal - deposit);

  if (count <= 0 || remainder <= 0) {
    return schedule;
  }

  // Split the remainder evenly; the LAST entry absorbs the rounding so the whole
  // schedule sums to `total` to the cent.
  const per = round2(remainder / count);
  const start = toIsoDay(firstDueDate) || today;

  let scheduledSoFar = 0;
  for (let i = 0; i < count; i += 1) {
    const isLast = i === count - 1;
    const amount = isLast ? round2(remainder - scheduledSoFar) : per;
    scheduledSoFar = round2(scheduledSoFar + amount);
    schedule.push({
      dueDate: i === 0 ? start : addDays(start, interval * i),
      amount,
      paidAt: null,
    });
  }

  return schedule;
}

/** Sum of all scheduled amounts (== `total` for a built schedule). */
function scheduledTotal(schedule) {
  if (!Array.isArray(schedule)) return 0;
  return round2(schedule.reduce((sum, e) => sum + (Number(e && e.amount) || 0), 0));
}

/** Sum of amounts whose `paidAt` is set (i.e. collected). */
function collectedTotal(schedule) {
  if (!Array.isArray(schedule)) return 0;
  return round2(schedule.reduce(
    (sum, e) => sum + (e && e.paidAt ? (Number(e.amount) || 0) : 0),
    0,
  ));
}

/**
 * Plan balance snapshot.
 * @returns {{ scheduled:number, collected:number, remaining:number,
 *             nextDue:{dueDate:string, amount:number}|null }}
 *   `remaining` = scheduled − collected (clamped to >= 0). `nextDue` is the
 *   earliest unpaid entry (by dueDate, then schedule order), or null when none.
 */
function planBalance(schedule) {
  const scheduled = scheduledTotal(schedule);
  const collected = collectedTotal(schedule);
  const remaining = round2(Math.max(0, scheduled - collected));

  let nextDue = null;
  if (Array.isArray(schedule)) {
    const unpaid = schedule
      .map((e, i) => ({ e, i }))
      .filter(({ e }) => e && !e.paidAt);
    unpaid.sort((a, b) => {
      const da = a.e.dueDate || '';
      const db = b.e.dueDate || '';
      if (da !== db) return da < db ? -1 : 1;
      return a.i - b.i; // stable: earlier schedule position wins on a tie
    });
    if (unpaid.length) {
      nextDue = { dueDate: unpaid[0].e.dueDate, amount: unpaid[0].e.amount };
    }
  }

  return { scheduled, collected, remaining, nextDue };
}

/**
 * Mark a single installment collected. Pure — returns a NEW schedule (and new
 * entry objects), never mutating the input.
 * @param {Array} schedule
 * @param {number} index   Index of the entry to mark paid.
 * @param {string|Date} paidIso  When it was collected (ISO day; defaults today).
 * @returns {Array} a new schedule.
 */
function markInstallmentPaid(schedule, index, paidIso) {
  if (!Array.isArray(schedule)) return [];
  const paidAt = toIsoDay(paidIso) || toIsoDay(new Date());
  return schedule.map((entry, i) => {
    if (i !== index || !entry) return entry;
    return { ...entry, paidAt };
  });
}

/**
 * Unpaid entries that are due (dueDate <= now), earliest first. "Due" includes
 * overdue. Entries without a dueDate are never considered due here.
 * @param {Array} schedule
 * @param {string|Date} now  The injected current time.
 * @returns {Array} unpaid, due entries sorted by dueDate ascending.
 */
/**
 * Instalment plans that ask for more than the order still owes.
 *
 * The generator used to split the order's GROSS PRICE, ignoring anything already
 * paid — so a SAR 3,000 job with a SAR 1,000 deposit became three payments of
 * SAR 1,000, billing SAR 3,000 against SAR 2,000 outstanding. That is fixed for
 * new plans; the ones already written to disk still say what they said.
 *
 * These are NOT rewritten. A schedule is an agreement the shop may have put in
 * writing to a customer, and silently changing the amounts would be a worse
 * thing to do than saying so. The deposit migration in lib/split-order.js is
 * different in kind: there the money was already RECORDED and only needed
 * attributing to the right rows, which is arithmetic, not a renegotiation.
 *
 * Unpaid rows only. What the customer has already handed over is not something
 * to flag, and a plan the shop has been working through is exactly where a
 * surprise edit would do the most damage.
 *
 * @param {object[]} orders the print log
 * @returns {{id:string, project:string, scheduled:number, owed:number, over:number}[]}
 */
function overBilledPlans(orders) {
  if (!Array.isArray(orders)) return [];
  const out = [];
  for (const o of orders) {
    if (!o || typeof o !== 'object' || !Array.isArray(o.instalments) || !o.instalments.length) continue;
    const paid = +o.paidAmount || 0;
    const credited = (o.creditNotes || []).reduce((s, c) => s + (+c.amount || 0), 0);
    const gift = +o.giftCardDiscount || 0;
    // Nothing was paid up front, so the plan cannot have double-counted a deposit.
    if (paid <= 0 && credited <= 0 && gift <= 0) continue;
    const owed = round2(Math.max(0, (+o.price || 0) - paid - credited - gift));
    const outstandingRows = o.instalments.filter((i) => i && !i.paid);
    const scheduled = round2(outstandingRows.reduce((s, i) => s + (+i.amount || 0), 0));
    // A cent of rounding is not an over-bill.
    if (scheduled - owed <= 0.01) continue;
    out.push({
      id: String(o.id || ''),
      project: String(o.project || o.id || ''),
      scheduled,
      owed,
      over: round2(scheduled - owed),
    });
  }
  return out;
}

function dueInstallments(schedule, now) {
  if (!Array.isArray(schedule)) return [];
  const today = toIsoDay(now) || toIsoDay(new Date());
  return schedule
    .filter(e => e && !e.paidAt && e.dueDate && toIsoDay(e.dueDate) <= today)
    .slice()
    .sort((a, b) => {
      const da = toIsoDay(a.dueDate);
      const db = toIsoDay(b.dueDate);
      if (da !== db) return da < db ? -1 : 1;
      return 0;
    });
}

/**
 * The clock, as a LOCAL Date — from a Date, a 'YYYY-MM-DD' day, or nothing.
 *
 * `new Date('2026-01-31')` is UTC midnight, which is the 30th anywhere west of
 * Greenwich and the 31st here — a plan's first payment landing a day early or
 * late depending on where the shop is. A day string is read as that day in the
 * shop's own calendar, which is the only reading that matches how it was
 * written. The macOS app passes one; the renderer passes a Date.
 */
function localDate(input) {
  if (input instanceof Date) return input;
  if (typeof input === 'string') {
    const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(input);
    if (m) return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  }
  return new Date();
}

/**
 * The plan a shop is offered when it asks for one: three payments, a month
 * apart, covering what the job STILL OWES.
 *
 * ── WHY THE DATE ARITHMETIC IS HERE AND NOT AT THE CALLER ─────────────────
 *
 * `new Date(2026, 1, 31)` is the 3rd of March, silently — so a plan generated
 * on the 31st skipped February altogether and asked for its first payment two
 * months out. The clamp below is the fix, and it lives in the shared rule
 * because a second host writing the same three lines would reintroduce the
 * same bug on its own schedule.
 *
 * The FIRST payment falls a month from today (calendar month, clamped to that
 * month's length); the rest follow at `intervalDays`. That difference — one
 * calendar month, then fixed intervals — is what the Electron plan generator
 * has always done, and it is deliberate: a shop says "next month, then every
 * thirty days", not "every thirty days starting in thirty".
 *
 * @param {object} opts
 * @param {number} opts.owed     What the order still owes — NOT its gross
 *                               price. A job with a deposit already taken
 *                               produced a schedule billing that deposit a
 *                               second time.
 * @param {Date|string} [opts.today] Injected clock — a Date, or a
 *                               'YYYY-MM-DD' day in the shop's own calendar.
 * @param {number} [opts.installments] How many payments (default 3).
 * @param {number} [opts.intervalDays] Days between them after the first
 *                               (default 30).
 * @returns {Array<{dueDate:string, amount:number, paidAt:null}>} a schedule,
 *   empty when nothing is owed.
 */
function monthlyPlan({ owed, today, installments = 3, intervalDays = 30 } = {}) {
  const total = round2(pos(owed));
  if (total <= 0) return [];
  const now = localDate(today);
  const year = now.getFullYear();
  const month = now.getMonth() + 1;
  // Day 0 of the month AFTER the target is the target month's last day.
  const lastDay = new Date(year, month + 1, 0).getDate();
  const firstDueDate = localIsoDay(new Date(year, month, Math.min(now.getDate(), lastDay)));
  return buildSchedule({
    total, depositAmount: 0, installments, firstDueDate, intervalDays,
  });
}

/**
 * What an order's cash figures become once its plan rows are marked collected.
 *
 * ── THE TWO WAYS THIS HAS DESTROYED MONEY ─────────────────────────────────
 *
 * `paidAmount` is the authoritative CASH figure: the deposit is written
 * straight into it when the order is taken, and `payStatus()`/`orderOwedBase()`
 * both read it.
 *
 *   1. Assigning the collected instalment total OVER it destroyed the deposit.
 *      A freshly generated plan has nothing collected, so a SAR 500 deposit
 *      vanished with no ledger entry the moment the order was saved.
 *
 *   2. `Math.max(paidAmount, collected)` was right only while the generator
 *      spanned the GROSS price. Against a plan covering the BALANCE it leaves
 *      the deposit uncounted forever: a customer who has paid in full is
 *      chased for the deposit they started with.
 *
 * `instalmentBase` is the cash the order held when the plan was generated,
 * written only by the generator. A plan made before it existed — or built by
 * hand, whose amounts mean whatever the shop decided — has none and keeps the
 * old rule, which is the right one for a schedule spanning the whole price.
 *
 * The `Math.max` that remains is not belt-and-braces: `paidAmount` can have
 * GROWN since the plan was made — cash taken at the counter and typed straight
 * in — and `base + collected` would then be lower than what the order already
 * holds. That is the bug money-integrity.test.js exists to catch, and it
 * caught it.
 *
 * Settled against the ORDER PRICE, not the instalment total. Instalment
 * amounts are freely editable, so a partial plan (two SAR 100 rows on a
 * SAR 2,000 order) marked paid reported the whole order as settled — and
 * `paymentStatus` is what the payment_received/paid webhooks carry.
 *
 * @param {object} opts
 * @param {number} opts.price          The order's price.
 * @param {number} opts.paidAmount     What the order already holds.
 * @param {Array} opts.instalments     Rows of `{amount, paid}`.
 * @param {number} [opts.instalmentBase] Cash held when the plan was generated.
 * @returns {{paidAmount:number, paymentStatus:string, collected:number}}
 */
function collectionTotals({ price, paidAmount, instalments, instalmentBase } = {}) {
  const held = Number(paidAmount) || 0;
  const rows = Array.isArray(instalments) ? instalments : [];
  const collected = round2(rows.reduce(
    (sum, ins) => sum + (ins && ins.paid ? (Number(ins.amount) || 0) : 0), 0,
  ));
  const fromPlan = (typeof instalmentBase === 'number' && instalmentBase >= 0)
    ? round2(instalmentBase + collected)
    : collected;
  const paid = Math.max(held, fromPlan);
  const owed = Number(price) || 0;
  const paymentStatus = paid <= 0
    ? 'unpaid'
    : (owed > 0 && paid + 0.005 >= owed ? 'paid' : 'partial');
  return { paidAmount: paid, paymentStatus, collected };
}

const api = {
  buildSchedule,
  monthlyPlan,
  collectionTotals,
  scheduledTotal,
  collectedTotal,
  planBalance,
  markInstallmentPaid,
  dueInstallments,
  overBilledPlans,
  // low-level (exposed for tests / reuse)
  round2,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPaymentPlan = api;

})();
