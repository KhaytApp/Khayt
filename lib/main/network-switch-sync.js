'use strict';
/**
 * The desktop's half of Khayt Cloud's network-switch route (khayt-cloud #223;
 * Turki, Nov 22). The rules are lib/network-switch.js; this makes the calls.
 *
 * WHAT THIS COMPUTER KEEPS, never in the book (userData/network-switch-cloud.json),
 * per Khayt Cloud server and shop (reviews of #2645: one shop's stamps or held
 * value must never reach another, nor a server the window pointed at):
 *   share        "Also tell my other computers through Khayt Cloud": THIS
 *                computer's choice, off by default, the owner's to turn on
 *                (Dev Hub, Nov 22: not settings.network.shareViaCloud)
 *   highestSeen  the highest changedAt this computer has seen from the route
 *                or sent there; never lowered (rule 4). The book's own
 *                settings.network.changedAt counts too: a switch the person
 *                set here, sent or not, is never overwritten by an older one
 *   pending      a value the age rule held back: "Apply it here?" (frame G)
 *   conflict     a 409 on the person's own change here (rule 3). While it is
 *                open, nothing from the route is applied: the person chooses
 *                (frame G) — never silently, never by retrying to win
 *   pendingOff   "off" that could not be sent (locked, no network, a timeout):
 *                sent again, with the SAME stamp, at every start and tick, so
 *                the other computers still come back online together (rule 1)
 *   refusals     409s in a row on this computer's own changes; from the
 *                second, frame G says this computer's clock may be behind
 *
 * THE CONFLICT'S TWO ANSWERS (frame G, Turki Nov 22): 'adopt' takes the newer
 * setting. 'keep' ("Keep it on this computer only") is offered only when the
 * person was turning the switch ON here: it turns THIS computer's own switch
 * on (network-local, stricter-only) and the shop takes the newer setting. A
 * computer may be stricter than the shop, never looser, so 'keep' after
 * turning it OFF is refused ('looser'): there is nothing it could keep.
 *
 * WHEN IT CALLS (the gate decides every call, lib/outbound.js):
 *   - GET when Khayt Cloud unlocks (the shop key exists only then; there is
 *     no call before, by design: the key is never stored) and every 15 min,
 *     as 'switch-sync'. Offline that is the ONE call kept, and only when the
 *     switch came through Khayt Cloud (settings.network.via 'cloud').
 *   - publish(): the owner changed the switch HERE (main checks the staff
 *     lock, as for every switch change).
 *       on:  if `share`, PUT {offline:true} BEFORE the window saves it, the
 *            last call while still online; 10 s cap
 *       off: AFTER the window saved it, from the book on disk (never the
 *            window's copy): GET first, and PUT {offline:false} if a value is
 *            published, whatever `share` says here (rule 1)
 *   - A computer offline by its own switch makes no call (lib/outbound.js).
 *
 * Only `network switch: ignored, <why>` is logged, never the value.
 */
const NS = require('../network-switch.js');

const EVERY_MS = 15 * 60 * 1000;
const PUT_CAP_MS = 10000;
/** How far from now a switch the window is about to save may be stamped. */
const FRESH_MS = 2 * 60 * 1000;

