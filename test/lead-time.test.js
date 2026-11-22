const { test } = require('node:test');
const assert = require('node:assert/strict');
const L = require('../lib/lead-time.js');

/**
 * A promise a customer will hold the shop to.
 *
 * The failure that matters is over-promising: telling somebody their order ships
 * Tuesday when the shop has a week of queue in front of it. Every test below is
 * either "does it account for the thing that makes it later" or "does it refuse
 * to answer rather than answer optimistically".
 */

const T = '2026-08-31'; // a Monday

test('the print time alone is never the answer', () => {
  // The whole reason this module exists. Same 3-hour job, two shops.
  const idle = L.promise({ jobHours: 3, today: T });
  const busy = L.promise({ jobHours: 3, queue: [{ hours: 40 }], today: T });
  assert.ok(busy.printedBy > idle.printedBy, 'a queue must push the date out');
  assert.equal(idle.queueHours, 0);
  assert.equal(busy.queueHours, 40);
});

test('the job goes BEHIND the queue, not alongside it', () => {
  // A shop does not start a new order the moment it arrives. A promise that
  // assumes it does breaks on the shop's busiest week — which is when it was made.
  const r = L.promise({ jobHours: 8, queue: [{ hours: 8 }], dailyHours: 8, workingDaysPerWeek: 7, today: T });
  assert.equal(r.workingDays, 2, '16 hours at 8/day is two days, not one');
});

test('a five-day week is longer in calendar days than a seven-day one', () => {
  // Measured across a job that CROSSES a weekend. At exactly one working week
  // the two shops finish on the same date and should — a Monday-to-Friday job is
  // five calendar days either way. The earlier version of this test used 40
  // hours and passed only because the arithmetic was adding a weekend nobody
  // waits through; it was asserting the bug.
  const five = L.promise({ jobHours: 64, dailyHours: 8, workingDaysPerWeek: 5, today: T });
  const seven = L.promise({ jobHours: 64, dailyHours: 8, workingDaysPerWeek: 7, today: T });
  assert.ok(five.printedBy > seven.printedBy,
    'a shop that is shut at the weekend cannot promise a weekday shop’s date');
  // And at exactly one working week they agree, which is the case that used to
  // be wrong in the other direction.
  const fiveWeek = L.promise({ jobHours: 40, dailyHours: 8, workingDaysPerWeek: 5, today: T });
  const sevenWeek = L.promise({ jobHours: 40, dailyHours: 8, workingDaysPerWeek: 7, today: T });
  assert.equal(fiveWeek.printedBy, sevenWeek.printedBy);
});

test('finishing and dispatch are working days; transit is not', () => {
  // A closed shop is not packing boxes. A carrier moves on its own days.
  const r = L.promise({
    jobHours: 1, dailyHours: 8, workingDaysPerWeek: 5,
    finishingDays: 1, dispatchDays: 1, transitDays: 3, today: T,
  });
  assert.ok(r.readyBy > r.printedBy);
  assert.ok(r.shipsBy > r.readyBy);
  assert.equal(r.deliveredBy, L.addDaysIso(r.shipsBy, 3));
});

test('no transit asked for means no delivery date invented', () => {
  const r = L.promise({ jobHours: 1, today: T });
  assert.equal(r.deliveredBy, null, 'a carrier estimate we were not given is not ours to guess');
});

test('a same-day shop can say so', () => {
  // Zero is a real answer for finishing and dispatch, not a missing one — which
  // is why they default only when nothing usable is given.
  // Note it must also waive the safety day: that is padding on the PROMISE, so a
  // shop claiming same-day dispatch is claiming it without slack, deliberately.
  const r = L.promise({ jobHours: 1, finishingDays: 0, dispatchDays: 0, safetyDays: 0, today: T });
  assert.equal(r.readyBy, r.printedBy);
  assert.equal(r.shipsBy, r.printedBy);
  // And with the default safety day it does NOT collapse, which is the point.
  const padded = L.promise({ jobHours: 1, finishingDays: 0, dispatchDays: 0, today: T });
  assert.ok(padded.shipsBy > padded.printedBy);
});

