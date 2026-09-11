'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const ad = require('../lib/auto-dispatch.js');

/**
 * Which job goes on which printer next.
 *
 * Most of these are about what must NOT be offered. A dispatcher that suggests
 * a machine with yesterday's part still on the plate is worse than no
 * dispatcher: the nozzle goes through it at speed.
 */

const machine = (over = {}) => ({
  id: 'M1', name: 'One', maxColors: 1,
  printerApi: { type: 'moonraker', host: '10.0.0.5' },
  bedClearedAt: '2026-09-11T10:00:00Z',
  ...over,
});
const ready = { state: 'idle', lastFinishedAt: '2026-09-11T09:00:00Z' };
const job = (over = {}) => ({
  id: 'J1', status: 'pending', date: '2026-09-01', priority: false,
  parts: [{ material: 'PLA', colour: 'black' }], ...over,
});

// ── THE BED ────────────────────────────────────────────────────────────────

test('a machine whose bed has not been cleared since its last print is not offered', () => {
  const dirty = machine({ bedClearedAt: '2026-09-11T08:00:00Z' });   // BEFORE it finished
  assert.equal(ad.machineBlocked(dirty, ready), 'ad.bed_not_clear');

  const out = ad.plan({ orders: [job()], machines: [dirty], live: { M1: ready } });
  assert.deepEqual(out.proposals, [], 'offered a machine with a part still on it');
  assert.deepEqual(out.waiting, [{ machineId: 'M1', blocked: 'ad.bed_not_clear' }]);
});

/// Reported, never silently dropped: a farm tool that quietly stops offering a
/// printer is one nobody trusts.
test('a machine nobody has ever marked clear says so rather than vanishing', () => {
  const unknown = machine({ bedClearedAt: undefined });
  assert.equal(ad.machineBlocked(unknown, ready), 'ad.bed_unknown');
  const out = ad.plan({ orders: [job()], machines: [unknown], live: { M1: ready } });
  assert.equal(out.waiting[0].blocked, 'ad.bed_unknown');
});

test('a cleared bed after the last print is offered', () => {
  assert.equal(ad.machineBlocked(machine(), ready), null);
  const out = ad.plan({ orders: [job()], machines: [machine()], live: { M1: ready } });
  assert.deepEqual(out.proposals.map((p) => [p.orderId, p.machineId]), [['J1', 'M1']]);
});

// ── THE MACHINE ────────────────────────────────────────────────────────────

test('a printer that is printing, errored, silent or unlinked is not offered', () => {
  assert.equal(ad.machineBlocked(machine(), { state: 'printing' }), 'ad.busy');
  assert.equal(ad.machineBlocked(machine(), { state: 'idle', error: 'thermal' }), 'ad.printer_error');
  // Never heard from. Not an error — and not something to start a print on.
  assert.equal(ad.machineBlocked(machine(), {}), 'ad.no_reading');
  assert.equal(ad.machineBlocked(machine({ printerApi: { type: 'none' } }), ready), 'ad.no_printer');
  assert.equal(ad.machineBlocked(machine(), ready, { paused: { M1: true } }), 'ad.held');
});

// ── THE JOB ────────────────────────────────────────────────────────────────

test('a job is not sent to a machine that cannot print its material', () => {
  const resin = machine({ compatMaterials: ['Resin'] });
  assert.equal(ad.jobBlocked(job(), resin), 'ad.material');
  assert.equal(ad.jobBlocked(job(), machine({ compatMaterials: ['PLA', 'PETG'] })), null);
});

/// Since the catalog fix `maxColors` is what a machine prints AS SOLD, so this
/// is now a question about the machine on the bench rather than its ceiling.
test('a four-colour job is not sent to a one-colour printer', () => {
  const four = job({ parts: [
    { material: 'PLA', colour: 'red' }, { material: 'PLA', colour: 'blue' },
    { material: 'PLA', colour: 'white' }, { material: 'PLA', colour: 'black' },
  ] });
  assert.equal(ad.coloursOf(four), 4);
  assert.equal(ad.jobBlocked(four, machine()), 'ad.colours');
  assert.equal(ad.jobBlocked(four, machine({ maxColors: 4 })), null);
});

/// Refusing every machine with an empty `compatMaterials` would make this do
/// nothing at all on a real book, which is how a correct rule gets switched off.
test('a machine that lists no materials is allowed, with a caveat', () => {
  assert.equal(ad.jobBlocked(job(), machine({ compatMaterials: [] })), null);
  const out = ad.plan({ orders: [job()], machines: [machine()], live: { M1: ready } });
  assert.deepEqual(out.proposals[0].caveats, ['ad.materials_unknown']);
});

// ── THE ORDER OF WORK ──────────────────────────────────────────────────────

/// The board's order exactly. A shop seeing one sequence on screen and another
/// in the dispatcher has two queues.
test('urgent first, then due date, then longest waiting', () => {
  const queue = [
    job({ id: 'later',  dueDate: '2026-10-01', date: '2026-09-01' }),
    job({ id: 'urgent', dueDate: '2026-12-01', priority: true }),
    job({ id: 'soon',   dueDate: '2026-09-20', date: '2026-09-02' }),
    job({ id: 'undated', date: '2026-08-01' }),
  ];
  assert.deepEqual([...queue].sort(ad.queueOrder).map((o) => o.id),
                   ['urgent', 'soon', 'later', 'undated']);
});

