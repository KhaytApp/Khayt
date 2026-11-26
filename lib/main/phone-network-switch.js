'use strict';
/**
 * An owner's phone turning the shop's "Make no internet calls" on or off
 * (iPhone frame 1B; `POST /api/network/switch`, docs/LAN_API.md). The Mac's
 * `Shop.phoneSetOutbound` (Shop+PhoneNetworkSwitch.swift), rule for rule, on
 * Windows/Linux (Dev Hub, Nov 26: the parity gap the iPhone lane found).
 *
 * The ROUTE (lib/lan-server.js) lets through only a SIGNED, enrolled phone
 * whose role is owner: the shared role rule answers `owner` for a route its
 * table does not name. What happens then is this computer's own change, by
 * the same path the window takes (renderer/internet-use.js saveNetwork):
 *   - the same forward-only stamp (lib/network-switch.js stampAfter, never
 *     before the book's own stamp or the highest one heard from Khayt Cloud);
 *   - turning it ON tells the other computers FIRST, while this computer is
 *     still online, and only a value the cloud took makes it `via: 'cloud'`;
 *     turning it OFF tells them AFTER the write (main sends what the book holds);
 *   - one write of `settings.network` through main's write chain, and the
 *     window told (hub:network-applied), which also moves the outbound gate.
 * Nothing here is a second way to flip the switch.
 *
 *   createPhoneNetworkSwitch(d).handle({ body, deviceName, now? }) → { status, body }
 *     d.getSettings()           the book's settings (null: not read yet → 503 busy)
 *     d.updateNetwork(fn)       fn(before) → next | before (no write); resolves when written
 *     d.publish({ offline, network? }) → { ok, via? }   networkSwitchSync.publish
 *     d.highestSeen()           the highest changedAt heard from Khayt Cloud, or null
 *     d.notify(network)         the window applies what was written
 *     d.now()                   ms
 */
const Outbound = require('../outbound.js');
const NS = require('../network-switch.js');

/** What a phone may keep while the switch is on: every purpose but `lan` and `switch-sync`. */
const PHONE_KEEPABLE = Object.freeze(Outbound.PURPOSES.filter((p) => p !== 'lan' && p !== 'switch-sync'));
const MAX_BODY = 4096;
const NAME_CHARS = 80;
const NAME_BYTES = 240;

const isPlain = (v) => !!v && typeof v === 'object' && !Array.isArray(v);

/** A device name as other computers will show it: no control, newline or direction-changing characters, bounded. */
function cleanName(name) {
  let s = String(name == null ? '' : name)
    // C0/C1 controls (newlines included) and the bidi controls (LRM/RLM, embeddings, isolates).
    .replace(/[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, '')
    .trim();
  s = Array.from(s).slice(0, NAME_CHARS).join('');
  while (Buffer.byteLength(s, 'utf8') > NAME_BYTES) s = Array.from(s).slice(0, -1).join('');
  return s;
}

/** The switch as a phone is told it: only the purposes this computer shows a phone. */
function forPhone(network) {
  const n = isPlain(network) ? network : {};
  const keep = Array.isArray(n.keep) ? n.keep.filter((k) => typeof k === 'string' && PHONE_KEEPABLE.indexOf(k) !== -1) : [];
  return { offline: n.offline === true, keep, changedAt: n.changedAt == null ? null : n.changedAt, changedBy: n.changedBy == null ? null : n.changedBy };
}

/** `seen` against the book's stamp: the same INSTANT, or (not a stamp) the same text. */
function sameMoment(current, seen) {
  if (typeof current !== 'string') return false;
  const a = Date.parse(current), b = Date.parse(seen);
  if (Number.isFinite(a) && Number.isFinite(b)) return a === b;
  return current === seen;
}

/** The request, read exactly, or the reason it is refused. */
function parse(body) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(String(body == null ? '' : body), 'utf8');
  if (buf.length > MAX_BODY) return { error: 'bad-body' };
  let asked;
  try { asked = JSON.parse(buf.toString('utf8')); } catch (_) { return { error: 'bad-body' }; }
  if (!isPlain(asked) || typeof asked.offline !== 'boolean') return { error: 'bad-body' };
  let keep = null;
  if (asked.keep !== undefined && asked.keep !== null) {
    if (!Array.isArray(asked.keep)) return { error: 'bad-body' };
    keep = [];
    for (const id of asked.keep) {
      // An entry this computer does not know is REFUSED, not dropped, so a
      // phone with a newer list learns it is talking to an older computer.
      if (typeof id !== 'string' || PHONE_KEEPABLE.indexOf(id) === -1) return { error: 'bad-keep' };
      if (keep.indexOf(id) === -1) keep.push(id);
    }
  }
  let seen = null;
  if (asked.seen !== undefined && asked.seen !== null) {
    if (typeof asked.seen !== 'string') return { error: 'bad-body' };
    seen = asked.seen;
  }
  let seenKeep = null;
  if (asked.seenKeep !== undefined && asked.seenKeep !== null) {
    if (!Array.isArray(asked.seenKeep) || asked.seenKeep.some((x) => typeof x !== 'string')) return { error: 'bad-body' };
    seenKeep = asked.seenKeep.slice();
  }
  return { offline: asked.offline, keep, seen, seenKeep };
}

