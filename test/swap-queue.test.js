'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const SQ = require('../lib/swap-queue');

// Spools. Distinct enough that no two are "the same filament".
const RED = '#D32F2F', BLUE = '#1565C0', WHITE = '#FFFFFF', BLACK = '#111111';
const GREEN = '#2E7D32', YELLOW = '#F9A825', ORANGE = '#EF6C00', GREY = '#8C9099';

// A day in the shop: 26 Sep 2026, 08:00 local.
const NOW = new Date('2026-09-26T08:00:00').getTime();

function job(id, colors, extra) {
  return Object.assign({ id, colors: colors.map((hex) => ({ hex })), material: 'PLA', printTime: 1 }, extra || {});
}
const U1 = (hexes) => hexes.map((hex, slot) => ({ slot, hex, material: 'PLA' }));

test('jobs sharing spools are grouped, and what is loaded goes first', () => {
  // The U1 has red, blue, white, black on it. The queue alternates between
  // that set and a green/yellow/orange/grey one.
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const jobs = [
    job('flag', [GREEN, YELLOW, ORANGE, GREY]),
    job('mug', [RED, BLUE, WHITE, BLACK]),
    job('sign', [GREEN, YELLOW, ORANGE, GREY]),
    job('key', [RED, WHITE]),
  ];
  const p = SQ.plan(jobs, { loaded, heads: 4, now: NOW });
  assert.deepEqual(p.order, ['mug', 'key', 'flag', 'sign']);
  assert.equal(p.changed, true);
  // Current: flag 4, mug 4, sign 4, key 2 = 14. Grouped: 0, 0, 4, 0 = 4.
  assert.deepEqual(p.current, { swaps: 14, minutes: 42 });
  assert.deepEqual(p.proposed, { swaps: 4, minutes: 12 });
  assert.deepEqual(p.saved, { swaps: 10, minutes: 30 });
  assert.equal(p.estimate, true);
});

test('each job says what it adds, now and in the plan, and they sum to the plan', () => {
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const jobs = [
    job('flag', [GREEN, YELLOW, ORANGE, GREY]),
    job('mug', [RED, BLUE, WHITE, BLACK]),
    job('sign', [GREEN, YELLOW, ORANGE, GREY]),
  ];
  const p = SQ.plan(jobs, { loaded, heads: 4, now: NOW, swapMinutes: 5 });
  const byId = Object.fromEntries(p.jobs.map((j) => [j.id, j]));
  assert.deepEqual(
    { now: byId.flag.swapsNow, planned: byId.flag.swapsPlanned, delta: byId.flag.delta, mins: byId.flag.minutesDelta },
    { now: 4, planned: 4, delta: 0, mins: 0 });
  assert.equal(byId.mug.swapsNow, 4);
  assert.equal(byId.mug.swapsPlanned, 0);
  assert.equal(byId.mug.minutesDelta, -20);
  assert.equal(byId.sign.swapsPlanned, 0);
  assert.equal(p.jobs.reduce((n, j) => n + j.swapsPlanned, 0), p.proposed.swaps);
  assert.equal(p.jobs.reduce((n, j) => n + j.swapsNow, 0), p.current.swaps);
  assert.equal(-p.jobs.reduce((n, j) => n + j.delta, 0), p.saved.swaps);
  assert.deepEqual(p.jobs.map((j) => j.position), [0, 1, 2]);
  assert.deepEqual(p.jobs.map((j) => j.was), [1, 0, 2]);
});

test('a queue already in its best order is left alone', () => {
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const jobs = [job('a', [RED, BLUE]), job('b', [WHITE]), job('c', [GREEN])];
  const p = SQ.plan(jobs, { loaded, now: NOW });
  assert.deepEqual(p.order, ['a', 'b', 'c']);
  assert.equal(p.changed, false);
  assert.equal(p.saved.swaps, 0);
});

test('two jobs that both fit what is loaded are not shuffled for nothing', () => {
  const loaded = U1([RED, BLUE]);
  const jobs = [job('a', [RED, BLUE]), job('b', [GREEN, YELLOW]), job('c', [RED, BLUE])];
  const p = SQ.plan(jobs, { loaded, heads: 2, now: NOW });
  // c moves up behind a; a stays first.
  assert.deepEqual(p.order, ['a', 'c', 'b']);
});

