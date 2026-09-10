'use strict';

const test = require('node:test');
const assert = require('node:assert');

require('../lib/scheduling.js');
require('../lib/order-deduction.js');
const MB = require('../lib/machine-band.js');

const HOUR = 3600000;
const NOW = Date.UTC(2026, 8, 8, 7, 0, 0); // Tue 8 Sep 2026, 07:00

const machine = (id, name) => ({ id, name });
const job = (o) => Object.assign({
  id: 'J', status: 'pending', machineId: 'M1', printTime: 4, project: 'A job', parts: [],
}, o);

// ── What is known ──────────────────────────────────────────────────────────

test('a running job ends when the printer says it does', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [job({ id: 'run', status: 'printing', printTime: 8 })],
    live: { M1: { progress: 50, timeRemaining: 4 * 3600 } },
    now: NOW, hours: 48,
  });
  const block = b.rows[0].blocks[0];
  assert.equal(block.kind, 'printing');
  assert.equal(block.endsAt, NOW + 4 * HOUR, 'timeRemaining is the printer\'s own answer');
  // Its start is its end less its own estimate, which puts it before the window.
  assert.equal(block.startsAt, NOW - 4 * HOUR);
  assert.equal(block.clippedStart, true);
  assert.equal(block.beforeMinutes, 240);
  assert.equal(block.startMinute, 0, 'clipped to the window, not drawn off the left edge');
  assert.equal(block.minutes, 240);
});

test('with no timeRemaining, progress against the job estimate answers', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [job({ id: 'run', status: 'printing', printTime: 10 })],
    live: { M1: { progress: 40 } },
    now: NOW, hours: 48,
  });
  // 60% of ten hours left.
  assert.equal(b.rows[0].blocks[0].endsAt, NOW + 6 * HOUR);
});

test('timeRemaining WINS over progress, because it is the printer\'s own answer', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [job({ id: 'run', status: 'printing', printTime: 10 })],
    live: { M1: { progress: 40, timeRemaining: 3600 } },
    now: NOW, hours: 48,
  });
  assert.equal(b.rows[0].blocks[0].endsAt, NOW + 1 * HOUR);
});

// ── What is NEITHER known nor projectable ──────────────────────────────────

test('a machine printing something Khayt cannot time is left out of the totals', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1'), machine('M2', 'X1C')],
    orders: [
      job({ id: 'dark', status: 'printing', machineId: 'M1', printTime: 8 }),
      job({ id: 'lit', status: 'printing', machineId: 'M2', printTime: 8 }),
    ],
    live: { M2: { timeRemaining: 2 * 3600 } },   // M1 is not being polled
    now: NOW, hours: 48,
  });
  const dark = b.rows.find(r => r.machineId === 'M1');
  assert.equal(dark.known, false, 'no estimate is not the same as free');
  assert.deepEqual(dark.blocks, []);
  assert.equal(dark.freeMinutes, 0, 'an unaskable machine has no free hours, it has unknown ones');

  // THE POINT: capacity is over two machines, not three.
  assert.equal(b.countedMachines, 1);
  assert.equal(b.unknownMachines, 1);
  assert.equal(b.capacityMinutes, 48 * 60,
    'counting the offline machine would overstate the shop by a whole printer');
  assert.equal(b.bookedMinutes, 120);
  assert.equal(b.freeMinutes, 48 * 60 - 120);
});

test('a machine with nothing on it is free, and that IS known', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')], orders: [], live: {}, now: NOW, hours: 48,
  });
  assert.equal(b.rows[0].known, true);
  assert.equal(b.rows[0].state, 'free');
  assert.equal(b.rows[0].freeMinutes, 48 * 60);
  assert.equal(b.utilised, 0);
});

// ── What is projected ──────────────────────────────────────────────────────

