const dns = require('dns');
// The syntactic half of the printer guard, split out so the Mac app — which
// polls the same machines and has no `dns` — shares the same rule rather than
// writing a second, more forgiving one in Swift.
const { canonicalizeIpv4, isAllowedPrinterHost, sanitizePrinterHost } = require('./printer-host.js');


/**
 * DNS-rebinding defence for outbound requests. Resolves a hostname to ALL of
 * its A/AAAA addresses and reports whether ANY resolved IP falls in a blocked
 * range (loopback/private/link-local/metadata), reusing isBlockedHost for the
 * range logic. A literal IP is checked directly.
 *
 * Best-effort only: this is a TOCTOU check — the OS resolver may return a
 * different answer when the socket actually connects, and Node's fetch does
 * not expose the resolved peer address for a post-connect re-check. Resolution
 * failures fail closed (treated as blocked).
 */
async function resolvesToBlockedHost(hostname) {
  const h = normalizeHostForCheck(hostname);
  if (!h) return true;
  // Literal IPs (v4 or v6) are already fully covered by the string check.
  if (/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(h) || h.includes(':')) {
    return isBlockedHost(h);
  }
  try {
    const addrs = await dns.promises.lookup(h, { all: true });
    return addrs.some(a => isBlockedHost(a.address));
  } catch {
    return true; // fail closed — cannot verify, so refuse
  }
}

/* The range checks live in `lib/host-ranges.js` now — the Mac app needs them to
 * send a webhook safely and cannot have this file, which requires Node's `dns`
 * for the resolving layer below. Re-exported here so every existing caller is
 * unchanged, and so there is exactly one copy of rules that are almost entirely
 * made of holes somebody found. */
const { normalizeHostForCheck, isBlockedHost, isBlockedLoopbackOrMetadata } =
  require('./host-ranges.js');

/** Allow only a plain hostname for Mailgun API path (blocks slashes, userinfo, ports). */
function sanitizeMailgunDomain(domain) {
  const d = String(domain || '').trim().toLowerCase();
  if (!d || d.length > 253) return null;
  if (!/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/.test(d)) return null;
  return d;
}

module.exports = {
  isBlockedHost, isAllowedPrinterHost, isBlockedLoopbackOrMetadata, sanitizeMailgunDomain,
  resolvesToBlockedHost, canonicalizeIpv4, sanitizePrinterHost,
};