test('never makes a job late to save a swap', () => {
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  // `rush` needs a full swap and is due TODAY: 08:00 + 12 min + 14 h is
  // 22:12, on time. Running even one three-hour loaded-colour job first
  // would save swaps and finish `rush` at 01:12 tomorrow.
  const jobs = [
    job('rush', [GREEN, YELLOW, ORANGE, GREY], { printTime: 14, dueDate: '2026-09-26' }),
    job('mug', [RED, BLUE, WHITE, BLACK], { printTime: 3 }),
    job('key', [RED, WHITE], { printTime: 3 }),
    job('sign', [GREEN, YELLOW, ORANGE, GREY], { printTime: 1 }),
  ];
  const p = SQ.plan(jobs, { loaded, now: NOW });
  assert.equal(p.order[0], 'rush');
});

test('the same queue with room in the due date IS grouped', () => {
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const jobs = [
    job('rush', [GREEN, YELLOW, ORANGE, GREY], { printTime: 14, dueDate: '2026-09-28' }),
    job('mug', [RED, BLUE, WHITE, BLACK], { printTime: 3 }),
    job('key', [RED, WHITE], { printTime: 3 }),
    job('sign', [GREEN, YELLOW, ORANGE, GREY], { printTime: 1 }),
  ];
  const p = SQ.plan(jobs, { loaded, now: NOW });
  assert.deepEqual(p.order, ['mug', 'key', 'rush', 'sign']);
});

test('a job already late gets no later, though it may get earlier', () => {
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const jobs = [
    job('overdue', [GREEN, YELLOW, ORANGE, GREY], { printTime: 2, dueDate: '2026-09-20' }),
    job('mug', [RED, BLUE, WHITE, BLACK], { printTime: 2 }),
  ];
  const p = SQ.plan(jobs, { loaded, now: NOW });
  assert.deepEqual(p.order, ['overdue', 'mug']);
  assert.equal(p.changed, false);
});

test('a higher-priority job never falls behind a lower one it was ahead of', () => {
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const jobs = [
    job('vip', [GREEN, YELLOW, ORANGE, GREY], { priorityLevel: 'urgent' }),
    job('mug', [RED, BLUE, WHITE, BLACK]),
  ];
  assert.deepEqual(SQ.plan(jobs, { loaded, now: NOW }).order, ['vip', 'mug']);
  // The board's boolean flag counts the same.
  const flagged = [job('vip', [GREEN, YELLOW, ORANGE, GREY], { priority: true }), job('mug', [RED, BLUE, WHITE, BLACK])];
  assert.deepEqual(SQ.plan(flagged, { loaded, now: NOW }).order, ['vip', 'mug']);
  // Equal priority: free to move.
  const equal = [job('vip', [GREEN, YELLOW, ORANGE, GREY]), job('mug', [RED, BLUE, WHITE, BLACK])];
  assert.deepEqual(SQ.plan(equal, { loaded, now: NOW }).order, ['mug', 'vip']);
});

test('a lower-priority job may still move up past nothing it outranks', () => {
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const jobs = [
    job('vip', [GREEN, YELLOW, ORANGE, GREY], { priorityLevel: 'high' }),
    job('other', [GREEN, YELLOW, ORANGE, GREY]),
    job('mug', [RED, BLUE, WHITE, BLACK]),
  ];
  // vip must stay ahead of both; mug is free to go right after it but not
  // before it.
  const p = SQ.plan(jobs, { loaded, now: NOW });
  assert.equal(p.order[0], 'vip');
});

test('a model with no colours on file counts no swaps and is not moved for them', () => {
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const jobs = [job('unknown', []), job('mug', [RED, BLUE])];
  const p = SQ.plan(jobs, { loaded, now: NOW });
  assert.deepEqual(p.order, ['unknown', 'mug']);
  assert.equal(p.jobs[0].known, false);
  assert.equal(p.jobs[0].swapsNow, 0);
});

test('the right colour in the wrong material is a swap', () => {
  const loaded = [{ slot: 0, hex: RED, material: 'PLA' }];
  const petg = job('petg', [RED], { material: 'PETG' });
  const pla = job('pla', [RED], { material: 'PLA Silk' });
  assert.equal(SQ.plan([petg], { loaded, now: NOW }).current.swaps, 1);
  assert.equal(SQ.plan([pla], { loaded, now: NOW }).current.swaps, 0);
});

test('two spools a few hex digits apart are the same filament', () => {
  const loaded = U1(['#FFFFFF']);
  assert.equal(SQ.plan([job('a', ['#FDFDFD'])], { loaded, now: NOW }).current.swaps, 0);
});

