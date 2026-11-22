'use strict';
/**
 * The desktop's half of Khayt Cloud's network-switch route (khayt-cloud #223;
 * Turki, Nov 22). The rules are lib/network-switch.js; this makes the calls.
 *
 * WHAT THIS COMPUTER KEEPS, never in the book (userData/network-switch-cloud.json):
 *   share        "Also tell my other computers through Khayt Cloud": THIS
 *                computer's choice, off by default, the owner's to turn on
 *                (Dev Hub, Nov 22: per computer like the stricter-only switch,
 *                not settings.network.shareViaCloud; the option does not travel)
 *   highestSeen  the highest changedAt this computer has seen, applied or set
 *                itself; never lowered (rule 4)
 *   pending      a value the age rule held back: "Apply it here?" (UI later)
 *   lastConflict the last 409 on this computer's own change (UI later)
 *
 * WHEN IT CALLS (the gate decides every call, lib/outbound.js):
 *   - GET at start (when Khayt Cloud unlocks: the key exists only then) and
 *     every 15 minutes, as 'switch-sync'. Online that is an ordinary call;
 *     offline it is the ONE call kept, and only when the switch came through
 *     Khayt Cloud (settings.network.via 'cloud') and the row is ticked.
 *   - publish(): the owner changed the switch HERE.
 *       on:  if `share`, PUT {offline:true} as the last call, 10 s cap. The
 *            window calls this BEFORE it saves offline, while still online.
 *       off: GET first; if a value is published (the shop opted in at SOME
 *            computer; the option does not travel), PUT {offline:false}
 *            whatever `share` says here (contract rule 1). Called AFTER the
 *            window saved online.
 *     A 409 is never retried with a fresh stamp and never silently undone:
 *     it is returned (and kept as lastConflict) for the window to say "the
 *     switch was changed at another computer at <time>" (rule 3).
 *   - A computer offline by its own switch makes no call (lib/outbound.js).
 *
 * WHAT IT APPLIES: only a value that opens with the shop key and passes
 * lib/network-switch.js judge(). It writes settings.network through the store's
 * write chain and tells the windows (`hub:network-applied`). Nothing is
 * logged but the reason: `network switch: ignored, <why>`.
 */
const NS = require('../network-switch.js');

const EVERY_MS = 15 * 60 * 1000;
const PUT_CAP_MS = 10000;

