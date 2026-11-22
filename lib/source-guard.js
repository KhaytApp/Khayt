'use strict';
/**
 * Keep a build from leaving the checkout modified.
 *
 * scripts/build-bedready.mjs has to swap package.json to Bed Ready's version for the
 * duration of a build, because Bed Ready ships on its own version line out of the same
 * repo. It then has to put the original bytes back, on every exit path.
 *
 * Restoring once is not enough, because the build is not the only writer. electron-builder
 * runs @electron/rebuild and an npm "collector" with `projectDir=./ appDir=./` — the same
 * directory — and `spawnSync` waits for its own child, not for that child's children. A
 * straggler npm can therefore still be writing package.json after the restore has verified
 * its own write and reported success.
 *
 * That is not hypothetical. One `npm run pack:bedready` left package.json holding Bed
 * Ready's version with the entire `scripts` block gone, having logged "source restored
 * byte-identical (finally)" and exited 0. Nothing looked wrong until the next `npm run` in
 * that checkout failed with "npm error npm run", by which point the cause was several
 * commands in the past. The same command run again restored cleanly, which is what makes
 * it a race rather than a bug in the restore.
 *
 * So the contract here is: restore, then keep looking for a while, repair anything that
 * moves, and — because silence is the dangerous outcome — fail loudly if a file will not
 * stay restored.
 */
const fsDefault = require('fs');

/**
 * @param {string[]} files absolute paths to guard
 * @param {{ fs?: typeof import('fs'), sleep?: (ms: number) => void, log?: Function, error?: Function }} deps
 */
function createSourceGuard(files, deps = {}) {
  const fs = deps.fs || fsDefault;
  const log = deps.log || (() => {});
  const error = deps.error || (() => {});
  // Atomics.wait is the only synchronous sleep Node offers without spawning anything.
  const sleep = deps.sleep
    || ((ms) => { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); });

  /** Exact bytes, snapshotted before anything is allowed to touch them. */
  const guarded = files.map((file) => ({ file, bytes: fs.readFileSync(file) }));
  const name = (g) => g.file.split(/[\\/]/).pop();

  let restoredOnce = false;

  /** Files whose current bytes differ from the snapshot (unreadable counts as differing). */
  function drifted() {
    return guarded.filter((g) => {
      try { return !fs.readFileSync(g.file).equals(g.bytes); } catch (_) { return true; }
    });
  }

  /**
   * Put the snapshot back. Latched to once unless `again` — the signal handlers and the
   * finally block both call it, and only the first should do the work.
   */
  function restore(reason, { again = false } = {}) {
    if (restoredOnce && !again) return true;
    restoredOnce = true;
    let ok = true;
    for (const g of guarded) {
      try {
        fs.writeFileSync(g.file, g.bytes);
        // Proves the write landed. It does NOT prove nothing will overwrite it next.
        if (!fs.readFileSync(g.file).equals(g.bytes)) ok = false;
      } catch (e) {
        ok = false;
        error(`restore of ${name(g)} failed: ${(e && e.message) || e}`);
      }
    }
    log(ok
      ? `source restored byte-identical (${reason}).`
      : `WARNING: source restore had problems (${reason}).`);
    return ok;
  }

  /**
   * Watch for a while after the build and repair anything a straggler rewrites.
   * @returns {boolean} true when every guarded file ended up matching its snapshot
   */
  function settleAndVerify({ rounds = 8, waitMs = 250, onCheck = null } = {}) {
    for (let i = 0; i < rounds; i++) {
      if (onCheck) onCheck(i); else sleep(waitMs);
      const bad = drifted();
      if (!bad.length) continue;
      error(`${bad.map(name).join(', ')} changed AFTER the restore — a straggler process `
        + 'from the build is still writing. Restoring again.');
      restore('post-build drift', { again: true });
    }
    if (onCheck) onCheck(rounds);
    const bad = drifted();
    if (bad.length) {
      error(`FAILED to keep ${bad.map(name).join(', ')} restored. Your checkout is modified — `
        + `run \`git checkout -- ${bad.map(name).join(' ')}\` before doing anything else.`);
      return false;
    }
    return true;
  }

  return { guarded, restore, settleAndVerify, drifted };
}

module.exports = { createSourceGuard };
