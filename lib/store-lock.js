'use strict';

/**
 * Who owns khayt-store.json.
 *
 * Khayt has always had exactly one writer, and never said so out loud. Electron
 * takes `app.requestSingleInstanceLock()`, so the renderer, the fifteen LAN
 * handlers, the printer poll and the updater are all one process, and
 * `store-io`'s `_writeChain` serialises them. The invariant held because there
 * was nothing else on the machine that could open the file.
 *
 * The native Mac app is that something else. This makes the invariant checkable
 * rather than assumed.
 *
 * WHY OWNERSHIP AND NOT A LOCK AROUND EACH WRITE. Per-write locking looks like
 * the smaller change and does not work. `updateStoreOnDisk` reads
 * `getStore()` — the in-memory copy — in preference to the disk, so a second
 * process could take a perfectly correct lock, write, release, and have its
 * change overwritten by the incumbent's next save from memory. What has to be
 * exclusive is the whole session, not the moment of writing.
 *
 * PURE. No fs, no process, no clock. The caller reads the file, checks whether a
 * pid is alive and supplies the time; this decides what those facts mean
 * together. That is what makes the rules testable, and what lets the Swift app
 * implement the same protocol against the same cases.
 */

/** The lock lives beside the store it protects. */
const LOCK_FILENAME = 'khayt-store.lock';

/** How often a holder should refresh its record. */
const HEARTBEAT_MS = 30_000;

/**
 * When a record from a host we cannot probe is old enough to ignore.
 *
 * Three missed heartbeats. Only ever consulted for a lock written by a DIFFERENT
 * machine, where liveness cannot be checked — see `decide`.
 */
const STALE_AFTER_MS = 90_000;

const str = (v) => String(v == null ? '' : v).trim();

/**
 * A hostname, comparably.
 *
 * Node's `os.hostname()` and Swift's `ProcessInfo.hostName` return the SAME
 * machine in different case — `Turkis-MacBook-Air.local` against
 * `turkis-macbook-air.local`. Compared raw, the Mac app reads the Electron
 * app's lock as coming from another machine, stops asking whether that pid is
 * alive, and falls back to the clock: a live holder whose heartbeat lagged
 * ninety seconds would have its lock taken. Two writers, which is the one thing
 * this file exists to prevent.
 *
 * Hostnames are case-insensitive by convention, so folding is not a workaround.
 */
const host = (v) => str(v).toLowerCase();
const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0);

/**
 * Is this record old enough to ignore?
 *
 * A heartbeat in the FUTURE is not stale. Two machines never agree on the time,
 * and a store reached over a share can easily carry a record stamped ahead of
 * the reader's clock; treating a negative age as "old" broke a live holder's
 * lock instantly, which is the one outcome this whole file exists to prevent.
 */
function isStale(record, now) {
  return num(now) - num(record && record.heartbeat) >= STALE_AFTER_MS;
}

/**
 * The record a holder writes.
 *
 * `app` is a label for a person to read in a message, never something to branch
 * on: "Khayt" and "Khayt for Mac" both mean "not you".
 */
function claim({ app, pid, host: hostname, now }) {
  return {
    v: 1,
    app: str(app) || 'Khayt',
    pid: num(pid),
    host: host(str(hostname)),
    takenAt: num(now),
    heartbeat: num(now),
  };
}

/** A holder refreshing its own record. Same object, later heartbeat. */
function beat(record, now) {
  return { ...record, heartbeat: num(now) };
}

/**
 * What the lock file we found means.
 *
 * @param {object|null} existing  the parsed record, or null when there is no file
 * @param {{pid:number, host:string, now:number, alive:boolean|null}} self
 *        `alive` answers "is existing.pid a running process on THIS machine?" —
 *        null when the caller could not tell, which includes the case where the
 *        record came from another host.
 * @returns {{action:'take'|'own'|'held', holder:object|null, reason:string}}
 */
function decide(existing, self) {
  const me = self || {};
  const now = num(me.now);

  if (!existing || typeof existing !== 'object') {
    return { action: 'take', holder: null, reason: 'no-lock' };
  }
  const pid = num(existing.pid);
  const theirHost = host(existing.host);
  if (!pid) {
    // A file that is not a lock record. Treat it as no lock rather than as a
    // holder that can never be disproved.
    return { action: 'take', holder: null, reason: 'unreadable' };
  }
  if (pid === num(me.pid) && theirHost === host(me.host)) {
    return { action: 'own', holder: existing, reason: 'already-ours' };
  }

  // LIVENESS BEATS TIME, and only where liveness can be established. A process
  // that is running still owns the store even if it has not written a heartbeat
  // for an hour — it may be paused at a breakpoint, or stopped by the OS, and
  // breaking its lock on a stopwatch is how two writers happen.
  if (theirHost && host(me.host) && theirHost !== host(me.host)) {
    if (!isStale(existing, now)) {
      return { action: 'held', holder: existing, reason: 'other-host-fresh' };
    }
    return { action: 'take', holder: existing, reason: 'other-host-stale' };
  }
  if (me.alive === true) return { action: 'held', holder: existing, reason: 'holder-alive' };
  if (me.alive === false) return { action: 'take', holder: existing, reason: 'holder-gone' };

  // Could not tell on our own machine. Fall back to the clock rather than
  // assuming either way.
  if (!isStale(existing, now)) {
    return { action: 'held', holder: existing, reason: 'unknown-fresh' };
  }
  return { action: 'take', holder: existing, reason: 'unknown-stale' };
}

/**
 * A sentence for a person. Never mentions a pid: the useful facts are which
 * application, and — when it is elsewhere — which machine.
 */
function describe(verdict) {
  const v = verdict || {};
  if (v.action !== 'held') return '';
  const who = str(v.holder && v.holder.app) || 'Another copy of Khayt';
  const theirHost = host(v.holder && v.holder.host);
  const where = theirHost && theirHost !== host(v.selfHost)
    ? ` on ${str(v.holder.host)}` : '';
  return `${who}${where} has this shop's book open. Opened read-only so nothing is lost.`;
}

const api = {
  LOCK_FILENAME, HEARTBEAT_MS, STALE_AFTER_MS,
  claim, beat, decide, describe,
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytStoreLock = api;