function createNetworkSwitchSync(deps) {
  const d = deps || {};
  const now = typeof d.now === 'function' ? d.now : () => Date.now();
  const log = typeof d.log === 'function' ? d.log : (m) => console.warn(m);
  let timer = null;
  let running = null;

  const readMine = () => {
    let m = {};
    try { m = (typeof d.readMine === 'function' && d.readMine()) || {}; } catch (_) { m = {}; }
    return {
      share: m.share === true,
      highestSeen: typeof m.highestSeen === 'string' && NS.STAMP.test(m.highestSeen) ? m.highestSeen : null,
      pending: m.pending && typeof m.pending === 'object' ? m.pending : null,
      lastConflict: m.lastConflict && typeof m.lastConflict === 'object' ? m.lastConflict : null,
    };
  };
  const writeMine = (patch) => {
    const next = Object.assign(readMine(), patch);
    // Never lowered (rule 4).
    const was = readMine().highestSeen;
    if (was && !NS.newer(next.highestSeen, was)) next.highestSeen = was;
    try { if (typeof d.writeMine === 'function') d.writeMine(next); } catch (e) { log('network switch: could not save this computer\'s state'); }
    return next;
  };
  const seen = (stamp) => { if (NS.newer(stamp, readMine().highestSeen)) writeMine({ highestSeen: stamp }); };

  /** The session while Khayt Cloud is unlocked: { url, shopId, token, role, dek }, else null. */
  const session = () => { try { return (typeof d.session === 'function' && d.session()) || null; } catch (_) { return null; } };
  const network = () => {
    const s = (typeof d.getSettings === 'function' && d.getSettings()) || null;
    return s && s.network && typeof s.network === 'object' && !Array.isArray(s.network) ? s.network : {};
  };

  /** One GET, judged and applied. → { ok, status, act?, why? } */
  async function pull(opts) {
    const s = session();
    if (!s || !s.dek) return { ok: false, why: 'locked' };
    let r;
    try { r = await d.client.getNetworkSwitch(s.url, s.shopId, s.token, { purpose: (opts && opts.purpose) || 'switch-sync' }); }
    catch (e) { return { ok: false, why: e && e.code === 'outbound.blocked' ? 'blocked' : 'network', error: String((e && e.message) || e) }; }
    if (r.status === 404) {
      // The shop stopped sharing (or never did). An offline computer that went
      // offline through the cloud stops calling: its value stands, untied.
      if (network().via === 'cloud' && typeof d.updateNetwork === 'function') {
        try { await d.updateNetwork((n) => (n.via === 'cloud' ? Object.assign({}, n, { via: null }) : n)); } catch (_) { /* next tick */ }
      }
      return { ok: true, status: 404, act: 'none' };
    }
    if (r.status !== 200 || !r.body || typeof r.body.ciphertext !== 'object') return { ok: false, status: r.status, why: 'http' };
    let plain;
    try { plain = d.crypto.decryptStore(r.body.ciphertext, s.dek); }
    catch (_) { log('network switch: ignored, sealed'); return { ok: true, status: 200, act: 'ignore', why: 'sealed' }; }
    const mine = readMine();
    const j = NS.judge(plain, { serverChangedAt: r.body.changedAt, shopId: s.shopId, highestSeen: mine.highestSeen, now: now() });
    if (j.act === 'ignore') { log(`network switch: ignored, ${j.why}`); return { ok: true, status: 200, act: 'ignore', why: j.why }; }
    if (j.act === 'ask') { writeMine({ pending: j.value }); return { ok: true, status: 200, act: 'ask', value: j.value }; }
    await applyValue(j.value);
    return { ok: true, status: 200, act: 'apply', value: j.value };
  }

  async function applyValue(value) {
    if (typeof d.updateNetwork !== 'function') throw new Error('network switch: no book writer');
    await d.updateNetwork((n) => NS.applied(n, value));
    writeMine({ highestSeen: value.changedAt, pending: null });
    if (typeof d.notify === 'function') { try { d.notify(network()); } catch (_) { /* a window gone */ } }
  }

  /** The age rule's answer from the window: apply the held value here, or not. */
  async function answerPending(apply) {
    const p = readMine().pending;
    if (!p) return { ok: false, why: 'none' };
    if (!apply) { writeMine({ pending: null, highestSeen: p.changedAt }); return { ok: true, applied: false }; }
    if (!NS.newer(p.changedAt, readMine().highestSeen)) { writeMine({ pending: null }); return { ok: false, why: 'not-newer' }; }
    await applyValue(p);
    return { ok: true, applied: true };
  }

  async function put(s, net, changedBy) {
    const plain = NS.plainFor({ shopId: s.shopId, network: net, changedBy });
    if (!plain) return { ok: false, why: 'stamp' };
    const ciphertext = d.crypto.encryptStore(plain, s.dek);
    let timeout;
    const capped = new Promise((resolve) => { timeout = setTimeout(() => resolve({ status: 0, body: null, timedOut: true }), PUT_CAP_MS); });
    let r;
    try {
      r = await Promise.race([d.client.putNetworkSwitch(s.url, s.shopId, s.token, { ciphertext, changedAt: plain.changedAt }), capped]);
    } catch (e) {
      return { ok: false, why: e && e.code === 'outbound.blocked' ? 'blocked' : 'network', error: String((e && e.message) || e) };
    } finally { clearTimeout(timeout); }
    if (r.timedOut) return { ok: false, why: 'timeout' };
    if (r.status === 200) { seen(plain.changedAt); return { ok: true, changedAt: plain.changedAt }; }
    if (r.status === 409) {
      const at = r.body && r.body.changedAt;
      const conflict = { at: typeof at === 'string' ? at : null, mine: plain.changedAt, offline: plain.offline };
      writeMine({ lastConflict: conflict });
      return { ok: false, why: 'stale', conflict };
    }
    return { ok: false, why: (r.body && r.body.reason) || 'http', status: r.status };
  }

  /**
   * The owner changed the switch here. `network` is what the window is about
   * to save (on) or just saved (off), with its changedAt. → the outcome.
   */
  async function publish({ offline, network: net, changedBy } = {}) {
    const s = session();
    if (!s || !s.dek) return { ok: false, why: 'locked' };
    if (s.role !== 'owner') return { ok: false, why: 'role' };
    const n = net && typeof net === 'object' ? net : network();
    if (offline === true) {
      if (!readMine().share) return { ok: true, sent: false };
      const r = await put(s, Object.assign({}, n, { offline: true }), changedBy);
      return Object.assign({ sent: r.ok }, r, { via: r.ok ? 'cloud' : null });
    }
    // Off: tell the cloud if a value is published, whatever this computer's option.
    let published = readMine().share;
    if (!published) {
      try {
        const g = await d.client.getNetworkSwitch(s.url, s.shopId, s.token, { purpose: 'cloud' });
        published = g && g.status === 200;
      } catch (e) { return { ok: false, why: e && e.code === 'outbound.blocked' ? 'blocked' : 'network' }; }
    }
    if (!published) return { ok: true, sent: false };
    const r = await put(s, Object.assign({}, n, { offline: false }), changedBy);
    return Object.assign({ sent: r.ok }, r);
  }

  /** "Also tell my other computers through Khayt Cloud": this computer's, the owner's to turn on. */
  function setShare(on) {
    const s = session();
    if (on === true && !(s && s.role === 'owner')) return { ok: false, why: 'role' };
    writeMine({ share: on === true });
    return { ok: true, share: on === true };
  }

  async function tick() {
    if (running) return running;
    running = (async () => { try { return await pull(); } finally { running = null; } })();
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
    const m = readMine();
    return { share: m.share, highestSeen: m.highestSeen, pending: m.pending, lastConflict: m.lastConflict, running: !!timer };
  }

  return { start, stop, tick, pull, publish, setShare, answerPending, state, EVERY_MS, PUT_CAP_MS };
}

module.exports = { createNetworkSwitchSync, EVERY_MS, PUT_CAP_MS };
