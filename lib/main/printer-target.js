'use strict';
/**
 * Where a printer request may go, decided once, by ADDRESS.
 *
 * isAllowedPrinterHost judges the text of a host. For an address that is the
 * whole answer; for a NAME it is no answer at all — it accepts any DNS name,
 * so a machine record that arrived by sync or restore with
 * `printerApi.host = printer.attacker.example` would have every poll carry the
 * printer's X-Api-Key, or a Bambu access code, to the internet in plain HTTP.
 * And looking the name up in one place and connecting in another lets a
 * rebinding name answer LAN for the check and the internet for the request.
 *
 * So: resolve the name, require EVERY address it gives to be a LAN address,
 * and hand back the one to connect to. Callers build their URL from
 * `urlHost` and never from the name again. The Mac's printer poller does the
 * same (#1955).
 */
const dns = require('dns');
const net = require('net');
const { canonicalizeIpv4, isAllowedPrinterHost, sanitizePrinterHost } = require('../printer-host.js');

/** An address as it goes in a URL: IPv6 in brackets. */
function urlHostOf(address) {
  return net.isIPv6(address) ? `[${address}]` : address;
}

/**
 * @returns {Promise<{ok: true, address: string, urlHost: string} | {ok: false, error: string}>}
 */
async function resolvePrinterTarget(host, { lookup = dns.promises.lookup } = {}) {
  const name = sanitizePrinterHost(host);
  if (!isAllowedPrinterHost(name)) return { ok: false, error: 'Invalid printer host' };
  const literal = canonicalizeIpv4(name) || (net.isIP(name) ? name : null);
  if (literal) return { ok: true, address: literal, urlHost: urlHostOf(literal) };
  let found;
  try {
    found = await lookup(name, { all: true, verbatim: true });
  } catch (e) {
    return { ok: false, error: 'Printer host not found' };
  }
  const addrs = (Array.isArray(found) ? found : []).map((a) => String(a && a.address || '')).filter(Boolean);
  if (!addrs.length) return { ok: false, error: 'Printer host not found' };
  // Every address, not the first: a name that answers one LAN and one public
  // address is a name that can be steered to the public one.
  if (!addrs.every((a) => isAllowedPrinterHost(a.replace(/%.*$/, '')))) {
    return { ok: false, error: 'Printer host is not on this network' };
  }
  return { ok: true, address: addrs[0], urlHost: urlHostOf(addrs[0]) };
}

module.exports = { resolvePrinterTarget, urlHostOf };
