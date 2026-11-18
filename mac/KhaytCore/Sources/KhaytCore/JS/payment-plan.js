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
      project: String(o.project || o.jobNumber || o.id || ''),
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
 * @param {number} [opts.giftCardDiscount] Gift card spent on the order.
 * @param {number} [opts.credited]  Credit notes against it.
 * @param {number} [opts.due]       What the order is BILLED, when that is not
 *                                  the price — an exclusive shop's price + tax
 *                                  (`KhaytOrderMoney.orderGrossRaw`).
 * @returns {{paidAmount:number, paymentStatus:string, collected:number}}
 *
 * ── A GIFT CARD IS A TENDER, AND THE PLAN DOES NOT COVER IT ──────────────
 *
 * A plan is generated over what is OWED — price less the gift card and the
 * credit notes — so collecting every row of it brings the CASH to
 * price − gift card. Judged against the bare price, that order stayed
 * "partial" for ever: a 500 job with a 100 card and a 400 plan, fully
 * collected, was chased for the 100 the card had already paid. Settled is
 * judged the way `KhaytOrderPayment.statusOf` judges it: cash + gift card
 * against what is billed less credit notes.
 */
function collectionTotals({
  price, paidAmount, instalments, instalmentBase, giftCardDiscount, credited, due,
} = {}) {
  const held = Number(paidAmount) || 0;
  const rows = Array.isArray(instalments) ? instalments : [];
  const collected = round2(rows.reduce(
    (sum, ins) => sum + (ins && ins.paid ? (Number(ins.amount) || 0) : 0), 0,
  ));
  const fromPlan = (typeof instalmentBase === 'number' && instalmentBase >= 0)
    ? round2(instalmentBase + collected)
    : collected;
  const paid = Math.max(held, fromPlan);
  const billed = (typeof due === 'number' && due >= 0) ? due : (Number(price) || 0);
  const owed = Math.max(0, billed - pos(credited));
  const tendered = paid + pos(giftCardDiscount);
  const paymentStatus = tendered <= 0
    ? 'unpaid'
    : (owed > 0 && tendered + 0.005 >= owed ? 'paid' : 'partial');
  return { paidAmount: paid, paymentStatus, collected };
}

// ── Saving a plan, and collecting one of its payments (Dev Hub, Nov 18) ───
//
// The editor's "Mark paid" flipped a flag on a row, and its save rewrote
// paidAmount from the flags (collectionTotals): money on the books with no
// payment recorded, and a click away from moving again. Now the plan is only
// the SCHEDULE. applyPlan saves its rows and never touches paidAmount; a row
// is paid only by recordRowPayment, which records the money through
// lib/order-payment.js recordPayment (its clamp, its status, its effects).
//
// Rows already ticked paid in a book from before keep their tick: they are
// paid and locked exactly like a recorded one, and named for what they are,
// 'legacy' (marked paid, no payment recorded). Nothing is rewritten, and the
// job's paidAmount stays as it is.

function libOf(name, file) {
  const g = typeof globalThis !== 'undefined' ? globalThis[name] : undefined;
  if (g) return g;
  if (typeof require === 'function') { try { return require(file); } catch (_) { /* not bundled here */ } }
  return null;
}
/**
 * Why a job's PLAN may not change, or null. Only a voided or cancelled job:
 * a credit note or a ZATCA report does not stop money still owed from being
 * scheduled (2,120 with 500 credited still owes 620; money review, Nov 18).
 */
function planFrozen(order) {
  const o = order || {};
  if (o.voidedAt) return 'voided';
  if (o.status === 'cancelled') return 'cancelled';
  return null;
}
/**
 * Why a PAYMENT may not be recorded on the job, or null: a voided or
 * cancelled job, a quote ('quote'), or one that can owe nothing at all
 * (lib/order-money.js owesAtAll: credited in full, not earning: 'nothing_owed').
 */
