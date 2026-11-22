'use strict';
/**
 * Each printer's live state, as one row per machine, and the snapshot of those
 * rows this computer publishes to Khayt Cloud for the phone and the PWA to read
 * away from the shop.
 *
 * Pure: no clock, no socket, no key. The caller hands in the time, the poll
 * cache and the sealing function.
 *
 * Two jobs, one file, so the LAN and the cloud cannot drift apart:
 *   - `liveRows` builds `GET /api/machines/live`'s rows (lib/lan-server.js),
 *     and the cloud snapshot is made of the same rows.
 *   - `snapshot` / `body` / `signature` / `due` are the Mac's
 *     `LivePrinters` (mac/KhaytCore/Sources/KhaytCore/LivePrinters.swift),
 *     rule for rule. The cloud contract is khayt-cloud's
 *     `docs/api-contract.md`, "Live channel & live printers", and
 *     docs/LAN_API.md "Khayt Cloud: the same rows away from the shop".
 */

const PrinterNeeds = require('./printer-needs.js');

/** The serialised envelope must stay at or under this (the server's 413 line). */
const MAX_CIPHERTEXT = 65536;
/** The server refuses a second snapshot inside 2 s per shop (429). */
const MIN_INTERVAL_MS = 2000;
/** With nothing changed, a heartbeat this often keeps `receivedAt` fresh, so a
 *  viewer can tell "idle" from "the computer is off" (contract: 30–60 s). */
const HEARTBEAT_MS = 45000;
/** How recent a printer's last answer must be for this computer to speak for the shop. */
const FRESH_MS = 3 * 60 * 1000;
/** The longest a 429's retryAfter is honoured (a wrong answer must not silence this for hours). */
const MAX_RETRY_AFTER_MS = 5 * 60 * 1000;

/**
 * Has this computer heard from at least one printer lately? The cloud keeps
 * ONE snapshot per shop, newest wins, and every unlocked computer of the shop
 * may publish. A computer that cannot reach the printers (the owner's laptop
 * at home), or whose polling stopped (a frozen cache), would replace the shop
 * computer's real picture with "not heard" or a stale one. Only a computer
 * that is actually hearing from the printers publishes (security review).
 */
function hasFreshPoll(rows, now) {
  const t = Number.isFinite(now) ? now : Date.now();
  return (Array.isArray(rows) ? rows : []).some((r) => {
    const v = r && r.lastOkAt;
    const ok = typeof v === 'number' && Number.isFinite(v) ? v : epochMs(v);
    return ok != null && ok <= t + 60 * 1000 && t - ok <= FRESH_MS;
  });
}

const ISO_DATE_TIME = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;

/** When a printer last ANSWERED, as ISO 8601, or null. */
function lastOkAtOf(s) {
  const v = s.error ? s.lastOkAt : (s.lastOkAt || s.lastUpdated);
  const t = typeof v === 'number' ? v : Date.parse(v || '');
  return Number.isFinite(t) && t > 0 ? new Date(t).toISOString() : null;
}

/**
 * `GET /api/machines/live`'s rows: one per `store.machines` entry, from the
 * poll cache (`printerStatusCache` in main.js) and the shared rule for what
 * each printer needs (lib/printer-needs.js, the Mac's #2621 shape).
 */
function liveRows(store, cache) {
  const book = store && typeof store === 'object' ? store : {};
  const c = cache && typeof cache === 'object' ? cache : {};
  const machines = Array.isArray(book.machines) ? book.machines : [];
  // What each printer needs from a person: always present, empty when nothing is needed.
  let needs = {};
  try {
    needs = PrinterNeeds.printerNeeds({
      machines, cache: c, polled: PrinterNeeds.polledFrom(c),
      completions: book.printerCompletions || {}, orders: book.printLog || [],
    }) || {};
  } catch (_) { needs = {}; }
  return machines.map((m) => {
    const s = c[m.id] || {};
    const need = needs[m.id] || { problems: [], waiting: [] };
    return {
      id: m.id,
      name: m.name,
      hasPrinterApi: !!(m.printerApi?.type && m.printerApi.type !== 'none'),
      state: s.state || null,
      progress: s.progress != null ? Math.round(+s.progress) : null,
      filename: s.filename || null,
      timeRemaining: s.timeRemaining != null ? Math.round(+s.timeRemaining) : null,
      tempNozzle: s.tempNozzle != null ? Math.round(+s.tempNozzle) : null,
      tempBed: s.tempBed != null ? Math.round(+s.tempBed) : null,
      error: s.error || null,
      lastUpdated: s.lastUpdated || null,
      apiType: s.type || m.printerApi?.type || null,
      problems: need.problems,
      waiting: need.waiting,
      // When it last ANSWERED, and why not, in a word no language changes
      // (the Mac's names, docs/LAN_API.md): lastUpdated moves on a failed
      // poll too; error is a sentence in the shop's language.
      lastOkAt: lastOkAtOf(s),
      errorCode: s.error ? (s.errorCode || 'unreachable') : null,
      httpStatus: s.error && Number.isInteger(s.httpStatus) ? s.httpStatus : null,
    };
  });
}