test('a missing setting defaults, and does not become NaN', () => {
  // `Number(undefined)` is NaN and `NaN ?? 1` is still NaN — the first draft of
  // this file shipped exactly that, and it produced an Invalid Date rather than
  // a wrong one, which is the only reason it was noticed.
  const r = L.promise({ jobHours: 1, today: T });
  assert.equal(r.basis.finishingDays, 1);
  assert.equal(r.basis.dispatchDays, 1);
  assert.match(r.shipsBy, /^\d{4}-\d{2}-\d{2}$/);
});

test('a nonsense offset throws rather than silently promising today', () => {
  // Quietly treating it as zero would hand a customer today's date as a delivery
  // promise, which is the worst available way to be wrong.
  assert.throws(() => L.addDaysIso(T, NaN), /not a number/);
});

// ── Which lane the job lands on ─────────────────────────────────────────────

test('a free machine takes the job, because a shop would put it there', () => {
  const r = L.promise({
    jobHours: 3, queue: [{ hours: 40, machineId: 'a' }], machineIds: ['a', 'b'], today: T,
  });
  assert.equal(r.queueHours, 0, 'lane b is free');
});

test('unassigned work is not wished away across lanes', () => {
  // It is queued labour whoever ends up doing it. Ignoring it flatters the date;
  // so does spreading it so thin that the lightest lane looks empty.
  const spread = L.promise({ jobHours: 1, queue: [{ hours: 20 }], machineIds: ['a', 'b'], today: T });
  assert.equal(spread.queueHours, 10, '20 unassigned hours over two lanes is 10 each');
  const ignored = L.promise({ jobHours: 1, queue: [{ hours: 20, machineId: 'zzz' }], machineIds: ['a', 'b'], today: T });
  assert.equal(ignored.queueHours, 10, 'work assigned to a machine we were not given is still work');
});

test('a shop with no machines recorded still has a queue', () => {
  // Not "no machines, therefore nothing queued" — that is the reading that would
  // promise instantly to every single-printer shop that has not filled in a form.
  const r = L.promise({ jobHours: 1, queue: [{ hours: 16 }], today: T });
  assert.equal(r.queueHours, 16);
});

test('what the date rests on comes back with it', () => {
  // So a caller can say "based on 8 h/day, five days a week" instead of
  // presenting a date as though it were a fact about the future.
  const r = L.promise({ jobHours: 1, dailyHours: 6, workingDaysPerWeek: 6, today: T });
  assert.deepEqual(r.basis, {
    dailyHours: 6, workingDaysPerWeek: 6, finishingDays: 1, dispatchDays: 1,
    safetyDays: 1, transitDays: 0,
  });
});

// ── The safety day ──────────────────────────────────────────────────────────

test('the safety day moves the promise and nothing else', () => {
  // A shop's own plan and the date it gives a stranger are different documents.
  // Padding the plan would make the shop schedule against slack it added for
  // customers, and it would see a "printed by" date it never chose.
  const r = L.promise({ jobHours: 8, safetyDays: 1, today: T });
  assert.ok(r.shipsBy > r.shipsByUnpadded, 'the promise is later than the plan');
  assert.equal(r.basis.safetyDays, 1, 'and the padding is visible, not folded away');
  const none = L.promise({ jobHours: 8, safetyDays: 0, today: T });
  assert.equal(none.shipsBy, none.shipsByUnpadded);
});

test('a delivered date is measured from the padded ship date', () => {
  // Otherwise the safety day is silently spent by the carrier.
  const r = L.promise({ jobHours: 1, safetyDays: 2, transitDays: 3, today: T });
  assert.equal(r.deliveredBy, L.addDaysIso(r.shipsBy, 3));
});

// ── Publishing to a storefront ──────────────────────────────────────────────

