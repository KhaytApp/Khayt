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

  /* The switch going on (the shop's or this computer's) is told to the host
   * once per change (d.onOffline), which purges what was saved up before it:
   * nothing kept from before may leave after it is turned off (D5). */
  let anyWasOffline = null;
  function noteAny(off) {
    if (off && anyWasOffline !== true && typeof d.onOffline === 'function') { try { d.onOffline(); } catch (_) { /* never break a check */ } }
    anyWasOffline = off;
  }

  /* ── THE LAST SYNC (design §1.4, the sync trap) ─────────────────────────
   * The switch lives in the book, and the book syncs over Khayt Cloud, which
   * the switch blocks. So the computer that turns it on would never tell the
   * others. When THIS computer's window saves the shop's switch from online
   * to offline (observe({ fromSave: true })), one sync may still finish within
   * GRACE_MS: the push, and when it meets a conflict (409) the pull and the
   * push again that the window's sync makes next (reviews of #2628: a 409
   * spent the window and the switch never reached the others). It closes when
   * a push lands without a conflict, or when the time is up.
   *
   * ONLY THE SYNC ITSELF passes: the allowance travels with the sync's own
   * call chain (AsyncLocalStorage), never as a flag every other cloud call
   * could see, so a vault upload or the lead-time publisher started meanwhile
   * is refused as usual. One sync chain at a time. A change that arrives from
   * elsewhere (a pull, the LAN) opens nothing, and this computer's own switch
   * is not the shop's: no window for it.
   */
  const GRACE_MS = 30000;
  let shopWasOffline = null;
  let graceUntil = 0;
  let chainBusy = false;
  const { AsyncLocalStorage } = require('async_hooks');
  const syncChain = new AsyncLocalStorage();
  function observe(opts) {
    const s = settings();
    if (!s || typeof s !== 'object') return;
    const off = Outbound.isOffline(s, {});
    if (shopWasOffline === false && off && opts && opts.fromSave === true) graceUntil = now() + GRACE_MS;
    if (!off) graceUntil = 0;
    shopWasOffline = off;
    noteAny(Outbound.isOffline(s, { local: local() }));
  }
  const windowOpen = () => graceUntil > 0 && now() < graceUntil;
  /** Run one step of the sync (push or pull) inside the window, if it is open. */
  async function lastSync(fn, { push } = {}) {
    if (!windowOpen() || chainBusy) return fn();
    chainBusy = true;
    try {
      const out = await syncChain.run({ lastSync: true }, fn);
      // Landed without a conflict: the others have the switch. Close.
      if (push && !(out && out.conflict)) graceUntil = 0;
      return out;
    } finally { chainBusy = false; }
  }
  const lastPush = (fn) => lastSync(fn, { push: true });
  const lastPull = (fn) => lastSync(fn, { push: false });

  function check(purpose, extra) {
    observe();   // never opens the window: only this computer's save does
    const ctx = { local: local() };
    if (extra && typeof extra === 'object' && extra.host !== undefined) ctx.host = extra.host;
    let r = Outbound.allowed(settings(), purpose, ctx);
    if (!r.allowed && r.reason === 'offline' && purpose === 'cloud' && windowOpen()) {
      const ctx2 = syncChain.getStore();
      if (ctx2 && ctx2.lastSync) r = { allowed: true, reason: 'kept', purpose, lastSync: true };
    }
    // A book on disk that cannot be read (corrupt, the keychain refused) is
    // not a switch anyone can know, and Khayt Cloud is how such a shop
    // restores: cloud is not held back for it (review of #2628).
    if (!r.allowed && r.reason === 'settings-unknown' && purpose === 'cloud'
        && typeof d.bookUnreadable === 'function' && d.bookUnreadable() === true) {
      r = { allowed: true, reason: 'ok', purpose };
    }
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
    if (next.offline) noteAny(true);
    return next;
  }

  function describe() {
    const b = blocked();
    return Outbound.describe(settings(), { local: local() }).map((row) => Object.assign(row, {
      blockedCount: b[row.purpose] ? b[row.purpose].count : 0,
      lastBlockedAt: b[row.purpose] ? b[row.purpose].lastBlockedAt : null,
    }));
  }

  return { check, gate, for: forPurpose, blocked, local, setLocal, describe, lastPush, lastPull, observe };
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
  // The same reading as lib/outbound.js: present and anything but false is
  // offline (security review of #2627: "true" or 1 started Sentry here while
  // the runtime gate already said offline).
  const on = (v) => v !== undefined && v !== null && v !== false;
  try {
    const raw = fs.readFileSync(localFile, 'utf8');
    if (on(JSON.parse(raw).offline)) return true;
  } catch (_) { /* no file: this computer has not said */ }
  try {
    const st = fs.statSync(storeFile);
    if (!st.isFile() || st.size > 50 * 1024 * 1024) return true;
    const raw = fs.readFileSync(storeFile, 'utf8');
    // Most shops have never touched it: one search, no parse, for them.
    if (raw.indexOf('"network"') === -1) return false;
    const store = JSON.parse(raw);
    const net = store && store.settings && store.settings.network;
    return !!(net && typeof net === 'object' && on(net.offline));
  } catch (_) {
    return true;
  }
}

module.exports = { createOutboundGate, OutboundBlocked, isBlocked, offlineAtStartup };
