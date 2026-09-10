const { test } = require('node:test');
const assert = require('node:assert/strict');
const P = require('../lib/lead-time-publish.js');

/**
 * Every decision here changes a date a customer is given before they order, and
 * each one has an optimistic failure mode that nothing would report. These pin
 * the pessimistic reading in each case.
 */

const ON = {
  publishToCloud: true, dailyHours: 8, workingDaysPerWeek: 5,
  finishingDays: 1, dispatchDays: 1, safetyDays: 1,
};
const build = (over = {}) => P.buildSnapshot({
  settings: { leadTime: { ...ON, ...(over.leadTime || {}) } },
  printLog: over.printLog || [],
  machines: over.machines || [{ id: 'm1' }],
  today: '2026-08-31',
  nowIso: '2026-08-31T09:00:00Z',
});

test('nothing is published unless the shop asked for it', () => {
  assert.equal(P.buildSnapshot({ settings: { leadTime: { publishToCloud: false } } }), null);
  assert.equal(P.buildSnapshot({ settings: {} }), null);
  assert.equal(P.buildSnapshot({}), null, 'a shop with no settings has not opted in');
});

test('finished work is not queued work', () => {
  const busy = build({ printLog: [{ status: 'queued', printTime: 40 }] });
  const done = build({ printLog: [{ status: 'completed', printTime: 40 }, { status: 'delivered', printTime: 40 }] });
  assert.ok(busy.availableFrom > done.availableFrom);
  assert.equal(done.availableFrom, '2026-08-31', 'a shop with only finished jobs is free today');
});

test('a job with no estimate still occupies the queue', () => {
  // Skipping it would shorten every promise a shop makes while it has
  // unestimated orders in front of it — which is exactly when it is busiest.
  const q = P.activeQueue([{ status: 'queued' }, { status: 'queued', printTime: 'oops' }]);
  assert.equal(q.length, 2, 'both are still work');
  assert.equal(q[0].hours, 0);
});

test('an offline printer is not capacity', () => {
  // A shop with one printer down has less capacity, and a customer should be
  // given the true date rather than one that assumes a repair.
  assert.deepEqual(P.usableMachines([{ id: 'a' }, { id: 'b', isOffline: true }, { id: 'c', status: 'offline' }]), ['a']);
  assert.deepEqual(P.usableMachines([{ id: 'd', status: 'retired' }]), []);
  assert.deepEqual(P.usableMachines(null), []);
});

test('a second working printer brings the date forward', () => {
  const one = build({ printLog: [{ status: 'queued', printTime: 40, machineId: 'm1' }], machines: [{ id: 'm1' }] });
  const two = build({ printLog: [{ status: 'queued', printTime: 40, machineId: 'm1' }], machines: [{ id: 'm1' }, { id: 'm2' }] });
  assert.ok(two.availableFrom < one.availableFrom, 'the free lane takes the next job');
});

test('the published snapshot never carries the queue', () => {
  const s = build({ printLog: [{ status: 'queued', printTime: 40 }] });
  const wire = JSON.stringify(s);
  assert.ok(!wire.includes('40'), 'hours booked must not leave the machine');
  assert.ok(!('queuedHours' in s) && !('machineIds' in s));
  assert.deepEqual(Object.keys(s).sort(), [
    'availableFrom', 'computedAt', 'dailyHours', 'handlingDays', 'staleAfterHours', 'workingDaysPerWeek',
  ]);
});

test('the shop\'s own buffers are summed, not published separately', () => {
  const s = build({ leadTime: { finishingDays: 2, dispatchDays: 1, safetyDays: 3 } });
  assert.equal(s.handlingDays, 6);
  assert.ok(!('safetyDays' in s), 'how the shop splits its margin is its business');
});

// ── When to republish ───────────────────────────────────────────────────────

test('a snapshot that says the same thing is not "different"', () => {
  // computedAt moves on every tick, so comparing whole snapshots would publish
  // constantly and never say anything new.
  const a = build({ printLog: [{ status: 'queued', printTime: 8 }] });
  const b = { ...a, computedAt: '2026-08-31T10:00:00Z' };
  assert.equal(P.differs(a, b), false);
});

