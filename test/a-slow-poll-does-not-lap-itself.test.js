'use strict';
/**
 * A printer poll that outruns its own interval used to lap itself.
 *
 * `setInterval(poll, 30000)` does not wait for an async callback, and a poll is
 * SEQUENTIAL: one `fetchPrinterStatus` per machine, each with a 5-second
 * timeout. Seven machines that do not answer — a shop whose printers are off
 * overnight — take 35 seconds, so the next tick fires 5 seconds before the
 * previous poll has finished, and from then on they stack.
 *
 * Two polls in flight both read `before` from printerStatusCache and both write
 * it back. Measured against the real merge functions:
 *
 *     completion seen by the poll that read the fresh state : true
 *     completion seen by the poll that read a STALE state   : false
 *
 * That edge out of printing is the only moment a job's measured filament and
 * duration are true — the printer's counters reset when the next job starts. So
 * losing the race loses the measurement, silently, which is the same data
 * `printerCompletions` was rescued for in #900.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { mergePollSuccess, completionIsNew } = require('../lib/printer-poll-cache.js');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');
const code = (p) => read(p).replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');

test('the arithmetic that makes overlap reachable', () => {
  // Not a guess: these three numbers are in the source.
  const main = code('main.js');
  assert.match(main, /setInterval\(poll, 30000\)/, 'the poll interval changed');
  assert.match(main, /AbortSignal\.timeout\(5000\)/, 'the per-printer timeout changed');
  assert.match(main, /for \(const machine of machineList\)/, 'the poll is no longer sequential');
  // 7 unreachable machines at 5s each = 35s against a 30s interval.
  assert.ok(7 * 5000 > 30000, 'seven machines no longer outrun the interval');
});

test('a stale-read poll misses the completion the fresh one sees', () => {
  // Why overlap costs something, driven through the real merge functions.
  const printing = { ok: true, state: 'printing', filename: 'job.gcode' };
  const done = { ok: true, state: 'idle', filename: 'job.gcode', actuals: { filamentGrams: 222, durationS: 7200 } };

  const beforeAnything = undefined;
  const afterFirstPoll = mergePollSuccess(beforeAnything, printing, 1000);

  assert.equal(completionIsNew(afterFirstPoll, mergePollSuccess(afterFirstPoll, done, 2000)), true,
    'the poll that read the fresh state sees the job finish');
  assert.equal(completionIsNew(beforeAnything, mergePollSuccess(beforeAnything, done, 2000)), false,
    'setup: a poll holding a stale `before` does not see the edge');
});

/** The guard, lifted out of main.js and driven. */
function loadGuardedPoll(onceImpl) {
  const main = read('main.js');
  // The flag is module-level (one poll at a time across every start), and a
  // start whose generation is no longer the latest polls nothing.
  assert.ok(main.includes('let printerPollInFlight = false;'), 'the in-flight guard is gone');
  const a = main.indexOf('  const poll = async () => {\n    if (printerPollInFlight');
  assert.ok(a > 0, 'the in-flight guard is gone from the poll loop');
  const b = main.indexOf('  const pollOnce = async () => {', a);
  assert.ok(b > a, 'pollOnce is gone');
  const body = main.slice(a, b);
  return new Function('pollOnce',
    `let printerPollInFlight = false; const printerPollGeneration = 1, generation = 1; ${body}; return poll;`)(onceImpl);
}

test('a second tick during a slow poll is skipped, not queued', async () => {
  let running = 0;
  let peak = 0;
  let calls = 0;
  const slow = async () => {
    calls++; running++; peak = Math.max(peak, running);
    await new Promise((r) => setTimeout(r, 30));
    running--;
  };
  const poll = loadGuardedPoll(slow);

  // Three ticks while the first is still running.
  const first = poll();
  poll(); poll();
  await first;

  assert.equal(peak, 1, 'two polls ran at once — they read and write the same cache');
  assert.equal(calls, 1, 'a skipped tick was queued instead; the next one is 30s away and asks a stale question');
});

test('the guard releases, so polling continues after a slow one', async () => {
  let calls = 0;
  const poll = loadGuardedPoll(async () => { calls++; });
  await poll();
  await poll();
  assert.equal(calls, 2, 'the in-flight flag was never cleared — polling stopped for good');
});

test('a throwing poll still releases the guard', async () => {
  // Without the finally, one network error would stop polling permanently and
  // the shop would see printer status frozen with no message.
  let calls = 0;
  const poll = loadGuardedPoll(async () => { calls++; throw new Error('network'); });
  await assert.rejects(() => poll());
  await assert.rejects(() => poll());
  assert.equal(calls, 2, 'a failed poll left the guard set and polling never resumed');
});
