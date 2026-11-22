/**
 * The per-branch summary shown in the organisation overview.
 *
 * Pure counting, but two of its decisions are load-bearing and would be easy to
 * "improve" into a wrong number:
 *
 *   - archived orders are excluded, because every active-order view in the app
 *     excludes them. A cross-branch view that counted them would report more work
 *     in flight than the branch's own screen does, and the owner would have no way
 *     to reconcile the two.
 *   - money comes from the branch's own code and nowhere else, and calendar days
 *     come from the caller. Both were once refused outright; the terms they came
 *     back on are in the module header, and these tests are those terms.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { summarizeBranch, totalBranches, totalMoney } = require('../lib/branch-summary.js');

const order = (over) => ({ id: 'o' + Math.random().toString(36).slice(2, 8), status: 'pending', ...over });

test('counts work in flight the way the app defines it', () => {
  const s = summarizeBranch({
    printLog: [
      order({ status: 'pending' }), order({ status: 'printing' }),
      order({ status: 'post' }), order({ status: 'qc' }),
      order({ status: 'quote' }), order({ status: 'on_hold' }),
      order({ status: 'completed' }), order({ status: 'delivered' }),
    ],
  });
  assert.equal(s.inFlight, 4, 'pending + printing + post + qc');
  assert.equal(s.printing, 1);
  assert.equal(s.quotes, 1, 'a quote is not work in flight — nobody has said yes');
  assert.equal(s.onHold, 1, 'nor is one on hold');
  assert.equal(s.done, 2);
  assert.equal(s.orders, 8);
});

test('archived orders are excluded, matching every active-order view in the app', () => {
  const s = summarizeBranch({
    printLog: [order({ status: 'printing' }), order({ status: 'printing', archived: true })],
  });
  assert.equal(s.printing, 1);
  assert.equal(s.orders, 1, 'the archived one is not counted at all');
});

test('last activity is the newest updatedAt, returned raw', () => {
  const s = summarizeBranch({
    printLog: [
      order({ updatedAt: '2026-07-01T10:00:00.000Z' }),
      order({ updatedAt: '2026-07-29T22:00:00.000Z' }),
      order({ updatedAt: '2026-07-15T10:00:00.000Z' }),
    ],
  });
  assert.equal(s.lastActivity, '2026-07-29T22:00:00.000Z');
  // Raw ISO on purpose: the renderer formats it through localeTag(). A calendar
  // day computed here would be the WRONG day for a branch in another timezone.
  assert.match(s.lastActivity, /T\d\d:\d\d/, 'a timestamp, not a date');
});

test('a store with nothing in it is not an error', () => {
  const s = summarizeBranch({ printLog: [], clients: [] });
  assert.equal(s.orders, 0);
  assert.equal(s.inFlight, 0);
  assert.equal(s.lastActivity, null);
  assert.equal(s.unreadable, false);
});

test('junk in, zeros out — never a throw', () => {
  // This runs on data from another machine, decrypted moments earlier. It has to
  // survive anything rather than take the whole overview down with it.
  for (const bad of [null, undefined, 42, 'text', [], { printLog: 'not an array' }]) {
    const s = summarizeBranch(bad);
    assert.equal(typeof s.orders, 'number');
  }
  assert.equal(summarizeBranch(null).unreadable, true);
  assert.equal(summarizeBranch({ printLog: [null, undefined, 7, order({ status: 'printing' })] }).printing, 1);
});

test('the summary reports money, and only through the branch\'s own code', () => {
  // This used to assert that no money was reported at all. It reports it now —
  // but the condition the old test was protecting is unchanged and is what
  // cloud-branch-money.test.js pins: the figures come from the branch's own
  // orderNetRevenueBase / orderOwedBase, never from arithmetic in this file.
  const s = summarizeBranch({
    settings: { currency: 'SAR' },
    printLog: [order({ price: 5000, status: 'completed' })],
  });
  assert.equal(s.money.currency, 'SAR');
  assert.equal(s.money.revenue, 5000);
});

test('a credit note is subtracted, because the branch subtracts it', () => {
  // The exact case the "no money" rule existed for: a PARTIAL refund leaves a
  // plain completed order with no voidedAt and no other marker, so any
  // re-implementation that filtered on status books the full price.
  const s = summarizeBranch({
    settings: { currency: 'SAR' },
    printLog: [order({ price: 1000, status: 'completed', creditNotes: [{ amount: 400 }] })],
  });
  assert.equal(s.money.revenue, 600, 'the refund came off, without this file knowing what a refund is');
});

test('a voided order earns nothing', () => {
  const s = summarizeBranch({
    settings: { currency: 'SAR' },
    printLog: [order({ price: 900, status: 'completed', voidedAt: '2026-08-01T00:00:00.000Z' })],
  });
  assert.equal(s.money.revenue, 0);
});

test('late counts need the reader\'s day, and are absent without it', () => {
  const store = {
    settings: { currency: 'SAR' },
    printLog: [
      order({ status: 'printing', dueDate: '2026-08-10' }),   // late
      order({ status: 'pending', dueDate: '2026-08-14' }),    // today
      order({ status: 'pending', dueDate: '2026-08-20' }),    // ahead
      order({ status: 'completed', dueDate: '2026-08-01' }),  // late but finished
    ],
  };

  const blind = summarizeBranch(store);
  assert.equal(blind.overdue, undefined, 'no day supplied, so no claim is made');
  assert.equal(blind.dueToday, undefined);

  const seeing = summarizeBranch(store, { today: '2026-08-14' });
  assert.equal(seeing.overdue, 1, 'only work still in flight can be late');
  assert.equal(seeing.dueToday, 1);
});

test('a malformed day is refused rather than compared', () => {
  // '14/08/2026' or 'today' would compare lexicographically against every
  // dueDate and call the entire branch late.
  for (const bad of ['14/08/2026', 'today', '2026-8-14', '', null, 20260814]) {
    const s = summarizeBranch({ printLog: [order({ status: 'pending', dueDate: '2026-08-10' })] }, { today: bad });
    assert.equal(s.overdue, undefined, `refused: ${String(bad)}`);
  }
});

test('totals skip branches that could not be read, and say how many', () => {
  const t = totalBranches([
    { orders: 3, inFlight: 2, printing: 1, onHold: 0, quotes: 1, clients: 5 },
    { orders: 4, inFlight: 1, printing: 1, onHold: 2, quotes: 0, clients: 2 },
    null,                       // a branch whose row carried an error
    { unreadable: true },       // or one the key could not open
  ]);
  assert.equal(t.branches, 4);
  assert.equal(t.reachable, 2, 'so the UI can say the totals leave two out');
  assert.equal(t.inFlight, 3);
  assert.equal(t.printing, 2);
  assert.equal(t.onHold, 2);
  assert.equal(t.clients, 7);
});

test('totals do not invent a chain-wide last activity', () => {
  // "The chain last did something at X" is a fact about ONE branch wearing a
  // costume. Deliberately absent.
  const t = totalBranches([{ orders: 1, lastActivity: '2026-07-29T22:00:00.000Z' }]);
  assert.equal(t.lastActivity, undefined);
});

/* ── The chain total ────────────────────────────────────────────────────── */