test('a changed queue IS different', () => {
  const a = build({ printLog: [{ status: 'queued', printTime: 8 }] });
  const b = build({ printLog: [{ status: 'queued', printTime: 80 }] });
  assert.equal(P.differs(a, b), true);
});

test('having nothing to compare against counts as different', () => {
  // First publish after a restart must happen, not be optimised away.
  assert.equal(P.differs(null, build()), true);
  assert.equal(P.differs(build(), null), true);
});

/* ── a printer that is printing is not a free lane ────────────────────────
 *
 * The queue was built from ORDERS alone, so a machine running a job sent to it
 * straight from a slicer counted as available and the shop quoted a customer a
 * turnaround that assumed an idle printer. Reported from the bench: a U1 five
 * hours into a print, with Khayt showing it idle.
 */
const Pub = require('../lib/lead-time-publish.js');

test('a printer mid-job adds its remaining time to that lane', () => {
  const machines = [{ id: 'M1', printerApi: { type: 'moonraker' } }];
  const cache = { M1: { state: 'printing', progress: 40, timeRemaining: 7200, lastUpdated: 1 } };
  const { queue, occupied } = Pub.printerInFlight(machines, cache, []);
  assert.deepEqual(queue, [{ hours: 2, machineId: 'M1' }]);
  assert.deepEqual(occupied, []);
});

test('a printer mid-job with no usable estimate takes the lane out of service', () => {
  /* Klipper reports no usable remaining time below ~1% of a job, so this is the
   * normal state for the first minutes of every print. Inventing hours would put
   * a guess inside a date a customer holds the shop to; dropping the lane says
   * "busy, duration unknown", which is what is actually known. */
  const machines = [{ id: 'M1', printerApi: { type: 'moonraker' } }];
  const cache = { M1: { state: 'printing', progress: 0, timeRemaining: null, lastUpdated: 1 } };
  const { queue, occupied } = Pub.printerInFlight(machines, cache, []);
  assert.deepEqual(queue, []);
  assert.deepEqual(occupied, ['M1']);
});

test('a machine that already has an active order is not counted twice', () => {
  // The order on that machine IS the job on the bed. Counting both would inflate
  // every promise the shop makes while it is working normally.
  const machines = [{ id: 'M1', printerApi: { type: 'moonraker' } }];
  const cache = { M1: { state: 'printing', progress: 40, timeRemaining: 7200, lastUpdated: 1 } };
  const orders = [{ id: 'O1', status: 'printing', machineId: 'M1', printTime: 2 }];
  const { queue, occupied } = Pub.printerInFlight(machines, cache, orders);
  assert.deepEqual(queue, []);
  assert.deepEqual(occupied, []);
});

test('an idle or unpolled printer changes nothing', () => {
  const machines = [{ id: 'M1', printerApi: { type: 'moonraker' } }, { id: 'M2' }];
  assert.deepEqual(Pub.printerInFlight(machines, { M1: { state: 'Operational', progress: 0 } }, []),
    { queue: [], occupied: [] });
  // No reading at all: machineState says 'unknown', not 'printing'. A machine
  // nobody has heard from must not silently remove capacity either.
  assert.deepEqual(Pub.printerInFlight(machines, {}, []), { queue: [], occupied: [] });
});

test('the promise gets longer once the printer is counted', () => {
  const settings = { leadTime: { publishToCloud: true, dailyHours: 8, workingDaysPerWeek: 5, safetyDays: 0, finishingDays: 0, dispatchDays: 0 } };
  const machines = [{ id: 'M1', printerApi: { type: 'moonraker' } }];
  const base = { settings, printLog: [], machines, today: '2026-08-31', nowIso: '2026-08-31T09:00:00.000Z' };
  const idle = Pub.buildSnapshot({ ...base, statusCache: {} });
  const busy = Pub.buildSnapshot({ ...base, statusCache: { M1: { state: 'printing', progress: 40, timeRemaining: 3600 * 20, lastUpdated: 1 } } });
  /* snapshot() publishes a DATE, not hours — that is what a storefront quotes,
   * so that is what this asserts. Twenty hours on the bed at eight hours a day
   * is three working days, and 2026-08-31 is a Monday. */
  assert.equal(idle.availableFrom, '2026-08-31', 'an idle shop can start today');
  assert.equal(busy.availableFrom, '2026-09-03',
    'a printer twenty hours from finishing must push the date a customer is given');
});

