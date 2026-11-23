'use strict';
(function (global) {

/**
 * Printers this computer has FOUND on the network, remembered for a while
 * (C10, batch 4 of ~/Khayt-proposals/prusa-ideas-plan.md).
 *
 * "Find printers" was a one-off scan: 6 s of mDNS (4 s on the Mac) and an SDCP
 * shout, then the list was thrown away. A printer that was asleep, busy
 * answering something else, or slow to repeat its announcement during those
 * seconds was simply not there, and the owner pressed the button again and
 * hoped. Every scan (the owner's, and the background one that looks for a
 * printer whose address moved) now adds what it saw to a short list kept on
 * this computer, each entry with when it was first and last seen. Entries
 * nobody has seen for `ttlMs` are dropped, and the list never holds more than
 * `cap` printers, the most recently seen kept.
 *
 *   remember(list, found, now, { source, ttlMs, cap })
 *     → the new list (never mutates `list`)
 *   recent(list, now, { ttlMs })
 *     → entries still inside the expiry, most recently seen first
 *   forScan(list, scanned, now, { ttlMs })
 *     → what a picker shows: this scan's printers (`seenNow: true`) then the
 *       remembered ones this scan did not see (`seenNow: false`, `lastSeen`)
 *
 * ONE printer, one entry: matched by its serial when it announced one (an
 * address moves with a DHCP lease, a serial does not), otherwise by its
 * address and port. Two printers cannot answer on one address and port at
 * once, so when a find claims an address an older entry held under another
 * identity, the older entry goes.
 *
 * What is kept is what the picker needs and nothing more: no TXT dump (`raw`),
 * every string bounded. These come from unauthenticated devices on the LAN.
 * The list is a per-computer fact, never part of the book: it is not shared
 * with phones or other computers, and nothing here reaches the internet.
 *
 * Pure: the clock is handed in; the host reads and writes the file.
 */

const TTL_MS = 3 * 24 * 60 * 60 * 1000;   // three days: a weekend off, then gone
const CAP = 40;
const MAX_TEXT = 200;
const SOURCES = Object.freeze(['mdns', 'sdcp', 'sweep']);
const FIELDS = Object.freeze(['id', 'name', 'vendor', 'model', 'label', 'host', 'serial', 'firmware',
  'connection', 'catalogId', 'linkMode', 'mac']);

const text = (v) => (v == null ? '' : String(v)).slice(0, MAX_TEXT);
const port = (v) => { const n = Number(v); return Number.isInteger(n) && n > 0 && n < 65536 ? n : 0; };
const time = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const lower = (v) => text(v).trim().toLowerCase();

/** The identity a printer is remembered under. */
function keyOf(p) {
  if (!p) return '';
  const sn = lower(p.serial);
  if (sn) return 'sn:' + sn;
  const host = lower(p.host);
  return host ? 'host:' + host + ':' + port(p.port) : '';
}
const addrOf = (p) => (p && lower(p.host) ? lower(p.host) + ':' + port(p.port) : '');

function sourceOf(p, fallback) {
  if (p && SOURCES.includes(p.source)) return p.source;
  if (SOURCES.includes(fallback)) return fallback;
  const id = String((p && p.id) || '');
  if (id.startsWith('sdcp|')) return 'sdcp';
  if (id.startsWith('sweep|')) return 'sweep';
  return 'mdns';
}

/** A stored entry: only the known fields, bounded. Null when it cannot be one. */
function clean(p, fallbackSource) {
  if (!p || typeof p !== 'object') return null;
  const out = {};
  for (const f of FIELDS) {
    if (f === 'connection' || f === 'catalogId') { out[f] = p[f] == null || p[f] === '' ? null : text(p[f]); continue; }
    out[f] = text(p[f]);
  }
  out.port = port(p.port);
  out.advertisedPort = port(p.advertisedPort);
  out.source = sourceOf(p, fallbackSource);
  out.firstSeen = time(p.firstSeen);
  out.lastSeen = time(p.lastSeen);
  out.seenCount = Number.isInteger(p.seenCount) && p.seenCount > 0 ? p.seenCount : 0;
  // "It was at another address before": kept through the file, or the picker
  // could never say so after a write and a read back (the Mac's review).
  const prev = text(p.previousHost).trim();
  if (prev) out.previousHost = prev;
  return keyOf(out) ? out : null;
}

function opts_(o) {
  const ttlMs = o && Number(o.ttlMs) > 0 ? Number(o.ttlMs) : TTL_MS;
  const cap = o && Number.isInteger(o.cap) && o.cap > 0 ? o.cap : CAP;
  return { ttlMs, cap };
}

function remember(list, found, now, o) {
  const { ttlMs, cap } = opts_(o);
  const source = o && o.source;
  // What is on disk may be anything: an older format, a hand edit, a cut-off write.
  let out = (Array.isArray(list) ? list : []).map((p) => clean(p)).filter((p) => p && p.lastSeen !== null);
  for (const raw of Array.isArray(found) ? found : []) {
    const f = clean(raw, source);
    if (!f) continue;
    const key = keyOf(f);
    const addr = addrOf(f);
    // The same printer: same serial, or (no serial on one side) the same address.
    let i = out.findIndex((p) => keyOf(p) === key);
    if (i < 0 && addr) i = out.findIndex((p) => addrOf(p) === addr && (!lower(p.serial) || !lower(f.serial)));
    const was = i >= 0 ? out[i] : null;
    // What this find did not say is kept from before, for EVERY field: a
    // sweep knows no model, mDNS no hardware address, and the other app's
    // scanner may not fill an id, label, link mode, port or vendor that this
    // one did. clean() turned "not said" into '' / null / 0, so empty is
    // "not said", never "now blank" (the Mac's review).
    const kept = {};
    for (const k of FIELDS) {
      const empty = f[k] === '' || f[k] == null;
      kept[k] = empty && was ? was[k] : f[k];
    }
    kept.port = f.port || (was && was.port) || 0;
    kept.advertisedPort = f.advertisedPort || (was && was.advertisedPort) || 0;
    const next = Object.assign({}, was || {}, f, kept, {
      firstSeen: was && was.firstSeen !== null && was.firstSeen <= now ? was.firstSeen : now,
      lastSeen: now,
      seenCount: (was ? was.seenCount : 0) + 1,
    });
    if (was && lower(was.host) && addrOf(was) !== addr) next.previousHost = text(was.host);
    else if (was && was.previousHost) next.previousHost = text(was.previousHost);
    if (i >= 0) out.splice(i, 1);
    // Another identity on this address is a printer that is no longer there.
    if (addr) out = out.filter((p) => addrOf(p) !== addr);
    out.push(next);
  }
  return out
    .filter((p) => now - p.lastSeen < ttlMs && p.lastSeen <= now + ttlMs)
    .sort((a, b) => (b.lastSeen - a.lastSeen) || keyOf(a).localeCompare(keyOf(b)))
    .slice(0, cap);
}

/**
 * Remember a scan in a file another app may write at the same time (the Mac
 * and this computer share it). Read, merge, then read again just before
 * writing: if the bytes changed, the other app wrote in between, so merge
 * again from what it wrote. After `rounds` tries this scan is not remembered
 * (it costs one more scan, never the other app's printers). The write itself
 * is the host's temp file and rename.
 *
 *   io.read()        → the file's text, or '' when there is none
 *   io.write(text)   → writes it atomically (temp + rename)
 *
 * @returns {boolean} whether it was written
 */
function rememberInFile(io, found, now, o) {
  const rounds = o && Number.isInteger(o.rounds) && o.rounds > 0 ? o.rounds : 3;
  const parse = (t) => { try { const j = JSON.parse(t); return Array.isArray(j && j.printers) ? j.printers : []; } catch (_) { return []; } };
  for (let r = 0; r < rounds; r++) {
    const before = String(io.read() || '');
    const text = JSON.stringify({ version: 1, printers: remember(parse(before), found, now, o) });
    if (String(io.read() || '') !== before) continue;
    io.write(text);
    return true;
  }
  return false;
}

function recent(list, now, o) {
  const { ttlMs } = opts_(o);
  return (Array.isArray(list) ? list : [])
    .map((p) => clean(p))
    .filter((p) => p && p.lastSeen !== null && now - p.lastSeen < ttlMs)
    .sort((a, b) => (b.lastSeen - a.lastSeen) || keyOf(a).localeCompare(keyOf(b)));
}

function forScan(list, scanned, now, o) {
  const here = (Array.isArray(scanned) ? scanned : []).filter(Boolean);
  const keys = new Set();
  const addrs = new Set();
  for (const p of here) { const k = keyOf(clean(p)); if (k) keys.add(k); const a = addrOf(p); if (a) addrs.add(a); }
  const earlier = recent(list, now, o)
    .filter((p) => !keys.has(keyOf(p)) && !addrs.has(addrOf(p)))
    .map((p) => Object.assign(p, { seenNow: false }));
  return here.map((p) => Object.assign({}, p, { seenNow: true })).concat(earlier);
}

const api = { TTL_MS, CAP, SOURCES, keyOf, clean, remember, rememberInFile, recent, forScan };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytFoundPrinters = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
