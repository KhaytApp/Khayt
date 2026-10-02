'use strict';
/**
 * The highest revision of a shop's cloud store this device has seen.
 *
 * ── ROLLBACK, CHECKED ON THIS SIDE ─────────────────────────────────────────
 *
 * The store and its deltas are sealed with the shop's data key, so a
 * compromised or misbehaving server cannot WRITE a store this app would open.
 * It can still hand back an OLD one, under a lower revision, and every device
 * would fold it and treat the shop's newer records as the ones to overwrite.
 * The ciphertext does not bind the revision (a format change every client has
 * to make together), so the only defence a client has alone is memory: a cloud
 * that answers BELOW a revision this device has already seen has gone
 * backwards, and that is refused, not applied.
 *
 * Raised by every accepted pull, SET by every push the server confirms (a
 * whole-store push after a cloud reset legitimately restarts the count, and the
 * server has just said so in answer to this device's own write). A shop that
 * restored its cloud on purpose says so with `accept`, which takes the refused
 * revision as the new mark.
 *
 * Kept on disk, per cloud address and shop, so a relaunch remembers it: a
 * rollback is most likely to be noticed after a restart, which an in-memory
 * check would have forgotten. A number, not a secret.
 *
 * The same rule as the Mac's CloudReader.RevisionMemory (#1712), key included.
 */

const keyFor = (url, shopId) => String(url || '').trim().toLowerCase().replace(/\/+$/, '') + '|' + String(shopId || '');

/**
 * @param {{ file?: string, url: string, shopId: string, fs?: object }} opts
 *   `file` omitted keeps the mark in memory only (tests).
 */
function createRevisionMemory({ file, url, shopId, fs = require('fs') } = {}) {
  const key = keyFor(url, shopId);
  let memory = {};
  let pending = null;

  const readAll = () => {
    if (!file) return memory;
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {};
    } catch (_) { return {}; }
  };
  const writeAll = (all) => {
    if (!file) { memory = all; return; }
    try {
      const tmp = `${file}.tmp.${process.pid}`;
      fs.writeFileSync(tmp, JSON.stringify(all), { mode: 0o600 });
      fs.renameSync(tmp, file);
    } catch (_) { /* a mark that cannot be saved is only a weaker check, never a broken sync */ }
  };

  function highest() {
    const v = readAll()[key];
    return Number.isInteger(v) && v >= 0 ? v : null;
  }
  function set(rev) {
    const all = readAll();
    all[key] = rev;
    pending = null;
    writeAll(all);
  }

  return {
    key,
    highest,
    /** A pull was accepted at `rev`: raise the mark, never lower it. */
    saw(rev) {
      const r = Number(rev) || 0;
      const seen = highest();
      if (seen !== null && seen >= r) return;
      set(r);
    },
    /** The server accepted this device's own push and is now at `rev`. */
    confirmed(rev) { set(Number(rev) || 0); },
    /** A pull at `rev` was refused for going backwards; held until accepted. */
    refused(rev) { pending = Number(rev) || 0; },
    /** The revision last refused, while it still is. */
    refusal() { return pending; },
    /** The shop trusts the older cloud: take the refused revision as the mark. */
    accept() {
      if (pending === null) return false;
      set(pending);
      return true;
    },
  };
}

module.exports = { createRevisionMemory, keyFor };