test('queued work is laid end to end behind the running job, and says it is a projection', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [
      job({ id: 'run', status: 'printing', printTime: 8 }),
      job({ id: 'q1', printTime: 3, dueDate: '2026-09-09' }),
      job({ id: 'q2', printTime: 5, dueDate: '2026-09-20' }),
    ],
    live: { M1: { timeRemaining: 2 * 3600 } },
    now: NOW, hours: 48,
  });
  const [running, first, second] = b.rows[0].blocks;
  assert.equal(running.projected, false);
  assert.equal(first.orderId, 'q1', 'the sooner due job runs first, as the board would run it');
  assert.equal(first.projected, true);
  assert.equal(first.startsAt, running.endsAt, 'no gap invented between them');
  assert.equal(second.startsAt, first.endsAt);
  assert.equal(b.rows[0].bookedMinutes, (2 + 3 + 5) * 60);
});

test('a job that runs past the window is clipped and SAYS how far past', () => {
  const b = MB.band({
    machines: [machine('M1', 'X1C')],
    orders: [job({ id: 'big', status: 'printing', printTime: 42 })],
    live: { M1: { timeRemaining: 42 * 3600 } },
    now: NOW, hours: 24,
  });
  const block = b.rows[0].blocks[0];
  assert.equal(block.clippedEnd, true);
  assert.equal(block.afterMinutes, 18 * 60, 'eighteen hours past the edge of a one-day window');
  assert.equal(block.minutes, 24 * 60);
  assert.equal(b.rows[0].overrunMinutes, 18 * 60);
  assert.equal(b.rows[0].freeMinutes, 0);
});

test('a 42-hour job FITS a 48-hour window, which is the whole point of it', () => {
  const b = MB.band({
    machines: [machine('M1', 'X1C')],
    orders: [job({ id: 'big', status: 'printing', printTime: 42 })],
    live: { M1: { timeRemaining: 42 * 3600 } },
    now: NOW, hours: 48,
  });
  const block = b.rows[0].blocks[0];
  assert.equal(block.clippedEnd, false);
  assert.equal(block.minutes, 42 * 60, 'drawn at its real length, not squashed to the day');
  assert.equal(b.rows[0].freeMinutes, 6 * 60);
});

test('the first job beyond the window is named but occupies nothing', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [
      job({ id: 'fills', status: 'printing', printTime: 48 }),
      job({ id: 'next', printTime: 5 }),
      job({ id: 'later', printTime: 5 }),
    ],
    live: { M1: { timeRemaining: 48 * 3600 } },
    now: NOW, hours: 48,
  });
  const beyond = b.rows[0].blocks.filter(x => x.beyond);
  assert.equal(beyond.length, 1, 'one, so a shop can see what it just missed — not the whole queue');
  assert.equal(beyond[0].orderId, 'next');
  assert.equal(b.rows[0].bookedMinutes, 48 * 60, 'and it adds nothing to the booked hours');
});

// ── Blocked on stock ───────────────────────────────────────────────────────

const spool = (id, material, weight) => ({ id, material, weight });
const partOf = (filamentId, grams) => ({ filamentId, printWeight: grams, supportWeight: 0, qty: 1 });

test('a queued job needing more filament than the shelf holds is blocked', () => {
  const b = MB.band({
    machines: [machine('M1', 'X1C')],
    orders: [job({ id: 'museum', printTime: 42, parts: [partOf('s1', 480)] })],
    inventory: [spool('s1', 'PA-CF', 120)],
    live: {}, now: NOW, hours: 48,
  });
  const block = b.rows[0].blocks[0];
  assert.equal(block.kind, 'blocked');
  assert.equal(block.shortfall.material, 'PA-CF');
  assert.equal(block.shortfall.needs, 480);
  assert.equal(block.shortfall.has, 120);
  assert.equal(block.shortfall.short, 360);
  // It still occupies the band: the machine is committed to it and stuck, which
  // is what makes "one spool is holding 42 machine hours" a true sentence.
  assert.equal(b.rows[0].bookedMinutes, 42 * 60);
});

test('another spool of the same material unblocks it, because completing it would use one', () => {
  const b = MB.band({
    machines: [machine('M1', 'X1C')],
    orders: [job({ id: 'museum', printTime: 42, parts: [partOf('s1', 480)] })],
    inventory: [spool('s1', 'PA-CF', 120), spool('s2', 'PA-CF', 900)],
    live: {}, now: NOW, hours: 48,
  });
  assert.equal(b.rows[0].blocks[0].kind, 'queued');
  assert.equal(b.rows[0].blocks[0].shortfall, null);
});

