const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createMfClient, HANG_MSG, CRASH_MSG } = require('../lib/mf-client.js');

/**
 * The converter runs in a shared child process. A child that EXITS was always
 * handled; a child that HANGS was not handled at all — the promise never
 * settled, the IPC call never returned, and the renderer span forever with no
 * error to show. These pin the hang path down, including the part that is easy
 * to get wrong: a hang is not one job's problem, because everything queued
 * behind it on the same process is stuck too.
 */

/** A fake child that answers only when told to. */
function fakeChild() {
  const handlers = {};
  const sent = [];
  return {
    sent,
    killed: 0,
    on(ev, cb) { handlers[ev] = cb; },
    postMessage(msg) { sent.push(msg); },
    kill() { this.killed += 1; if (handlers.exit) handlers.exit(0); },
    answer(id, res) { if (handlers.message) handlers.message({ id, res }); },
    die(code) { if (handlers.exit) handlers.exit(code); },
    /** Simulate a wedged process: accepts work, never replies, ignores kill. */
    wedge() { this.kill = () => { this.killed += 1; }; },
  };
}

const inlineOk = (op) => Promise.resolve({ ok: true, ranInline: true, op });

test('a job that is answered resolves with the answer and cancels its guard', async () => {
  const c = fakeChild();
  const client = createMfClient({ fork: () => c, inline: inlineOk, timeoutMs: 50 });
  const p = client.run('convert', { src: 'a.3mf' });
  c.answer(c.sent[0].id, { ok: true, buffer: 'bytes' });
  assert.deepEqual(await p, { ok: true, buffer: 'bytes' });
  assert.equal(client.pendingCount(), 0);
  // If the guard were still armed it would fire after the test and replace a
  // perfectly healthy child.
  await new Promise((r) => setTimeout(r, 80));
  assert.equal(c.killed, 0, 'a completed job must not kill the worker later');
});

test('a child that never answers fails the job instead of hanging forever', async () => {
  const c = fakeChild();
  c.wedge();
  const client = createMfClient({ fork: () => c, inline: inlineOk, timeoutMs: 30 });
  const res = await client.run('convert', { src: 'big.3mf' });
  assert.equal(res.ok, false);
  assert.equal(res.error, HANG_MSG, 'the shop gets a reason, not a spinner');
  assert.equal(res.available, false);
});

test('a hang fails the jobs queued behind it AS SOON AS it is known', async () => {
  // The process is shared, so a job behind a hang is already doomed. Every job
  // does carry its own guard, which means "settle only the timed-out one" looks
  // identical in a test where both guards are milliseconds apart — and is very
  // different in production, where the second job would sit for another THIRTY
  // MINUTES waiting on a process already known to be dead.
  //
  // So this staggers them: B starts late enough that its own guard could not
  // have fired yet when A's does. If B is settled at that point, it was settled
  // by the hang being detected, not by its own timer.
  const c = fakeChild();
  c.wedge();
  const T = 300;
  const client = createMfClient({ fork: () => c, inline: inlineOk, timeoutMs: T });

  let bDone = null;
  const a = client.run('convert', { src: 'a.3mf' });
  await new Promise((r) => setTimeout(r, T * 0.7));            // A's guard fires at T
  const b = client.run('analyze', { src: 'b.3mf' }).then((res) => { bDone = res; return res; });

  await new Promise((r) => setTimeout(r, T * 0.6));            // now past T, well short of B's own 1.7T
  assert.notEqual(bDone, null, 'the queued job was left waiting for its own timeout');
  assert.equal(bDone.error, HANG_MSG);

  assert.equal((await a).error, HANG_MSG);
  assert.equal((await b).error, HANG_MSG);
  assert.equal(client.pendingCount(), 0);
});

test('a hang replaces the worker, so the next job gets a clean one', async () => {
  let forks = 0;
  const made = [];
  const client = createMfClient({
    fork: () => { forks += 1; const c = fakeChild(); c.wedge(); made.push(c); return c; },
    inline: inlineOk,
    timeoutMs: 30,
  });
  await client.run('convert', { src: 'a.3mf' });
  assert.equal(made[0].killed, 1, 'the wedged process should be killed');
  assert.equal(client.hasChild(), false, 'and forgotten');
  await client.run('convert', { src: 'b.3mf' });
  assert.equal(forks, 2, 'the next job must not be handed the same dead process');
});

test('a crash still reports as a crash, not as a hang', async () => {
  const c = fakeChild();
  const client = createMfClient({ fork: () => c, inline: inlineOk, timeoutMs: 5000 });
  const p = client.run('convert', { src: 'huge.3mf' });
  c.die(9);
  const res = await p;
  assert.match(res.error, /stopped while working on this file/);
  assert.match(res.error, /exit 9/);
  assert.notEqual(res.error, HANG_MSG, 'a killed process and a wedged one are different faults');
});

test('no child means the work runs inline, exactly as before', async () => {
  const client = createMfClient({ fork: () => null, inline: inlineOk, timeoutMs: 30 });
  assert.deepEqual(await client.run('analyze', {}), { ok: true, ranInline: true, op: 'analyze' });
});

test('a fork that throws falls back inline rather than losing the feature', async () => {
  const warned = [];
  const client = createMfClient({
    fork: () => { throw new Error('ENOENT'); },
    inline: inlineOk, timeoutMs: 30, onWarn: (m) => warned.push(m),
  });
  assert.deepEqual(await client.run('analyze', {}), { ok: true, ranInline: true, op: 'analyze' });
  assert.match(warned[0], /worker unavailable/);
});

test('a postMessage that throws falls back inline and disarms the guard', async () => {
  const c = fakeChild();
  c.postMessage = () => { throw new Error('channel closed'); };
  const client = createMfClient({ fork: () => c, inline: inlineOk, timeoutMs: 30 });
  assert.deepEqual(await client.run('analyze', {}), { ok: true, ranInline: true, op: 'analyze' });
  assert.equal(client.pendingCount(), 0);
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(c.killed, 0, 'a job that never reached the child must not kill it');
});

test('an answer for an unknown id is ignored', async () => {
  const c = fakeChild();
  const client = createMfClient({ fork: () => c, inline: inlineOk, timeoutMs: 5000 });
  const p = client.run('convert', {});
  c.answer(9999, { ok: true, stray: true });
  assert.equal(client.pendingCount(), 1, 'a stray reply must not settle a real job');
  c.answer(c.sent[0].id, { ok: true });
  assert.deepEqual(await p, { ok: true });
});

test('dispose settles nothing but leaves no timer armed', async () => {
  const c = fakeChild();
  const client = createMfClient({ fork: () => c, inline: inlineOk, timeoutMs: 30 });
  client.run('convert', {});
  client.dispose();
  assert.equal(client.pendingCount(), 0);
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(c.killed, 1, 'killed once by dispose, not again by a stray guard');
});

test('CRASH and HANG are different messages', () => {
  assert.notEqual(CRASH_MSG, HANG_MSG);
});