test('an empty head is filled, and that counts as a swap', () => {
  const p = SQ.plan([job('a', [RED, BLUE])], { loaded: [], heads: 4, now: NOW });
  assert.equal(p.current.swaps, 2);
  assert.equal(p.loadedKnown, false);
});

test('the minutes are the shop\'s estimate, clamped, three by default', () => {
  assert.equal(SQ.DEFAULT_SWAP_MINUTES, 3);
  assert.equal(SQ.swapMinutesFrom({}), 3);
  assert.equal(SQ.swapMinutesFrom(null), 3);
  assert.equal(SQ.swapMinutesFrom({ swapMinutes: 5 }), 5);
  assert.equal(SQ.swapMinutesFrom({ swapMinutes: '4.5' }), 4.5);
  assert.equal(SQ.swapMinutesFrom({ swapMinutes: -2 }), 0);
  assert.equal(SQ.swapMinutesFrom({ swapMinutes: 999 }), 60);
  assert.equal(SQ.swapMinutesFrom({ swapMinutes: 'soon' }), 3);
  const p = SQ.plan([job('a', [RED])], { loaded: [], now: NOW, swapMinutes: 8 });
  assert.equal(p.swapMinutes, 8);
  assert.equal(p.current.minutes, 8);
});

test('the same input gives the same plan', () => {
  const loaded = U1([RED, BLUE]);
  const jobs = [job('a', [GREEN]), job('b', [RED]), job('c', [GREEN, BLUE]), job('d', [YELLOW])];
  const one = SQ.plan(jobs, { loaded, heads: 2, now: NOW });
  const two = SQ.plan(jobs, { loaded, heads: 2, now: NOW });
  assert.deepEqual(one, two);
  assert.ok(one.proposed.swaps <= one.current.swaps);
});

test('nothing in, nothing out', () => {
  const p = SQ.plan([], { now: NOW });
  assert.deepEqual(p.order, []);
  assert.equal(p.saved.swaps, 0);
  assert.equal(p.changed, false);
});

test('a busy week of sample jobs on a U1 never gets worse and never breaks a promise', () => {
  const palette = [RED, BLUE, WHITE, BLACK, GREEN, YELLOW, ORANGE, GREY];
  // A fixed pseudo-random queue, so the test is the same every run.
  let seed = 7;
  const rnd = () => { seed = (seed * 16807) % 2147483647; return seed / 2147483647; };
  const jobs = [];
  for (let i = 0; i < 18; i++) {
    const n = 1 + Math.floor(rnd() * 4);
    const cols = [];
    while (cols.length < n) { const c = palette[Math.floor(rnd() * palette.length)]; if (!cols.includes(c)) cols.push(c); }
    const extra = { printTime: 1 + Math.floor(rnd() * 5) };
    if (rnd() < 0.4) extra.dueDate = `2026-09-${String(26 + Math.floor(rnd() * 4)).padStart(2, '0')}`;
    if (rnd() < 0.15) extra.priorityLevel = 'high';
    jobs.push(job('j' + i, cols, extra));
  }
  const loaded = U1([RED, BLUE, WHITE, BLACK]);
  const p = SQ.plan(jobs, { loaded, now: NOW });
  assert.ok(p.proposed.swaps <= p.current.swaps);
  assert.equal(p.order.length, jobs.length);
  assert.deepEqual([...p.order].sort(), jobs.map((j) => j.id).sort());

  // Finishes, recomputed here from the plan's own swap counts.
  const finishes = (order, key) => {
    let t = NOW;
    const out = {};
    for (const id of order) {
      const j = jobs.find((x) => x.id === id);
      const s = p.jobs.find((x) => x.id === id)[key];
      t += s * p.swapMinutes * 60000 + j.printTime * 3600000;
      out[id] = t;
    }
    return out;
  };
  const before = finishes(jobs.map((j) => j.id), 'swapsNow');
  const after = finishes(p.order, 'swapsPlanned');
  for (const j of jobs) {
    if (!j.dueDate) continue;
    const deadline = new Date(j.dueDate + 'T00:00:00').getTime() + 86400000;
    assert.ok(after[j.id] <= Math.max(deadline, before[j.id]), `${j.id} made late`);
  }
  // Priority: every high job still ahead of every normal job it led.
  const pos = Object.fromEntries(p.order.map((id, k) => [id, k]));
  jobs.forEach((a, ia) => jobs.forEach((b, ib) => {
    if (ia < ib && a.priorityLevel === 'high' && b.priorityLevel !== 'high') {
      assert.ok(pos[a.id] < pos[b.id], `${a.id} fell behind ${b.id}`);
    }
  }));
});
