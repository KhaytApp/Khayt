/**
 * Builds — several printed jobs that are one physical object.
 *
 * The shop this comes from printed a figure as Head, Hand, Body and Legs: four
 * jobs, four print-log entries, 42 hours and 1.27 kg, and nothing anywhere saying
 * they are the same object. "What did that figure cost" is arithmetic across four
 * rows.
 *
 * Almost all of the risk here is in the totalling, and it is one shape: a sum
 * that quietly omits what it could not add. Every real print log this was written
 * against is uniformly complete — every job measured, one currency, all completed
 * — so a fixture copied from real data would pass with the omission bugs intact.
 * The fixtures below are deliberately ragged instead.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { groupByKit, rollup, accuracy, isComplete } = require('../lib/print-kits.js');
const K = require('../lib/print-kits.js');

/** A print-log entry, in the store's real shape, with only what matters here. */
const job = (o = {}) => ({
  id: o.id || 'ORD-0001',
  project: o.project || 'Part',
  status: o.status || 'completed',
  currency: 'currency' in o ? o.currency : 'SAR',
  printTime: 'printTime' in o ? o.printTime : 10,
  actualPrintTime: 'actualPrintTime' in o ? o.actualPrintTime : 9,
  actualWeight: 'actualWeight' in o ? o.actualWeight : 100,
  costBasis: 'costBasis' in o ? o.costBasis : 7.5,
  parts: 'parts' in o ? o.parts : [{ printWeight: 101 }],
  kitId: o.kitId,
});

// ------------------------------------------------------------------ totalling

test('a job that was never measured does not silently count as zero', () => {
  // The bug this exists for: summing actualPrintTime over [9, null] gives 9,
  // which reads as the kit's total and is missing a whole job.
  const r = rollup([job({ actualPrintTime: 9 }), job({ actualPrintTime: null, actualWeight: null })]);
  assert.equal(r.jobs, 2);
  assert.equal(r.actualHours, 9);
  assert.equal(r.measuredTime, 1, 'the total must say how many jobs are behind it');
  assert.equal(r.measuredWeight, 1);
});

test('the estimate still covers the unmeasured job', () => {
  // Otherwise the two totals describe different sets of jobs and comparing them
  // is meaningless — which is what accuracy() below refuses to do.
  const r = rollup([job({ printTime: 10 }), job({ printTime: 5, actualPrintTime: null })]);
  assert.equal(r.estHours, 15);
  assert.equal(r.actualHours, 9);
  assert.equal(r.measuredTime, 1);
});

test('a cancelled or in-flight job is not part of the kit total', () => {
  // An in-flight rate is not the job's rate, and a cancelled job's filament is
  // waste rather than part of the object.
  const r = rollup([
    job({ status: 'completed' }),
    job({ status: 'cancelled', actualPrintTime: 4 }),
    job({ status: 'printing', actualPrintTime: 2 }),
  ]);
  assert.equal(r.jobs, 1);
  assert.equal(r.actualHours, 9);
});

test('delivered counts — it is completed work that moved on', () => {
  assert.equal(rollup([job({ status: 'delivered' })]).jobs, 1);
});

test('two currencies refuse to add rather than producing a number', () => {
  // 12 SAR + 3 EUR = 15 of nothing. A shop mid-migration is the realistic case.
  const r = rollup([job({ currency: 'SAR', costBasis: 12 }), job({ currency: 'EUR', costBasis: 3 })]);
  assert.equal(r.mixedCurrency, true);
  assert.equal(r.cost, null, 'a mixed-currency total was invented');
  assert.equal(r.currency, null);
});

test('one currency totals normally and is named', () => {
  const r = rollup([job({ costBasis: 12 }), job({ costBasis: 3 })]);
  assert.equal(r.cost, 15);
  assert.equal(r.currency, 'SAR');
  assert.equal(r.mixedCurrency, false);
  assert.equal(r.costed, 2);
});