test('a job nobody assigned filament to is not blocked, it is unknown — and unknown is not a warning', () => {
  const b = MB.band({
    machines: [machine('M1', 'X1C')],
    orders: [job({ id: 'vague', printTime: 4, parts: [{ printWeight: 500, qty: 1 }] })],
    inventory: [spool('s1', 'PA-CF', 10)],
    live: {}, now: NOW, hours: 48,
  });
  assert.equal(b.rows[0].blocks[0].kind, 'queued',
    'inventing a shortage from a part with no spool would cry wolf on every old job');
});

// ── The gaps, which are the reason the band exists ─────────────────────────

test('the free stretches are the gaps between what is booked', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [job({ id: 'run', status: 'printing', printTime: 4 })],
    live: { M1: { timeRemaining: 4 * 3600 } },
    now: NOW, hours: 48,
  });
  assert.deepEqual(b.rows[0].gaps, [{ startMinute: 240, minutes: 44 * 60 }]);
});

test('booked and free add up to the window, on every machine', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1'), machine('M2', 'Prusa'), machine('M3', 'X1C')],
    orders: [
      job({ id: 'a', status: 'printing', machineId: 'M1', printTime: 4 }),
      job({ id: 'b', machineId: 'M1', printTime: 16 }),
      job({ id: 'c', status: 'printing', machineId: 'M2', printTime: 5.3 }),
      job({ id: 'd', machineId: 'M3', printTime: 42, parts: [partOf('s1', 480)] }),
    ],
    inventory: [spool('s1', 'PA-CF', 120)],
    live: { M1: { timeRemaining: 4 * 3600 }, M2: { timeRemaining: 5.3 * 3600 }, M3: {} },
    now: NOW, hours: 48,
  });
  for (const r of b.rows) {
    assert.ok(Math.abs(r.bookedMinutes + r.freeMinutes - 48 * 60) < 1e-6,
      `${r.name}: ${r.bookedMinutes} + ${r.freeMinutes} != 2880`);
  }
  assert.equal(b.capacityMinutes, 3 * 48 * 60);
  assert.ok(Math.abs(b.bookedMinutes + b.freeMinutes - b.capacityMinutes) < 1e-6);
  assert.ok(Math.abs(b.utilised - b.bookedMinutes / b.capacityMinutes) < 1e-9);
});

// ── Determinism ────────────────────────────────────────────────────────────

test('no clock inside: the same inputs give the same band', () => {
  const inputs = {
    machines: [machine('M1', 'U1')],
    orders: [job({ id: 'run', status: 'printing', printTime: 8 }), job({ id: 'q', printTime: 3 })],
    live: { M1: { timeRemaining: 2 * 3600 } },
    now: NOW, hours: 48,
  };
  assert.deepEqual(JSON.parse(JSON.stringify(MB.band(inputs))),
                   JSON.parse(JSON.stringify(MB.band(inputs))));
});

test('a job with no estimate takes no time rather than defaulting to something', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [job({ id: 'q', printTime: 0 })],
    live: {}, now: NOW, hours: 48,
  });
  assert.equal(b.rows[0].blocks[0].minutes, 0);
  assert.equal(b.rows[0].freeMinutes, 48 * 60);
});

test('every block carries the same fields, whatever kind it is', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [
      job({ id: 'run', status: 'printing', printTime: 4 }),
      job({ id: 'q', printTime: 3, parts: [partOf('s1', 900)] }),
    ],
    inventory: [spool('s1', 'PA-CF', 100)],
    live: { M1: { timeRemaining: 4 * 3600 } },
    now: NOW, hours: 48,
  });
  const shape = k => Object.keys(k).sort().join(',');
  const [running, queued] = b.rows[0].blocks;
  assert.equal(shape(running), shape(queued),
    'a shape that varies by kind makes a typed caller decode "absent" and "false" as one thing');
  assert.equal(running.beyond, false);
  assert.equal(running.shortfall, null);
});

