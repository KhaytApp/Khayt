'use strict';

/**
 * Money for a branch in the organisation overview.
 *
 * `lib/branch-summary.js` refused to report money for a year, on the grounds
 * that a second implementation "that happens to look right" would produce a
 * chain total disagreeing with every branch's own reporting — a number the owner
 * cannot reconcile and has no reason to distrust. The condition for lifting that
 * was to reuse the branch's own code.
 *
 * These tests are that condition. Most of them are chosen because a plausible
 * re-implementation gets them WRONG: the gift card that is a tender and not a
 * discount, the partial refund that leaves no marker on the order, the branch
 * that prices in a currency the reader does not use.
 */

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { moneyForBranch } = require('../lib/branch-money.js');

const order = (over) => ({ id: 'o' + Math.random().toString(36).slice(2, 8), status: 'completed', ...over });

test('revenue is the branch KPI: completed or delivered, not voided, net of credits', () => {
  const m = moneyForBranch({
    settings: { currency: 'SAR' },
    printLog: [
      order({ price: 1000, status: 'completed' }),
      order({ price: 500, status: 'delivered' }),
      order({ price: 900, status: 'printing' }),                                    // not earned yet
      order({ price: 700, status: 'completed', voidedAt: '2026-08-01T00:00:00Z' }), // never earned
      order({ price: 400, status: 'completed', creditNotes: [{ amount: 150 }] }),   // partly refunded
    ],
  });
  assert.equal(m.currency, 'SAR');
  assert.equal(m.revenue, 1000 + 500 + (400 - 150));
});

test('THE ONE A REWRITE GETS WRONG: a gift card is a tender, not a discount', () => {
  // orderNetRevenueBase deliberately does NOT subtract giftCardDiscount.
  // Issuing a gift card creates no order, so redemption is the only moment the
  // money can be recognised as revenue — netting it here would make it revenue
  // nowhere at all. Every "obvious" reimplementation treats it as a discount and
  // reports 0 here.
  const m = moneyForBranch({
    settings: { currency: 'SAR' },
    printLog: [order({ price: 1000, giftCardDiscount: 1000, status: 'completed' })],
  });
  assert.equal(m.revenue, 1000, 'the gift card paid the order; it did not shrink the sale');
  assert.equal(m.outstanding, 0, 'and nothing is owed on it');
});

test('a partial refund still leaves a plain completed order, and is still subtracted', () => {
  // generateCreditNote records a partial credit ONLY in creditNotes[] — no
  // voidedAt, no creditedAt, no status change. A status filter books the full
  // price, which is the failure this whole arrangement exists to prevent.
  const m = moneyForBranch({
    settings: { currency: 'SAR' },
    printLog: [order({ price: 1000, status: 'completed', creditNotes: [{ amount: 250 }] })],
  });
  assert.equal(m.revenue, 750);
});

test('outstanding is what the branch dashboard shows, by the same filter', () => {
  const m = moneyForBranch({
    settings: { currency: 'SAR' },
    printLog: [
      order({ price: 1000, paidAmount: 0, status: 'delivered' }),     // fully owed
      order({ price: 1000, paidAmount: 400, status: 'delivered' }),   // partly paid
      order({ price: 1000, paidAmount: 1000, status: 'delivered' }),  // settled, excluded
    ],
  });
  assert.equal(m.outstanding, 1000 + 600);
});

test('a fully-credited order is settled, not outstanding', () => {
  // payStatus calls a fully-credited order 'voided' — the money is not coming.
  const m = moneyForBranch({
    settings: { currency: 'SAR' },
    printLog: [order({
      price: 1000, paidAmount: 0, status: 'completed',
      creditNotes: [{ amount: 1000 }], creditedAt: '2026-08-01T00:00:00Z',
    })],
  });
  assert.equal(m.outstanding, 0);
  assert.equal(m.revenue, 0, 'and it earned nothing either');
});

/* ── Each branch on its own books ───────────────────────────────────────── */

test('a branch converts at ITS OWN rates, into ITS OWN base currency', () => {
  // Branch bases in USD; the order is priced in the client's SAR at this
  // branch's rate. The reader's shop has nothing to do with it.
  const m = moneyForBranch({
    settings: { currency: 'USD', exchangeRates: { SAR: 0.27 } },
    clients: [{ id: 'c1', currency: 'SAR' }],
    printLog: [order({ price: 1000, clientId: 'c1', status: 'completed' })],
  });
  assert.equal(m.currency, 'USD');
  assert.equal(m.revenue, 270);
});

test('THE ISOLATION ONE: one branch\'s rates never reach another', () => {
  // The bug a shared global would have. These functions read
  // `global.settings.exchangeRates` at CALL time, so a single mutable global
  // swapped per branch would attribute one branch's money at another's rates the
  // first time an await was threaded through the loop. A context per branch
  // cannot do it.
  const store = (currency, rate) => ({
    settings: { currency, exchangeRates: { SAR: rate } },
    clients: [{ id: 'c1', currency: 'SAR' }],
    printLog: [order({ price: 1000, clientId: 'c1', status: 'completed' })],
  });

  const usd = moneyForBranch(store('USD', 0.27));
  const eur = moneyForBranch(store('EUR', 0.25));
  const usdAgain = moneyForBranch(store('USD', 0.27));

  assert.equal(usd.revenue, 270);
  assert.equal(eur.revenue, 250);
  assert.equal(usdAgain.revenue, 270, 'the EUR branch in between changed nothing');
});

test('the main process keeps its own globals', () => {
  // Both source modules end with Object.assign(global, api). Requiring them here
  // would put payStatus, downloadBlob and a dozen more onto the main process's
  // globalThis, in a file the size of main.js.
  moneyForBranch({ settings: { currency: 'SAR' }, printLog: [order({ price: 1 })] });
  for (const name of ['orderNetRevenueBase', 'orderOwedBase', 'payStatus', 'downloadBlob', 'getAllTags']) {
    assert.equal(typeof globalThis[name], 'undefined', `${name} must not leak into the main process`);
  }
});

/* ── Survivable ─────────────────────────────────────────────────────────── */

test('a branch with no money to report says null, never zero', () => {
  // Zero is a claim — "this branch earned nothing" — and the overview would show
  // it next to branches that really did. Absence is the honest answer.
  assert.equal(moneyForBranch(null), null);
  assert.equal(moneyForBranch('nonsense'), null);
});

test('junk inside the store does not take the overview down', () => {
  // This runs on data decrypted from another machine moments earlier.
  const m = moneyForBranch({
    settings: { currency: 'SAR' },
    clients: 'not an array',
    printLog: [null, 7, 'x', order({ price: 100, status: 'completed' })],
  });
  assert.equal(m.revenue, 100);
});

test('a store with no settings still reports, in the default base', () => {
  const m = moneyForBranch({ printLog: [order({ price: 100, status: 'completed' })] });
  assert.equal(m.currency, 'SAR');
  assert.equal(m.revenue, 100);
});