test('a snapshot still builds when nothing has ever been polled', () => {
  const settings = { leadTime: { publishToCloud: true } };
  assert.doesNotThrow(() => Pub.buildSnapshot({
    settings, printLog: [], machines: [{ id: 'M1' }], today: '2026-08-31', nowIso: '2026-08-31T09:00:00.000Z',
  }));
});

/**
 * ── THE WORKING WEEK THE SHOP TYPED ────────────────────────────────────────
 *
 * The Operations pane holds a Working Hours grid — one number per day of the
 * week — and, a few rows below it, "Working days per week" and "Printing hours
 * per working day" under Delivery Estimates. Two models of one fact, both
 * editable, on the same screen.
 *
 * The promise counted the second pair and ignored the grid. `KhaytWorkingWeek
 * .workingDaysPerWeek` existed for this and had no callers at all.
 *
 * None of the tests above reach it, because `build()` passes no `workingHours`
 * and the default week is five days at eight hours — exactly what the other box
 * says. The disagreement only exists for a shop that customised its week, so
 * that is the shop these describe.
 */
const week = (hours, leadTime = {}) => P.buildSnapshot({
  settings: { leadTime: { ...ON, ...leadTime }, workingHours: hours },
  printLog: [{ id: 'j1', status: 'pending', printTime: 40, machineId: 'm1' }],
  machines: [{ id: 'm1' }],
  today: '2026-08-31',
  nowIso: '2026-08-31T09:00:00Z',
});

test('a six-day shop is promised on six days, not on the five in the other box', () => {
  const six = week({ sun: 8, mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 8 });
  assert.equal(six.workingDaysPerWeek, 6,
    'the grid says six days are open; the leadTime box still says five');
});

test('a shop that closed a day is promised on the days it kept', () => {
  const four = week({ sun: 8, mon: 8, tue: 8, wed: 8, thu: 0, fri: 0, sat: 0 });
  assert.equal(four.workingDaysPerWeek, 4);
  // And it must be SLOWER than the six-day shop on the same queue. The whole
  // point is that a customer's date moves when the shop's week does.
  const six = week({ sun: 8, mon: 8, tue: 8, wed: 8, thu: 8, fri: 0, sat: 8 });
  assert.ok(four.availableFrom > six.availableFrom,
    `four open days must not promise sooner than six (${four.availableFrom} vs ${six.availableFrom})`);
});

test('the hours in a day come from the grid too', () => {
  const long = week({ sun: 12, mon: 12, tue: 12, wed: 12, thu: 12, fri: 0, sat: 0 });
  assert.equal(long.dailyHours, 12, 'twelve-hour days, not the eight in the other box');
  // Closed days are not averaged in: a five-day shop at twelve hours works
  // twelve-hour days, not twelve times five over seven.
  const mixed = week({ sun: 8, mon: 8, tue: 8, wed: 8, thu: 10, fri: 0, sat: 0 });
  assert.equal(mixed.dailyHours, 8.4, 'the mean over the OPEN days');
});

test('a book with no working week at all still gets a promise', () => {
  // A shop from before the grid, or a caller that passed no settings: the
  // stored figures are all there is, and a date is better than nothing.
  const none = P.buildSnapshot({
    settings: { leadTime: { ...ON, workingDaysPerWeek: 3, dailyHours: 6 }, workingHours: {} },
    printLog: [{ id: 'j1', status: 'pending', printTime: 40, machineId: 'm1' }],
    machines: [{ id: 'm1' }], today: '2026-08-31', nowIso: '2026-08-31T09:00:00Z',
  });
  assert.equal(none.workingDaysPerWeek, 3);
  assert.equal(none.dailyHours, 6);
});
