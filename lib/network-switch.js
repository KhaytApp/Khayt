'use strict';
/**
 * The shop's "make no internet calls" switch, carried between its computers
 * through Khayt Cloud (Turki, Nov 22; khayt-cloud #223,
 * `/v1/shops/{id}/network-switch`, docs/api-contract.md there).
 *
 * The book's settings never come down in a sync (lib/cloud-inbox.js), so
 * without this a switch turned on at one computer reached no other. The
 * value is SEALED with the shop key; the server only orders and relays it.
 * This module is the rules, pure: what is sealed, which received value a
 * computer may apply, and what the switch becomes. The calls are
 * lib/main/network-switch-sync.js.
 *
 *   plainFor({ shopId, network, changedBy })  → the plaintext to seal
 *   judge(plain, { serverChangedAt, shopId, highestSeen, now })
 *     → { act: 'apply' | 'ask' | 'ignore', why, value }
 *        apply  every check passed: write it to the book
 *        ask    a computer with no stamp of its own yet (highestSeen null)
 *               and an offline:true more than 7 days old: "Your shop turned
 *               off internet use on <date>. Apply it here?" (the age rule)
 *        ignore one check failed; `why` names it, never the content
 *   applied(network, value)  → the book's next settings.network
 *   newer(a, b)              → is stamp a strictly after stamp b
 *   keepNewerNetwork(incoming, disk) → a window save never puts an OLDER
 *               switch back over one main applied (settings never come down,
 *               so the window's copy can be behind)
 *
 * The five checks (contract, "A computer applies a value only if"):
 *   1. it opened with the shop key: the caller decrypts, and hands only what
 *      opened (decryption failure is the caller's 'ignore', 'sealed')
 *   2. kind 'khayt-network-switch', v 1, shopId this shop
 *   3. the sealed changedAt equals the changedAt the server returned
 *   4. the sealed changedAt is newer than the highest this computer has seen
 *      (applied or set itself; kept on this computer, never lowered)
 *   5. offline is a boolean, keep a list (unknown purposes, 'lan' and
 *      'switch-sync' dropped), changedBy text of at most 80 characters
 *
 * Pure and JavaScriptCore-safe: no Node API. It reads lib/outbound.js
 * PURPOSES (the KhaytOutbound global under JSC).
 */
