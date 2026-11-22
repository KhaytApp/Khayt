const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const { dashboardFacts, lateOrderIds, ACTIVE_STATUSES } = require('../lib/dashboard-facts.js');
const KhaytAttention = require('../lib/attention.js');

const NOW = Date.parse('2026-08-25T09:00:00Z');
const ORDERS = [
  { id: 'o1', project: 'Late job',  status: 'pending',   dueDate: '2026-08-20' },
  { id: 'o2', project: 'Running',   status: 'printing',  dueDate: '2026-09-10' },
  { id: 'o3', project: 'Finishing', status: 'post',      dueDate: '2026-09-10' },
  { id: 'o4', project: 'Done',      status: 'completed', dueDate: '2026-08-01' },
];
const MACHINES = [{ id: 'm1', name: 'X1C' }, { id: 'm2', name: 'MK4S' }, { id: 'm3', name: 'K1' }];
const CACHE = {
  m1: { state: 'printing', lastUpdated: NOW - 1000 },
  m2: { state: 'offline',  lastUpdated: NOW - 1000 },
  // m3 has never reported — neither live nor offline, just unknown.
};

const base = (over = {}) => dashboardFacts({
  orders: ORDERS, machines: MACHINES, statusCache: CACHE, now: NOW,
  attention: KhaytAttention, settings: { mode: 'business' }, ...over,
});

test('THE FLOW BUG: selectAttention returns an object, and iterating it threw', () => {
  // Flow did this, with its own comment saying it was borrowing rather than
  // re-deriving — and got the borrow wrong twice:
  //
  //   const attn = selectAttention({…}) || [];
  //   for (const a of attn) if (a.orderId) ids.add(a.orderId);
  //
  // `selectAttention` returns {count, items}. `for…of` on that throws, and the
  // theme's own try/catch swallowed it, so Flow's "late" chip and its "{n} late"
  // alert have never once appeared.
  const raw = KhaytAttention.selectAttention({ machines: MACHINES, orders: ORDERS, statusCache: CACHE, now: NOW });
  assert.equal(Array.isArray(raw), false, 'it is an object, not an array');
  assert.throws(() => { for (const _ of raw) break; }, TypeError, 'this is what Flow ran every render');

  // Second mistake, independent of the first: the items carry `id`, not `orderId`.
  assert.ok(raw.items.some((i) => i.kind === 'order'), 'there IS a late order to find');
  assert.equal(raw.items.every((i) => i.orderId === undefined), true, 'nothing carries orderId');

  // What it should have produced all along.
  const ids = lateOrderIds(KhaytAttention, { machines: MACHINES, orders: ORDERS, statusCache: CACHE, now: NOW });
  assert.deepEqual([...ids], ['o1']);
});

test('dashboardFacts carries the finished jobs charged nothing, beside attn and not in it', () => {
  const f = base();
  assert.deepEqual(f.unpriced, { count: 1, ids: ['o4'] }, 'Done has no price and is not marked');
  assert.ok(!f.attn.items.some((i) => i.id === 'o4'));
  const marked = base({ orders: ORDERS.map((o) => (o.id === 'o4' ? { ...o, nonBusiness: true } : o)) });
  assert.equal(marked.unpriced.count, 0);
  const noModule = dashboardFacts({ orders: ORDERS, now: NOW });
  assert.deepEqual(noModule.unpriced, { count: 0, ids: [] });
});

test('lateOrderIds takes both shapes, and never throws', () => {
  const input = { machines: MACHINES, orders: ORDERS, statusCache: CACHE, now: NOW };
  // Documented shape.
  assert.equal(lateOrderIds({ selectAttention: () => ({ count: 1, items: [{ kind: 'order', id: 'x' }] }) }, input).has('x'), true);
  // Tolerated: a bare array, so a change to the engine degrades rather than
  // silently emptying every board.
  assert.equal(lateOrderIds({ selectAttention: () => [{ kind: 'order', id: 'y' }] }, input).has('y'), true);
  // Machines in the attention list are not orders and must not become order ids.
  const mixed = lateOrderIds({ selectAttention: () => ({ items: [{ kind: 'machine', id: 'm1' }, { kind: 'order', id: 'o9' }] }) }, input);
  assert.deepEqual([...mixed], ['o9']);
  // Absent, broken and throwing engines all yield an empty set rather than a crash.
  for (const eng of [null, undefined, {}, { selectAttention: () => { throw new Error('nope'); } }, { selectAttention: () => null }]) {
    assert.equal(lateOrderIds(eng, input).size, 0);
  }
});

test('one answer to "what is on the floor"', () => {
  const f = base();
  assert.equal(f.activeCount, 3, 'pending + printing + post; completed is not on the floor');
  assert.equal(f.printingCount, 1);
  assert.deepEqual(f.byStatus, { pending: 1, printing: 1, post: 1, completed: 1 });
  assert.equal(f.lateCount, 1);
  assert.equal(f.isLate(ORDERS[0]), true);
  assert.equal(f.isLate(ORDERS[1]), false);
  // The status list is exported so a theme cannot quietly disagree about it.
  assert.ok(ACTIVE_STATUSES.includes('on_hold'), 'on hold is still on the floor');
  assert.ok(!ACTIVE_STATUSES.includes('quote'), 'a quote is not work yet');
});