test('only pending work with no machine already on it is dispatched', () => {
  const orders = [
    job({ id: 'printing', status: 'printing' }),
    job({ id: 'done', status: 'completed' }),
    job({ id: 'assigned', machineId: 'M9' }),
    job({ id: 'free' }),
  ];
  const out = ad.plan({ orders, machines: [machine()], live: { M1: ready } });
  assert.deepEqual(out.proposals.map((p) => p.orderId), ['free']);
});

// ── CHANGEOVERS ────────────────────────────────────────────────────────────

/// A changeover is a person unloading a spool. Khayt does not know what is
/// loaded right now, so what a machine printed LAST is the best signal there is.
test('the machine that last printed this material is preferred', () => {
  const machines = [machine({ id: 'A' }), machine({ id: 'B' })];
  const live = { A: ready, B: ready };
  const out = ad.plan({
    orders: [job({ parts: [{ material: 'PETG' }] })],
    machines, live,
    lastMaterialByMachine: { A: 'PLA', B: 'PETG' },
  });
  assert.equal(out.proposals[0].machineId, 'B', 'chose the machine needing a spool change');
  assert.equal(out.proposals[0].reason, 'ad.same_material');
});

test('one job per machine, and the spare machines are named', () => {
  const machines = [machine({ id: 'A' }), machine({ id: 'B' }), machine({ id: 'C' })];
  const live = { A: ready, B: ready, C: ready };
  const out = ad.plan({ orders: [job({ id: 'J1' }), job({ id: 'J2' })], machines, live });
  assert.equal(out.proposals.length, 2);
  assert.equal(new Set(out.proposals.map((p) => p.machineId)).size, 2, 'two jobs on one machine');
  assert.deepEqual(out.idle.length, 1);
});

test('an empty shop is an answer, not a throw', () => {
  const out = ad.plan({});
  assert.deepEqual(out, { proposals: [], idle: [], waiting: [] });
  assert.deepEqual(ad.plan({ orders: [job()], machines: [], live: {} }).proposals, []);
});

/// Keys, not sentences: three hosts, nine languages.
test('every reason is a key the interface can translate', () => {
  const out = ad.plan({
    orders: [job()],
    machines: [machine({ id: 'A' }), machine({ id: 'B', bedClearedAt: undefined })],
    live: { A: ready, B: ready },
  });
  for (const text of [out.proposals[0].reason, ...out.proposals[0].caveats,
                      out.waiting[0].blocked]) {
    assert.match(text, /^ad\.[a-z_]+$/, `${text} is not a locale key`);
  }
});

// ── AND THAT IT IS REACHED ──────────────────────────────────────────────────
//
// A correct module with no caller is this repo's commonest defect, and a rule
// nobody asks is a feature that does not exist.
const fs = require('node:fs');
const path = require('node:path');
const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

test('the Mac app bundles the rule and asks it', () => {
  const engine = read('mac/KhaytCore/Sources/KhaytCore/KhaytEngine.swift');
  assert.match(engine, /"auto-dispatch"/, 'not in the bundled module list');
  assert.match(engine, /KhaytAutoDispatch\.plan\(/, 'the engine never calls it');

  const shop = read('mac/KhaytCore/Sources/KhaytApp/Shop.swift');
  assert.match(shop, /func planDispatch\(\) async/, 'nothing on Shop asks for a plan');
  // Delete this call and the panel draws nothing for ever — which is the
  // failure this whole block exists to make loud.
  const floor = read('mac/KhaytCore/Sources/KhaytApp/ShopFloor.swift');
  assert.match(floor, /await shop\.planDispatch\(\)/, 'the plan is never recomputed');
  assert.match(floor, /NextUp\(shop: shop\)/, 'the panel is on no screen');
});

/// The bed line is the whole safety story, so the words for it must exist —
/// a missing key renders as a literal `ad.bed_not_clear` on a shop's screen.
test('every reason the rule can return has words in the Mac app', () => {
  const words = read('mac/KhaytCore/Sources/KhaytApp/Words.swift');
  const keys = ['ad.next_in_queue', 'ad.same_material', 'ad.materials_unknown',
                'ad.bed_not_clear', 'ad.bed_unknown', 'ad.busy', 'ad.printer_error',
                'ad.no_reading', 'ad.no_printer', 'ad.held'];
  for (const key of keys) {
    assert.ok(words.includes(`"${key}"`), `${key} would render as its own name`);
  }
});

/// The bed check is not decoration. If this ever returns null for a machine
/// nobody has cleared, Khayt starts a print onto somebody's finished part.
test('nothing can propose a machine whose bed is unaccounted for', () => {
  for (const bed of [undefined, '', 'not a date']) {
    const m = { id: 'M', printerApi: { type: 'moonraker' }, bedClearedAt: bed };
    assert.ok(ad.machineBlocked(m, { state: 'idle' }),
              `a bed of ${JSON.stringify(bed)} was treated as clear`);
  }
});
