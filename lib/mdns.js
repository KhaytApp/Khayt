'use strict';
/**
 * Minimal mDNS (RFC 6762 / DNS-SD) codec — just enough to ask "what printers are on this
 * LAN?" and understand the answer.
 *
 * Deliberately dependency-free. Every mDNS package on npm pulls a transitive tree for
 * what amounts to a few hundred lines of DNS wire format, and this app ships four runtime
 * dependencies total. The socket lives in the host; everything here is pure and testable
 * without a network.
 *
 * ── Uint8Array, NOT Buffer ────────────────────────────────────────────────────────────
 *
 * This was written on Node's `Buffer` throughout. The native Mac app runs these rules in
 * JavaScriptCore, which has no `Buffer` at all — so a wire-format codec that both apps
 * ought to share could be loaded by only one of them, and the Mac would have needed a
 * second implementation of DNS name compression. Two codecs is two chances to get that
 * wrong on a packet arriving from an unauthenticated device on the LAN.
 *
 * `Buffer` IS a `Uint8Array`, so Node is unaffected and its callers never noticed.
 *
 * PRIVACY: discovery is LAN-only multicast (224.0.0.251:5353). Nothing is sent off the
 * network, and the scan is owner-initiated — never on a timer.
 */
(function () {
  const MDNS_ADDR = '224.0.0.251';
  const MDNS_PORT = 5353;

  const TYPE = { A: 1, PTR: 12, TXT: 16, AAAA: 28, SRV: 33 };

  /** UTF-8 bytes of a string, without TextEncoder — JavaScriptCore has it, but a
   *  codec this small should not depend on a host global to encode a label. */
  function utf8(str) {
    const out = [];
    for (const ch of String(str)) {
      let c = ch.codePointAt(0);
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
  }

  /** And back. Malformed sequences become U+FFFD rather than throwing: this reads
   *  packets from the network, and one bad byte must not lose the whole scan. */
  function fromUtf8(bytes, start, end) {
    let out = '';
    for (let i = start; i < end;) {
      const b = bytes[i];
      let c, n;
      if (b < 0x80) { c = b; n = 1; }
      else if ((b & 0xe0) === 0xc0) { c = b & 31; n = 2; }
      else if ((b & 0xf0) === 0xe0) { c = b & 15; n = 3; }
      else if ((b & 0xf8) === 0xf0) { c = b & 7; n = 4; }
      else { out += '\ufffd'; i += 1; continue; }
      if (i + n > end) { out += '\ufffd'; break; }
      for (let k = 1; k < n; k++) c = (c << 6) | (bytes[i + k] & 63);
      out += String.fromCodePoint(c);
      i += n;
    }
    return out;
  }

  const u16 = (bytes, off) => (bytes[off] << 8) | bytes[off + 1];

  /** Encode a dotted name as length-prefixed DNS labels. */
  function encodeName(name) {
    const out = [];
    for (const label of String(name || '').split('.')) {
      if (!label) continue;
      const b = utf8(label);
      if (b.length > 63) throw new Error('label too long');
      out.push(b.length, ...b);
    }
    out.push(0);
    return out;
  }

  /**
   * Build a PTR query for one or more service types.
   *
   * `unicast` sets the QU bit, asking responders to reply straight to our port. Some
   * devices honour it and some only ever multicast — the Prusa CORE One is in the second
   * group — so the caller must ALSO join the multicast group to hear everyone. Learned
   * from real hardware: with QU alone, the Snapmaker answered and the Prusa did not.
   */
  function encodeQuery(names, opts) {
    const list = Array.isArray(names) ? names : [names];
    const out = [0, 0, 0, 0, (list.length >> 8) & 255, list.length & 255, 0, 0, 0, 0, 0, 0];
    const qclass = (opts && opts.unicast) ? 0x8001 : 0x0001;
    for (const n of list) {
      out.push(...encodeName(n));
      out.push((TYPE.PTR >> 8) & 255, TYPE.PTR & 255, (qclass >> 8) & 255, qclass & 255);
    }
    return Uint8Array.from(out);
  }

  /**
   * Read a (possibly compressed) name. Returns [name, offsetAfterName].
   * Compression pointers jump backwards; the guard bounds pathological/hostile packets.
   */
  function readName(buf, offset) {
    const labels = [];
    let off = offset;
    let end = offset;
    let jumped = false;
    for (let guard = 0; guard < 128; guard++) {
      if (off >= buf.length) break;
      const len = buf[off];
      if (len === 0) { if (!jumped) end = off + 1; break; }
      if ((len & 0xc0) === 0xc0) {
        if (off + 1 >= buf.length) break;
        const ptr = ((len & 0x3f) << 8) | buf[off + 1];
        if (!jumped) { end = off + 2; jumped = true; }
        if (ptr >= off) break; // only backwards jumps are legal — refuse loops
        off = ptr;
        continue;
      }
      if (off + 1 + len > buf.length) break;
      labels.push(fromUtf8(buf, off + 1, off + 1 + len));
      off += len + 1;
    }
    return [labels.join('.'), end];
  }

  /** Parse a TXT rdata block into key/value pairs. */
  function parseTxt(rd) {
    const out = {};
    let p = 0;
    while (p < rd.length) {
      const len = rd[p];
      if (len === undefined || p + 1 + len > rd.length) break;
      const entry = fromUtf8(rd, p + 1, p + 1 + len);
      const eq = entry.indexOf('=');
      if (eq > 0) out[entry.slice(0, eq)] = entry.slice(eq + 1);
      p += len + 1;
    }
    return out;
  }

  /**
   * Decode a DNS message into a flat record list. Returns [] on anything malformed —
   * this parses unauthenticated packets from the local network, so it must never throw.
   */
  function decodeMessage(buf) {
    try {
      if (!buf || typeof buf.length !== 'number' || buf.length < 12) return [];
      const qd = u16(buf, 4);
      const counts = [u16(buf, 6), u16(buf, 8), u16(buf, 10)];
      let off = 12;
      for (let i = 0; i < qd; i++) {
        const [, e] = readName(buf, off);
        off = e + 4;
      }
      const records = [];
      for (const count of counts) {
        for (let i = 0; i < count; i++) {
          if (off + 10 > buf.length) return records;
          const [name, e] = readName(buf, off);
          off = e;
          const type = u16(buf, off);
          const rdlen = u16(buf, off + 8);
          const rdStart = off + 10;
          if (rdStart + rdlen > buf.length) return records;
          const rd = buf.slice(rdStart, rdStart + rdlen);
          off = rdStart + rdlen;
          const rec = { name, type };
          if (type === TYPE.PTR) rec.ptr = readName(buf, rdStart)[0];
          else if (type === TYPE.TXT) rec.txt = parseTxt(rd);
          else if (type === TYPE.SRV && rdlen >= 7) {
            rec.srv = { port: u16(rd, 4), target: readName(buf, rdStart + 6)[0] };
          } else if (type === TYPE.A && rdlen === 4) rec.a = Array.from(rd).join('.');
          records.push(rec);
        }
      }
      return records;
    } catch {
      return [];
    }
  }

  // ── ADVERTISING A SERVICE (DNS-SD, RFC 6763) ─────────────────────────────────────────
  //
  // The desktop's LAN server says it is here the way the native Mac's does over Bonjour:
  // `_khayt._tcp`, the shop's name as the instance, TXT `v=1` (lib/main/lan-advertise.js
  // owns the socket). An instance name is ONE label that may itself hold dots, so names
  // are built from label lists here, never split on '.'.

  /** Length-prefixed labels, then the root. Each label at most 63 bytes. */
  function encodeLabels(labels) {
    const out = [];
    for (const label of labels) {
      const b = utf8(label);
      if (!b.length) continue;
      if (b.length > 63) throw new Error('label too long');
      out.push(b.length, ...b);
    }
    out.push(0);
    return out;
  }

  /** TXT rdata: one length-prefixed `key=value` per entry; empty is a single zero byte. */
  function encodeTxt(txt) {
    const out = [];
    for (const k of Object.keys(txt || {})) {
      const b = utf8(k + '=' + String(txt[k]));
      if (b.length > 255) throw new Error('txt entry too long');
      out.push(b.length, ...b);
    }
    return out.length ? out : [0];
  }

  function record(nameBytes, type, cls, ttl, rdata) {
    return [...nameBytes, (type >> 8) & 255, type & 255, (cls >> 8) & 255, cls & 255,
      (ttl >>> 24) & 255, (ttl >>> 16) & 255, (ttl >>> 8) & 255, ttl & 255,
      (rdata.length >> 8) & 255, rdata.length & 255, ...rdata];
  }

  /**
   * An unsolicited mDNS response announcing one service instance:
   *   PTR  _services._dns-sd._udp.local → <service>.local          (shared)
   *   PTR  <service>.local → <instance>.<service>.local            (shared)
   *   SRV  <instance>.<service>.local → <host>.local:<port>        (unique, cache-flush)
   *   TXT  <instance>.<service>.local                              (unique, cache-flush)
   *   A    <host>.local → each IPv4                                (unique, cache-flush)
   * `ttl` 0 is the goodbye (RFC 6762 §10.1). No name compression: a few hundred bytes.
   *
   * @param {object} o
   * @param {string} o.instance   the shop's name, at most 63 bytes
   * @param {string} [o.service]  '_khayt._tcp'
   * @param {string} o.host       host label (without .local)
   * @param {number} o.port
   * @param {object} [o.txt]      {v: '1'}
   * @param {string[]} [o.ipv4]
   * @param {number} [o.ttl]      seconds for PTR/TXT (4500); SRV and A use min(ttl, 120)
   */
  function encodeAdvertisement(o) {
    const service = String((o && o.service) || '_khayt._tcp').split('.').filter(Boolean);
    const svc = [...service, 'local'];
    const inst = [String(o.instance), ...svc];
    const host = [String(o.host), 'local'];
    const ttl = o.ttl == null ? 4500 : Math.max(0, Math.floor(o.ttl));
    const hostTtl = Math.min(ttl, 120);
    const ips = (o.ipv4 || []).filter((ip) => /^\d{1,3}(\.\d{1,3}){3}$/.test(ip));
    const port = Math.floor(+o.port) & 0xffff;
    const answers = [
      record(encodeLabels(['_services', '_dns-sd', '_udp', 'local']), TYPE.PTR, 1, ttl, encodeLabels(svc)),
      record(encodeLabels(svc), TYPE.PTR, 1, ttl, encodeLabels(inst)),
      record(encodeLabels(inst), TYPE.SRV, 0x8001, hostTtl, [0, 0, 0, 0, (port >> 8) & 255, port & 255, ...encodeLabels(host)]),
      record(encodeLabels(inst), TYPE.TXT, 0x8001, ttl, encodeTxt(o.txt)),
      ...ips.map((ip) => record(encodeLabels(host), TYPE.A, 0x8001, hostTtl, ip.split('.').map((n) => +n & 255))),
    ];
    const n = answers.length;
    const out = [0, 0, 0x84, 0, 0, 0, (n >> 8) & 255, n & 255, 0, 0, 0, 0];
    for (const a of answers) out.push(...a);
    return Uint8Array.from(out);
  }

  /** The questions of a query (name lower-cased, type, QU bit); [] on anything malformed or a response. */
  function decodeQuestions(buf) {
    try {
      if (!buf || typeof buf.length !== 'number' || buf.length < 12) return [];
      if (buf[2] & 0x80) return [];            // a response, not a query
      const qd = u16(buf, 4);
      const out = [];
      let off = 12;
      for (let i = 0; i < qd && i < 64; i++) {
        const [name, e] = readName(buf, off);
        if (e + 4 > buf.length) break;
        out.push({ name: name.toLowerCase(), type: u16(buf, e), unicast: (buf[e + 2] & 0x80) !== 0 });
        off = e + 4;
      }
      return out;
    } catch {
      return [];
    }
  }

  const api = { MDNS_ADDR, MDNS_PORT, TYPE, encodeName, encodeQuery, readName, parseTxt, decodeMessage,
    encodeLabels, encodeTxt, encodeAdvertisement, decodeQuestions };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytMdns = api;
})();