function createNetworkSwitchSync(deps) {
  const d = deps || {};
  const now = typeof d.now === 'function' ? d.now : () => Date.now();
  const log = typeof d.log === 'function' ? d.log : (m) => console.warn(m);
  let timer = null;
  let running = null;

  /** The session while Khayt Cloud is unlocked AND it is the book's own cloud: { url, shopId, token, role, dek, scope }, else null. */
  const session = () => {
    let s = null;
    try { s = (typeof d.session === 'function' && d.session()) || null; } catch (_) { s = null; }
    if (!s || !s.dek || typeof s.shopId !== 'string' || !s.shopId || typeof s.scope !== 'string' || !s.scope) return null;
    return s;
  };
  const mayChange = () => { try { return typeof d.mayChange === 'function' ? d.mayChange() === true : false; } catch (_) { return false; } };
  const network = () => {
    let st = null;
    try { st = (typeof d.getSettings === 'function' && d.getSettings()) || null; } catch (_) { st = null; }
    return st && st.network && typeof st.network === 'object' && !Array.isArray(st.network) ? st.network : {};
  };
  /** A stamp that is not ahead of now by more than the contract's 10 min, else null. */
  const sane = (stamp) => (typeof stamp === 'string' && NS.STAMP.test(stamp) && Date.parse(stamp) <= now() + NS.FUTURE_MS ? stamp : null);

  // ── this computer's file, per scope ──
  const readFile = () => {
    let f = {};
    try { f = (typeof d.readMine === 'function' && d.readMine()) || {}; } catch (_) { f = {}; }
    return f && typeof f === 'object' && f.scopes && typeof f.scopes === 'object' ? f : { v: 2, scopes: {} };
  };
  const mineFor = (scope) => {
    const raw = (readFile().scopes || {})[scope] || {};
    return {
      share: raw.share === true,
      highestSeen: sane(raw.highestSeen),
      pending: raw.pending && typeof raw.pending === 'object' ? raw.pending : null,
      conflict: raw.conflict && typeof raw.conflict === 'object' ? raw.conflict : null,
      pendingOff: raw.pendingOff && typeof raw.pendingOff === 'object' ? raw.pendingOff : null,
      refusals: Number.isInteger(raw.refusals) && raw.refusals > 0 ? raw.refusals : 0,
    };
  };
  /** Tell the window a question or a conflict appeared or went (frame G). */
  const changed = () => { try { if (typeof d.changed === 'function') d.changed(); } catch (_) { /* gone */ } };
  const writeMine = (scope, patch) => {
    const f = readFile();
    const was = mineFor(scope);
    const next = Object.assign({}, was, patch);
    if (was.highestSeen && !NS.newer(next.highestSeen, was.highestSeen)) next.highestSeen = was.highestSeen;   // never lowered
    if (!sane(next.highestSeen)) next.highestSeen = was.highestSeen;
    f.v = 2;
    f.scopes = Object.assign({}, f.scopes, { [scope]: next });
    try { if (typeof d.writeMine === 'function') d.writeMine(f); } catch (_) { log('network switch: could not save this computer\'s state'); }
    const asked = (x) => JSON.stringify([!!x.pending, !!x.conflict, (x.refusals || 0) >= 2]);
    if (asked(was) !== asked(next)) changed();
    return next;
  };
  /** The highest stamp this computer must not go below: the route's, and the book's own switch. */
  const mark = (scope) => {
    const a = mineFor(scope).highestSeen;
    const b = sane(network().changedAt);
    if (!a) return b;
    if (!b) return a;
    return NS.newer(b, a) ? b : a;
  };

  /** One GET, judged; applied unless a conflict is open. → { ok, status, act?, why? } */
  async function pull() {
    const s = session();
    if (!s) return { ok: false, why: 'locked' };
    let r;
    try { r = await d.client.getNetworkSwitch(s.url, s.shopId, s.token, { purpose: 'switch-sync' }); }
    catch (e) { return { ok: false, why: e && e.code === 'outbound.blocked' ? 'blocked' : 'network' }; }
    if (r.status === 404) {
      // The shop stopped sharing (or never did): an offline computer that went
      // offline through the cloud stops calling; its value stands.
      if (network().via === 'cloud' && typeof d.updateNetwork === 'function') {
        try {
          await d.updateNetwork((n) => (n.via === 'cloud' ? Object.assign({}, n, { via: null }) : n));
          if (typeof d.notify === 'function') d.notify(network());
        } catch (_) { /* next tick */ }
      }
      return { ok: true, status: 404, act: 'none' };
    }
    if (r.status !== 200 || !r.body || !r.body.ciphertext || typeof r.body.ciphertext !== 'object') return { ok: false, status: r.status, why: 'http' };
    let plain;
    try { plain = d.crypto.decryptStore(r.body.ciphertext, s.dek); }
    catch (_) { log('network switch: ignored, sealed'); return { ok: true, status: 200, act: 'ignore', why: 'sealed' }; }
    const j = NS.judge(plain, { serverChangedAt: r.body.changedAt, shopId: s.shopId, highestSeen: mark(s.scope), now: now() });
    if (j.act === 'ignore') { log(`network switch: ignored, ${j.why}`); return { ok: true, status: 200, act: 'ignore', why: j.why }; }
    const mine = mineFor(s.scope);
    if (mine.conflict) {
      // The person's own change met a newer one: they choose (frame G).
      writeMine(s.scope, { conflict: Object.assign({}, mine.conflict, { remote: j.value }) });
      return { ok: true, status: 200, act: 'held', why: 'conflict' };
    }
    if (j.act === 'ask') { writeMine(s.scope, { pending: Object.assign({ shopId: s.shopId }, j.value) }); return { ok: true, status: 200, act: 'ask' }; }
    const applied = await applyValue(s, j.value);
    return { ok: true, status: 200, act: applied ? 'apply' : 'ignore', why: applied ? 'ok' : 'not-newer' };
  }

  /** Write it, inside the write chain, only if still newer there and the session is still this one. */
  async function applyValue(s, value) {
    if (typeof d.updateNetwork !== 'function') throw new Error('network switch: no book writer');
    let did = false;
    await d.updateNetwork((n) => {
      const cur = session();
      if (!cur || cur.scope !== s.scope) return n;                                   // locked or switched meanwhile
      if (sane(n.changedAt) && !NS.newer(value.changedAt, n.changedAt)) return n;   // a newer switch landed meanwhile
      did = true;
      return NS.applied(n, value);
    });
    if (!did) return false;
    writeMine(s.scope, { highestSeen: value.changedAt, pending: null });
    if (typeof d.notify === 'function') { try { d.notify(network()); } catch (_) { /* a window gone */ } }
    return true;
  }

  /** The age rule's answer: apply the held value here, or not. */
  async function answerPending(apply) {
    if (!mayChange()) return { ok: false, why: 'not_permitted' };
    const s = session();
    if (!s) return { ok: false, why: 'locked' };
    const p = mineFor(s.scope).pending;
    if (!p || p.shopId !== s.shopId) { writeMine(s.scope, { pending: null }); return { ok: false, why: 'none' }; }
    if (!apply) { writeMine(s.scope, { pending: null, highestSeen: p.changedAt }); return { ok: true, applied: false }; }
    writeMine(s.scope, { pending: null });
    const value = { offline: p.offline === true, keep: p.keep, changedAt: p.changedAt, changedBy: p.changedBy };
    if (!NS.newer(value.changedAt, mark(s.scope))) return { ok: false, why: 'not-newer' };
    return { ok: true, applied: await applyValue(s, value) };
  }

  /**
   * The person's answer to a conflict (frame G): 'adopt' the newer setting
   * (applied at once if it is held, else at the next check), or 'keep' this
   * computer's (the newer one is marked seen and not applied here).
   */
  async function answerConflict(choice) {
    if (!mayChange()) return { ok: false, why: 'not_permitted' };
    const s = session();
    if (!s) return { ok: false, why: 'locked' };
    const c = mineFor(s.scope).conflict;
    if (!c) return { ok: false, why: 'none' };
    let kept = false;
    if (choice === 'keep') {
      // Stricter-only: only a person who was turning the switch ON can keep
      // it on, and only on this computer. The conflict stays open otherwise.
      if (c.offline !== true) return { ok: false, why: 'looser' };
      if (typeof d.setLocalOffline !== 'function') return { ok: false, why: 'unavailable' };
      try { d.setLocalOffline(); } catch (_) { return { ok: false, why: 'local' }; }
      kept = true;
    }
    writeMine(s.scope, { conflict: null });
    // The shop takes the newer setting, whichever answer.
    if (c.remote) {
      // Newer than what the person set here, and they chose it: past the mark.
      const ok = await applyValueOver(s, c.remote);
      return { ok: true, kept, applied: ok };
    }
    // Nothing held yet: the newer value is fetched now, or at the next check
    // (the conflict is gone, so the timer applies it). Answered either way.
    const pr = await pull();
    return { ok: true, kept, applied: pr.act === 'apply', later: pr.act !== 'apply' };
  }
  /** Apply a value the person chose over their own newer-stamped change (409 adopt). */
  async function applyValueOver(s, value) {
    let did = false;
    await d.updateNetwork((n) => {
      const cur = session();
      if (!cur || cur.scope !== s.scope) return n;
      did = true;
      return NS.applied(n, value);
    });
    if (did) {
      writeMine(s.scope, { highestSeen: value.changedAt, pending: null });
      if (typeof d.notify === 'function') { try { d.notify(network()); } catch (_) { /* gone */ } }
    }
    return did;
  }

  async function put(s, net) {
    const plain = NS.plainFor({ shopId: s.shopId, network: net });
    if (!plain) return { ok: false, why: 'stamp' };
    const ciphertext = d.crypto.encryptStore(plain, s.dek);
    let timeout;
    const capped = new Promise((resolve) => { timeout = setTimeout(() => resolve({ status: 0, body: null, timedOut: true }), PUT_CAP_MS); });
    let r;
    try {
      r = await Promise.race([d.client.putNetworkSwitch(s.url, s.shopId, s.token, { ciphertext, changedAt: plain.changedAt }), capped]);
    } catch (e) {
      return { ok: false, why: e && e.code === 'outbound.blocked' ? 'blocked' : 'network' };
    } finally { clearTimeout(timeout); }
    if (r.timedOut) return { ok: false, why: 'timeout' };
    if (r.status === 200) { writeMine(s.scope, { highestSeen: plain.changedAt, refusals: 0 }); return { ok: true, changedAt: plain.changedAt }; }
    if (r.status === 409) {
      const at = r.body && typeof r.body.changedAt === 'string' ? r.body.changedAt : null;
      const conflict = { at, mine: plain.changedAt, offline: plain.offline, remote: null };
      writeMine(s.scope, { conflict, refusals: mineFor(s.scope).refusals + 1 });
      return { ok: false, why: 'stale', conflict: { at, mine: plain.changedAt, offline: plain.offline } };
    }
    return { ok: false, why: (r.body && typeof r.body.reason === 'string' ? r.body.reason : 'http'), status: r.status };
  }

  /** Send "off" from the book on disk; kept for later when it cannot go now. */
  async function sendOff(s, net) {
    let published = mineFor(s.scope).share;
    if (!published) {
      let g;
      try { g = await d.client.getNetworkSwitch(s.url, s.shopId, s.token, { purpose: 'cloud' }); }
      catch (e) { writeMine(s.scope, { pendingOff: { changedAt: net.changedAt } }); return { ok: false, why: e && e.code === 'outbound.blocked' ? 'blocked' : 'network', later: true }; }
      if (g && g.status === 404) { writeMine(s.scope, { pendingOff: null, highestSeen: net.changedAt }); return { ok: true, sent: false }; }
      if (!g || g.status !== 200) { writeMine(s.scope, { pendingOff: { changedAt: net.changedAt } }); return { ok: false, why: 'http', later: true }; }
      published = true;
    }
    const r = await put(s, Object.assign({}, net, { offline: false }));
    if (r.ok || r.why === 'stale') writeMine(s.scope, { pendingOff: null });
    else if (['network', 'timeout', 'blocked', 'http'].includes(r.why) || r.status >= 500) { writeMine(s.scope, { pendingOff: { changedAt: net.changedAt } }); r.later = true; }
    return Object.assign({ sent: r.ok }, r);
  }

  /**
   * The owner changed the switch here.
   *   on:  `network` is what the window is ABOUT to save (stamped now)
   *   off: the book on disk is read; the window's copy is not trusted
   */
  async function publish({ offline, network: net } = {}) {
    if (!mayChange()) return { ok: false, why: 'not_permitted' };
    const s = session();
    if (offline === true) {
      if (!s) return { ok: false, why: 'locked' };
      const n = net && typeof net === 'object' && !Array.isArray(net) ? net : null;
      const at = n && sane(n.changedAt);
      if (!n || !at || Math.abs(Date.parse(at) - now()) > FRESH_MS) return { ok: false, why: 'stamp' };
      if (s.role !== 'owner') return { ok: false, why: 'role' };
      if (!mineFor(s.scope).share) return { ok: true, sent: false };
      const r = await put(s, Object.assign({}, n, { offline: true }));
      return Object.assign({ sent: r.ok }, r, { via: r.ok ? 'cloud' : null });
    }
    const book = network();
    if (book.offline === true || !sane(book.changedAt)) return { ok: false, why: 'not-saved' };   // the off was refused or not saved
    if (!s) return { ok: false, why: 'locked', later: true, note: 'sent at the next unlock' };
    if (s.role !== 'owner') return { ok: false, why: 'role' };
    return sendOff(s, book);
  }

  /** "Also tell my other computers through Khayt Cloud": this computer's, for this shop's cloud. */
  function setShare(on) {
    if (!mayChange()) return { ok: false, why: 'not_permitted' };
    const s = session();
    if (!s) return { ok: false, why: 'locked' };
    if (on === true && s.role !== 'owner') return { ok: false, why: 'role' };
    writeMine(s.scope, { share: on === true });
    return { ok: true, share: on === true };
  }

  /** A switched-off book whose "off" never reached the cloud, at start or a tick. */
  async function retryOff(s) {
    const book = network();
    const mine = mineFor(s.scope);
    // Owed when it could not go (pendingOff), or when the switch was turned off
    // here while Khayt Cloud was locked and the shop shares it (this
    // computer's option, or a switch that came through the cloud).
    const shares = mine.share || book.via === 'cloud';
    const owed = mine.pendingOff || (book.offline !== true && sane(book.changedAt) && NS.newer(book.changedAt, mine.highestSeen) && shares ? { changedAt: book.changedAt } : null);
    if (!owed || book.offline === true || s.role !== 'owner') return null;
    if (book.changedAt !== owed.changedAt) { writeMine(s.scope, { pendingOff: null }); return null; }   // changed since: that change speaks
    return sendOff(s, book);
  }

  async function tick() {
    if (running) return running;
    running = (async () => {
      try {
        const s = session();
        if (s) { try { await retryOff(s); } catch (_) { /* next tick */ } }
        return await pull();
      } finally { running = null; }
    })();
    return running;
  }
  function start() {
    stop();
    tick().catch(() => {});
    timer = setInterval(() => { tick().catch(() => {}); }, EVERY_MS);
    if (timer && typeof timer.unref === 'function') timer.unref();
  }
  function stop() { if (timer) clearInterval(timer); timer = null; }

  function state() {
    const s = session();
    const m = s ? mineFor(s.scope) : { share: false, highestSeen: null, pending: null, conflict: null, pendingOff: null, refusals: 0 };
    return {
      unlocked: !!s, share: m.share, highestSeen: m.highestSeen,
      pending: m.pending ? { offline: m.pending.offline === true, changedAt: m.pending.changedAt, changedBy: m.pending.changedBy || '' } : null,
      conflict: m.conflict ? { at: m.conflict.at, mine: m.conflict.mine, offline: m.conflict.offline, held: !!m.conflict.remote } : null,
      pendingOff: !!m.pendingOff, running: !!timer,
      // From the second 409 in a row (frame G): this computer's clock may be behind.
      clockBehind: m.refusals >= 2,
      // Who may turn "Also tell my other computers" on: the cloud owner (a hint; the server decides).
      owner: !!s && s.role === 'owner',
    };
  }

  return { start, stop, tick, pull, publish, setShare, answerPending, answerConflict, state, EVERY_MS, PUT_CAP_MS };
}

/** The scope a session's state is kept under: the server's origin and the shop. */
function scopeOf(url, shopId) {
  let origin = '';
  try { origin = new URL(String(url)).origin.toLowerCase(); } catch (_) { origin = ''; }
  return origin && shopId ? `${origin}|${shopId}` : '';
}

module.exports = { createNetworkSwitchSync, scopeOf, EVERY_MS, PUT_CAP_MS, FRESH_MS };
