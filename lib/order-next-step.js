'use strict';

/**
 * THE NEXT STEP FOR A JOB — one rule for the Mac, the desktop and the iPhone.
 *
 * A job page pins one button: the next thing the shop does to this job
 * (S1, Turki, Nov 11 2026). The rule lived twice — the Mac's
 * `Shop+NextStep.swift` over `Stage.progression`, and the iPhone's
 * `OrderStatus.nextInQueue` — and they disagreed: the phone knew nothing of
 * hand-over or payment, and neither offered anything for a job on hold. This
 * is the one place it is decided now; the apps only word it.
 *
 * PURE: no clock, no DOM, no i18n, no `global`/`window` (it runs in the Mac's
 * and the phone's JavaScriptCore). It reads `KhaytOrderStatus` (stage, gate)
 * and `KhaytOrderMoney` (what is owed) off `globalThis`, or through a guarded
 * `require`, and nothing else.
 *
 * ── nextSteps(order, ctx) ────────────────────────────────────────────────
 *
 * `ctx` (all optional):
 *   settings   the book's settings — the gate's (production paused, WIP
 *              limits) and the tax profile owed is judged under.
 *   orders     every job, for the WIP limit.
 *   today      'YYYY-MM-DD', the shop's day. Late = due before today.
 *   late       the caller's own answer to "is this job late" (the Mac's
 *              `attention` rule), used INSTEAD of the date comparison.
 *   canWrite   false = this person or device may not change the job; every
 *              step comes back blocked `read_only`.
 *
 * Returns null for no order, else:
 *   {
 *     stage,                  // stageOf: quote | pending | on_hold | printing |
 *                             //   post | qc | completed | shipped | delivered |
 *                             //   cancelled | split | …
 *     pill: { stage, tone },  // what the header chip says. `stage` is the
 *                             //   stage, or 'paid' for a job handed over and
 *                             //   settled. tone: steel | amber | green |
 *                             //   purple | grey.
 *     late,                   // boolean. Never for a finished or cancelled job.
 *     owed,                   // still to pay, the job's own currency (0 for a
 *                             //   quote, a cancelled or a voided job).
 *     heldFrom,               // on hold only: the stage it goes back to.
 *     primary,                // the ONE next step, or null:
 *       { code, to, asks, blocked }
 *     secondary: [ … ],       // the same shape: what else is one tap away.
 *     track: [ { stage, state: 'done' | 'current' | 'todo', at } ],
 *   }
 *
 * A step:
 *   code     what it is (below).
 *   to       the status it moves the job to, or null when it is not a move
 *            (a hand-over stamps a date; a payment opens a sheet).
 *   asks     the question the app must ask before doing it, or null:
 *              'hold'     why, and until when
 *              'actuals'  what it really took (the gate's `needsActuals`)
 *              'qc_fail'  what failed inspection
 *              'send'     how to send the quote
 *              'payment'  how much, and how
 *   blocked  null, or `{ code, params }` — the gate's refusal, said at the
 *            control instead of after the press: production_paused,
 *            wip_blocked, assembly_not_assembled, assembly_parts, read_only.
 *
 * ── THE STEPS (Turki's decisions, Nov 11) ────────────────────────────────
 *
 *   quote, not yet sent    send_quote      (take_job stays one tap away)
 *   quote, sent            take_job        → pending
 *   pending                start_printing  → printing
 *   on hold                resume          → the stage it was held from
 *   printing               mark_printed    → post
 *   post                   send_to_check   → qc        (QC stays its own step)
 *   qc                     mark_ready      → completed, asks actuals
 *   completed / shipped    hand_over       (stamps deliveredAt)
 *   delivered, owing       record_payment
 *   delivered, settled     —               the pill reads Paid
 *   cancelled, split       —
 *
 * "Sent" is `quoteSharedAt`, stamped when the quote link is copied, a
 * follow-up goes out or the paper is shared (Turki, Nov 11). NOT
 * `quoteSentAt`: `order-new.js` writes that on every quote the moment it is
 * created — it is the day it was quoted, and counting it would call every
 * quote sent. Until an app stamps `quoteSharedAt`, a quote's primary is
 * send_quote and take_job is its first secondary — an app that cannot send
 * says take_job.
 */