// ── The printer is a witness on its own ────────────────────────────────────
//
// Reported from a real shop: "even though the U1 is printing and it shows it,
// it tells me it's free". Its book held nineteen jobs, every one of them
// `completed`, and its U1 was answering Moonraker mid-print. The reading was
// discarded because nothing in the book said `printing`, and the band drew
// forty-eight free hours on a machine with plastic coming out of it.

test('a printer that is printing is busy even when the book has no job for it', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [job({ id: 'done', status: 'completed' })],
    live: { M1: { progress: 41, timeRemaining: 3 * 3600 } },
    now: NOW, hours: 48,
  });
  const row = b.rows[0];
  assert.equal(row.state, 'printing', 'the printer said so; the book not knowing does not undo that');
  assert.equal(row.blocks.length, 1);
  assert.equal(row.blocks[0].endsAt, NOW + 3 * HOUR);
  assert.equal(row.bookedMinutes, 180);
  assert.equal(row.freeMinutes, 45 * 60, 'not 48 — three of them are spoken for');
});

test('nothing is invented about a job the book does not hold', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [],
    live: { M1: { timeRemaining: HOUR / 1000 } },
    now: NOW, hours: 48,
  });
  const block = b.rows[0].blocks[0];
  assert.equal(block.title, '', 'Khayt knows the machine is busy, not what it is making');
  assert.equal(block.orderId, '');
  assert.equal(b.rows[0].runningOrderId, null);
});

test('a printer that will not say how long is left is unknown, not free', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [],
    live: { M1: { progress: 41 } },
    now: NOW, hours: 48,
  });
  const row = b.rows[0];
  assert.equal(row.state, 'printing');
  assert.equal(row.known, false, 'its next free hour is unknown, which is not the same as none');
  assert.equal(row.freeMinutes, 0);
  assert.equal(b.countedMachines, 0, 'and it is left out of a utilisation figure it would distort');
});

test('a silent machine with nothing booked is still free', () => {
  const b = MB.band({
    machines: [machine('M1', 'U1')],
    orders: [], live: {}, now: NOW, hours: 48,
  });
  assert.equal(b.rows[0].state, 'free');
  assert.equal(b.rows[0].freeMinutes, 48 * 60);
});

// ── A machine booked out for maintenance ───────────────────────────────────
//
// `downtimeBlocks` has been editable in Khayt's machine modal for releases and
// NOTHING THAT PLANS WORK READ IT — not this band, not scheduling, not the
// lead-time promise. A shop could book a printer out for a belt change and
// every screen answering "when is this machine free" went on offering the hours
// it had just been told about. That is worse than not having the feature: the
// shop believes it said something.

const down = (from, to, note) => ({ from: new Date(from).toISOString(), to: new Date(to).toISOString(), note });

test('a maintenance window is on the band, and is not free time', () => {
  const b = MB.band({
    machines: [Object.assign(machine('M1', 'U1'), {
      downtimeBlocks: [down(NOW + 10 * HOUR, NOW + 14 * HOUR, 'Belt change')],
    })],
    orders: [], live: { M1: {} }, now: NOW, hours: 48,
  });
  const row = b.rows[0];
  const block = row.blocks.find(x => x.kind === 'down');
  assert.ok(block, 'the window is not on the band at all');
  assert.equal(block.title, 'Belt change', 'the shop is not told what it is');
  assert.equal(row.downMinutes, 4 * 60);
  // NOT booked — utilisation is a figure about work, and a shop is not busier
  // for having serviced a printer.
  assert.equal(row.bookedMinutes, 0);
  // …and NOT free, which is the whole bug.
  assert.equal(row.freeMinutes, 48 * 60 - 4 * 60);
  assert.equal(row.state, 'down');
});

