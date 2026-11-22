'use strict';
/**
 * The client side of the 3MF converter's worker process.
 *
 * One long-lived child, forked on first use and reused; jobs are correlated by
 * id so several can be in flight at once. This lived inline in main.js, where it
 * could not be tested — which is why it shipped without the one thing below.
 *
 * THE GAP THIS CLOSES: a child that *exits* was handled well, but a child that
 * *hangs* was not handled at all. Nothing ever settled the promise, so the IPC
 * call never returned and the renderer waited on a spinner with no end and no
 * error — indistinguishable, from the shop's side, from the app being broken.
 *
 * A hung child is also not one job's problem. The process is shared, so every
 * job behind it is stuck too. On a timeout the child is therefore replaced, not
 * merely abandoned: the stuck jobs are failed with a reason and the next call
 * forks a clean process.
 */

/**
 * Long enough that no real job hits it, short enough that a wedged process is
 * not forever. This is a HANG GUARD, not a budget — a convert legitimately runs
 * for minutes on a large file, and killing honest work would be the worse bug.
 */
const DEFAULT_TIMEOUT_MS = 30 * 60 * 1000;

const CRASH_MSG = 'The converter stopped while working on this file — it may be too large for this machine.';
const HANG_MSG = 'The converter stopped responding and was restarted. Nothing was changed on disk.';

/**
 * @param {object} deps
 *   fork()            -> a child with on(event,cb) / postMessage(msg) / kill(), or null
 *   inline(op, args)  -> Promise, the same work on this thread when there is no child
 *   timeoutMs         -> optional override
 *   onWarn(message)   -> optional logger
 */
function createMfClient(deps) {
  const fork = deps && deps.fork;
  const inline = deps && deps.inline;
  const timeoutMs = (deps && deps.timeoutMs) || DEFAULT_TIMEOUT_MS;
  const onWarn = (deps && deps.onWarn) || (() => {});

  let child = null;
  let seq = 0;
  const pending = new Map();

  /** Settle everything still waiting and forget the process. */
  function failAll(error) {
    const dead = [...pending.values()];
    pending.clear();
    for (const p of dead) {
      if (p.timer) clearTimeout(p.timer);
      p.resolve({ ok: false, available: false, error });
    }
  }

  function ensureChild() {
    if (child) return child;
    let c;
    try {
      c = fork();
    } catch (e) {
      onWarn(`worker unavailable, running inline: ${(e && e.message) || e}`);
      return null;
    }
    if (!c) return null;

    c.on('message', (msg) => {
      const p = msg && pending.get(msg.id);
      if (!p) return;
      pending.delete(msg.id);
      if (p.timer) clearTimeout(p.timer);
      p.resolve(msg.res);
    });

    // A job big enough to kill the child must fail loudly. Falling back to
    // running the same job on this thread would freeze the app on its way to
    // the same death.
    c.on('exit', (code) => {
      child = null;
      failAll(CRASH_MSG + (code ? ` (exit ${code})` : ''));
    });

    child = c;
    return c;
  }

  /** Run an op off this thread, or on it if there is no child to run it on. */
  function run(op, args) {
    const c = ensureChild();
    if (!c) return inline(op, args);
    const id = ++seq;
    return new Promise((resolve) => {
      const rec = { resolve, timer: null };
      rec.timer = setTimeout(() => {
        // Settle THIS job first. Killing the child should also settle it via
        // 'exit', but a kill that fails, or a process that ignores it, would
        // otherwise leave the caller waiting exactly as before.
        if (pending.delete(id)) resolve({ ok: false, available: false, error: HANG_MSG });
        onWarn(`job ${id} (${op}) did not answer in ${timeoutMs} ms — replacing the worker`);
        const dying = child;
        child = null;                       // the next run() forks a clean one
        failAll(HANG_MSG);                  // everything behind it is stuck too
        try { dying && dying.kill(); } catch (_) { /* already gone */ }
      }, timeoutMs);
      pending.set(id, rec);

      try {
        c.postMessage({ id, op, args });
      } catch (e) {
        pending.delete(id);
        clearTimeout(rec.timer);
        resolve(inline(op, args));
      }
    });
  }

  /** Shut down on quit. */
  function dispose() {
    const dying = child;
    child = null;
    for (const p of pending.values()) if (p.timer) clearTimeout(p.timer);
    pending.clear();
    try { dying && dying.kill(); } catch (_) { /* already gone */ }
  }

  return { run, dispose, pendingCount: () => pending.size, hasChild: () => !!child };
}

const api = { createMfClient, DEFAULT_TIMEOUT_MS, CRASH_MSG, HANG_MSG };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
