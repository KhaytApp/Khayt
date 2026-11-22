'use strict';
/**
 * The main process's side of the "make no internet calls" switch (P8 PR 2;
 * ~/Khayt-proposals/outbound-switch-design.md §4.1, decided Nov 22).
 *
 * lib/outbound.js decides. This holds what it decides FROM on the desktop:
 * the book's settings (main's in-memory copy, as telemetryConsent reads
 * them), this computer's own stricter switch (userData/network-local.json)
 * and the install count's per-computer switch (active-count.json, D3). And it
 * remembers each refusal, so the Settings list can say "blocked N times, last
 * at …" without a toast per timer tick (§4.5).
 *
 *   const out = createOutboundGate({ getSettings, readLocal, writeLocal, readInstallCountOff, now })
 *   out.check(purpose, { host })   → the decision; a refusal is counted
 *   out.gate(purpose, { host })    → the same, but THROWS OutboundBlocked when refused
 *   out.for(purpose)               → a fetch that gates first (for injection)
 *   out.blocked()                  → { purpose: { count, lastBlockedAt, reason } }
 *   out.local() / out.setLocal({ offline })   this computer's switch
 *   out.describe()                 → lib/outbound.js describe() + the counts
 *
 * A refusal is an OutboundBlocked error with `code: 'outbound.blocked'`, so a
 * caller's retry and backoff can tell it from a network failure: a timer that
 * meets one does not back off, and notices the switch going off at its next
 * tick. Nothing is queued for later (D5).
 */
const Outbound = require('../outbound.js');

class OutboundBlocked extends Error {
  constructor(purpose, reason) {
    super(`outbound blocked: ${purpose} (${reason})`);
    this.name = 'OutboundBlocked';
    this.code = 'outbound.blocked';
    this.purpose = purpose;
    this.reason = reason;
  }
}

const isBlocked = (e) => !!(e && e.code === 'outbound.blocked');
const COUNTED = ['offline', 'offline-here', 'lan-host-public', 'lan-host-missing'];

function createOutboundGate(deps) {
  const d = deps || {};
  const now = typeof d.now === 'function' ? d.now : () => Date.now();
  const counts = Object.create(null);
  // Not a book field, so not in the window's save: read from disk each time it
  // is asked (a few times an hour), so a second window or a restart agrees.
  const local = () => {
    let l = {};
    try { l = (typeof d.readLocal === 'function' && d.readLocal()) || {}; } catch (_) { l = {}; }
    let installCountOff = false;
    try { installCountOff = typeof d.readInstallCountOff === 'function' && d.readInstallCountOff() === true; } catch (_) { installCountOff = false; }
    // The lib reads anything present but false as offline; pass it through.
    return { offline: l.offline, installCountOff };
  };
  const settings = () => { try { return typeof d.getSettings === 'function' ? d.getSettings() : null; } catch (_) { return null; } };

  function check(purpose, extra) {
    const ctx = { local: local() };
    if (extra && typeof extra === 'object' && extra.host !== undefined) ctx.host = extra.host;
    const r = Outbound.allowed(settings(), purpose, ctx);
    // Counted only when the SWITCH refused it: a purpose its own opt-in keeps
    // off (most shops never opt in to crash reports) is not a block, and
    // telemetryConsent asks many times an hour.
    if (!r.allowed && COUNTED.indexOf(r.reason) !== -1) {
      const k = r.purpose;
      const c = counts[k] || { count: 0, lastBlockedAt: null, reason: null };
      c.count += 1; c.lastBlockedAt = new Date(now()).toISOString(); c.reason = r.reason;
      counts[k] = c;
    }
    return r;
  }

  function gate(purpose, extra) {
    const r = check(purpose, extra);
    if (!r.allowed) throw new OutboundBlocked(r.purpose, r.reason);
    return r;
  }

  /** A fetch for one purpose: it gates before every call. `impl` is the real fetch. */
  function forPurpose(purpose, impl) {
    // outbound-exempt: gate — the wrapper itself: every call through it gates first, below
    const f = typeof impl === 'function' ? impl : (...a) => fetch(...a);
    return async (...args) => { gate(purpose); return f(...args); };
  }

  function blocked() {
    const out = {};
    for (const k of Object.keys(counts)) out[k] = Object.assign({}, counts[k]);
    return out;
  }

  function setLocal(patch) {
    const next = { offline: !!(patch && patch.offline === true) };
    if (typeof d.writeLocal === 'function') d.writeLocal(next);
    return next;
  }

  function describe() {
    const b = blocked();
    return Outbound.describe(settings(), { local: local() }).map((row) => Object.assign(row, {
      blockedCount: b[row.purpose] ? b[row.purpose].count : 0,
      lastBlockedAt: b[row.purpose] ? b[row.purpose].lastBlockedAt : null,
    }));
  }

  return { check, gate, for: forPurpose, blocked, local, setLocal, describe };
}

/**
 * The shop's switch, read from the store on disk before the app is ready, for
 * the one decision taken before the book is in memory: whether Sentry may
 * start (lib/main/sentry-consent.js has the consent half). True also when this
 * computer's own file says offline. Fails toward OFFLINE: a store that cannot
 * be read is not a reason to start a reporter (it would not start anyway
 * without consent).
 */
function offlineAtStartup(fs, storeFile, localFile) {
  try {
    const raw = fs.readFileSync(localFile, 'utf8');
    if (raw.indexOf('true') !== -1 && JSON.parse(raw).offline === true) return true;
  } catch (_) { /* no file: this computer has not said */ }
  try {
    const st = fs.statSync(storeFile);
    if (!st.isFile() || st.size > 50 * 1024 * 1024) return true;
    const raw = fs.readFileSync(storeFile, 'utf8');
    // Most shops never turn it on: one search, no parse, for them.
    if (raw.indexOf('"offline":true') === -1 && raw.indexOf('"offline": true') === -1) return false;
    const store = JSON.parse(raw);
    const net = store && store.settings && store.settings.network;
    return !!(net && net.offline === true);
  } catch (_) {
    return true;
  }
}

module.exports = { createOutboundGate, OutboundBlocked, isBlocked, offlineAtStartup };
