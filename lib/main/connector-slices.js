'use strict';
/**
 * A paired slicer plugin's slices: announced (POST /api/connectors/slices),
 * then waiting for their file, then in the inbox, then gone from it. The
 * native Mac's `LanServer+Connector` slice records, state for state.
 *
 *   awaiting-file  announced; the file may be PUT until `uploadBy` (600 s)
 *   receiving      a file is arriving now (shown as awaiting-file)
 *   in-inbox       filed (lib/main/slicer-inbox.js)
 *   left-inbox     the shop took it into a job or the library, or threw it away
 *   expired        not sent in time, sent wrong twice, or waiting when the app stopped
 *
 * KEPT ACROSS A RESTART, BESIDE THE INBOX, NEVER IN THE BOOK: one small JSON
 * per slice in `From slicer/.slices/` holding ids, state, hash, size and
 * times. NEVER a file name, the suggestion or the slots (a file name can hold
 * a client's name): those live in memory only, which is why a slice read back
 * after a restart cannot take a file any more. The sweep at launch (`load`)
 * expires every slice still waiting or receiving; the plugin announces again.
 *
 * Times are the WALL clock (ms): the records outlive the app.
 *
 * Main process only (node:fs).
 */
const nodePath = require('path');
const crypto = require('crypto');
const { isoSeconds } = require('./slicer-inbox.js');

const AWAIT_MS = 600_000;
const MAX_ATTEMPTS = 2;
const MAX_SLICES = 1000;
const KEEP_EXPIRED_MS = 24 * 3600_000;
const KEEP_LEFT_MS = 7 * 24 * 3600_000;
const STATES = ['awaiting-file', 'receiving', 'in-inbox', 'left-inbox', 'expired'];

/** 16 characters of RFC 4648 base32: 80 random bits (the Mac's freshSliceId). */
function freshSliceId() {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let out = '';
  for (const b of crypto.randomBytes(16)) out += alphabet[b & 31];
  return out;
}
const plausibleSliceId = (id) => typeof id === 'string' && /^[A-Z2-7]{16}$/.test(id);

/** What is kept on disk: sorted keys, ISO dates (the Mac's Saved, `.sortedKeys`). */
function savedOf(s) {
  const out = {
    attempts: s.attempts, bytes: s.bytes, changedAt: isoSeconds(s.changedAt), connectorId: s.connectorId,
    id: s.id,
  };
  if (s.inboxId) out.inboxId = s.inboxId;
  out.sha256 = s.sha256;
  out.state = s.state;
  out.uploadBy = isoSeconds(s.uploadBy);
  return out;
}

/**
 * @param {object} o
 * @param {object} o.fs
 * @param {string} o.dir        `From slicer/.slices`
 * @param {function} [o.now]    wall ms
 */
function createConnectorSlices({ fs, dir, now = Date.now }) {
  let map = null;   // id -> { id, connectorId, name, bytes, sha256, suggested, slots, uploadBy, state, attempts, inboxId, changedAt }

  function persist(id) {
    const s = map.get(id);
    const file = nodePath.join(dir, id + '.json');
    try {
      if (!s) { fs.rmSync(file, { force: true }); return; }
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(file + '.tmp', JSON.stringify(savedOf(s)), { mode: 0o600 });
      fs.renameSync(file + '.tmp', file);
    } catch (_) { /* the record is a convenience; the next change writes it again */ }
  }

  /**
   * Read the records once. A slice that was waiting for its file (or
   * receiving one) when the app stopped is expired now: its file name was
   * never written down. An unreadable record is removed.
   */
  function load() {
    if (map) return map;
    map = new Map();
    let names = [];
    try { names = fs.readdirSync(dir); } catch (_) { return map; }
    const t = now();
    for (const n of names) {
      if (!n.endsWith('.json')) continue;
      const file = nodePath.join(dir, n);
      let s = null;
      try { s = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { s = null; }
      const ok = s && plausibleSliceId(s.id) && n === s.id + '.json' && STATES.includes(s.state)
        && typeof s.connectorId === 'string' && typeof s.sha256 === 'string'
        && !Number.isNaN(Date.parse(s.uploadBy)) && !Number.isNaN(Date.parse(s.changedAt));
      if (!ok) { try { fs.rmSync(file, { force: true }); } catch (_) { /* next time */ } continue; }
      const waiting = s.state === 'awaiting-file' || s.state === 'receiving';
      map.set(s.id, {
        id: s.id, connectorId: s.connectorId, name: '', bytes: +s.bytes || 0, sha256: s.sha256,
        suggested: { intent: 'inbox' }, slots: null, uploadBy: Date.parse(s.uploadBy),
        state: waiting ? 'expired' : s.state, attempts: +s.attempts || 0, inboxId: s.inboxId || null,
        changedAt: waiting ? t : Date.parse(s.changedAt),
      });
      if (waiting) persist(s.id);
    }
    return map;
  }

  /** Expire what waited past uploadBy, forget what is old, keep the map bounded. */
  function prune() {
    load();
    const t = now();
    for (const [id, s] of [...map]) {
      if (s.state === 'awaiting-file' && t > s.uploadBy) setState(id, 'expired');
      else if ((s.state === 'expired' && t - s.changedAt > KEEP_EXPIRED_MS)
        || (s.state === 'left-inbox' && t - s.changedAt > KEEP_LEFT_MS)) { map.delete(id); persist(id); }
    }
    if (map.size > MAX_SLICES) {
      const oldest = [...map.values()].sort((a, b) => a.changedAt - b.changedAt).slice(0, map.size - MAX_SLICES);
      for (const s of oldest) { map.delete(s.id); persist(s.id); }
    }
  }

  function setState(id, state) {
    load();
    const s = map.get(id);
    if (!s) return;
    s.state = state;
    s.changedAt = now();
    persist(id);
  }

  function put(slice) { load(); map.set(slice.id, slice); persist(slice.id); return slice; }
  function update(id, fields) { load(); const s = map.get(id); if (!s) return null; Object.assign(s, fields); persist(id); return s; }
  function get(id) { load(); return map.get(id) || null; }
  /** The slice, only for the connector that announced it; anyone else's is "not here". */
  function own(id, connectorId) { prune(); const s = map.get(id); return s && s.connectorId === connectorId ? s : null; }
  function values() { load(); return [...map.values()]; }
  function removeConnector(connectorId) {
    load();
    for (const [id, s] of [...map]) if (s.connectorId === connectorId) { map.delete(id); persist(id); }
  }

  return { load, prune, setState, put, update, get, own, values, removeConnector };
}

module.exports = {
  createConnectorSlices, freshSliceId, plausibleSliceId, savedOf,
  AWAIT_MS, MAX_ATTEMPTS, MAX_SLICES, KEEP_EXPIRED_MS, KEEP_LEFT_MS,
};