/** An ISO 8601 date-time as epoch milliseconds, or null. */
function epochMs(iso) {
  if (typeof iso !== 'string' || !ISO_DATE_TIME.test(iso)) return null;
  const t = Date.parse(iso);
  return Number.isFinite(t) ? Math.round(t) : null;
}

/**
 * One row as the cloud contract wants it: `lastUpdated` and `lastOkAt` as
 * epoch MILLISECONDS, never one ISO string beside one number (a phone's whole
 * list once failed to decode on that). The desktop's `lastUpdated` is already
 * a number (`Date.now()` in the poll cache); a number is kept.
 */
function cloudRow(row) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) return row;
  const o = Object.assign({}, row);
  for (const key of ['lastUpdated', 'lastOkAt']) {
    if (typeof o[key] === 'string') o[key] = epochMs(o[key]);
    else if (typeof o[key] === 'number' && !Number.isFinite(o[key])) o[key] = null;
  }
  return o;
}

/** The plaintext: `{ v: 1, at, printers }`. */
function snapshot(rows, at) {
  return { v: 1, at, printers: (rows || []).map(cloudRow) };
}

/** A row with `filename` and `error` dropped: the contract's order for an
 *  envelope over the size line, before any printer is dropped. */
function slim(row) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) return row;
  return Object.assign({}, row, { filename: null, error: null });
}

/**
 * The request body, `{ ciphertext, at }`, where `ciphertext` is the sealed
 * envelope OBJECT (`seal(plain)` → `{ v, z, iv, ct, tag }`, lib/sync-crypto.js
 * encryptStore under the shop's key). Over the size line it is built again
 * without `filename` and `error`; null when even that does not fit.
 */
function body(rows, at, seal) {
  for (const trimmed of [false, true]) {
    const used = trimmed ? rows.map(slim) : rows;
    const ciphertext = seal(snapshot(used, at));
    if (JSON.stringify(ciphertext).length > MAX_CIPHERTEXT) continue;
    return { ciphertext, at };
  }
  return null;
}

/** JSON with sorted keys, so two rows that hold the same compare the same. */
function canonical(v) {
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (v && typeof v === 'object') {
    return '{' + Object.keys(v).filter((k) => v[k] !== undefined).sort()
      .map((k) => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}';
  }
  return JSON.stringify(v === undefined ? null : v);
}

/**
 * What is compared to decide "changed": everything but `lastUpdated` and
 * `lastOkAt`. Both move on every poll (lastOkAt on every ANSWERED poll, which
 * is every poll of a healthy printer); counted as changes they would mean a
 * snapshot every sweep while nothing a person could see had changed. The
 * heartbeat carries them. A printer that stops answering still changes
 * `errorCode` and `error`, so it IS a change.
 */
function signature(rows) {
  return canonical((rows || []).map((row) => {
    if (!row || typeof row !== 'object' || Array.isArray(row)) return row;
    const o = Object.assign({}, row);
    delete o.lastUpdated;
    delete o.lastOkAt;
    return o;
  }));
}

/**
 * Send now? On a change once 2 s have passed since the last accepted
 * snapshot; with no change, every heartbeat; never before `notBefore` (a
 * 429's retryAfter, or the back-off after an error). Times are epoch ms.
 */
function due({ changed, now, lastSent, notBefore }) {
  if (notBefore != null && now < notBefore) return false;
  if (lastSent == null) return true;
  const gap = now - lastSent;
  return changed ? gap >= MIN_INTERVAL_MS : gap >= HEARTBEAT_MS;
}

module.exports = {
  liveRows, cloudRow, snapshot, slim, body, signature, due, epochMs, hasFreshPoll,
  MAX_CIPHERTEXT, MIN_INTERVAL_MS, HEARTBEAT_MS, FRESH_MS, MAX_RETRY_AFTER_MS,
};