test('an empty kit totals to nothing, not to NaN', () => {
  const r = rollup([]);
  assert.equal(r.jobs, 0);
  assert.equal(r.actualHours, 0);
  assert.equal(r.cost, 0);
  assert.equal(accuracy(r), null);
});

test('rounding happens at the edge, not per job', () => {
  // Rounding each job before summing drifts; three jobs at 1.005 h is 3.015.
  // Per-job rounding would give 1.01 x 3 = 3.03. Summing first gives
  // 3.0149999999999997, which is 3.01 — the float, not a tidier 3.015.
  const r = rollup([1, 2, 3].map(() => job({ actualPrintTime: 1.005, printTime: 1.005 })));
  assert.notEqual(r.actualHours, 3.03, 'each job was rounded before summing');
  assert.equal(r.actualHours, 3.01);
});

// ------------------------------------------------------------------ accuracy

test('no kit-level delta unless every job was measured', () => {
  // Three of four measured is a real per-job story and NO kit-level number:
  // the estimate covers four jobs, the actual covers three.
  const partly = rollup([job(), job(), job(), job({ actualPrintTime: null })]);
  assert.equal(accuracy(partly), null, 'a delta was computed across mismatched sets');
  const all = rollup([job(), job()]);
  assert.ok(accuracy(all), 'a fully measured kit should produce a delta');
});

test('the delta matches the four real jobs this was built from', () => {
  // Head, Hand, Body, Legs — the actual figures, so the arithmetic is checked
  // against something real rather than invented.
  const real = [
    job({ project: 'Legs part 1', printTime: 15.6811, actualPrintTime: 14.88, actualWeight: 298, costBasis: 22.36, parts: [{ printWeight: 298.13 }] }),
    job({ project: 'Head', printTime: 10.1175, actualPrintTime: 9.81, actualWeight: 167, costBasis: 12.55, parts: [{ printWeight: 167.29 }] }),
    job({ project: 'Hand', printTime: 6.388, actualPrintTime: 6.21, actualWeight: 79.14, costBasis: 5.93, parts: [{ printWeight: 79.12 }] }),
    job({ project: 'Body', printTime: 40.19, actualPrintTime: 38.3, actualWeight: 728.89, costBasis: 54.66, parts: [{ printWeight: 728.84 }] }),
  ];
  const r = rollup(real);
  assert.equal(r.jobs, 4);
  assert.equal(r.actualHours, 69.2);
  assert.equal(r.actualGrams, 1273.03);
  assert.equal(r.cost, 95.5);
  assert.equal(r.currency, 'SAR');
  const a = accuracy(r);
  // Every one of these four ran under its estimate, so the kit must too.
  assert.ok(a.time < 0, `expected the kit to run under estimate, got ${a.time}%`);
  assert.ok(Math.abs(a.time) > 3 && Math.abs(a.time) < 6, `time delta out of the observed band: ${a.time}%`);
  assert.ok(Math.abs(a.weight) < 0.1, `weight should land within 0.1%, got ${a.weight}%`);
});

// ------------------------------------------------------------------ grouping

test('jobs group by kitId and keep their order', () => {
  const { kits, ungrouped } = groupByKit(
    [job({ id: 'A', kitId: 'B1' }), job({ id: 'B' }), job({ id: 'C', kitId: 'B1' })],
    [{ id: 'B1', name: 'Figure' }],
  );
  assert.equal(kits.length, 1);
  assert.equal(kits[0].name, 'Figure');
  assert.deepEqual(kits[0].entries.map((e) => e.id), ['A', 'C']);
  assert.deepEqual(ungrouped.map((e) => e.id), ['B']);
});

test('a kit whose definition is gone keeps its history on screen', () => {
  // Deleting a definition must not take the work with it, and must not show a
  // raw id — that reads as corruption to whoever is looking at it.
  const { kits } = groupByKit([job({ kitId: 'B9', project: 'Dragon head' })], []);
  assert.equal(kits.length, 1);
  assert.equal(kits[0].orphaned, true);
  assert.equal(kits[0].name, 'Dragon head', 'an orphan showed its id instead of a name');
  assert.equal(kits[0].rollup.jobs, 1);
});

