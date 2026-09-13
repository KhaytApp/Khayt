'use strict';
(function (global) {

/**
 * Which hosts an outbound request may NOT go to.
 *
 * ── WHY THIS IS ITS OWN FILE ──────────────────────────────────────────────
 *
 * It was the top of `lib/host-guard.js`, which cannot be shared: that file
 * `require`s Node's `dns` for its second layer, and neither the renderer nor
 * JavaScriptCore has one. The Mac app needed exactly these range checks to send
 * a webhook safely, and rewriting them in Swift was not an option.
 *
 * ── AND WHY REWRITING THEM WOULD HAVE BEEN THE WRONG CALL ─────────────────
 *
 * Almost every line here is a hole somebody found. `127.0.0.1` was blocked
 * while `http://[::1]:PORT/` sailed through, and the unit tests passed the one
 * shape that worked. `::ffff:127.0.0.1` has two spellings and WHATWG URL
 * normalises to the hex one. A numeric IPv4 like `2130706433` resolves to
 * loopback. A second implementation would start again from the version that
 * looked right.
 *
 * THIS IS ONE LAYER OF TWO. It inspects a NAME. A public-looking hostname can
 * still resolve to an internal address, so a host that passes here must also be
 * resolved and every answer checked — `resolvesToBlockedHost` in `host-guard.js`
 * for Node, and the same walk in Swift for the Mac. Neither layer is sufficient
 * alone.
 *
 * Pure: no dns, no fs, no clock.
 */

/* Read at CALL time, not at load. A load-time capture is null whenever
 * `printer-host` happens to load after this file, and the failure is silent and
 * security-relevant: `canonicalizeIpv4` is what turns `2130706433` into
 * `127.0.0.1`, so without it that spelling stops being blocked and everything
 * still looks fine. */
function canonicalizeIpv4(h) {
  const PH = (typeof global !== 'undefined' && global.KhaytPrinterHost) || null;
  return (PH && typeof PH.canonicalizeIpv4 === 'function') ? PH.canonicalizeIpv4(h) : null;
}

/**
 * Normalise a hostname for the checks below.
 *
 * Every production caller passes `new URL(url).hostname`, which returns an IPv6 literal
 * WRAPPED IN BRACKETS — "[::1]", "[fd00::1]". The IPv6 patterns here test bare literals
 * ("^::1$", "^fc", "^fd", "^::ffff:"), so none of them ever matched a real caller and the
 * function fell through to "not blocked". IPv4 was unaffected, which is why this went
 * unnoticed: 127.0.0.1 was blocked while http://[::1]:PORT/ sailed through to fetch().
 * The unit tests passed the bare form, the only shape that worked.
 *
 * Also lowercases, since the IPv6 tests are otherwise case-sensitive in places.
 */
function normalizeHostForCheck(h) {
  const bare = String(h || '').trim().replace(/^\[/, '').replace(/\]$/, '').toLowerCase();
  // Unwrap IPv4-mapped IPv6 to its dotted form so the IPv4 range logic applies. WHATWG URL
  // normalises "[::ffff:127.0.0.1]" to "[::ffff:7f00:1]" (hex), so both spellings must be
  // decoded — otherwise ::ffff:127.0.0.1 slipped past isBlockedLoopbackOrMetadata, which
  // has no IPv6 branch for it at all.
  const dotted = /^::ffff:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/.exec(bare);
  if (dotted) return dotted[1];
  const hex = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(bare);
  if (hex) {
    const n = (parseInt(hex[1], 16) << 16) | parseInt(hex[2], 16);
    return [(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255].join('.');
  }
  // Numeric IPv4 spellings resolve to the same address a dotted quad does, so
  // the range tests below must see the dotted quad. Shared by isBlockedHost and
  // isBlockedLoopbackOrMetadata — the latter guards outbound SMTP and, like the
  // printer path, has no DNS-resolving second layer behind it.
  return canonicalizeIpv4(bare) || bare;
}

/** True when host must not be used for outbound requests (loopback, RFC1918, metadata, etc.). */
function isBlockedHost(rawHost) {
  const h = normalizeHostForCheck(rawHost);
  if (!h) return true;
  if (/^(localhost|ip6-localhost|ip6-loopback)$/i.test(h)) return true;
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (v4) {
    const [, a, b, c, d] = v4.map(Number);
    if (a === 0) return true;
    if (a === 10) return true;
    if (a === 127) return true;
    if (a === 169 && b === 254) return true;
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 198 && (b === 18 || b === 19)) return true;
    if (a === 240) return true;
    if (a === 255) return true;
  }
  if (/^::1$|^::$|^fe80:/i.test(h)) return true;
  if (/^fc|^fd/i.test(h)) return true;
  if (/^::ffff:/i.test(h)) return true;
  return false;
}

/** Block loopback and cloud metadata — used for outbound SMTP (allows LAN mail relays). */
function isBlockedLoopbackOrMetadata(rawHost) {
  const h = normalizeHostForCheck(rawHost);
  if (!h) return true;
  if (/^(localhost|ip6-localhost|ip6-loopback)$/i.test(h)) return true;
  const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
  if (v4) {
    const [, a, b, c, d] = v4.map(Number);
    if (a === 127) return true;
    if (a === 0) return true;
    if (a === 169 && b === 254 && c === 169 && d === 254) return true;
  }
  if (/^::1$|^::$|^fe80:/i.test(h)) return true;
  return false;
}

const api = { normalizeHostForCheck, isBlockedHost, isBlockedLoopbackOrMetadata };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytHostRanges = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