function paymentFrozen(order) {
  const o = order || {};
  const plan = planFrozen(o);
  if (plan) return plan;
  if (o.status === 'quote') return 'quote';
  const M = libOf('KhaytOrderMoney', './order-money.js');
  if (M && M.owesAtAll && !M.owesAtAll(o)) return 'nothing_owed';
  return null;
}
/** 'recorded' (paid through a recorded payment), 'legacy' (ticked paid, no payment recorded) or 'open'. */
function rowState(row) {
  if (!row || !row.paid) return 'open';
  return row.recorded === true ? 'recorded' : 'legacy';
}
/** The cash the job can still take (lib/order-payment.js cashDue less what is paid), to the cent. */
function owedNow(order, ctx) {
  const P = libOf('KhaytOrderPayment', './order-payment.js');
  const cash = P && P.cashDue ? P.cashDue(order, ctx).cash : (Number(order && order.price) || 0);
  return round2(Math.max(0, cash - (Number(order && order.paidAmount) || 0)));
}
const keyOf = (r) => JSON.stringify([r.id, round2(Number(r.amount) || 0), r.dueDate || '', r.note || '', !!r.paid, r.paidAt || null, r.recorded === true, r.method || null]);

/**
 * Save a job's plan: `rows` is the whole schedule as the dialog holds it.
 * Refused, with nothing written:
 *   'voided'/'cancelled' planFrozen: only these stop a plan;
 *   'paid_row_locked'    a paid row (recorded or legacy) was changed or removed;
 *   'paid_needs_payment' a new row arrives paid (a row is paid by a payment);
 *   'bad_amount'         an amount that is not a number 0 or more;
 *   'over_owed'          the unpaid rows ask for more than the job still owes
 *                        (`over` says by how much). Under is allowed.
 * paidAmount and paymentStatus are never touched.
 */
function applyPlan(order, rows, ctx) {
  const frozen = planFrozen(order);
  if (frozen) return { ok: false, reason: frozen };
  const next = Array.isArray(rows) ? rows.filter(Boolean) : [];
  const old = Array.isArray(order.instalments) ? order.instalments.filter(Boolean) : [];
  for (const p of old.filter((r) => r.paid)) {
    const kept = next.find((r) => r.id === p.id);
    if (!kept || keyOf(kept) !== keyOf(p)) return { ok: false, reason: 'paid_row_locked' };
  }
  for (const r of next) {
    if (r.paid && !old.some((p) => p.paid && p.id === r.id)) return { ok: false, reason: 'paid_needs_payment' };
    if (r.paid) continue;  // a paid row is copied through as it was, whatever it holds
    // A payment of nothing is not a payment: recorded, it would still fire the
    // payment email, the webhook and an accounting entry (money review, Nov 18).
    const n = Number(r.amount);
    if (!Number.isFinite(n) || n <= 0) return { ok: false, reason: 'bad_amount' };
  }
  // What the unpaid rows still ask for (rows not paid, and covered rows the
  // money behind them no longer pays: reopened), less the money already
  // recorded outside the plan, which pays them down: whole rows it covers AND
  // the part of the next one.
  const al = allocate(Object.assign({}, order, { instalments: next }));
  const outside = Math.max(0, al.unallocated);
  const unpaid = round2(next.filter((r, i) => !r.paid || al.rows[i].reopened).reduce((s, r) => s + (Number(r.amount) || 0), 0) - outside);
  const owed = owedNow(order, ctx);
  if (unpaid > owed + 0.005) return { ok: false, reason: 'over_owed', over: round2(unpaid - owed) };
  const before = JSON.stringify([order.instalments, order.instalmentBase]);
  if (!next.length) {
    delete order.instalments;
    delete order.instalmentBase;
  } else {
    // The cash the job already held when the plan was made: for a new plan,
    // and for a plan from before the base was kept (delta review: without it
    // every payment outside the plan counted twice), what is paid less the
    // plan's paid rows. Kept as it is otherwise.
    if (!old.length || typeof order.instalmentBase !== 'number') {
      const paidRows = next.filter((r) => r.paid).reduce((sum, r) => sum + (Number(r.amount) || 0), 0);
      order.instalmentBase = round2(Math.max(0, (Number(order.paidAmount) || 0) - paidRows));
    }
    order.instalments = next.map((r) => {
      // A row that has not changed is copied through BYTE FOR BYTE, as stored:
      // a paid or legacy row from an older book keeps its exact shape (no
      // dueDate or note added, '373.34' left a string), so an untouched plan
      // reports changed: false (money review, Nov 18).
      const same = old.find((p) => p.id === r.id && keyOf(p) === keyOf(r));
      if (same) return JSON.parse(JSON.stringify(same));
      const out = { id: r.id, amount: round2(Number(r.amount) || 0), dueDate: r.dueDate || '', note: r.note || '', paid: !!r.paid, paidAt: r.paidAt || null };
      if (r.recorded === true) out.recorded = true;
      if (r.method) out.method = r.method;
      return out;
    });
  }
  return { ok: true, changed: JSON.stringify([order.instalments, order.instalmentBase]) !== before };
}

