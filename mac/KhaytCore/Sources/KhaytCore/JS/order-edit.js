'use strict';

/**
 * Changing a job's own details, and remembering that it changed.
 *
 * The order editor writes thirty fields; five of them are RECORDED — the due
 * date, the discount, the shipping, and the two that carry the priority. Those
 * five are the ones a customer can be told a different answer about later, so
 * `editHistory` exists to say who moved the goalposts and when.
 *
 * The rule lived inside the editor's save handler, which meant anything else
 * that changed a due date changed it silently. The Mac app is about to be one
 * of those things.
 *
 * PURE: no globals, and no clock — `ctx.now` is the current time in
 * milliseconds. `ctx.id` supplies the entry's identifier, because a random
 * source is what a pure module does not have.
 *
 * ── THE PRIORITY IS TWO FIELDS AND THEY MOVE TOGETHER ──────────────────────
 * `priorityLevel` is the answer ('normal' | 'high' | 'urgent') and `priority`
 * is the older boolean that the kanban card, the Mac app's card and every
 * older record still carry. Setting one without the other leaves a job that is
 * urgent on one screen and ordinary on another, which is exactly what
 * `getPriorityLevel` was written to paper over. They are set as a pair here.
 */
(function (global) {

  /** A job remembers its last hundred edits and no more. */
  const EDIT_HISTORY_CAP = 100;

  /** The fields whose changes are written down. */
  // `price` joined on 2026-09-16: a job's total can be adjusted after it is
  // taken — "we agreed 1,800 in the end" — and that is the change a customer
  // is most likely to be told a different answer about later.
  const TRACKED_FIELDS = ['dueDate', 'discountPct', 'shippingCost', 'priority', 'priorityLevel', 'price'];

  /** In the order a shop escalates. */
  const PRIORITY_LEVELS = ['normal', 'high', 'urgent'];

  const ctxOf = (ctx) => (ctx && typeof ctx === 'object' ? ctx : {});

  /**
   * The priority as BOTH fields.
   *
   * An unknown level is 'normal': a job whose urgency nobody can read is not
   * urgent, and guessing upward would put it at the top of every queue.
   */
  function priorityFrom(level) {
    const wanted = PRIORITY_LEVELS.indexOf(level) === -1 ? 'normal' : level;
    return { priorityLevel: wanted, priority: wanted !== 'normal' };
  }

  /** The level a job is at, however old the record is. */
  function priorityOf(order) {
    if (!order) return 'normal';
    if (PRIORITY_LEVELS.indexOf(order.priorityLevel) > 0) return order.priorityLevel;
    if (order.priorityLevel === 'normal') return 'normal';
    return order.priority ? 'high' : 'normal';
  }

  /**
   * What changed, among the fields that are written down.
   *
   * Compared as STRINGS, the way the editor always has: a due date arrives from
   * a date input and a discount from a number input, and `5` and `'5'` are the
   * same answer typed twice. Null and undefined and '' are all "not set".
   */
  function changesBetween(order, next) {
    const changes = {};
    for (const key of TRACKED_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(next, key)) continue;
      const from = order[key];
      const to = next[key];
      if (String(from == null ? '' : from) !== String(to == null ? '' : to)) {
        changes[key] = { from, to };
      }
    }
    return changes;
  }

  /**
   * Write an edit into the job's history.
   *
   * Nothing is recorded for an empty change set — an editor opened and closed
   * again is not an edit, and a history full of those hides the real ones.
   */
  function recordEdit(order, changes, ctx) {
    if (!changes || Object.keys(changes).length === 0) return false;
    const c = ctxOf(ctx);
    order.editHistory = order.editHistory || [];
    order.editHistory.push({
      id: c.id || null,
      at: new Date(typeof c.now === 'number' ? c.now : Date.now()).toISOString(),
      fields: changes,
    });
    if (order.editHistory.length > EDIT_HISTORY_CAP) {
      order.editHistory = order.editHistory.slice(-EDIT_HISTORY_CAP);
    }
    return true;
  }

  /**
   * Apply a set of tracked changes to a job, in place, and record them.
   *
   * `next` names only the fields being changed. `dueDate` set to '' or null
   * clears it — a job with no due date is a real answer, and the field has to
   * be able to say it.
   *
   * Returns `{ changes, effects }`; `effects` is empty when nothing changed, so
   * a caller that saves on a non-empty list cannot write a revision for an
   * editor somebody opened and closed.
   */
  /** null, undefined and '' are ABSENT — an empty price box is not a free job. */
  function optional(v) {
    if (v === null || v === undefined || v === '') return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }

  function applyEdit(order, next, ctx) {
    const wanted = Object.assign({}, next || {});
    // The priority is a pair. A caller naming only the level gets both.
    if (Object.prototype.hasOwnProperty.call(wanted, 'priorityLevel')) {
      Object.assign(wanted, priorityFrom(wanted.priorityLevel));
    }
    // A price is a typed total: a number, never negative, money's two
    // decimals. Anything else is "leave the price alone", not "zero".
    if (Object.prototype.hasOwnProperty.call(wanted, 'price')) {
      const typed = optional(wanted.price);
      if (typed === null || typed < 0) delete wanted.price;
      else wanted.price = Math.round(typed * 100) / 100;
    }
    const changes = changesBetween(order, wanted);
    if (Object.keys(changes).length === 0) return { changes: {}, effects: [] };

    for (const key of TRACKED_FIELDS) {
      if (!Object.prototype.hasOwnProperty.call(wanted, key)) continue;
      const value = wanted[key];
      if (key === 'dueDate' && (value === '' || value == null)) order.dueDate = null;
      else order[key] = value;
    }
    if (changes.price) adjustPrice(order, changes.price, ctx);
    recordEdit(order, changes, ctx);

    return {
      changes,
      effects: [
        { type: 'save' },
        { type: 'render', dashboard: true },
        { type: 'toast_saved' },
      ],
    };
  }

  /**
   * What follows a typed price.
   *
   * The record says how its price was reached (`lib/order-new.js` writes
   * `computedPrice` / `priceSource` when rounding or a typed figure did):
   * an adjustment keeps the arithmetic's figure — the one already there, or
   * the price this edit replaced when nothing had been written down — marks
   * the source as `override`, and keeps the typed figure beside it.
   *
   * And the money follows the price. What has been paid can never exceed
   * what is owed, and the payment status is the payment rule's answer, not a
   * stored word that now disagrees with the arithmetic — see
   * `lib/order-payment.js` for why that word is derived.
   */
  /**
   * `ctx.settings`, when given, makes the cap and the status tax-aware: a shop
   * that adds tax on top can hold price + tax as paid (order-money.js).
   */
  function adjustPrice(order, change, ctx) {
    if (order.priceSource !== 'override') {
      const had = optional(order.computedPrice);
      const was = optional(change.from);
      if (had !== null) order.computedPrice = had;
      else if (was !== null) order.computedPrice = was;
    }
    order.priceSource = 'override';
    order.priceOverride = order.price;
    const paid = optional(order.paidAmount) || 0;
    const settingsCtx = ctx && ctx.settings ? { settings: ctx.settings } : undefined;
    const Money = typeof globalThis !== 'undefined' ? globalThis.KhaytOrderMoney : undefined;
    const billed = (Money && typeof Money.orderGrossRaw === 'function')
      ? Money.orderGrossRaw(order, settingsCtx) : order.price;
    if (paid > billed) order.paidAmount = billed;
    const Pay = typeof globalThis !== 'undefined' ? globalThis.KhaytOrderPayment : undefined;
    if (Pay && typeof Pay.statusOf === 'function') {
      order.paymentStatus = Pay.statusOf(order, settingsCtx);
    } else {
      const p = optional(order.paidAmount) || 0;
      order.paymentStatus = p <= 0 ? 'unpaid' : (p + 0.005 >= order.price ? 'paid' : 'partial');
    }
  }

  /* ── THE REST OF THE ORDER EDITOR ─────────────────────────────────────────
   *
   * `applyEdit` holds the six tracked fields. The editor writes more than that
   * — notes, tags, the delivery address, who is on it, and the three terms
   * that move the price (discount, shipping, extra charges). That arithmetic
   * lived inline in the desktop's save handler (renderer/order-flows.js), so
   * the Mac app could not change a discount without inventing its own sum.
   * It is here now, unchanged, and both apps run it.
   */

  /** Text fields the editor writes as `value || undefined` — empty is GONE. */
  const OPTIONAL_TEXT = ['internalNotes', 'invoiceNotes', 'courierName', 'trackingNumber',
                         'deliveryAddress', 'operatorId'];

  const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);
  const amountOf = (v) => { const n = +v; return Number.isFinite(n) ? n : 0; };

  /** `renderer/app-helpers.js parseTags`: trimmed, de-duplicated, sorted. */
  function parseTags(raw) {
    const list = Array.isArray(raw) ? raw : String(raw == null ? '' : raw).split(',');
    return [...new Set(list.map((t) => String(t == null ? '' : t).trim()).filter(Boolean))].sort();
  }

  /** An extra charge as the editor keeps it: a label, an amount never below 0. */
  function cleanLine(line) {
    const l = Object.assign({}, line || {});
    l.label = String(l.label == null ? '' : l.label);
    l.amount = Math.max(0, amountOf(l.amount));
    return l;
  }

  /** Round to a price step — lib/pricing.js `roundToStep` when it is loaded. */
  function roundPrice(value, rule) {
    const P = typeof globalThis !== 'undefined' ? globalThis.KhaytPricing : undefined;
    const step = +rule.step;
    if (P && typeof P.roundToStep === 'function') return P.roundToStep(value, step, rule.mode);
    const q = value / step;
    const whole = Math.abs(q - Math.round(q)) < 1e-9;
    const raw = whole ? Math.round(q)
      : (rule.mode === 'up' ? Math.ceil(q) : rule.mode === 'down' ? Math.floor(q) : Math.round(q));
    return Math.round(raw * step * 100) / 100;
  }

  /**
   * Re-price a job for a new discount, shipping cost and/or extra charges.
   *
   * FORWARD, from what the job was priced from — never by working backwards
   * from the price and adding things to it again (that double-counted the
   * agreed part amounts and dropped the rush fee: a 150 job holding 50 agreed
   * went to 210 when 10 of shipping was added). The order of operations is
   * lib/pricing.js `quoteTotal`'s, and it is that function that does the sum:
   *
   *     subtotal = base × (1 − discount%) + agreedAmount
   *     rush     = subtotal × rush%
   *     total    = subtotal + rush + shipping + extras
   *
   * The inputs are read off the job as lib/order-new.js stored them:
   *   base         `priceBeforeDiscount` (stored when there was a discount);
   *                else recovered from the arithmetic figure — `computedPrice`
   *                on a rounded or typed job, else `price` — less shipping,
   *                extras, the rush fee and the agreed amount, grossed back
   *                up through the old discount;
   *   agreed       `agreedAmount` — added once, never discounted;
   *   rush%        `rushFeeAmount` as a share of the old subtotal (the
   *                setting may have moved since; the job's own rate has not);
   *   rounding     `priceRound` on a job whose `priceSource` is 'rounded'.
   *
   * A TYPED price (`priceSource: 'override'`, or a price that is not what its
   * own inputs give — edited by hand at some point) stays as typed: it moves
   * by exactly what the changed term moved the arithmetic, nothing else.
   * Extra lines are taken at their frozen `amount`, as the editor shows them.
   *
   * Nothing happens when none of the three moved. When they did, what was paid
   * is capped at what is now billed and the payment status is re-read.
   * `terms` names only what is changing; the rest is read off the order.
   * Returns true when the price was worked out again.
   */
  function repriceTerms(order, terms, ctx) {
    const t = terms || {};
    const prevDiscountPct = order.discountPct || 0;
    const prevShipping = +order.shippingCost || 0;
    const prevOldExtra = (order.extraLines || []).reduce((s, l) => s + (+(l && l.amount) || 0), 0);
    const discountPct = has(t, 'discountPct')
      ? Math.min(100, Math.max(0, +t.discountPct || 0)) : prevDiscountPct;
    const shippingCost = has(t, 'shippingCost') ? Math.max(0, +t.shippingCost || 0) : prevShipping;
    const lines = has(t, 'extraLines') ? (Array.isArray(t.extraLines) ? t.extraLines : []) : null;
    const newExtraTotal = lines
      ? lines.reduce((s, l) => s + Math.max(0, +(l && l.amount) || 0), 0) : prevOldExtra;
    if (discountPct === prevDiscountPct && shippingCost === prevShipping && newExtraTotal === prevOldExtra) {
      return false;
    }

    // ── What the job was priced from ──
    const price = +order.price || 0;
    const agreed = Math.max(0, +order.agreedAmount || 0);
    const rushAmt = Math.max(0, +order.rushFeeAmount || +order.rushFee || 0);
    const typedSource = order.priceSource === 'override';
    const roundRule = order.priceSource === 'rounded' && order.priceRound && +order.priceRound.step > 0
      ? order.priceRound : null;
    const storedBase = +order.priceBeforeDiscount > 0 ? +order.priceBeforeDiscount : null;
    let base;
    let oldSubtotal;
    if (storedBase !== null) {
      base = storedBase;
      oldSubtotal = base * (1 - prevDiscountPct / 100) + agreed;
    } else {
      // Older jobs, and every job taken without a discount: back out of the
      // ARITHMETIC figure (not a rounded or typed one) what sits on top of
      // the subtotal, then the agreed amount, then the discount.
      const computed = (typedSource || roundRule) && Number.isFinite(+order.computedPrice) && order.computedPrice !== null
        ? +order.computedPrice : price;
      oldSubtotal = Math.max(0, computed - prevShipping - prevOldExtra - rushAmt);
      const costed = Math.max(0, oldSubtotal - agreed);
      base = prevDiscountPct < 100 ? costed / (1 - prevDiscountPct / 100) : costed; // 100%: unrecoverable, keep it
    }
    const rushPct = rushAmt > 0 && oldSubtotal > 0 ? rushAmt / oldSubtotal * 100 : 0;

    // ── The same sum that priced the job, for the old terms and the new ──
    const P = typeof globalThis !== 'undefined' ? globalThis.KhaytPricing : undefined;
    const priceOf = (dPct, ship, extras) => {
      if (P && typeof P.quoteTotal === 'function') {
        const q = P.quoteTotal({
          baseCost: base, margin: 0, qty: 1, priceTier: null, discountPct: dPct,
          agreedAmount: agreed, rushEnabled: rushPct > 0, rushPct, shippingCost: ship,
          extraLines: extras > 0 ? [{ amount: extras }] : [], business: true,
        });
        return { total: q.computedTotal, rush: q.rushFee };
      }
      const sub = base * (1 - dPct / 100) + agreed;
      const rush = sub * rushPct / 100;
      return { total: sub + rush + ship + extras, rush };
    };
    const finish = (v) => (roundRule ? roundPrice(v, roundRule) : +v.toFixed(2));
    const before = priceOf(prevDiscountPct, prevShipping, prevOldExtra);
    const after = priceOf(discountPct, shippingCost, newExtraTotal);
    // A price its own inputs do not give was set by hand: keep it, and move
    // it by what the changed term moved. A cent of slack for stored rounding.
    const typed = typedSource || Math.abs(finish(before.total) - price) > 0.011;
    const newPrice = typed
      ? Math.max(0, +(price + after.total - before.total).toFixed(2))
      : Math.max(0, finish(after.total));

    order.price = newPrice;
    order.discountPct = discountPct;
    order.priceBeforeDiscount = discountPct > 0 ? +base.toFixed(2) : null;
    order.shippingCost = shippingCost;
    if (rushPct > 0) {
      const rush = +after.rush.toFixed(2);
      order.rushFeeAmount = rush;
      if (rush > 0) order.rushFee = rush; else delete order.rushFee;
    }
    if (has(order, 'computedPrice') && order.computedPrice !== null && order.computedPrice !== undefined) {
      order.computedPrice = +after.total.toFixed(2);
    }
    if (typedSource) order.priceOverride = newPrice;
    // Billed, not priced: a shop that adds tax on top can hold price + tax.
    const settingsCtx = ctx && ctx.settings ? { settings: ctx.settings } : undefined;
    const Money = typeof globalThis !== 'undefined' ? globalThis.KhaytOrderMoney : undefined;
    const billed = (Money && typeof Money.orderGrossRaw === 'function')
      ? Money.orderGrossRaw(order, settingsCtx) : order.price;
    if ((order.paidAmount || 0) > billed) order.paidAmount = billed;
    const Pay = typeof globalThis !== 'undefined' ? globalThis.KhaytOrderPayment : undefined;
    if (Pay && typeof Pay.statusOf === 'function') order.paymentStatus = Pay.statusOf(order, settingsCtx);
    return true;
  }

  /**
   * Save the order editor: every field it names, in the desktop's order.
   *
   * `next` names ONLY what is changing (`hasOwnProperty`, as `applyEdit`), so
   * an editor that sends what the shop touched cannot write back a stale copy
   * of a field somebody else changed meanwhile. Understood:
   *
   *   notes, internalNotes, invoiceNotes, courierName, trackingNumber,
   *   deliveryAddress, operatorId, tags (array or comma text), dueDate,
   *   priorityLevel, discountPct, shippingCost, extraLines, price (a typed
   *   total — the last word, after the arithmetic).
   *
   * The due date, discount, shipping and priority go into `editHistory` as
   * ONE entry (`ctx.id`), compared before anything moves, exactly as the
   * desktop's save does; a typed price is its own entry (`ctx.priceId`).
   *
   * Returns `{ changes, changed }` — `changed` false when the record came out
   * as it went in, so a caller writes nothing for an editor opened and closed.
   */
  function applyDetails(order, next, ctx) {
    const c = ctxOf(ctx);
    const n = Object.assign({}, next || {});
    const before = JSON.stringify(order);

    // Normalised first, so what is RECORDED is what is written.
    if (has(n, 'discountPct')) n.discountPct = Math.min(100, Math.max(0, +n.discountPct || 0));
    if (has(n, 'shippingCost')) n.shippingCost = Math.max(0, +n.shippingCost || 0);
    if (has(n, 'extraLines')) n.extraLines = (Array.isArray(n.extraLines) ? n.extraLines : []).map(cleanLine);
    if (has(n, 'dueDate')) n.dueDate = n.dueDate || null;

    const tracked = {};
    for (const k of ['dueDate', 'discountPct', 'shippingCost']) if (has(n, k)) tracked[k] = n[k];
    if (has(n, 'priorityLevel')) Object.assign(tracked, priorityFrom(n.priorityLevel));
    const changes = changesBetween(order, tracked);
    recordEdit(order, changes, { now: c.now, id: c.id });

    if (has(n, 'notes')) order.notes = String(n.notes == null ? '' : n.notes);
    for (const k of OPTIONAL_TEXT) {
      if (!has(n, k)) continue;
      const v = n[k] == null ? '' : String(n[k]);
      if (v) order[k] = v; else delete order[k];
    }
    if (has(n, 'tags')) {
      const tags = parseTags(n.tags);
      if (tags.length) order.tags = tags; else delete order.tags;
    }
    if (has(n, 'dueDate')) order.dueDate = n.dueDate;
    if (has(n, 'priorityLevel')) Object.assign(order, priorityFrom(n.priorityLevel));
    // The shop's own order fields (`settings.customFields`), stored as
    // `customData: { [fieldId]: text }`. MERGED, one key at a time: a value
    // for a field this editor was not handed — one the shop has since
    // removed from Settings, or one added on another device — stays. A blank
    // value takes its key away, and no values left takes `customData` away,
    // as the desktop's editor leaves it.
    if (has(n, 'customData') && n.customData && typeof n.customData === 'object') {
      const cd = Object.assign({}, (order.customData && typeof order.customData === 'object') ? order.customData : {});
      for (const k of Object.keys(n.customData)) {
        const v = n.customData[k] == null ? '' : String(n.customData[k]).trim();
        if (v) cd[k] = v; else delete cd[k];
      }
      if (Object.keys(cd).length) order.customData = cd; else delete order.customData;
    }

    const terms = {};
    for (const k of ['discountPct', 'shippingCost', 'extraLines']) if (has(n, k)) terms[k] = n[k];
    repriceTerms(order, terms, c);

    let priceChanges = {};
    if (has(n, 'price') && optional(n.price) !== null) {
      priceChanges = applyEdit(order, { price: Math.max(0, +n.price || 0) },
        { now: c.now, id: c.priceId || c.id, settings: c.settings }).changes;
    }
    if (has(n, 'extraLines')) {
      if (n.extraLines.length) order.extraLines = n.extraLines.map((l) => Object.assign({}, l));
      else delete order.extraLines;
    }
    return {
      changes: Object.assign({}, changes, priceChanges),
      changed: JSON.stringify(order) !== before,
    };
  }

  /* ── READING WHAT HAPPENED TO A JOB ────────────────────────────────────── */

  /**
   * The job's edits, newest first, each as a list of `{ field, from, to }` —
   * what the desktop's Edit history table shows (renderer/order-flows.js).
   */
  function editLog(order) {
    const list = Array.isArray(order && order.editHistory) ? order.editHistory : [];
    return list.slice().reverse().filter((h) => h && typeof h === 'object').map((h) => ({
      id: h.id || null,
      at: h.at || null,
      fields: Object.keys(h.fields || {}).map((k) => {
        const v = (h.fields || {})[k] || {};
        return { field: k,
                 from: v.from == null ? '' : String(v.from),
                 to: v.to == null ? '' : String(v.to) };
      }),
    }));
  }

  /**
   * The job's way through the stages, from `statusHistory`: each step with how
   * long the job sat in it — up to the next step, or to `nowMs` for the stage
   * it is in now — and the whole span from the first step to the last. The
   * desktop's Order timeline (renderer/order-flows.js openOrderTimeline).
   */
  function timeline(order, nowMs) {
    const hist = (Array.isArray(order && order.statusHistory) ? order.statusHistory : [])
      .filter((h) => h && h.at && Number.isFinite(new Date(h.at).getTime()));
    const now = typeof nowMs === 'number' ? nowMs : Date.now();
    const steps = hist.map((entry, i) => {
      const start = new Date(entry.at).getTime();
      const end = i + 1 < hist.length ? new Date(hist[i + 1].at).getTime() : now;
      return { status: String(entry.status || ''), at: entry.at, ms: Math.max(0, end - start),
               current: i === hist.length - 1, note: entry.note || null };
    });
    const totalMs = hist.length
      ? Math.max(0, new Date(hist[hist.length - 1].at).getTime() - new Date(hist[0].at).getTime()) : 0;
    return { steps, totalMs };
  }

  /* ── WHOSE JOB IT IS ───────────────────────────────────────────────────── */

  /*
   * Turki's rule (Nov 10, option C): a job's customer can be changed until
   * its invoice is submitted to ZATCA, voided, credited or paid; then it is
   * locked. A job with NO customer can always be given one, locked or not —
   * a walk-in paid at the counter is still somebody's job.
   *
   * Being numbered is not a lock. Every booked job gets its invoice number at
   * booking (lib/order-new.js), so "locked once invoiced" would lock every job
   * but a quote. What locks it is what has left the shop: a submission to
   * ZATCA, a void or a credit note, or money taken against that customer.
   */

  const present = (v) => v !== undefined && v !== null && String(v).trim() !== '';
  const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

  /** lib/record-delete.js — what "paid" means is the delete rule's. */
  function recordDelete() {
    const G = typeof globalThis !== 'undefined' ? globalThis : {};
    if (G.KhaytRecordDelete) return G.KhaytRecordDelete;
    if (typeof require === 'function') { try { return require('./record-delete.js'); } catch (_) { /* fall through */ } }
    return null;
  }

  /**
   * Why this job's customer can no longer be changed, or null if it can.
   * `zatca`, `voided`, `credited` or `paid`, in that order: the first is the
   * one the shop cannot undo, so it is the one worth saying.
   */
  function customerLocked(order) {
    if (!isObj(order)) return null;
    if (present(order.zatcaUuid) || isObj(order.zatcaSubmission)) return 'zatca';
    if (present(order.voidedAt)) return 'voided';
    if (present(order.creditedAt) || (Array.isArray(order.creditNotes) && order.creditNotes.length > 0)) return 'credited';
    const RD = recordDelete();
    if (RD && typeof RD.paid === 'function' ? RD.paid(order) : (+order.paidAmount > 0 || +order.depositAmount > 0)) return 'paid';
    return null;
  }

  /**
   * A customer's name as a record would show it, if the caller gives no way:
   * in the shop's own content languages (lib/content-languages.js), never a
   * two-language pick that is blank for a shop writing anything else.
   */
  function nameOfClient(cl, ctx) {
    if (!cl) return '';
    if (ctx && typeof ctx.nameOf === 'function') return String(ctx.nameOf(cl) || '');
    const G = typeof globalThis !== 'undefined' ? globalThis : {};
    let CL = G.KhaytContentLanguages;
    if (!CL && typeof require === 'function') { try { CL = require('./content-languages.js'); } catch (_) { CL = null; } }
    const settings = ctx && ctx.settings ? ctx.settings : null;
    const read = CL && typeof CL.read === 'function' ? CL.read(cl, 'name', null, settings) : '';
    return String(read || cl.name || '');
  }

  /**
   * May this job be given this customer (an id, or null to take the customer
   * off)? `{ ok: true, reason: null }` or `{ ok: false, reason }`, where reason
   * is `missing` (no job), `same`, `unknown` (no such customer in
   * `ctx.clients`, when given), or the lock: `zatca` | `voided` | `credited` |
   * `paid`.
   */
  function canChangeCustomer(order, clientId, ctx) {
    if (!isObj(order)) return { ok: false, reason: 'missing' };
    const from = present(order.clientId) ? String(order.clientId) : null;
    const to = present(clientId) ? String(clientId) : null;
    if (from === to) return { ok: false, reason: 'same' };
    const c = ctxOf(ctx);
    if (to !== null && Array.isArray(c.clients) && !c.clients.some((x) => x && String(x.id) === to)) {
      return { ok: false, reason: 'unknown' };
    }
    if (from === null) return { ok: true, reason: null };   // always: a job with no customer
    const locked = customerLocked(order);
    return locked ? { ok: false, reason: locked } : { ok: true, reason: null };
  }

  /**
   * Give a job another customer, in place, and write it in the edit history.
   *
   * `ctx`: `{ now, id, clients, settings, nameOf }`. Only `clientId` always
   * moves. The customer's NAME is written only on a record that carries one
   * (`order.client` — LAN and older jobs; a desktop or Mac job carries the id
   * alone and reads the name from the customer). The price and the currency
   * stay as they were agreed: a change of customer is not a new quote. When
   * the new customer bills in another currency than the job,
   * `currencyDiffers` says so, for the editor to warn; nothing is converted.
   *
   * Returns `{ ok, reason, changes, currencyDiffers }`; `ok: false` leaves the
   * job untouched.
   */
  function changeCustomer(order, clientId, ctx) {
    const verdict = canChangeCustomer(order, clientId, ctx);
    if (!verdict.ok) return { ok: false, reason: verdict.reason, changes: {}, currencyDiffers: false };
    const c = ctxOf(ctx);
    const to = present(clientId) ? String(clientId) : null;
    const cl = to !== null && Array.isArray(c.clients) ? c.clients.find((x) => x && String(x.id) === to) : null;
    const changes = { clientId: { from: present(order.clientId) ? order.clientId : null, to } };
    order.clientId = to;
    if (Object.prototype.hasOwnProperty.call(order, 'client')) {
      const name = cl ? nameOfClient(cl, c) : '';
      if (String(order.client || '') !== name) {
        changes.client = { from: order.client == null ? '' : order.client, to: name };
        order.client = name;
      }
    }
    recordEdit(order, changes, c);
    const shopCur = (c.settings && c.settings.currency) || 'SAR';
    const jobCur = order.currency || shopCur;
    const clientCur = (cl && cl.currency) || shopCur;
    return { ok: true, reason: null, changes, currencyDiffers: !!cl && jobCur !== clientCur };
  }

  const api = {
    EDIT_HISTORY_CAP, TRACKED_FIELDS, PRIORITY_LEVELS,
    priorityFrom, priorityOf, changesBetween, recordEdit, applyEdit, adjustPrice,
    parseTags, repriceTerms, applyDetails, editLog, timeline,
    customerLocked, canChangeCustomer, changeCustomer,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrderEdit = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
