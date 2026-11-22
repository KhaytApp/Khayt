'use strict';
(function (global) {

/**
 * Gift cards: issuing one, and spending one against an order.
 *
 * ── WHY THIS IS IN lib/ ───────────────────────────────────────────────────
 *
 * It was in `renderer/operations-extras.js`, which is to say it existed only
 * inside Electron. The native Mac app cannot reach a renderer, and neither can
 * the LAN server, so a shop taking a gift card on the phone or on the Mac had
 * nowhere to take it. Two implementations of money is worse than one place that
 * cannot do it yet — `calculator-cost.js` says the same thing at greater length
 * and for the same reason.
 *
 * ── WHAT MOVING IT CHANGED ────────────────────────────────────────────────
 *
 * The renderer worked out what an order still owed as
 *
 *     price − paidAmount − giftCardDiscount
 *
 * which is `orderOwedRaw` with the CREDIT NOTES left out. On a 500 order
 * carrying a 300 credit note that reads 500 rather than 200, so redeeming a
 * card against it spent 300 of the customer's balance on money they did not
 * owe. The card is the customer's property; over-spending it is not a rounding
 * difference. This asks `KhaytOrderMoney` instead, which is where that question
 * has a single answer.
 *
 * PURE: no DOM, no store, no clock beyond the `today` and `now` it is handed.
 * Nothing here mutates its arguments — `redeem` returns the card and the order
 * as they should become, and the caller writes them.
 */

const money = () => (typeof global.KhaytOrderMoney !== 'undefined')
  ? global.KhaytOrderMoney
  : (() => { try { return require('./order-money.js'); } catch (e) { return null; } })();

const num = (v) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };
const str = (v) => (typeof v === 'string' ? v : (v == null ? '' : String(v)));

/** Codes are shouted and unpunctuated: they get read down a telephone. */
const CODE = /^[A-Z0-9]{3,20}$/;
/** Above this and it is a typo, not a gift card. */
const MAX_BALANCE = 100000;

const ACTIVE = 'active';
const USED = 'used';
const EXPIRED = 'expired';

function normaliseCode(raw) { return str(raw).trim().toUpperCase(); }

/**
 * What a card is today.
 *
 * EXPIRY BEATS AN EMPTY BALANCE, because "Expired" tells a shop why it cannot
 * be used and "Used" would suggest the customer had the benefit of it.
 * A card with no expiry date never expires; a blank one is not "expired today".
 */
function status(card, today) {
  const expires = str(card && card.expiresAt);
  if (expires && str(today) && expires < str(today)) return EXPIRED;
  if (num(card && card.balance) <= 0) return USED;
  return ACTIVE;
}

function spendable(card, today) { return status(card, today) === ACTIVE; }

/**
 * Issue one.
 *
 * @returns {{ok: true, card: object} | {ok: false, error: string}}
 *   `error` is a KEY, not a sentence — the app that called this owns the
 *   language. Every refusal happens before anything is built.
 */
function newCard(input, ctx) {
  const c = ctx || {};
  const code = normaliseCode(input && input.code);
  if (!code) return { ok: false, error: 'giftCardCodeRequired' };
  if (!CODE.test(code)) return { ok: false, error: 'giftCardCodeInvalid' };

  const taken = (c.existing || []).some((g) => normaliseCode(g && g.code) === code);
  if (taken) return { ok: false, error: 'giftCardCodeDuplicate' };

  const balance = Math.max(0, Math.min(MAX_BALANCE, num(input && input.initialBalance)));
  if (balance <= 0) return { ok: false, error: 'giftCardBalanceRequired' };

  return {
    ok: true,
    card: {
      id: str(c.id) || code,
      code,
      initialBalance: balance,
      balance,
      issuedTo: str(input && input.issuedTo) || null,
      issuedToName: str(input && input.issuedToName),
      issuedAt: str(c.now) || '',
      expiresAt: str(input && input.expiresAt) || null,
      redeemedOrders: [],
    },
  };
}

/**
 * Spend a card against an order.
 *
 * Returns what the card and the order SHOULD BECOME rather than editing them,
 * so a caller that cannot save has changed nothing. The amount is capped by
 * both sides — the card's balance and what the order actually owes — and a cap
 * that lands on zero is a refusal rather than a no-op write.
 *
 * @returns {{ok: true, amount: number, card: object, order: object}
 *          |{ok: false, reason: string}}
 */
function redeem(card, order, ctx) {
  const c = ctx || {};
  if (!card || !order) return { ok: false, reason: 'giftCardInvalid' };
  if (num(card.balance) <= 0) return { ok: false, reason: 'giftCardInvalid' };
  if (status(card, c.today) === EXPIRED) return { ok: false, reason: 'giftCardExpired' };

  // THE ONE ANSWER TO "what is still owed", credit notes and all. Falling back
  // to the old arithmetic when the module is absent would quietly restore the
  // bug this move was made to fix, so an absent module refuses instead.
  const m = money();
  if (!m || typeof m.orderOwedRaw !== 'function') {
    return { ok: false, reason: 'giftCardNoMoneyRule' };
  }
  // With the shop's settings when the caller has them: an exclusive shop's
  // order is billed price + tax, and a card may pay the tax too.
  const owed = Math.max(0, num(m.orderOwedRaw(order, c.settings ? { settings: c.settings } : undefined)));
  const amount = Math.min(num(card.balance), owed);
  if (amount <= 0) return { ok: false, reason: 'orderFullyCovered' };

  return {
    ok: true,
    amount,
    card: {
      ...card,
      balance: Math.max(0, num(card.balance) - amount),
      // Cards imported or made before this field existed would throw on push.
      redeemedOrders: (Array.isArray(card.redeemedOrders) ? card.redeemedOrders : [])
        .concat([{ orderId: str(order.id), amount, at: str(c.now) }]),
    },
    order: {
      ...order,
      giftCardCode: card.code,
      // Accumulated, so a second card on one order keeps the first's credit.
      giftCardDiscount: num(order.giftCardDiscount) + amount,
    },
  };
}

const api = {
  ACTIVE, USED, EXPIRED, CODE, MAX_BALANCE,
  normaliseCode, status, spendable, newCard, redeem,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytGiftCard = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