test('blank and missing kitIds are not a kit called ""', () => {
  const { kits, ungrouped } = groupByKit(
    [job({ kitId: '' }), job({ kitId: '   ' }), job({ kitId: null }), job({})], [],
  );
  assert.equal(kits.length, 0);
  assert.equal(ungrouped.length, 4);
});

test('nothing in, nothing out — and no throw on junk', () => {
  assert.deepEqual(groupByKit(null, null), { kits: [], ungrouped: [] });
  assert.deepEqual(groupByKit([null, undefined], []).ungrouped, []);
});

test('a kit is complete only when every job in it is measured', () => {
  const { kits } = groupByKit(
    [job({ kitId: 'B' }), job({ kitId: 'B', actualWeight: null })],
    [{ id: 'B', name: 'X' }],
  );
  assert.equal(isComplete(kits[0]), false, 'an unmeasured weight still read as complete');
  const { kits: k2 } = groupByKit([job({ kitId: 'B' })], [{ id: 'B', name: 'X' }]);
  assert.equal(isComplete(k2[0]), true);
});

/*
 * Filing work into a kit AFTER it was printed.
 *
 * This is what kits are for — the module header has said so since they shipped —
 * but both places that made one asked the shop to TYPE the name, including when
 * the kit already existed. That is backwards for the case it serves: three parts
 * filed last week, the fourth printed today, and now reproduce a string from
 * memory. Get it right and it works. Get it slightly wrong and nothing fails —
 * you quietly own two kits with almost the same name and a rollup split between
 * them, which is the one outcome both call sites' comments claim to prevent.
 */

test('a name that already exists IS that kit, however it was typed', () => {
  const defs = [{ id: 'KIT-1', name: 'Dragon' }, { id: 'KIT-2', name: 'Gundam RX' }];
  for (const typed of ['Dragon', 'dragon', '  DRAGON  ', 'dRaGoN']) {
    const r = K.resolveKitName(typed, defs);
    assert.equal(r.id, 'KIT-1', `"${typed}" minted a second kit`);
    assert.equal(r.created, false);
    assert.equal(r.name, 'Dragon', 'the kit keeps the name it was given, not the one just typed');
  }
  // Repeated spaces are typing, not meaning.
  assert.equal(K.resolveKitName('Gundam   RX', defs).id, 'KIT-2');
});

test('a genuinely new name mints a kit, and says that it did', () => {
  const defs = [{ id: 'KIT-1', name: 'Dragon' }];
  const r = K.resolveKitName('Castle', defs, () => 'KIT-NEW');
  assert.deepEqual(r, { id: 'KIT-NEW', name: 'Castle', created: true });

  assert.equal(K.resolveKitName('', defs), null, 'an empty name is not a kit');
  assert.equal(K.resolveKitName('   ', defs), null);
  assert.equal(K.resolveKitName(null, defs), null);
});

test('a near miss is offered, never taken', () => {
  // The asymmetry that decides this: a wrongly-merged job is one click to pull
  // back out, while a silently split rollup looks correct and is never noticed.
  // So ask — and only ask.
  const defs = [{ id: 'KIT-1', name: 'Dragon' }, { id: 'KIT-2', name: 'Castle' }];
  const near = K.similarKitNames('Dragn', defs);
  assert.equal(near.length, 1);
  assert.equal(near[0].name, 'Dragon');
  assert.equal(near[0].distance, 1);

  // resolveKitName is NOT influenced by it: on its own, a near miss is a new kit.
  assert.equal(K.resolveKitName('Dragn', defs, () => 'KIT-X').created, true);

  // An exact match is a match, not a near miss — or the shop is asked to confirm
  // the thing it just did correctly.
  assert.deepEqual(K.similarKitNames('Dragon', defs), []);
});