test('the public payload carries no queue', () => {
  /* It is read per shop slug with no credential, so it must answer the question
     asked and disclose nothing else. Hours of booked work is a revenue proxy —
     published hourly it is a competitor's view of how busy a shop is, week by
     week — and it is not needed: a storefront needs to know when the shop could
     START, not how much is in front of it. */
  const snap = L.snapshot({ computedAt: '2026-08-31T09:00:00Z', today: T, queue: [{ hours: 40 }], dailyHours: 8 });
  const wire = JSON.stringify(snap);
  assert.ok(!('queuedHours' in snap), 'the queue must not leave the machine');
  assert.ok(!wire.includes('40'), 'nor survive as a recognisable figure');
  assert.ok(!('machineIds' in snap), 'nor how many printers there are');
  // The three buffers are one number: how long a shop spends on QC versus
  // packing is its business; the sum is all a customer's date depends on.
  assert.equal(snap.handlingDays, 3);
  assert.ok(!('finishingDays' in snap) && !('safetyDays' in snap));
  // What it DOES carry is when the shop is next free, which is a fact already
  // decided rather than an answer about an order nobody has placed.
  assert.match(snap.availableFrom, /^\d{4}-\d{2}-\d{2}$/);
  assert.ok(snap.availableFrom > T, '40 queued hours is not "free today"');
});

test('a busy shop and an idle one differ only in when they are free', () => {
  const busy = L.snapshot({ computedAt: '2026-08-31T09:00:00Z', today: T, queue: [{ hours: 40 }] });
  const idle = L.snapshot({ computedAt: '2026-08-31T09:00:00Z', today: T, queue: [] });
  assert.ok(busy.availableFrom > idle.availableFrom);
  assert.equal(idle.availableFrom, T, 'an idle shop can start today');
});

test('a fresh snapshot quotes, and the sum is the basket not the item', () => {
  const snap = L.snapshot({
    computedAt: '2026-08-31T09:00:00Z', today: T, queue: [], dailyHours: 8,
    workingDaysPerWeek: 7, finishingDays: 0, dispatchDays: 0, safetyDays: 0,
  });
  const now = Date.parse('2026-08-31T10:00:00Z');
  // Three items of 8h are one 24h promise, not three 8h ones: they print
  // sequentially and ship together.
  const one = L.fromSnapshot(snap, 8, T, now);
  const three = L.fromSnapshot(snap, 24, T, now);
  assert.ok(three.shipsBy > one.shipsBy);
  assert.equal(one.snapshotAgeHours, 1);
});

test('a shop whose availableFrom has passed is free now, not overdue', () => {
  // A snapshot taken last week says the shop was free on Tuesday. Read today,
  // that means "start now" — not a date in the past.
  const snap = L.snapshot({ computedAt: '2026-08-31T09:00:00Z', today: T, queue: [] });
  const later = L.fromSnapshot(snap, 8, '2026-09-01', Date.parse('2026-08-31T20:00:00Z'));
  assert.ok(later.printedBy >= '2026-09-01', 'never quotes a date before the reader’s today');
});

test('a stale snapshot refuses rather than guessing', () => {
  // The queue shrinks as a shop prints and grows as orders arrive, so a stale
  // number can be wrong in either direction and there is no honest correction
  // from outside. A storefront handed null must say "we will confirm".
  const snap = L.snapshot({ computedAt: '2026-08-31T09:00:00Z', today: T, queue: [], staleAfterHours: 24 });
  assert.ok(L.fromSnapshot(snap, 1, T, Date.parse('2026-08-31T20:00:00Z')), 'inside the window it answers');
  assert.equal(L.fromSnapshot(snap, 1, T, Date.parse('2026-09-02T20:00:00Z')), null, 'outside it, nothing');
});

test('a snapshot from the future is a broken clock, not a fresh one', () => {
  const snap = L.snapshot({ computedAt: '2026-09-30T09:00:00Z', today: T, queue: [] });
  assert.equal(L.fromSnapshot(snap, 1, T, Date.parse('2026-08-31T09:00:00Z')), null);
});

test('an unusable snapshot is refused, never treated as an idle shop', () => {
  // The dangerous failure: a missing figure read as "free now", which promises
  // the fastest possible date to every customer of a busy shop.
  assert.equal(L.fromSnapshot(null, 1, T, 0), null);
  assert.equal(L.fromSnapshot({}, 1, T, 0), null);
  assert.equal(L.fromSnapshot({ computedAt: '2026-08-31T09:00:00Z', staleAfterHours: 24 }, 1, T, 0), null,
    'no availableFrom is not an idle shop');
  assert.equal(L.fromSnapshot({ computedAt: 'not-a-date', availableFrom: T, staleAfterHours: 24 }, 1, T, 0), null);
});