test('a printer is not live on one screen and offline on another', () => {
  const f = base();
  assert.deepEqual(f.fleet, { total: 3, live: 1, offline: 1, idle: 1 });
  // A machine that has never reported is idle, not live — claiming otherwise is
  // how a dashboard says "all clear" about a printer nobody has heard from.
  const silent = dashboardFacts({ machines: MACHINES, statusCache: {}, now: NOW, attention: KhaytAttention });
  assert.equal(silent.fleet.live, 0);
  assert.equal(silent.fleet.idle, 3);
});

test('money is answered once, and not at all when the shop has none', () => {
  const money = { payStatus: (o) => (o.id === 'o2' ? 'paid' : 'unpaid'), owedFor: () => 100 };

  const business = base({ money, tiers: { showsBusiness: () => true } });
  assert.equal(business.showsMoney, true);
  assert.equal(business.owed, 300, 'three unpaid orders at 100');

  // An enthusiast shop must not be shown a zero that reads like a fact.
  const hobby = base({ money, tiers: { showsBusiness: () => false } });
  assert.equal(hobby.showsMoney, false);
  assert.equal(hobby.owed, null);

  // One malformed order must not blank the whole strip.
  const rough = base({ money: { payStatus: (o) => { if (o.id === 'o3') throw new Error('bad'); return 'unpaid'; }, owedFor: () => 50 }, tiers: { showsBusiness: () => true } });
  assert.equal(rough.owed, 150, 'the other three still count');
});

test('junk in never becomes numbers out', () => {
  for (const inp of [undefined, {}, { orders: 'no' }, { machines: 7, statusCache: 'x' }, { orders: [null, undefined] }]) {
    const f = dashboardFacts(inp);
    assert.equal(typeof f.activeCount, 'number');
    assert.equal(f.lateCount, 0);
    assert.equal(f.fleet.total, Array.isArray(inp && inp.machines) ? inp.machines.length : 0);
  }
});

/**
 * Themes that still call the attention engine directly. This list may SHRINK and
 * must never grow — that is the whole guard.
 *
 * It is empty, and the assertions below keep it that way: a theme that starts
 * calling the engine itself fails, and a theme left on the list after being
 * converted also fails, so this cannot rot into a permanent exemption. Flow was
 * the first removed, and removing it fixed a bug live since the board shipped.
 */
const STILL_DERIVING_THEIR_OWN = [];

test('no theme re-derives lateness for itself', () => {
  // The guard, in the spirit of route-parity and mapper-parity: the point of a
  // shared derivation is defeated the moment one layout quietly computes its own.
  // A theme wanting different WORDS for late is fine; a theme wanting a
  // different ANSWER is the disagreement this prevents.
  //
  // Calling the engine directly is how the Flow bug happened: the call site has
  // to know the return shape, and one of six got it wrong with nothing to say so.
  const dir = path.join(__dirname, '..', 'renderer', 'themes');
  const stripComments = (src) => src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');

  const calling = [];
  for (const theme of fs.readdirSync(dir)) {
    const f = path.join(dir, theme, 'screens.js');
    if (!fs.existsSync(f)) continue;
    const code = stripComments(fs.readFileSync(f, 'utf8'));
    if (/selectAttention\s*\(/.test(code) && !/KhaytDashboardFacts/.test(code)) calling.push(theme);
  }

  const newOffenders = calling.filter((t) => !STILL_DERIVING_THEIR_OWN.includes(t));
  assert.deepEqual(newOffenders, [],
    `these themes derive their own lateness and should use KhaytDashboardFacts: ${newOffenders.join(', ')}`);

  // And the list must actually be shrinking: a theme that has been converted
  // has to leave, or this decays into a permanent exemption nobody revisits.
  const stale = STILL_DERIVING_THEIR_OWN.filter((t) => !calling.includes(t));
  assert.deepEqual(stale, [],
    `converted — remove from STILL_DERIVING_THEIR_OWN: ${stale.join(', ')}`);
});

test('Flow is converted, and the fix is visible in its source', () => {
  const src = fs.readFileSync(
    path.join(__dirname, '..', 'renderer', 'themes', 'flow', 'screens.js'), 'utf8');
  // Comments stripped: the file explains the bug it used to have, in prose that
  // necessarily quotes the broken code. Asserting over prose would forbid
  // writing down what went wrong, which is the opposite of what this repo does.
  const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
  assert.ok(code.includes('KhaytDashboardFacts.dashboardFacts'), 'uses the shared derivation');
  assert.ok(!/for \(const a of attn\)/.test(code), 'the un-iterable loop is gone');
  assert.ok(!/a\.orderId/.test(code), 'the wrong field name is gone');
  // It must still degrade rather than blank the screen if the module is absent.
  assert.ok(/if \(!global\.KhaytDashboardFacts\) return false/.test(src),
    'falls through to the shared dashboard rather than rendering nothing');
});

test('the facts module is actually loaded by the renderer', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
  assert.ok(html.includes('lib/dashboard-facts.js'), 'script tag present');
  // …and before the themes that consume it.
  assert.ok(html.indexOf('lib/dashboard-facts.js') < html.indexOf('themes/flow/screens.js'),
    'loaded before the theme that uses it');
});
