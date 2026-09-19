'use strict';
(function () {

/**
 * Loyalty & store-credit LEDGER math (Khayt 3.0). See
 * docs/KHAYT-3.0-LOYALTY-SPEC.md §2–§9.
 *
 * This is the PURE arithmetic core for the rewards system: it computes how many
 * points an order earns, folds the append-only ledger into current balances, and
 * builds the individual ledger entries (earn / redeem / referral / clawback).
 *
 * It deliberately does NOT touch the order payment math. Store credit redeems
 * through the SAME rail gift cards already use (`order.giftCardDiscount`, which
 * `payStatus`/`orderOwedBase` already handle correctly) — the renderer applies a
 * redemption to an order; this module only tracks the wallet balance behind it.
 * So there is no fs/renderer/Electron dependency here: balances are always the
 * deterministic sum of the ledger, which keeps them audit-friendly and testable.
 *
 * Ledger entry shape (a superset of what each kind needs):
 *   {
 *     type,        // 'earn' | 'redeem' | 'referral' | 'adjust' | 'clawback'
 *     points,      // signed integer delta (+earn, −redeem/clawback); 0 if none
 *     credit,      // signed SAR delta   (+referral/credit, −redeem); 0 if none
 *     orderId,     // source/target order, when applicable
 *     referredClientId, // referral target, when applicable
 *     ts,          // timestamp (ms or ISO) — caller-supplied, untouched here
 *   }
 *
 * Sign convention: a balance is the plain sum of the matching deltas across the
 * ledger. Earn/referral/adjust(+) push balances up; redeem and clawback push
 * them down via NEGATIVE deltas. points and credit are tracked SEPARATELY.
 *
 * Non-negativity rule: a real append-only ledger built only via the constructors
 * below can never drive a balance below zero (redeemEntry rejects over-redemption
 * and clawbackOnRefund caps removal at the originally-earned amount). As a
 * defensive, documented guard against hand-edited/corrupt ledgers, ledgerBalance
 * CLAMPS each running balance at 0 after applying every entry — credit/points can
 * never be reported negative.
 */

/** Round toward zero to an integer, treating non-finite/garbage as 0. */
function toInt(n) {
  const x = Number(n);
  return Number.isFinite(x) ? Math.trunc(x) : 0;
}

/** Coerce to a finite number, treating non-finite/garbage as 0. */
function toNum(n) {
  const x = Number(n);
  return Number.isFinite(x) ? x : 0;
}

/**
 * Points earned on an order's ex-VAT (by default) spend.
 *   floor(exVatAmount × pointsPerUnit × tierMultiplier)
 * Always a non-negative integer; negative/garbage input earns 0.
 *
 * @param {number} exVatAmount    countable spend (VAT-exclusive base by default)
 * @param {object} [opts]
 * @param {number} [opts.pointsPerUnit=1]  points per 1 unit (SAR) of spend
 * @param {number} [opts.tierMultiplier=1] multiplier from the client's tier
 * @returns {number} integer points (floored)
 */
function earnPoints(exVatAmount, { pointsPerUnit = 1, tierMultiplier = 1 } = {}) {
  const base = toNum(exVatAmount);
  const per = toNum(pointsPerUnit);
  const mult = toNum(tierMultiplier);
  const raw = base * per * mult;
  if (!(raw > 0)) return 0;
  return Math.floor(raw);
}

/**
 * Convert a point balance to its SAR store-credit value.
 *   credit = points × rate     (e.g. rate 0.01 ⇒ 100 pts = 1 SAR)
 * @param {number} points integer point count
 * @param {number} rate   SAR value of one point
 * @returns {number} credit value in SAR (never negative)
 */
function pointsToCredit(points, rate) {
  const p = toInt(points);
  const r = toNum(rate);
  const val = p * r;
  return val > 0 ? val : 0;
}

/**
 * Fold an append-only ledger into current balances.
 * @param {Array<object>} ledger entries with signed `points` / `credit` deltas
 * @returns {{ points:number, credit:number }} non-negative balances
 */
function ledgerBalance(ledger) {
  let points = 0;
  let credit = 0;
  if (Array.isArray(ledger)) {
    for (const entry of ledger) {
      if (!entry || typeof entry !== 'object') continue;
      points += toInt(entry.points);
      credit += toNum(entry.credit);
      // Clamp after every entry: a corrupt/hand-edited ledger can never make a
      // reported balance go negative (see module-level non-negativity rule).
      if (points < 0) points = 0;
      if (credit < 0) credit = 0;
    }
  }
  return { points, credit };
}

/**
 * Build an 'earn' ledger entry for a completed+paid order.
 * @param {object} args
 * @param {string} [args.orderId]
 * @param {number} args.exVatAmount       countable (ex-VAT) spend
 * @param {number} [args.pointsPerUnit=1]
 * @param {number} [args.tierMultiplier=1]
 * @param {number|string} [args.ts]
 * @returns {object} ledger entry (type 'earn', points ≥ 0, credit 0)
 */
function earnEntry({ orderId, exVatAmount, pointsPerUnit = 1, tierMultiplier = 1, ts } = {}) {
  const points = earnPoints(exVatAmount, { pointsPerUnit, tierMultiplier });
  return { type: 'earn', points, credit: 0, orderId, ts };
}

/**
 * Build a 'redeem' entry (negative deltas) for points and/or credit, rejecting
 * any redemption that would exceed the available balance.
 *
 * Pass the current balance directly, OR pass the full ledger as the first arg
 * and the request as the second — both forms are supported:
 *   redeemEntry({ points, credit, orderId, ts }, balance)
 *   redeemEntry(ledger, { points, credit, orderId, ts })
 *
 * @returns {object} ledger entry (type 'redeem', points ≤ 0, credit ≤ 0)
 * @throws if requested points/credit exceed the available balance
 */
function redeemEntry(arg1, arg2) {
  let request;
  let balance;
  // Disambiguate the two call shapes: a ledger is an Array.
  if (Array.isArray(arg1)) {
    request = arg2 || {};
    balance = ledgerBalance(arg1);
  } else {
    request = arg1 || {};
    balance = arg2 && typeof arg2 === 'object'
      ? { points: toInt(arg2.points), credit: toNum(arg2.credit) }
      : { points: 0, credit: 0 };
  }

  const reqPoints = toInt(request.points);
  const reqCredit = toNum(request.credit);
  if (reqPoints < 0 || reqCredit < 0) {
    throw new Error('redeemEntry: request amounts must be non-negative');
  }
  if (reqPoints === 0 && reqCredit === 0) {
    throw new Error('redeemEntry: nothing to redeem');
  }
  if (reqPoints > balance.points) {
    throw new Error(`redeemEntry: insufficient points (have ${balance.points}, need ${reqPoints})`);
  }
  if (reqCredit > balance.credit) {
    throw new Error(`redeemEntry: insufficient credit (have ${balance.credit}, need ${reqCredit})`);
  }

  return {
    type: 'redeem',
    points: -reqPoints,
    credit: -reqCredit,
    orderId: request.orderId,
    ts: request.ts,
  };
}

/**
 * Build a 'referral' credit entry (single-sided: credits the referred client).
 * @param {object} args
 * @param {string} args.referredClientId
 * @param {number} args.credit  SAR credit to award (clamped ≥ 0)
 * @param {number|string} [args.ts]
 * @returns {object} ledger entry (type 'referral', credit ≥ 0, points 0)
 */
function referralEntry({ referredClientId, credit, ts } = {}) {
  const amount = toNum(credit);
  return {
    type: 'referral',
    points: 0,
    credit: amount > 0 ? amount : 0,
    referredClientId,
    ts,
  };
}

/**
 * Build a 'clawback' entry removing points proportional to a refunded fraction.
 *   removed = floor(originalEarnPoints × clamp(refundFraction, 0..1))
 * The delta is negative; removal is capped at the originally-earned amount so a
 * full refund (fraction 1) reverses exactly what was earned, never more.
 *
 * @param {object} args
 * @param {number} args.originalEarnPoints points originally earned on the order
 * @param {number} args.refundFraction     fraction refunded (0..1)
 * @param {number|string} [args.ts]
 * @returns {object} ledger entry (type 'clawback', points ≤ 0, credit 0)
 */
function clawbackOnRefund({ originalEarnPoints, refundFraction, ts } = {}) {
  const earned = toInt(originalEarnPoints);
  let frac = toNum(refundFraction);
  if (frac < 0) frac = 0;
  if (frac > 1) frac = 1;
  const removed = earned > 0 ? Math.floor(earned * frac) : 0;
  return { type: 'clawback', points: removed === 0 ? 0 : -removed, credit: 0, ts };
}

/* ────────────────────────────────────────────────────────────────────────────
 * WHAT ONE CUSTOMER HAS EARNED, AND WHAT IS LEFT TO SPEND.
 *
 * This lived in `renderer/clients.js`, which means it lived where the macOS app
 * cannot reach it: a shop running the Mac could not see a customer's points at
 * all, let alone redeem them, while the other app was quietly accruing them.
 *
 * It is not a sum over prices, and every exclusion below was a real over-award:
 *
 *   - a VOIDED order is not a sale;
 *   - neither is a print the shop marked as not business, nor a split parent —
 *     `orderNetRevenueBase` already excludes both;
 *   - an order refunded in full by a credit note earned points anyway, because
 *     the loop read the gross price;
 *   - points are earned on the value the shop KEEPS, not the tax it merely
 *     collects — so the figure goes through the tax profile, mode and all;
 *   - and prices in different currencies were added together, which
 *     `orderNetRevenueBase` converts.
 *
 * Together those were four times the real figure on a customer with one kept
 * sale, one void, one personal print and one refund. Points are a liability the
 * shop honours in money, so over-awarding them is a discount on income it never
 * had.
 * ──────────────────────────────────────────────────────────────────────────── */

/* `globalThis`, NOT `global`.
 *
 * This file runs in three hosts, and JavaScriptCore — which is where the macOS
 * app runs every shared rule — has no `global` at all. Written the way
 * `gift-card.js` writes it (that file takes `global` as a wrapper argument and
 * this one does not), every call from the Mac threw
 * "ReferenceError: Can't find variable: global" before it read a single order. */
const dependency = (name, path) => () => {
  if (typeof globalThis !== 'undefined' && globalThis[name]) return globalThis[name];
  try { return require(path); } catch (e) { return null; }
};

const orderMoney = dependency('KhaytOrderMoney', './order-money.js');
const taxRules = dependency('KhaytTax', './tax.js');
const orderStatus = dependency('KhaytOrderStatus', './order-status.js');

/**
 * The highest tier a customer qualifies for, or null.
 *
 * Lifted out of `renderer/clients.js` with `earnedBy`, and for the same reason:
 * the multiplier it carries is an INPUT to what a customer has earned, so an
 * app that could not work out the tier would quietly under-count every
 * customer's points rather than fail.
 *
 * "Highest" is by the bar a tier sets, not by its multiplier: most orders
 * first, then most spend. A shop that writes a generous tier with a low bar
 * has said what it meant.
 *
 * @returns {object|null} the tier record itself, so the caller can show its
 *   name as well as use its multiplier.
 */
function tierFor({ orders, clientId, settings, clients } = {}) {
  const config = settings || {};
  if (!config.loyaltyEnabled) return null;
  const tiers = (Array.isArray(config.loyaltyTiers) ? config.loyaltyTiers : [])
    .filter((tier) => tier && tier.name);
  if (!tiers.length) return null;

  const M = orderMoney();
  const S = orderStatus();
  if (!M || !S) return null;
  const ctx = { settings: config, clients: Array.isArray(clients) ? clients : [] };

  let finished = 0;
  let spend = 0;
  for (const order of (Array.isArray(orders) ? orders : [])) {
    if (!order || order.clientId !== clientId || !S.isFinished(order)) continue;
    finished += 1;
    spend += toNum(M.orderNetRevenueBase(order, ctx));
  }

  const eligible = tiers.filter((tier) =>
    (!tier.minOrders || finished >= toNum(tier.minOrders))
    && (!tier.minSpend || spend >= toNum(tier.minSpend)));
  if (!eligible.length) return null;
  return eligible.slice().sort((a, b) => {
    const byOrders = toNum(b.minOrders) - toNum(a.minOrders);
    if (byOrders !== 0) return byOrders;
    return toNum(b.minSpend) - toNum(a.minSpend);
  })[0];
}

/**
 * Points one customer has earned across the book.
 *
 * @param {object} opts
 * @param {object[]} opts.orders      the print log
 * @param {string} opts.clientId      whose points
 * @param {object} opts.settings      the shop's settings (rate, tax profile)
 * @param {object[]} [opts.clients]   for the currency of a customer's orders
 * @param {number} [opts.tierMultiplier] the customer's tier multiplier
 * @returns {number} whole points; 0 when the programme is off.
 */
function earnedBy({ orders, clientId, settings, clients, tierMultiplier } = {}) {
  const config = settings || {};
  if (!config.loyaltyEnabled) return 0;
  // Worked out here when the caller has no opinion, so a host that cannot see
  // the tiers still counts the same points rather than silently missing the
  // multiplier.
  if (tierMultiplier === undefined) {
    const tier = tierFor({ orders, clientId, settings: config, clients });
    tierMultiplier = (tier && toNum(tier.pointsMultiplier)) || 1;
  }
  const M = orderMoney();
  const T = taxRules();
  const S = orderStatus();
  if (!M || !S) return 0;

  const perUnit = toNum(config.loyaltyPointsPerUnit) || 1;
  const mult = toNum(tierMultiplier) || 1;
  const ctx = { settings: config, clients: Array.isArray(clients) ? clients : [] };
  const profile = (T && typeof T.profileFromSettings === 'function')
    ? T.profileFromSettings(config) : null;

  let points = 0;
  for (const order of (Array.isArray(orders) ? orders : [])) {
    if (!order || order.clientId !== clientId) continue;
    if (!S.isFinished(order)) continue;
    if (order.voidedAt) continue;
    const kept = toNum(M.orderNetRevenueBase(order, ctx));
    if (kept <= 0) continue;
    const exVat = (profile && T && typeof T.computeTax === 'function')
      ? toNum(T.computeTax(kept, profile).subtotal)
      : kept;
    points += earnPoints(exVat, { pointsPerUnit: perUnit, tierMultiplier: mult });
  }
  return points;
}

/** Points already redeemed — the ledger's own redeem rows. */
function redeemedBy(ledger, clientId) {
  if (!Array.isArray(ledger)) return 0;
  return ledger
    .filter((e) => e && e.clientId === clientId && e.type === 'redeem')
    .reduce((sum, e) => sum + toNum(e.points), 0);
}

/**
 * What is left to spend: earned less redeemed, never below zero.
 *
 * The clamp matters. Correcting the over-award above LOWERS what a customer has
 * earned, and a customer who was told they had a balance can find they have
 * none. `overRedeemed` names them rather than letting the shop find out when
 * they ask.
 */
function availableFor({ orders, ledger, clientId, settings, clients, tierMultiplier } = {}) {
  const earned = earnedBy({ orders, clientId, settings, clients, tierMultiplier });
  return Math.max(0, earned - redeemedBy(ledger, clientId));
}

/**
 * Customers who have spent more points than they now appear to have earned.
 *
 * Report-only, deliberately. The points were over-awarded, the shop has already
 * honoured some of them, and re-inflating the balance would perpetuate a
 * liability it does not owe. `redeemed > earned` needs no stored history to
 * detect: it can only arise from points awarded against something that was not
 * a sale.
 */
function overRedeemed({ orders, ledger, clients, settings, tierOf } = {}) {
  if (!settings || !settings.loyaltyEnabled) return [];
  const out = [];
  for (const client of (Array.isArray(clients) ? clients : [])) {
    if (!client || typeof client.id !== 'string') continue;
    const redeemed = redeemedBy(ledger, client.id);
    if (redeemed <= 0) continue;
    const mult = (typeof tierOf === 'function' && toNum(tierOf(client.id))) || undefined;
    const earned = earnedBy({ orders, clientId: client.id, settings, clients, tierMultiplier: mult });
    if (redeemed > earned) {
      out.push({ id: client.id, name: client.name || client.id, earned, redeemed,
                 over: redeemed - earned });
    }
  }
  return out;
}

/**
 * Turning points into store credit — as records, not as writes.
 *
 * Store credit redeems through the SAME rail gift cards already use, and this
 * module never touches an order's money: it returns the card the shop issues
 * and the ledger row that stops the points being spent twice, and the caller
 * writes BOTH or neither. A card written without its ledger row is a customer
 * spending the same points again next month.
 *
 * @returns {{ok: boolean, reason?: string, card?: object, entry?: object}}
 */
function redemption({ clientId, clientName, points, rate, code, cardId, entryId, ts } = {}) {
  const available = toInt(points);
  if (available <= 0) return { ok: false, reason: 'no_points' };
  const credit = pointsToCredit(available, toNum(rate) || 0.01);
  if (credit <= 0) return { ok: false, reason: 'no_points' };
  const when = ts || new Date().toISOString();
  return {
    ok: true,
    card: {
      id: String(cardId || ''),
      code: String(code || ''),
      initialBalance: credit,
      balance: credit,
      issuedTo: String(clientId || ''),
      issuedToName: String(clientName || ''),
      issuedAt: when,
      expiresAt: null,
      redeemedOrders: [],
      // What the shop sees on the card later: this one was not sold, it was
      // earned.
      source: 'loyalty',
    },
    entry: {
      id: String(entryId || ''),
      clientId: String(clientId || ''),
      type: 'redeem',
      points: available,
      credit,
      giftCardCode: String(code || ''),
      ts: when,
    },
  };
}

const api = {
  earnPoints,
  tierFor,
  earnedBy,
  redeemedBy,
  availableFor,
  overRedeemed,
  redemption,
  pointsToCredit,
  ledgerBalance,
  earnEntry,
  redeemEntry,
  referralEntry,
  clawbackOnRefund,
};

// Dual export: CommonJS (node tests) + global (renderer <script>, like quote-followup).
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytLoyalty = api;

})();