(function (root) {

const KIND = 'khayt-network-switch';
const VERSION = 1;
const AGE_ASK_MS = 7 * 24 * 60 * 60 * 1000;
/** The server refuses a changedAt more than 10 min ahead of its clock; so does
 *  a computer (security review of #2645: a far-future stamp from a server
 *  working with a key holder froze the switch for good). */
const FUTURE_MS = 10 * 60 * 1000;
const MAX_BY = 80;
/** The contract's strict UTC stamp: YYYY-MM-DDTHH:MM:SS[.f{1,3}]Z. */
const STAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;

const isPlain = (o) => !!o && typeof o === 'object' && !Array.isArray(o);
const ms = (s) => (typeof s === 'string' && STAMP.test(s) ? Date.parse(s) : NaN);

function outbound() {
  if (root && root.KhaytOutbound) return root.KhaytOutbound;
  if (typeof require === 'function') { try { return require('./outbound.js'); } catch (_) { /* below */ } }
  return null;
}

/** The purposes a value may keep: known ones, never 'lan' or 'switch-sync', each once. */
function cleanKeep(keep) {
  const O = outbound();
  // Without lib/outbound.js nothing can be judged a purpose: say so rather
  // than silently dropping every kept purpose (review NIT).
  if (!O) throw new Error('network-switch: lib/outbound.js (KhaytOutbound) must be loaded first');
  const known = O.PURPOSES;
  const out = [];
  for (const k of Array.isArray(keep) ? keep : []) {
    if (typeof k !== 'string' || k === 'lan' || k === 'switch-sync' || known.indexOf(k) === -1 || out.indexOf(k) !== -1) continue;
    out.push(k);
  }
  return out;
}

/** Is stamp a strictly after stamp b? A stamp that is not the strict form is never newer; anything beats null. */
function newer(a, b) {
  const x = ms(a);
  if (!Number.isFinite(x)) return false;
  if (b === null || b === undefined) return true;
  const y = ms(b);
  return !Number.isFinite(y) || x > y;
}

/** The plaintext this computer seals for the route, from the book's settings.network. */
function plainFor({ shopId, network, changedBy } = {}) {
  const n = isPlain(network) ? network : {};
  if (typeof shopId !== 'string' || !shopId) return null;
  const changedAt = n.changedAt;
  if (!Number.isFinite(ms(changedAt))) return null;
  const by = typeof changedBy === 'string' ? changedBy : (typeof n.changedBy === 'string' ? n.changedBy : '');
  return {
    kind: KIND, v: VERSION, shopId,
    offline: n.offline === true,
    keep: cleanKeep(n.keep),
    changedAt,
    changedBy: by.slice(0, MAX_BY),
  };
}

function judge(plain, { serverChangedAt, shopId, highestSeen, now } = {}) {
  const no = (why) => ({ act: 'ignore', why, value: null });
  if (!isPlain(plain)) return no('shape');
  if (plain.kind !== KIND || plain.v !== VERSION) return no('kind');
  if (typeof shopId !== 'string' || !shopId || plain.shopId !== shopId) return no('shop');
  if (typeof plain.changedAt !== 'string' || !Number.isFinite(ms(plain.changedAt))) return no('stamp');
  if (plain.changedAt !== serverChangedAt) return no('stamp-mismatch');
  const t0 = typeof now === 'number' && Number.isFinite(now) ? now : Date.now();
  if (ms(plain.changedAt) > t0 + FUTURE_MS) return no('future');
  if (!newer(plain.changedAt, highestSeen === undefined ? null : highestSeen)) return no('not-newer');
  if (typeof plain.offline !== 'boolean') return no('offline');
  if (plain.keep !== undefined && !Array.isArray(plain.keep)) return no('keep');
  if (plain.changedBy !== undefined && plain.changedBy !== null && typeof plain.changedBy !== 'string') return no('changed-by');
  const value = {
    offline: plain.offline,
    keep: cleanKeep(plain.keep),
    changedAt: plain.changedAt,
    changedBy: typeof plain.changedBy === 'string' ? plain.changedBy.slice(0, MAX_BY) : '',
  };
  // The age rule: a computer with nothing of its own yet does not go offline
  // on its own on a week-old word; it asks. Off, and anything fresher, apply.
  const t = typeof now === 'number' && Number.isFinite(now) ? now : Date.now();
  if ((highestSeen === null || highestSeen === undefined) && value.offline && t - ms(value.changedAt) > AGE_ASK_MS) {
    return { act: 'ask', why: 'old', value };
  }
  return { act: 'apply', why: 'ok', value };
}

/**
 * The book's next settings.network after applying `value`. It came through
 * Khayt Cloud (`via: 'cloud'`, which keeps the switch-sync call while
 * offline); this computer's own untick (`dropSwitchSync`) stays.
 */
function applied(network, value) {
  const n = isPlain(network) ? network : {};
  const out = Object.assign({}, n, {
    offline: value.offline === true,
    keep: cleanKeep(value.keep),
    changedAt: value.changedAt,
    changedBy: typeof value.changedBy === 'string' ? value.changedBy.slice(0, MAX_BY) : '',
    via: 'cloud',
  });
  return out;
}

/**
 * A window save may not move the switch BACK in time. Main applies a value
 * from the route to the book; a window holding the older copy (settings never
 * come down, and the window may not have taken main's note yet) would save
 * it straight back. Returns the store to save: `incoming` unchanged, or with
 * disk's settings.network when disk's is strictly newer.
 */
function keepNewerNetwork(incoming, disk, now) {
  const inN = isPlain(incoming) && isPlain(incoming.settings) ? incoming.settings.network : undefined;
  const dN = isPlain(disk) && isPlain(disk.settings) ? disk.settings.network : undefined;
  if (!isPlain(dN)) return incoming;
  const inAt = isPlain(inN) ? inN.changedAt : null;
  if (isPlain(inN) && typeof inAt === 'string' && inAt === dN.changedAt) {
    // The same switch: `via` is main's field (it clears it when the shop
    // stops sharing), so a window holding the old one does not put it back
    // (correctness review of #2645, L1).
    // The window changes `via` only with a new stamp (turning the switch on).
    if ((inN.via || null) === (dN.via || null)) return incoming;
    const net = Object.assign({}, inN, { via: dN.via === undefined ? null : dN.via });
    return Object.assign({}, incoming, { settings: Object.assign({}, incoming.settings, { network: net }) });
  }
  if (dN.via !== 'cloud') return incoming;                                // only a value main applied is protected
  const t = typeof now === 'number' && Number.isFinite(now) ? now : Date.now();
  if (!(ms(dN.changedAt) <= t + FUTURE_MS)) return incoming;             // a stamp from the future protects nothing
  if (!newer(dN.changedAt, inAt === undefined ? null : inAt)) return incoming;
  // Disk is newer. Keep its switch, and the one field that is this
  // computer's own choice and dated by nothing: the switch-sync untick.
  const net = Object.assign({}, dN);
  if (isPlain(inN) && typeof inN.dropSwitchSync === 'boolean') net.dropSwitchSync = inN.dropSwitchSync;
  return Object.assign({}, incoming, { settings: Object.assign({}, incoming.settings, { network: net }) });
}

const api = Object.freeze({ KIND, VERSION, AGE_ASK_MS, FUTURE_MS, MAX_BY, STAMP, cleanKeep, newer, plainFor, judge, applied, keepNewerNetwork });
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (root) root.KhaytNetworkSwitch = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