test('one base currency across the chain totals; two do not', () => {
  const sar = (revenue, outstanding) => ({ money: { currency: 'SAR', revenue, outstanding } });

  const same = totalMoney([sar(1000, 200), sar(500, 0)]);
  assert.equal(same.mixed, false);
  assert.equal(same.currency, 'SAR');
  assert.equal(same.revenue, 1500);
  assert.equal(same.outstanding, 200);

  // The refusal that matters. Adding these would mean applying somebody's
  // exchange rates to somebody else's books, and the headline figure would
  // reconcile against no branch and no bank.
  const mixed = totalMoney([sar(1000, 0), { money: { currency: 'USD', revenue: 400, outstanding: 0 } }]);
  assert.equal(mixed.mixed, true);
  assert.deepEqual(mixed.currencies, ['SAR', 'USD']);
  assert.equal(mixed.revenue, undefined, 'no number at all, rather than a wrong one');
});

test('a branch whose money could not be read makes the total partial', () => {
  const t = totalMoney([
    { money: { currency: 'SAR', revenue: 1000, outstanding: 0 } },
    { money: null },   // readable store, unreadable money
  ]);
  assert.equal(t.revenue, 1000);
  assert.equal(t.partial, true, 'an owner reading a chain total assumes it is the whole chain');
});

test('unreadable branches are not what partial means', () => {
  // A branch the org key could not open is already reported separately, and
  // counting it here would double-warn about the same branch.
  const t = totalMoney([
    { money: { currency: 'SAR', revenue: 1000, outstanding: 0 } },
    { unreadable: true },
  ]);
  assert.equal(t.partial, false);
});

test('totals add the late counts only when every branch has them', () => {
  const t = totalBranches([
    { orders: 1, overdue: 2, dueToday: 1 },
    { orders: 1, overdue: 3, dueToday: 0 },
  ]);
  assert.equal(t.overdue, 5);
  assert.equal(t.dueToday, 1);

  const blind = totalBranches([{ orders: 1 }, { orders: 1 }]);
  assert.equal(blind.overdue, undefined, 'absent stays absent — never a silent zero');
});