test('two kits that really are one edit apart are still two kits', () => {
  // "Leg L" and "Leg R" is the case that makes auto-merging unacceptable. They
  // are offered as a question and nothing more.
  const defs = [{ id: 'KIT-1', name: 'Leg L' }];
  const near = K.similarKitNames('Leg R', defs);
  assert.equal(near.length, 1, 'the suggestion is still worth making');
  assert.equal(K.resolveKitName('Leg R', defs, () => 'KIT-R').created, true,
    'a one-edit name was silently folded into another kit');
});

test('a short name gets a tighter budget than a long one', () => {
  // At three or four characters, two edits is a different word rather than a slip.
  assert.deepEqual(K.similarKitNames('Cat', [{ id: 'K', name: 'Dog' }]), []);
  assert.equal(K.similarKitNames('Cat', [{ id: 'K', name: 'Cap' }]).length, 1);
  // …and at length, two edits is still plausibly a slip.
  assert.equal(K.similarKitNames('Millenium Falcn', [{ id: 'K', name: 'Millennium Falcon' }]).length, 1);
  // Three edits is not.
  assert.deepEqual(K.similarKitNames('Dragon', [{ id: 'K', name: 'Wagons' }]), []);
});

test('a kit nothing points at any more is reported, so it can be tidied away', () => {
  const defs = [{ id: 'KIT-1', name: 'Dragon' }, { id: 'KIT-2', name: 'Castle' }];
  const log = [{ id: 'a', kitId: 'KIT-1' }, { id: 'b' }, { id: 'c', kitId: 'KIT-1' }];
  assert.deepEqual(K.emptyKitIds(log, defs), ['KIT-2']);

  // Pull the last job out and the kit is a name attached to nothing.
  assert.deepEqual(K.emptyKitIds([{ id: 'a' }, { id: 'b' }], defs), ['KIT-1', 'KIT-2']);
  assert.deepEqual(K.emptyKitIds(log, []), []);
  assert.deepEqual(K.emptyKitIds(null, defs).sort(), ['KIT-1', 'KIT-2']);

  // This is NOT the mirror of `orphaned`: that is a job whose definition is
  // gone, and such a job must never be reported as an empty definition.
  assert.deepEqual(K.emptyKitIds([{ id: 'a', kitId: 'KIT-GONE' }], defs).sort(), ['KIT-1', 'KIT-2']);
});

test('the distance cap stops early instead of measuring how different two names are', () => {
  assert.equal(K.editDistance('abc', 'abc', 2), 0);
  assert.equal(K.editDistance('abc', 'abd', 2), 1);
  assert.ok(K.editDistance('abc', 'xyzzy', 2) > 2, 'a far-off name must exceed the cap, not report a real distance');
  // Length alone can settle it before any work is done.
  assert.ok(K.editDistance('a', 'aaaaaaaa', 2) > 2);
});

test('grouping still works on the entries these helpers file', () => {
  // End to end on the data model itself: resolve a name, stamp the entries,
  // group them, and the rollup must see all three jobs.
  const defs = [];
  const r = K.resolveKitName('Dragon', defs, () => 'KIT-D');
  defs.push({ id: r.id, name: r.name });
  const log = [
    { id: '1', status: 'completed', actualPrintTime: 2, actualWeight: 10, kitId: r.id },
    { id: '2', status: 'completed', actualPrintTime: 3, actualWeight: 15, kitId: r.id },
    { id: '3', status: 'completed', actualPrintTime: 1, actualWeight: 5 },
  ];
  const g = K.groupByKit(log, defs);
  assert.equal(g.kits.length, 1);
  assert.equal(g.kits[0].name, 'Dragon');
  assert.equal(g.kits[0].rollup.jobs, 2);
  assert.equal(g.ungrouped.length, 1);
  assert.equal(K.emptyKitIds(log, defs).length, 0);
});
