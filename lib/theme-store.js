'use strict';

(function (global) {
/**
 * Where an installed theme lives, and how it gets there.
 *
 * THE REASON THIS FILE EXISTS
 *
 * Khayt has been able to register a custom theme since the theme registry was
 * written. No user has ever done it, and none could: `themes/custom/index.json`
 * is inside `app.asar` — a read-only archive, replaced whole on every update. So
 * the only way to add a theme was to run from source, and the only way to keep
 * one was to never update. That is why the index still reads `{"themes": []}`.
 *
 * Themes belong in userData, next to the shop's own data: writable, and it
 * survives an update precisely because the installer does not own it.
 *
 * ONE FILE, NOT AN ARCHIVE
 *
 * A theme ships as a single JSON document carrying its manifest and its
 * stylesheets inline:
 *
 *     { "manifest": { "id": "my-shop", … }, "files": { "tokens.css": "…" } }
 *
 * A zip would have been the obvious choice and it is the wrong one. Unpacking
 * an archive from a stranger means owning zip-slip — an entry named
 * `../../../../etc/cron.d/x` that escapes the directory it is extracted into —
 * and that class of bug is subtle, well-known and entirely avoidable. JSON has
 * no notion of a path, so there is nothing to escape with: every filename is a
 * key this file checks before it becomes a filename.
 *
 * It is also the format a person can actually share. One file, readable, mailable,
 * diffable, and reviewable before installing by anyone who wants to look.
 *
 * PURE
 *
 * Decides paths and plans writes; performs none of them. The main process does
 * the I/O, so this is testable without touching a disk — and the containment
 * check below is the kind of thing that must be tested rather than reasoned about.
 */

const path = (typeof require === 'function') ? require('path') : null;

/** The one directory a theme may occupy. */
const THEMES_DIRNAME = 'themes';
const MANIFEST_NAME = 'manifest.json';

/**
 * The same id rule `registry-core.js` enforces.
 *
 * Restated rather than imported because this runs in the main process on a file
 * that arrived from outside, and a rule that matters this much should not be one
 * `require` away from being skipped.
 */
const ID_RE = /^[a-z][a-z0-9-]{1,31}$/;

/** A filename, not a path. Matches the rule lib/theme-package.js applies. */
const SAFE_FILENAME = /^[a-zA-Z0-9._-]+\.css$/;

/** Reserved: shipping a theme that shadows a built-in would be indistinguishable from replacing it. */
const RESERVED_IDS = ['khayt', 'workbench', 'command', 'vivid', 'blueprint', 'nocturne', 'meridian', 'foreman', 'flow', 'custom', 'default', 'base'];

function isValidId(id) {
  return typeof id === 'string' && ID_RE.test(id) && !RESERVED_IDS.includes(id);
}

/**
 * Is `target` genuinely inside `root`?
 *
 * The check that stops a theme writing outside its own folder. It compares
 * RESOLVED paths, because `root + '/' + id` is a string operation and
 * `..` is a perfectly good string. A prefix test alone is not enough either:
 * `/themes-evil` starts with `/themes`, so the separator has to be part of it.
 */
function isInsideRoot(root, target) {
  if (!path || typeof root !== 'string' || typeof target !== 'string' || !root || !target) return false;
  const r = path.resolve(root);
  const t = path.resolve(target);
  if (t === r) return false;                       // the root itself is not "inside" it
  return t.startsWith(r.endsWith(path.sep) ? r : r + path.sep);
}

/** Where a theme's folder is, or null when the id is not one we would accept. */
function themeDir(userDataPath, id) {
  if (!path || typeof userDataPath !== 'string' || !userDataPath) return null;
  if (!isValidId(id)) return null;
  const root = path.join(userDataPath, THEMES_DIRNAME);
  const dir = path.join(root, id);
  // Belt and braces: isValidId already forbids separators and dots, so this
  // cannot currently fail. It is here because the day someone loosens that
  // regex, this is what stops the loosening becoming an arbitrary file write.
  return isInsideRoot(root, dir) ? dir : null;
}

/** The themes root itself. */
function themesRoot(userDataPath) {
  return (path && typeof userDataPath === 'string' && userDataPath)
    ? path.join(userDataPath, THEMES_DIRNAME) : null;
}

/**
 * Parse a `.khayttheme` document.
 *
 * Shape only — the CSS is judged by lib/theme-package.js, which the caller runs
 * next. Split because "is this the right kind of document" and "is this content
 * safe" are different questions with different answers.
 *
 * @returns {{ok: boolean, error?: string, manifest?: object, files?: object}}
 */
function parseBundle(text) {
  if (typeof text !== 'string' || !text.trim()) return { ok: false, error: 'The file is empty.' };
  let doc;
  try { doc = JSON.parse(text); } catch (e) {
    return { ok: false, error: 'This is not a Khayt theme file — it is not valid JSON.' };
  }
  if (!doc || typeof doc !== 'object' || Array.isArray(doc)) {
    return { ok: false, error: 'This is not a Khayt theme file.' };
  }
  const manifest = doc.manifest;
  const files = doc.files;
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    return { ok: false, error: 'The theme file has no manifest.' };
  }
  if (!files || typeof files !== 'object' || Array.isArray(files)) {
    return { ok: false, error: 'The theme file carries no stylesheet.' };
  }
  if (!isValidId(manifest.id)) {
    return {
      ok: false,
      error: RESERVED_IDS.includes(manifest.id)
        ? `"${manifest.id}" is the name of a design Khayt already ships. Choose another id.`
        : 'The theme id must be lowercase letters, numbers and dashes (2–32 characters).',
    };
  }
  for (const [name, css] of Object.entries(files)) {
    if (typeof css !== 'string') return { ok: false, error: `${name} is not text.` };
  }
  return { ok: true, manifest, files };
}

/**
 * The exact writes an install performs, or null if it must not proceed.
 *
 * Returning a plan rather than doing the work means the caller can show it, and
 * means every path can be asserted in a test without a filesystem.
 *
 * @returns {{dir: string, writes: Array<{path: string, contents: string}>}|null}
 */
function planInstall(userDataPath, manifest, files) {
  const dir = themeDir(userDataPath, manifest && manifest.id);
  if (!dir || !path) return null;

  const writes = [{ path: path.join(dir, MANIFEST_NAME), contents: JSON.stringify(manifest, null, 2) }];
  for (const [name, css] of Object.entries(files || {})) {
    // Checked as a NAME first, before it is allowed to become a path.
    //
    // `path.join` is normalising, which is the trap: join(dir, '/abs.css') is
    // dir/abs.css, so a leading slash silently disappears and the file installs
    // under a name its author did not write. That is safe and it is still wrong
    // — the same "quietly cleaned up rather than refused" this system refuses to
    // do with CSS. So the name has to be a plain filename to begin with.
    if (!SAFE_FILENAME.test(name)) return null;
    const target = path.join(dir, name);
    // And then checked again as a path, because the two rules failing together
    // is what turns a loosened regex into an arbitrary write.
    if (!isInsideRoot(dir, target) || path.dirname(target) !== dir) return null;
    writes.push({ path: target, contents: css });
  }
  return { dir, writes };
}

/**
 * What a listing should say about an installed theme.
 *
 * A folder that no longer parses is reported as broken rather than skipped: a
 * theme that vanishes silently is one the owner cannot remove through the app,
 * because the app is pretending it is not there.
 */
function describeInstalled(id, manifest, problems) {
  const broken = !manifest || (Array.isArray(problems) && problems.length > 0);
  return {
    id,
    name: (manifest && typeof manifest.name === 'string' && manifest.name) || id,
    version: (manifest && manifest.version) || null,
    author: (manifest && typeof manifest.author === 'string') ? manifest.author : '',
    installed: true,
    broken,
    problems: Array.isArray(problems) ? problems : [],
  };
}

const api = {
  THEMES_DIRNAME, MANIFEST_NAME, RESERVED_IDS, ID_RE, SAFE_FILENAME,
  isValidId, isInsideRoot, themeDir, themesRoot, parseBundle, planInstall, describeInstalled,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytThemeStore = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