(function () {
  const G = typeof globalThis !== 'undefined' ? globalThis : {};
  const lazy = (name, path) => () => G[name] || (typeof require === 'function' ? (() => {
    try { return require(path); } catch (_) { return null; }
  })() : null);
  const statusLib = lazy('KhaytOrderStatus', './order-status.js');
  const moneyLib = lazy('KhaytOrderMoney', './order-money.js');

  const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);

  /** The stages a job is worked through, in order — and so the ones a held
   *  job can go back to. */
  const WORKING = ['pending', 'printing', 'post', 'qc'];

  /** The one move along from each working stage. */
  const ALONG = {
    pending: { code: 'start_printing', to: 'printing' },
    printing: { code: 'mark_printed', to: 'post' },
    post: { code: 'send_to_check', to: 'qc' },
    qc: { code: 'mark_ready', to: 'completed' },
  };

  const TONES = {
    quote: 'steel', pending: 'steel',
    printing: 'amber', post: 'amber', qc: 'amber',
    completed: 'green', shipped: 'green', delivered: 'green', paid: 'green',
    on_hold: 'purple',
  };
  const toneOf = (stage) => TONES[stage] || 'grey';

  /** The stage track, start to end. `quote` leads only for a job that was one. */
  const TRACK = ['pending', 'printing', 'post', 'qc', 'completed', 'delivered'];

  function stageOf(order) {
    const S = statusLib();
    if (S && S.stageOf) return S.stageOf(order);
    if (!order) return null;
    if (order.status === 'completed' && order.deliveredAt) return 'delivered';
    if (order.status === 'completed' && order.shippedAt) return 'shipped';
    return order.status || null;
  }

  const history = (order) => (Array.isArray(order.statusHistory) ? order.statusHistory : [])
    .filter((e) => isObj(e) && typeof e.status === 'string');

  /**
   * The working stage a job was in before its last move onto hold, from its
   * status history; `pending` when the history does not say. A job held from
   * anywhere else (a quote, a finished job) goes back to pending too: resume
   * means "back into the work".
   */
  function heldFrom(order) {
    const h = history(order);
    let held = -1;
    for (let i = h.length - 1; i >= 0; i -= 1) { if (h[i].status === 'on_hold') { held = i; break; } }
    for (let i = held - 1; i >= 0; i -= 1) {
      if (h[i].status === 'on_hold') continue;
      return WORKING.indexOf(h[i].status) !== -1 ? h[i].status : 'pending';
    }
    return 'pending';
  }

  /** Whether the customer has been sent this quote (`quoteSharedAt` only:
   *  `quoteSentAt` is written at creation and says nothing about sending). */
  function quoteSent(order) {
    return !!(order && order.quoteSharedAt);
  }

  /** What is still to pay, in the job's own currency. */
  function owedOf(order, ctx) {
    const M = moneyLib();
    if (M && M.orderOwedRaw) {
      const owed = +M.orderOwedRaw(order, { settings: isObj(ctx.settings) ? ctx.settings : {} });
      return Number.isFinite(owed) ? owed : 0;
    }
    if (!order || order.status === 'quote' || order.status === 'cancelled' || order.voidedAt || order.creditedAt) return 0;
    return Math.max(0, (+order.price || 0) - (+order.paidAmount || 0));
  }
  /** Under half a halala is nothing owed: a rounding crumb never asks for a payment. */
  const owes = (owed) => owed > 0.005;

  function isLate(order, stage, ctx) {
    if (stage === 'completed' || stage === 'shipped' || stage === 'delivered'
        || stage === 'cancelled' || stage === 'quote' || stage === 'split') return false;
    if (typeof ctx.late === 'boolean') return ctx.late;
    const due = typeof order.dueDate === 'string' ? order.dueDate.slice(0, 10) : '';
    const today = typeof ctx.today === 'string' ? ctx.today.slice(0, 10) : '';
    return !!due && !!today && due < today;
  }

  /** A step, with the gate's answer for a move. */
  function step(order, code, to, asks, ctx) {
    let blocked = null;
    let ask = asks || null;
    if (ctx.canWrite === false) {
      blocked = { code: 'read_only', params: {} };
    } else if (to) {
      const S = statusLib();
      const g = S && S.gate ? S.gate(order, to, { settings: ctx.settings, orders: ctx.orders }) : null;
      if (g && !g.ok && g.block) blocked = { code: g.block.code, params: g.block.params || {} };
      if (g && g.ok && g.needsActuals) ask = 'actuals';
    }
    return { code, to: to || null, asks: ask, blocked };
  }

  /** When the job reached `stage`, by its stamps and then its history. */
  function reachedAt(order, stage) {
    if (stage === 'delivered' && order.deliveredAt) return String(order.deliveredAt);
    if (stage === 'shipped' && order.shippedAt) return String(order.shippedAt);
    if (stage === 'completed' && order.completedAt) return String(order.completedAt);
    const h = history(order);
    for (let i = h.length - 1; i >= 0; i -= 1) {
      if (h[i].status === stage && h[i].at) return String(h[i].at);
    }
    return '';
  }

  /**
   * The stage track. The job's place on it is its stage — for a job on hold,
   * the stage it was held from (the header says it is on hold). A shipped job
   * stands at the last node, named `shipped` with its date, until it is
   * handed over (Dev Hub and the desktop, Nov 11). A cancelled or split job
   * has no current node: what it reached is done, the rest is not.
   */
  function trackOf(order, stage, held) {
    const wasQuote = stage === 'quote' || history(order).some((e) => e.status === 'quote') || !!order.quoteNumber;
    const nodes = (wasQuote ? ['quote'] : []).concat(TRACK);
    const at = stage === 'on_hold' ? held : stage === 'shipped' ? 'delivered' : stage;
    const here = nodes.indexOf(at);
    return nodes.map((node, i) => {
      const name = node === 'delivered' && stage === 'shipped' ? 'shipped' : node;
      let state;
      if (here === -1) state = reachedAt(order, node) ? 'done' : 'todo';
      else state = i < here ? 'done' : i === here ? 'current' : 'todo';
      // A job handed over has nothing left on the track.
      if (stage === 'delivered' && i === here) state = 'done';
      return { stage: name, state, at: state === 'todo' ? '' : reachedAt(order, name) };
    });
  }

  function nextSteps(order, ctx) {
    if (!isObj(order)) return null;
    const c = isObj(ctx) ? ctx : {};
    const stage = stageOf(order);
    const owed = owedOf(order, c);
    const held = stage === 'on_hold' ? heldFrom(order) : null;
    const dead = !!order.voidedAt;

    let primary = null;
    const secondary = [];
    const hold = () => step(order, 'hold', 'on_hold', 'hold', c);
    const pay = () => step(order, 'record_payment', null, 'payment', c);

    if (dead) {
      // A voided job is not worked on or collected.
    } else if (stage === 'quote') {
      const take = step(order, 'take_job', 'pending', null, c);
      if (quoteSent(order)) {
        primary = take;
        secondary.push(step(order, 'send_quote', null, 'send', c));
      } else {
        primary = step(order, 'send_quote', null, 'send', c);
        secondary.push(take);
      }
    } else if (ALONG[stage]) {
      primary = step(order, ALONG[stage].code, ALONG[stage].to, null, c);
      // Leaving inspection for anywhere but Completed is a failed check.
      if (stage === 'qc') secondary.push(step(order, 'fail_check', 'post', 'qc_fail', c));
      secondary.push(hold());
      if (owes(owed)) secondary.push(pay());
    } else if (stage === 'on_hold') {
      primary = step(order, 'resume', held, null, c);
      if (owes(owed)) secondary.push(pay());
    } else if (stage === 'completed' || stage === 'shipped') {
      primary = step(order, 'hand_over', null, null, c);
      // Shipping is a date stamped on a finished job, never a status.
      if (stage === 'completed') secondary.push(step(order, 'ship', null, null, c));
      if (owes(owed)) secondary.push(pay());
    } else if (stage === 'delivered') {
      if (owes(owed)) primary = pay();
    }

    const settled = stage === 'delivered' && !owes(owed) && (+order.price || 0) > 0 && !dead;
    const pillStage = settled ? 'paid' : stage;
    return {
      stage,
      pill: { stage: pillStage, tone: dead ? 'grey' : toneOf(pillStage) },
      late: dead ? false : isLate(order, stage, c),
      owed: Math.round(owed * 100) / 100,
      heldFrom: held,
      primary,
      secondary,
      track: trackOf(order, stage, held),
    };
  }

  /**
   * `nextSteps` for a whole book in one call: `{ [order.id]: steps }`.
   * `ctx.lateIds` (an array of ids) is each job's `late`, when the caller has
   * its own rule; without it the date comparison is used.
   */
  function nextStepsAll(orders, ctx) {
    const c = isObj(ctx) ? ctx : {};
    const list = Array.isArray(orders) ? orders : [];
    const lateIds = Array.isArray(c.lateIds) ? new Set(c.lateIds) : null;
    const out = {};
    for (const o of list) {
      if (!isObj(o) || typeof o.id !== 'string') continue;
      const one = Object.assign({}, c, { orders: c.orders || list });
      if (lateIds) one.late = lateIds.has(o.id);
      out[o.id] = nextSteps(o, one);
    }
    return out;
  }

  const api = { WORKING, TRACK, TONES, toneOf, heldFrom, quoteSent, nextSteps, nextStepsAll };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytOrderNextStep = api;
})();