// ── Money recorded outside the plan (Dev Hub option 1, Nov 18) ──────────
//
// A payment recorded as a TOTAL (the phone, the Mac, the desktop's own Record
// payment) moves paidAmount and ticks no row. That money is UNALLOCATED:
// paidAmount − (instalmentBase + the paid rows). It covers the oldest unpaid
// rows first, a row only when it covers all of it, and stops at the first it
// cannot cover. A covered row is never chased by a reminder, cannot be
// recorded again ('use_recorded'), and the shop can stamp it paid with no
// money moving (coverRow). One function says all of this, so the dialog,
// recordRowPayment and the reminders cannot drift.
//
// A plan with no instalmentBase (made before the base was kept) cannot tell
// its deposit from plan money, so nothing is covered on it: unallocated 0.

/**
 * Each row's state and the unallocated money: { unallocated, known, rows:
 * [{ id, state: 'recorded' | 'legacy' | 'covered' | 'open', part, reopened }] }.
 *
 * REOPENING (delta review): when the payment total is corrected DOWN after a
 * row was covered, unallocated goes below 0 and money is owed that no row
 * asks for. Rows that were only COVERED (stamped with no money of their own:
 * covered: true) reopen, newest first, until it is not; they are 'open'
 * again, and reminders chase them. A row paid by a real recorded payment
 * never reopens.
 *
 * `part`: what money recorded outside the plan already pays of the first open
 * row it cannot cover whole; recordRowPayment takes only the rest.
 */
function allocate(order) {
  const o = order || {};
  const rows = (Array.isArray(o.instalments) ? o.instalments : []).filter(Boolean);
  const known = typeof o.instalmentBase === 'number' && o.instalmentBase >= 0;
  const paidRows = round2(rows.filter((r) => r.paid).reduce((sum, r) => sum + (Number(r.amount) || 0), 0));
  let unallocated = known ? round2((Number(o.paidAmount) || 0) - o.instalmentBase - paidRows) : 0;
  const due = (r) => toIsoDay(r.dueDate) || '9999-12-31';
  const reopened = new Set();
  if (unallocated < -0.005) {
    const onlyCovered = rows.map((r, i) => ({ r, i })).filter((x) => x.r.paid && x.r.covered === true)
      .sort((a, b) => (due(a.r) !== due(b.r) ? (due(a.r) > due(b.r) ? -1 : 1) : b.i - a.i));
    for (const { r, i } of onlyCovered) {
      if (unallocated >= -0.005) break;
      reopened.add(i);
      unallocated = round2(unallocated + (Number(r.amount) || 0));
    }
  }
  const state = rows.map((r, i) => (reopened.has(i) ? 'open' : r.paid ? rowState(r) : 'open'));
  const part = rows.map(() => 0);
  const open = rows.map((r, i) => ({ r, i })).filter((x) => state[x.i] === 'open')
    .sort((a, b) => (due(a.r) !== due(b.r) ? (due(a.r) < due(b.r) ? -1 : 1) : a.i - b.i));
  let left = Math.max(0, unallocated);
  for (const { r, i } of open) {
    const amount = round2(Number(r.amount) || 0);
    if (amount > 0 && left + 0.005 >= amount) { state[i] = 'covered'; left = round2(left - amount); continue; }
    if (left > 0.005 && amount > 0) part[i] = round2(left);
    break;
  }
  return { unallocated, known, rows: rows.map((r, i) => ({ id: r.id, state: state[i], part: part[i], reopened: reopened.has(i) })) };
}
const allocOf = (order, rowId) => allocate(order).rows.find((x) => x.id === rowId) || { state: null, part: 0 };
const stateIn = (order, rowId) => allocOf(order, rowId).state;

