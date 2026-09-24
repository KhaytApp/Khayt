'use strict';
/*
 * WRAPPED IN AN IIFE, like every other shared module.
 *
 * It used to declare `const api` at the top level. In a browser that is a
 * module-scoped binding and harmless; in the ONE JavaScriptCore context the
 * Mac app loads every module into, it is a global — and the second module to
 * declare it fails the whole runtime with "Can't create duplicate variable:
 * 'api'". Which does not raise anywhere a shop can see: the app comes up with
 * no words, no tax and no writes.
 */
(function (global) {

  /**
   * The one backup that exists specifically to survive a bad upgrade.
   *
   * Khayt already protects the store well against crashes: writes are atomic with
   * an fsync'd temp swap, there is a one-generation `.prev` rollback,
   * recoverStoreRaw() heals from a half-finished write, and a store written by a
   * NEWER build is refused rather than saved over (see the guard in main.js).
   *
   * None of that covers the case this module exists for: a build whose own
   * migration is wrong. Then nothing crashes and nothing is refused — the app
   * reads the old store, transforms it, and writes the result. `.prev` holds the
   * good copy for exactly one save, and the daily auto-backup is keyed by DATE, so
   * the first backup after the upgrade overwrites the last good one from the same
   * day. The shop discovers the damage on Tuesday and finds Monday's backup, minus
   * everything it did on Monday.
   *
   * So: the first time a build opens a store written by an OLDER schema, copy that
   * store aside, verbatim, before anything in this build has touched it. It is
   * taken from the raw bytes read off disk rather than the normalized snapshot,
   * because normalizeStoreSnapshot is an allowlist and dropping an unrecognised
   * collection is one of the failures being insured against.
   *
   * These backups are never rotated away — see isProtectedBackup. There is one per
   * schema version the shop has ever upgraded through, which is a handful of files
   * over the life of an install, not a growing pile.
   *
   * Pure (no fs, no Electron) so the decision and the naming are testable without
   * a filesystem; main.js does the writing.
   */

  /** Marks a backup that rotation must never delete. */
  const PROTECTED_PREFIX = 'pre-upgrade-';

  /**
   * The OTHER backup routine housekeeping must not delete.
   *
   * `lib/updater.js` copies the store aside before installing an app update
   * and names it `pre-update-v<version>-<date>.json`. Two mechanisms, two
   * confusingly similar names, and this rule only ever knew about the first —
   * so an update backup was counted as rotatable.
   *
   * It survived by accident rather than by rule: rotation sorts the filenames
   * and deletes from the front, and `pre-update-…` sorts after every
   * `YYYY-MM-DD.json`, so the ones deleted were always dated. The accident
   * still cost a shop backups — three update backups meant twenty-seven daily
   * ones instead of thirty — and it would have become a deletion the moment
   * anything changed the sort or the slice.
   */
  const UPDATE_PREFIX = 'pre-update-';

  /**
   * The copy of the book a full wipe takes before it deletes anything.
   *
   * It is the one backup that exists only because the shop was about to lose
   * everything, so it is the last thing housekeeping may touch: never rotated,
   * and the one file the wipe itself leaves behind.
   */
  const WIPE_PREFIX = 'pre-wipe-';

  function preWipeBackupName(isoTimestamp) {
    return `${WIPE_PREFIX}${String(isoTimestamp || '').replace(/[:.]/g, '-')}.json`;
  }

  /**
   * Should this build take a pre-upgrade backup of what it just read?
   *
   * @param {number|null|undefined} diskVersion  `version` from the store on disk
   * @param {number} buildVersion                STORE_VERSION of this build
   * @param {boolean} existed                    whether a store file was actually there
   *
   * A store with NO version was written before versioning existed, which is the
   * oldest upgrade of all and the one most worth insuring — so a missing version
   * counts as older, not as "unknown, skip it". A fresh install has nothing to
   * back up, which is what `existed` distinguishes.
   *
   * A NEWER disk version returns false: that store is not being upgraded, it is
   * being refused, and the save guard already protects it.
   */
  function needsPreUpgradeBackup(diskVersion, buildVersion, existed = true) {
    if (!existed) return false;
    if (!Number.isFinite(buildVersion)) return false;
    const from = Number.isFinite(diskVersion) ? diskVersion : 0;
    return from < buildVersion;
  }

  /**
   * Filename for the backup, carrying both versions so the shop (and support) can
   * see what it is without opening it.
   *
   * @param {number|null|undefined} diskVersion
   * @param {number} buildVersion
   * @param {string} isoTimestamp  an ISO-8601 instant; ':' is not legal in a
   *                               Windows filename, so it is replaced
   */
  function preUpgradeBackupName(diskVersion, buildVersion, isoTimestamp) {
    const from = Number.isFinite(diskVersion) ? diskVersion : 0;
    const stamp = String(isoTimestamp || '').replace(/[:.]/g, '-');
    return `${PROTECTED_PREFIX}v${from}-to-v${buildVersion}-${stamp}.json`;
  }

  /**
   * Is this a backup rotation must keep?
   *
   * The daily rotation keeps the most recent 30 files in the backups directory.
   * Without this test a shop that opened the app on 30 consecutive days would have
   * its upgrade insurance quietly deleted by routine housekeeping — the backup
   * would exist for exactly as long as nobody needed it.
   */
  function isProtectedBackup(filename) {
    const name = String(filename || '');
    return name.startsWith(PROTECTED_PREFIX) || name.startsWith(UPDATE_PREFIX)
      || name.startsWith(WIPE_PREFIX);
  }

  /**
   * Split a directory listing into the files rotation may delete and those it may
   * not, preserving order.
   */
  function partitionForRotation(filenames) {
    const list = Array.isArray(filenames) ? filenames : [];
    const protectedFiles = [];
    const rotatable = [];
    for (const f of list) (isProtectedBackup(f) ? protectedFiles : rotatable).push(f);
    return { protectedFiles, rotatable };
  }

  /**
   * Which backups rotation deletes, oldest first — two pools, never one.
   *
   * ── WHY TWO ───────────────────────────────────────────────────────────
   *
   * Daily backups (`YYYY-MM-DD.json`) and snapshots (`YYYY-MM-DD-HHMM.json`,
   * taken before every cloud merge, every restore and on request) shared one
   * pool of thirty. With the cloud's delta chain shut, a Mac pushes the whole
   * book and takes a snapshot every fifteen minutes, so thirty slots were
   * about seven hours of a working day — and after one busy day every daily
   * backup older than that morning was gone. A mistake noticed tomorrow had
   * nothing to go back to. Found by a file-safety scan.
   *
   * So the dailies keep their own thirty and snapshots their own
   * `snapshots` (48 by default); pre-upgrade, pre-update and pre-wipe backups
   * are never deleted; and anything in `except` (a restore's own source) is kept
   * whatever its age.
   *
   * @param {string[]} filenames  the directory listing
   * @param {{daily?: number, snapshots?: number, except?: string[]}} [opts]
   * @returns {string[]} names to delete
   */
  function backupsToDelete(filenames, opts) {
    const o = opts || {};
    const daily = Number.isFinite(o.daily) ? o.daily : 30;
    const snapshots = Number.isFinite(o.snapshots) ? o.snapshots : 48;
    const except = new Set(Array.isArray(o.except) ? o.except : []);
    const { rotatable } = partitionForRotation(filenames);
    const sorted = rotatable.filter((f) => /\.json$/.test(f)).sort();
    const days = sorted.filter((f) => /^\d{4}-\d{2}-\d{2}\.json$/.test(f));
    const snaps = sorted.filter((f) => !/^\d{4}-\d{2}-\d{2}\.json$/.test(f));
    const oldest = (list, keep) => list.slice(0, Math.max(0, list.length - Math.max(0, keep)));
    return oldest(days, daily).concat(oldest(snaps, snapshots)).filter((f) => !except.has(f));
  }

  const api = {
    backupsToDelete,
    PROTECTED_PREFIX,
    UPDATE_PREFIX,
    WIPE_PREFIX,
    preWipeBackupName,
    needsPreUpgradeBackup,
    preUpgradeBackupName,
    isProtectedBackup,
    partitionForRotation,
  };

  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytUpgradeBackup = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