test('a full week of work does not wait through the weekend after it', () => {
  /* The first version returned `weeks * 7 + rem`, counting seven days for every
     complete week including the LAST one. Five working days became seven
     calendar days and ten became fourteen — the shop finishes on the Friday and
     the promise said the following Monday, two days later for every week of work.

     Erring late is what the safety margin is for: a number the shop chose and can
     see. It is not something the arithmetic should be adding quietly on top. */
  assert.equal(L.calendarDaysFor(5, 5), 5, 'a working week is five days, not seven');
  assert.equal(L.calendarDaysFor(10, 5), 12, 'two weeks spans one weekend, not two');
  assert.equal(L.calendarDaysFor(15, 5), 19);
  // A week followed by more work DOES span its weekend.
  assert.equal(L.calendarDaysFor(6, 5), 8);
  assert.equal(L.calendarDaysFor(11, 5), 15);
  // Part weeks are untouched, and so is a shop that works every day.
  assert.equal(L.calendarDaysFor(4, 5), 4);
  assert.equal(L.calendarDaysFor(10, 7), 10);
  assert.equal(L.calendarDaysFor(6, 6), 6);
  // Nothing to do takes no days, and never goes negative.
  assert.equal(L.calendarDaysFor(0, 5), 0);
  assert.ok(L.calendarDaysFor(0, 1) >= 0);
});

test('the correction never makes a promise earlier than the work takes', () => {
  // Sweep it: for every shape a shop might have, the calendar span must be at
  // least the working days themselves. An off-by-one in the other direction
  // would promise a date before the work could possibly be done.
  for (let w = 1; w <= 7; w++) {
    for (let d = 0; d <= 40; d++) {
      const c = L.calendarDaysFor(d, w);
      assert.ok(c >= d, `${d} working days at ${w}/week gave ${c} calendar days`);
      assert.ok(Number.isFinite(c) && c >= 0);
    }
  }
});

// ── A LANE BOOKED OUT IS A LANE WITH LESS TO GIVE ──────────────────────────
//
// `usableMachines` already drops an OFFLINE printer, on the principle that a
// shop with one machine down should tell a customer the true date rather than
// one that assumes a repair. A machine booked out for a belt change on Thursday
// is the same case said in advance, and nothing acted on it.

test('a lane booked out for maintenance does not promise those hours', () => {
  const base = {
    jobHours: 4, queue: [], machineIds: ['M1', 'M2'],
    dailyHours: 8, workingDaysPerWeek: 7, finishingDays: 0, dispatchDays: 0,
    safetyDays: 0, today: '2026-09-08',
  };
  const clear = L.promise(base);
  // Sixteen hours out of the only two lanes is two days of this shop's capacity.
  const down = L.promise({ ...base, downtimeHours: { M1: 16, M2: 16 } });
  assert.ok(down.printedBy > clear.printedBy,
    `maintenance did not move the promise: ${clear.printedBy} → ${down.printedBy}`);
});

test('the promise goes to the lane that is actually free', () => {
  const base = {
    jobHours: 4, queue: [], machineIds: ['M1', 'M2'],
    dailyHours: 8, workingDaysPerWeek: 7, finishingDays: 0, dispatchDays: 0,
    safetyDays: 0, today: '2026-09-08',
  };
  // One lane out for a week, the other clear. A customer is told about the
  // clear one, because that is where the job will run.
  const one = L.promise({ ...base, downtimeHours: { M1: 200 } });
  assert.equal(one.printedBy, L.promise(base).printedBy,
    'a second, free lane did not save the promise');
});

test('a shop with no lanes recorded is unchanged by any of this', () => {
  // Everything falls into one queue and there is no machine to book out — the
  // true reading for the single-printer shops this is mostly for.
  const noLanes = {
    jobHours: 4, queue: [{ hours: 10 }], machineIds: [],
    dailyHours: 8, workingDaysPerWeek: 7, finishingDays: 0, dispatchDays: 0,
    safetyDays: 0, today: '2026-09-08',
  };
  assert.equal(
    L.promise(noLanes).printedBy,
    L.promise({ ...noLanes, downtimeHours: { M1: 99 } }).printedBy);
});
