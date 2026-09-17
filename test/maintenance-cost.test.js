const { test } = require('node:test');
const assert = require('node:assert/strict');

const MC = require('../lib/maintenance-cost.js');

const MACHINES = [
  { id: 'm1', name: 'U1' },
  { id: 'm2', name: 'CORE One' },
  { id: 'm3', name: 'Mini' },
];

const LOG = [
  { id: 'a', machineId: 'm1', date: '2026-02-10', note: 'nozzle', cost: 40 },
  { id: 'b', machineId: 'm1', date: '2026-06-01', note: 'belts', cost: 25 },
  { id: 'c', machineId: 'm2', date: '2026-03-04', note: 'PTFE', cost: 90 },
  { id: 'd', machineId: 'm2', date: '2025-11-02', note: 'last year', cost: 500 },
  { id: 'e', machineId: 'm3', date: '2026-04-04', note: 'free service', cost: 0 },
];

/* ------------------------------------------------------------------
   The bug: the chart read a property nothing writes.
   ------------------------------------------------------------------ */

/**
 * What the chart used to do — total `machine.machMaintLog`, a per-machine
 * property no writer in Khayt has ever set. Kept here so the assertion below
 * says what was wrong rather than only what is right now.
 */
function theOldWay(machines, year) {
  return (machines || []).map(mach => {
    const log = mach.machMaintLog || [];
    const total = log.reduce((s, entry) => {
      if (!entry.date) return s;
      if (new Date(entry.date).getFullYear() !== year) return s;
      return s + (+entry.cost || 0);
    }, 0);
    return { name: mach.name || mach.id, total };
  }).filter(d => d.total > 0);
}

test('the old reader found nothing however much the shop had logged', () => {
  assert.deepEqual(theOldWay(MACHINES, 2026), [], 'always "No data yet"');
});

test('reading the real log finds what the shop spent', () => {
  const rows = MC.byMachine(MACHINES, LOG, { year: 2026 });
  assert.deepEqual(rows.map(r => [r.name, r.total]), [
    ['CORE One', 90],
    ['U1', 65],
  ]);
});

/* ------------------------------------------------------------------
   Years, compared as strings.
   ------------------------------------------------------------------ */

test('a year takes only that year', () => {
  assert.deepEqual(
    MC.byMachine(MACHINES, LOG, { year: 2025 }).map(r => [r.name, r.total]),
    [['CORE One', 500]],
  );
});

test('no year takes everything the shop has logged', () => {
  const rows = MC.byMachine(MACHINES, LOG, {});
  assert.deepEqual(rows.map(r => [r.name, r.total]), [
    ['CORE One', 590],
    ['U1', 65],
  ]);
  assert.deepEqual(MC.byMachine(MACHINES, LOG).map(r => r.total), [590, 65]);
});

test('a year is read off the string, not through a timezone', () => {
  // "2026-01-01" parses as midnight UTC, so `new Date(s).getFullYear()` answers
  // 2025 anywhere west of UTC. Every date in Khayt is a YYYY-MM-DD string and
  // is compared as one.
  assert.equal(MC.yearOf('2026-01-01'), '2026');
  assert.equal(MC.yearOf('2026-12-31'), '2026');
  const newYear = [{ machineId: 'm1', date: '2026-01-01', cost: 10 }];
  assert.equal(MC.byMachine(MACHINES, newYear, { year: 2026 })[0].total, 10);
  assert.deepEqual(MC.byMachine(MACHINES, newYear, { year: 2025 }), []);
});

test('a malformed date lands in no year at all', () => {
  assert.equal(MC.yearOf('2026'), '');
  assert.equal(MC.yearOf(''), '');
  assert.equal(MC.yearOf(undefined), '');
  assert.equal(MC.yearOf('not a date'), '');
  const junk = [
    { machineId: 'm1', date: '2026', cost: 10 },
    { machineId: 'm1', date: '', cost: 20 },
    { machineId: 'm1', cost: 30 },
  ];
  assert.deepEqual(MC.byMachine(MACHINES, junk, { year: 2026 }), []);
});

test('a year given as a string works the same as a number', () => {
  assert.deepEqual(
    MC.byMachine(MACHINES, LOG, { year: '2026' }).map(r => r.total),
    MC.byMachine(MACHINES, LOG, { year: 2026 }).map(r => r.total),
  );
});

/* ------------------------------------------------------------------
   What is kept and what is left out.
   ------------------------------------------------------------------ */

test('a machine that cost nothing is left out', () => {
  // m3 was serviced free of charge, so it has no bar to draw.
  assert.ok(!MC.byMachine(MACHINES, LOG, { year: 2026 }).some(r => r.machineId === 'm3'));
});

test('spending on a machine the shop has deleted is still spending', () => {
  const log = LOG.concat([{ machineId: 'gone', date: '2026-05-05', cost: 120 }]);
  const rows = MC.byMachine(MACHINES, log, { year: 2026 });
  const orphan = rows.find(r => r.machineId === 'gone');
  assert.ok(orphan, 'the money left the shop whether or not the printer did');
  assert.equal(orphan.total, 120);
  assert.equal(orphan.name, 'gone', 'labelled by the id, the only name it has');
  assert.equal(orphan.orphan, true);
  assert.equal(rows.find(r => r.machineId === 'm1').orphan, false);
});

test('an entry with no machine is not spending on any machine', () => {
  const log = [{ date: '2026-05-05', cost: 120 }, { machineId: '', date: '2026-05-05', cost: 90 }];
  assert.deepEqual(MC.byMachine(MACHINES, log, { year: 2026 }), []);
});

test('a machine falls back to its model, then to its id, for a name', () => {
  const machines = [{ id: 'm9', model: 'Prusa MK4' }, { id: 'm8' }];
  const log = [
    { machineId: 'm9', date: '2026-01-02', cost: 10 },
    { machineId: 'm8', date: '2026-01-02', cost: 20 },
  ];
  const rows = MC.byMachine(machines, log, { year: 2026 });
  assert.deepEqual(rows.map(r => r.name), ['m8', 'Prusa MK4']);
  assert.equal(rows[0].orphan, false, 'it is in the book, it just has no name');
});

test('a cost that is not a number counts as nothing', () => {
  const log = [
    { machineId: 'm1', date: '2026-01-02', cost: 'forty' },
    { machineId: 'm1', date: '2026-01-03', cost: null },
    { machineId: 'm1', date: '2026-01-04', cost: '15.50' },
  ];
  assert.equal(MC.byMachine(MACHINES, log, { year: 2026 })[0].total, 15.5);
});

test('equal spenders keep a stable order', () => {
  const log = [
    { machineId: 'm2', date: '2026-01-02', cost: 50 },
    { machineId: 'm1', date: '2026-01-02', cost: 50 },
  ];
  assert.deepEqual(MC.byMachine(MACHINES, log, { year: 2026 }).map(r => r.name), ['CORE One', 'U1']);
});

test('an empty or missing book yields nothing', () => {
  assert.deepEqual(MC.byMachine([], [], {}), []);
  assert.deepEqual(MC.byMachine(undefined, undefined, {}), []);
  assert.deepEqual(MC.byMachine(MACHINES, [], { year: 2026 }), []);
});
