'use strict';
/**
 * Is this string a LAN printer's address?
 *
 * A printer is a device on the shop's own network, so only the private ranges
 * are allowed — a public address here means something has pointed the poller at
 * an arbitrary internet host, which is server-side request forgery with a
 * printer card as the pretext.
 *
 * SPLIT OUT OF `lib/host-guard.js` SO THE MAC APP SHARES IT. That file requires
 * `dns` for the rebinding defence on the webhook path, which JavaScriptCore does
 * not have; this half is pure, and it is the half a poller needs. host-guard
 * re-exports it, so every existing caller and test is unchanged.
 *
 * The check is SYNTACTIC — a bare hostname like `octopi.local` is allowed and
 * not resolved. That is a deliberate trust boundary and it is why the numeric
 * spellings below matter so much: `connect()` goes through inet_aton, and
 * 2130706433, 0x7f000001, 127.1 and 0177.0.0.1 all reach loopback while none of
 * them matches a dotted-quad test.
 */
(function (global) {

  /**
   * Rewrite the legal-but-unusual spellings of an IPv4 address into a dotted quad.
   *
   * `connect()` goes through inet_aton, which accepts far more than four decimal
   * octets: a bare 32-bit integer, hex, octal, and short forms where the last part
   * absorbs the remaining bytes. All of these reach 127.0.0.1 —
   *
   *     2130706433      0x7f000001      127.1      0177.0.0.1
   *
   * — and none of them matches a `\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}` test. Before
   * this, they fell past the dotted-quad branch in isAllowedPrinterHost and landed
   * on the permissive "bare hostname" return at the bottom, so the guard blocked
   * `127.0.0.1` and allowed three other ways of writing it. Verified by connecting:
   * the first three reach loopback.
   *
   * The webhook path was never exposed — resolvesToBlockedHost() resolves the name
   * and catches all of them — but the printer path has only the syntactic check,
   * so the syntactic check has to be honest about what a host string means.
   *
   * @returns {string|null} dotted quad, or null when this is not numeric IPv4 at
   *   all (a real hostname), which the caller must keep treating as a hostname.
   */
  function canonicalizeIpv4(host) {
    const s = String(host || '').trim();
    if (!s || !/^[0-9a-fx.]+$/i.test(s)) return null;
    const parts = s.split('.');
    if (parts.length < 1 || parts.length > 4) return null;

    const nums = [];
    for (const p of parts) {
      if (p === '') return null;
      let n;
      if (/^0[xX][0-9a-fA-F]+$/.test(p)) n = parseInt(p, 16);
      else if (/^0[0-7]+$/.test(p)) n = parseInt(p, 8);
      else if (/^[0-9]+$/.test(p)) n = parseInt(p, 10);
      else return null;                      // e.g. "0x" alone, or "1a"
      if (!Number.isFinite(n) || n < 0) return null;
      nums.push(n);
    }
    // Every part but the last is one octet; the last absorbs what remains.
    const last = nums.pop();
    if (nums.some((n) => n > 255)) return null;
    const remaining = 4 - nums.length;
    if (last > Math.pow(256, remaining) - 1) return null;
    const bytes = [...nums];
    for (let i = remaining - 1; i >= 0; i--) bytes.push((last >>> (8 * i)) & 255);
    return bytes.join('.');
  }

  /**
   * True when host is valid for local printer API polling. Printers are LAN
   * devices, so only RFC1918 + link-local (and IPv6 ULA/link-local) ranges are
   * permitted — public IPs are rejected to stop a malicious renderer pointing
   * the poller at an arbitrary internet host (SSRF). Bare hostnames (e.g. the
   * mDNS "octopi.local") are allowed but unresolved here; that is a deliberate
   * trust boundary documented at the caller.
   */
  function isAllowedPrinterHost(h) {
    if (!h) return false;
    if (/^(localhost|ip6-localhost|ip6-loopback)$/i.test(h)) return false;
    // Numeric spellings first: 2130706433 and 127.1 are 127.0.0.1, and must be
    // judged as the address they are rather than fall through as "a hostname".
    const canon = canonicalizeIpv4(h);
    const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(canon || h);
    if (v4) {
      const [, a, b, c, d] = v4.map(Number);
      // Loopback / unspecified / broadcast / reserved — never a printer.
      if (a === 0 || a === 127 || a === 255 || a === 240) return false;
      // Link-local 169.254.x.x is fine for mDNS/direct printers, but never the
      // cloud metadata endpoint.
      if (a === 169 && b === 254) return !(c === 169 && d === 254);
      // RFC1918 private ranges only.
      if (a === 10) return true;
      if (a === 172 && b >= 16 && b <= 31) return true;
      if (a === 192 && b === 168) return true;
      // Anything else is a public/unexpected IPv4 — not a LAN printer.
      return false;
    }
    if (/^::1$|^::$/i.test(h)) return false;     // IPv6 loopback / unspecified
    if (/^::ffff:/i.test(h)) return false;       // IPv4-mapped — treat as untrusted
    if (/^fe80:/i.test(h)) return true;          // IPv6 link-local (LAN)
    if (/^fc|^fd/i.test(h)) return true;         // IPv6 ULA (LAN)
    return /^[a-zA-Z0-9.\-]+$/.test(h);
  }

  /**
   * A host string with everything that is not a hostname taken out.
   *
   * `@`, `/` and `:` in a host are how a URL is made to point somewhere other
   * than where it reads — `printer@evil.example` is a request to evil.example.
   * Stripping them before the check above is part of the same rule, so it lives
   * beside it rather than being written out at each caller.
   */
  function sanitizePrinterHost(host) {
    return String(host || '').replace(/[^a-zA-Z0-9.\-]/g, '');
  }

  const api = { canonicalizeIpv4, isAllowedPrinterHost, sanitizePrinterHost };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytPrinterHost = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
