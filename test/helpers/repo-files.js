'use strict';

/**
 * The files this repository actually contains, as git sees them.
 *
 * ── Why a helper rather than a directory walk ───────────────────────────────
 *
 * A test that walks the working directory does not search the repository. It
 * searches whatever happens to be sitting in the checkout, and on the machine
 * this is usually run from that is a lot: `Khayt/`, `khayt-cloud/`,
 * `khayt-website/` and an `export/` tree all sit untracked in the working root,
 * each holding an older copy of this same source.
 *
 * For a REACHABILITY test — "no locale key is unreachable from code", the shape
 * that walks widest — that is not a harmless extra. The stale copies still
 * contain the call sites the current tree deleted, so a key that is genuinely
 * dead is still "found", the test passes locally, and CI fails it on a clean
 * checkout. Bitten on 2026-08-24: `kit.existing` became unreachable, the full
 * local suite went green, and only CI caught it.
 *
 * That is this codebase's recurring defect wearing test clothes — a check that
 * silently becomes a non-check. It never errors; it just stops being able to
 * find anything.
 *
 * `git ls-files` is the corpus CI checks out, exactly. Local and CI stop being
 * able to disagree.
 *
 * ── The one thing to know before it surprises you ───────────────────────────
 *
 * A file that is not `git add`ed is not in the corpus. Write a new renderer
 * module that uses a locale key, run the suite before staging it, and the key
 * reads as unreachable. That is deliberate: CI cannot see that file either, so
 * a corpus that included it would put local back to being the weaker check —
 * which is the whole bug. `git add` it, or expect the failure.
 *
 * It throws rather than falling back to a walk if git is unavailable. A quiet
 * fallback here would restore the exact failure this exists to remove, on the
 * one machine where nobody would think to check.
 */

const { execFileSync } = require('child_process');
const path = require('path');

const ROOT = path.join(__dirname, '..', '..');

let cached = null;

/**
 * Every tracked file, repo-relative, with forward slashes on every platform.
 * Cached: the suite asks more than once and this shells out.
 */
function trackedFiles() {
  if (cached) return cached;
  let out;
  try {
    out = execFileSync('git', ['ls-files', '-z'], {
      cwd: ROOT,
      encoding: 'utf8',
      maxBuffer: 32 * 1024 * 1024,
    });
  } catch (err) {
    throw new Error(
      'test/helpers/repo-files.js could not run `git ls-files`, so it cannot tell ' +
      'this repository apart from whatever else is in the checkout. Refusing to ' +
      'fall back to a directory walk, because that is the failure this helper ' +
      `exists to remove. Original error: ${err && err.message}`
    );
  }
  cached = out.split('\0').filter(Boolean);
  return cached;
}

/**
 * Tracked files whose path passes `filter`, as absolute paths.
 * @param {(relPath: string) => boolean} [filter]
 */
function trackedPaths(filter) {
  const rels = filter ? trackedFiles().filter(filter) : trackedFiles();
  return rels.map((r) => path.join(ROOT, r));
}

module.exports = { ROOT, trackedFiles, trackedPaths };