test('a free stretch does not run through the maintenance window', () => {
  const b = MB.band({
    machines: [Object.assign(machine('M1', 'U1'), {
      downtimeBlocks: [down(NOW + 10 * HOUR, NOW + 14 * HOUR, '')],
    })],
    orders: [], live: { M1: {} }, now: NOW, hours: 48,
  });
  const gaps = b.rows[0].gaps;
  // Two gaps, before and after — not one 48-hour stretch straight through it.
  assert.equal(gaps.length, 2, `got ${gaps.length} gap(s): ${JSON.stringify(gaps)}`);
  assert.equal(gaps[0].minutes, 10 * 60);
  assert.equal(gaps[1].startMinute, 14 * 60);
});

test('a queued job waits for the machine rather than printing through it', () => {
  const b = MB.band({
    machines: [Object.assign(machine('M1', 'U1'), {
      downtimeBlocks: [down(NOW + 2 * HOUR, NOW + 6 * HOUR, '')],
    })],
    // Four hours of work, and the machine goes down two hours from now.
    orders: [job({ id: 'A', printTime: 4 })],
    live: { M1: {} }, now: NOW, hours: 48,
  });
  const queued = b.rows[0].blocks.find(x => x.orderId === 'A');
  assert.equal(queued.startsAt, NOW + 6 * HOUR,
    'the job was laid across a window the machine is out of action for');
});

test('a job pushed out of one window is not laid into the next', () => {
  const b = MB.band({
    machines: [Object.assign(machine('M1', 'U1'), {
      downtimeBlocks: [down(NOW + 1 * HOUR, NOW + 3 * HOUR, ''),
                       down(NOW + 4 * HOUR, NOW + 8 * HOUR, '')],
    })],
    orders: [job({ id: 'A', printTime: 4 })],
    live: { M1: {} }, now: NOW, hours: 48,
  });
  const queued = b.rows[0].blocks.find(x => x.orderId === 'A');
  assert.equal(queued.startsAt, NOW + 8 * HOUR,
    'clearing the first window landed the job inside the second');
});

test('maintenance is not counted against how busy the shop is', () => {
  const b = MB.band({
    machines: [Object.assign(machine('M1', 'U1'), {
      downtimeBlocks: [down(NOW, NOW + 24 * HOUR, '')],
    })],
    orders: [job({ id: 'A', printTime: 12 })],
    live: { M1: {} }, now: NOW, hours: 48,
  });
  // 48 hours of window, 24 booked out, 12 of work in what is left.
  assert.equal(b.downMinutes, 24 * 60);
  assert.equal(b.bookedMinutes, 12 * 60);
  // Utilisation is against the hours the shop HAS, not the hours the calendar
  // has: 12 of 24, not 12 of 48. Charging maintenance to the denominator makes
  // a shop look idle for keeping its printers working.
  assert.equal(Math.round(b.utilised * 100), 50);
});

test('a window that has already passed, or runs backwards, is ignored', () => {
  const b = MB.band({
    machines: [Object.assign(machine('M1', 'U1'), {
      downtimeBlocks: [
        down(NOW - 20 * HOUR, NOW - 10 * HOUR, 'last week'),
        down(NOW + 6 * HOUR, NOW + 2 * HOUR, 'typed backwards'),
        { from: '', to: new Date(NOW + 2 * HOUR).toISOString() },
        null,
      ],
    })],
    orders: [], live: { M1: {} }, now: NOW, hours: 48,
  });
  assert.equal(b.rows[0].downMinutes, 0);
  assert.equal(b.rows[0].freeMinutes, 48 * 60, 'a bad block cost the shop hours it has');
});

test('a machine with no downtime is exactly as it was', () => {
  const plain = { machines: [machine('M1', 'U1')], orders: [job({ id: 'A', printTime: 4 })],
                  live: { M1: {} }, now: NOW, hours: 48 };
  const b = MB.band(plain);
  assert.equal(b.rows[0].downMinutes, 0);
  assert.equal(b.rows[0].bookedMinutes, 4 * 60);
  assert.equal(b.rows[0].freeMinutes, 44 * 60);
  assert.equal(b.rows[0].blocks.find(x => x.orderId === 'A').startsAt, NOW);
});