function createPhoneNetworkSwitch(d) {
  const now = () => (typeof d.now === 'function' ? d.now() : Date.now());
  let inFlight = false;
  const answer = (status, body) => ({ status, body });
  const current = () => { const s = d.getSettings(); return isPlain(s) && isPlain(s.network) ? s.network : {}; };

  async function handle({ body, deviceName } = {}) {
    const asked = parse(body);
    if (asked.error) return answer(400, { ok: false, reason: asked.error });
    const settings = d.getSettings();
    if (!isPlain(settings)) return answer(503, { ok: false, reason: 'busy' });

    // What the person was LOOKING at when they tapped. If the book moved since,
    // nothing changes and the phone is shown what is true now.
    const n = current();
    const stale = () => answer(409, { ok: false, reason: 'changed', network: forPhone(current()) });
    if (asked.seen !== null && !sameMoment(n.changedAt, asked.seen)) return stale();
    if (asked.seenKeep !== null) {
      // Only the purposes this computer shows a phone: an id it does not know
      // is never in `shown`, and comparing it would answer "changed" for good.
      const shown = new Set(forPhone(n).keep);
      const theirs = new Set(asked.seenKeep.filter((k) => PHONE_KEEPABLE.indexOf(k) !== -1));
      if (shown.size !== theirs.size || [...shown].some((k) => !theirs.has(k))) return stale();
    }
    if (inFlight) return answer(409, { ok: false, reason: 'not-saved', network: forPhone(n) });
    inFlight = true;
    try {
      const name = cleanName(deviceName);
      const flipped = asked.offline !== (n.offline === true);
      const next = Object.assign({}, n, { offline: asked.offline });
      if (asked.keep !== null) {
        // A purpose already in the book that this computer does not know is
        // left there: it was never this request's to untick.
        const unknown = Array.isArray(n.keep) ? n.keep.filter((k) => typeof k === 'string' && PHONE_KEEPABLE.indexOf(k) === -1) : [];
        next.keep = asked.keep.concat(unknown);
      }
      // When and by whom are the SWITCH's: a Keep tick changes neither.
      if (flipped) {
        next.changedAt = NS.stampAfter(now(), [n.changedAt, typeof d.highestSeen === 'function' ? d.highestSeen() : null]) || new Date(now()).toISOString();
        next.changedBy = name || null;
      }
      // ON: tell the other computers first, while still online.
      if (flipped && asked.offline) {
        let pub = null;
        try { pub = await d.publish({ offline: true, network: next }); } catch (_) { pub = null; }
        next.via = pub && pub.ok && pub.via === 'cloud' ? 'cloud' : null;
      }
      // One write, and only over the book the phone was shown: a change that
      // landed meanwhile (the window, the cloud) is not overwritten blind.
      let wrote = false;
      let raced = false;
      try {
        await d.updateNetwork((before) => {
          const b = isPlain(before) ? before : {};
          if ((b.changedAt || null) !== (n.changedAt || null) || (b.offline === true) !== (n.offline === true)) { raced = true; return before; }
          wrote = true;
          return next;
        });
      } catch (_) { wrote = false; }
      if (!wrote) return answer(409, { ok: false, reason: raced ? 'changed' : 'not-saved', network: forPhone(current()) });
      try { if (typeof d.notify === 'function') d.notify(next); } catch (_) { /* the window reloads it */ }
      // OFF: tell them after, as the first call back (main sends what the book holds).
      if (flipped && !asked.offline) { try { await d.publish({ offline: false }); } catch (_) { /* main keeps the outcome */ } }
      return answer(200, { ok: true, network: forPhone(next) });
    } finally { inFlight = false; }
  }

  return { handle };
}

module.exports = { createPhoneNetworkSwitch, cleanName, forPhone, parse, PHONE_KEEPABLE, MAX_BODY };