/**
 * Stamp a COVERED row paid: money already recorded outside the plan pays it,
 * so nothing moves (no payment, no email, no accounting). Refused:
 * planFrozen's reason; 'missing'; 'not_covered'.
 */
function coverRow(order, rowId, ctx) {
  const frozen = planFrozen(order);
  if (frozen) return { ok: false, reason: frozen };
  const row = (Array.isArray(order.instalments) ? order.instalments : []).find((r) => r && r.id === rowId);
  if (!row) return { ok: false, reason: 'missing' };
  if (stateIn(order, rowId) !== 'covered') return { ok: false, reason: 'not_covered' };
  row.paid = true;
  row.paidAt = (ctx && ctx.today) || toIsoDay(new Date());
  row.recorded = true;
  row.covered = true;
  return { ok: true, reason: null };
}

/** The rows a reminder may chase: unpaid, not covered, due by `now`; oldest first. */
function dueRows(order, now) {
  const rows = (Array.isArray(order && order.instalments) ? order.instalments : []).filter(Boolean);
  const states = allocate(order).rows;
  const today = toIsoDay(now) || toIsoDay(new Date());
  return rows.filter((r, i) => states[i].state === 'open' && r.dueDate && toIsoDay(r.dueDate) <= today)
    .sort((a, b) => (toIsoDay(a.dueDate) < toIsoDay(b.dueDate) ? -1 : toIsoDay(a.dueDate) > toIsoDay(b.dueDate) ? 1 : 0));
}

/**
 * Collect one row: the job's payment rises by the row's amount through
 * lib/order-payment.js recordPayment, and the row is stamped paid by a
 * recorded payment. `payment`: { method, paidAt }. Refused, nothing written:
 * paymentFrozen's reason ('voided', 'cancelled', 'quote', 'nothing_owed');
 * 'missing'; 'already_paid'; 'bad_amount' (0 or less); 'over_billed' (the job would
 * hold more than it can be paid: an overpayment is a credit note).
 * Returns { ok, reason, effects } (recordPayment's effects, for the host).
 */
function recordRowPayment(order, rowId, payment, ctx) {
  const frozen = paymentFrozen(order);
  if (frozen) return { ok: false, reason: frozen };
  const row = (Array.isArray(order.instalments) ? order.instalments : []).find((r) => r && r.id === rowId);
  if (!row) return { ok: false, reason: 'missing' };
  const al = allocOf(order, rowId);
  // Paid, unless it was only covered and the money behind it was corrected away (reopened).
  if (row.paid && al.state !== 'open') return { ok: false, reason: 'already_paid' };
  const amount = round2(Number(row.amount) || 0);
  if (!(amount > 0)) return { ok: false, reason: 'bad_amount' };
  // A plan from before the base was kept cannot tell its deposit from plan
  // money: saving it once (applyPlan) sets the base; until then, no row.
  if (typeof order.instalmentBase !== 'number') return { ok: false, reason: 'no_base' };
  // Money already recorded pays this row: recording it again would count it twice.
  if (al.state === 'covered') return { ok: false, reason: 'use_recorded' };
  const P = libOf('KhaytOrderPayment', './order-payment.js');
  if (!P) return { ok: false, reason: 'missing' };
  // Only what is left of the row (money outside the plan may pay part of it),
  // and never more than the job can still take (delta review: a part-covered
  // last row was refused for ever, and chased for ever).
  const pay = round2(Math.min(round2(amount - (al.part || 0)), owedNow(order, ctx)));
  if (!(pay > 0.005)) return { ok: false, reason: 'over_billed' };
  const p = payment || {};
  const total = round2((Number(order.paidAmount) || 0) + pay);
  const out = P.recordPayment(order, { amount: total, method: p.method || null, paidAt: p.paidAt }, ctx);
  row.paid = true;
  row.paidAt = order.paidAt || p.paidAt || null;
  row.recorded = true;
  delete row.covered;  // paid by its own payment now, so it never reopens
  if (p.method) row.method = p.method;
  return { ok: true, reason: null, effects: out.effects, paid: pay };
}

const api = {
  applyPlan,
  recordRowPayment,
  planFrozen,
  paymentFrozen,
  allocate,
  coverRow,
  dueRows,
  rowState,
  owedNow,
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
