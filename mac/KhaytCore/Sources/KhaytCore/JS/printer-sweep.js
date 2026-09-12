'use strict';

/**
 * Finding a printer that answers nothing where it used to.
 *
 * WHY mDNS WAS NOT ENOUGH
 *
 * `lib/printer-relocate.js` can repair a machine whose DHCP lease moved it, and
 * it works — given something to match against. It gets that from
 * `lib/printer-discovery.js`, which browses mDNS for `_moonraker._tcp` and
 * `_octoprint._tcp`.
 *
 * The Snapmaker U1 advertises neither. Browsed on the bench LAN it was printing
 * on, the whole answer was:
 *
 *     _moonraker._tcp   nothing
 *     _octoprint._tcp   nothing
 *
 * — while mDNS itself worked perfectly and turned up a NAS and an HP laser over
 * `_http._tcp`. The printer simply announces nothing. So `planRelocations` was
 * handed an empty list, returned NOT_FOUND, and the owner was shown "offline"
 * with no hint that the fix was a two-second edit.
 *
 * That is worth stating plainly because `printer-relocate.js` opens by
 * describing this exact printer, moving from .77 to .56, losing a completion
 * history. It was written for a case it could not detect.
 *
 * WHAT THIS DOES INSTEAD
 *
 * Asks. A printer that does not announce itself will still answer a question put
 * directly to it, so this probes the subnet the machine was last seen on, on the
 * port its protocol uses, with a request that identifies the software.
 *
 * DELIBERATELY NARROW
 *
 * A tool that sweeps a network is a tool that can be mistaken for an attack, so
 * everything here is bounded on purpose and none of it is configurable:
 *
 *   - only the /24 the machine was ALREADY configured on. A re-leased address is
 *     almost always in the same subnet; wandering further would be a network
 *     scan rather than looking for one's own printer.
 *   - only RFC1918 / link-local, enforced by the caller's existing host guard.
 *   - only ports Khayt already speaks to, one request each, short timeout.
 *   - only when a configured machine is offline and mDNS has already failed.
 *
 * Pure. Candidate addresses and response identification are decided here; the
 * caller does the fetching, so this is testable without a network.
 */

/**
 * How to recognise each protocol, and what to learn from it.
 *
 * `path` is unauthenticated on every one of these — identification must work
 * before credentials are known, or a moved printer with a password would stay
 * lost, which is the case that needs help most.
 */
const PROBES = {
  moonraker: {
    port: 7125,
    path: '/printer/info',
    // Verified against a Snapmaker U1 running Moonraker 1.5.2:
    //   {"result":{"state":"ready","hostname":"lava","software_version":"1.5.2.13…"}}
    identify(status, body) {
      const r = body && body.result;
      if (status !== 200 || !r || typeof r !== 'object') return null;
      if (typeof r.software_version !== 'string' && typeof r.state !== 'string') return null;
      return { name: typeof r.hostname === 'string' ? r.hostname : '', firmware: r.software_version || '' };
    },
    // A second, optional request. `cpu_info.serial_number` is the board's own id
    // and does not move with a lease, so learning it turns the NEXT relocation
    // from "the only printer this could be" into "this is the machine" — which
    // printer-relocate applies without asking rather than merely proposing.
    identityPath: '/machine/system_info',
    identitySerial(body) {
      const info = body && body.result && body.result.system_info;
      const cpu = info && info.cpu_info;
      const s = cpu && cpu.serial_number;
      return typeof s === 'string' && s.trim() ? s.trim() : '';
    },
  },
  octoprint: {
    port: 80,
    path: '/api/version',
    // OctoPrint answers 403 to an unauthenticated /api/version rather than 404.
    // The refusal is the identification: only OctoPrint refuses in that shape at
    // that path, and a printer we cannot yet authenticate to is still a printer
    // we have found.
    //
    // MOONRAKER IMPERSONATES OCTOPRINT, and caught this on the first live run.
    // It ships a compatibility shim so OctoPrint clients keep working, and the
    // Snapmaker U1 answered on port 80 with:
    //
    //   {"server":"1.5.0","api":"0.1","text":"OctoPrint (Moonraker 1.5.2)"}
    //
    // — so one printer was reported twice, as a Moonraker AND as an OctoPrint.
    // For a Moonraker machine that is harmless noise; for an OctoPrint machine it
    // is a wrong candidate that could win a relocation. The shim names itself in
    // `text`, so take it at its word.
    identify(status, body) {
      if (status === 200 && body && typeof body.server === 'string') {
        if (/moonraker/i.test(String(body.text || ''))) return null;   // not an OctoPrint
        return { name: '', firmware: body.server };
      }
      if (status === 403 || status === 401) return { name: '', firmware: '' };
      return null;
    },
  },
  prusalink: {
    port: 80,
    path: '/api/v1/status',
    // Every /api/v1/* endpoint answers 401 without credentials — Prusa's own
    // firmware tests assert it. So a 401 here is a PrusaLink, and a 200 is a
    // PrusaLink that happens not to be protected.
    identify(status, body) {
      if (status === 401) return { name: '', firmware: '' };
      if (status === 200 && body && body.printer && typeof body.printer.state === 'string') {
        return { name: '', firmware: '' };
      }
      return null;
    },
  },
  duet: {
    port: 80,
    path: '/rr_model?key=boards&flags=d2',
    // RepRapFirmware standalone. A password-protected board answers 401, which
    // is still a Duet. (A Duet 3 with an SBC serves /machine/* instead and is
    // probed separately by the caller when this finds nothing.)
    identify(status, body) {
      if (status === 401) return { name: '', firmware: '' };
      const r = body && body.result;
      if (status === 200 && Array.isArray(r)) {
        const b = r[0] || {};
        return { name: b.name || '', firmware: b.firmwareVersion || '' };
      }
      return null;
    },
  },
};

/** Split a host into its first three octets, or null if it is not a dotted IPv4. */
function subnetOf(host) {
  const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(String(host || '').trim());
  if (!m) return null;
  const parts = m.slice(1, 5).map(Number);
  if (parts.some((n) => n < 0 || n > 255)) return null;
  return { prefix: parts.slice(0, 3).join('.'), last: parts[3] };
}

/**
 * Addresses to try for a machine that has stopped answering.
 *
 * Ordered outward from where it used to be, because a re-leased address is
 * usually near the old one and finding it in the first fifty probes rather than
 * the last is the difference between a scan that feels instant and one that
 * feels like something is wrong.
 *
 * The old address is excluded: it has already been polled and did not answer.
 *
 * @param {string} lastKnownHost  e.g. "192.168.68.77"
 * @param {object} [opts] {limit}
 * @returns {string[]}
 */
function candidateHosts(lastKnownHost, opts = {}) {
  const net = subnetOf(lastKnownHost);
  if (!net) return [];
  const limit = Number.isFinite(opts.limit) ? Math.max(0, opts.limit) : 254;
  const out = [];
  const seen = new Set([net.last]);
  for (let d = 1; d < 255 && out.length < limit; d += 1) {
    for (const n of [net.last - d, net.last + d]) {
      if (n < 1 || n > 254 || seen.has(n)) continue;
      seen.add(n);
      out.push(`${net.prefix}.${n}`);
      if (out.length >= limit) break;
    }
  }
  return out;
}

/**
 * Turn one probe response into a discovery-shaped record, or null.
 *
 * The shape matches `lib/printer-discovery.js` so `planRelocations` cannot tell
 * the two apart — a swept printer and an announced one are the same evidence.
 */
function identifyResponse(type, host, status, body) {
  const probe = PROBES[String(type || '').toLowerCase()];
  if (!probe) return null;
  let found = null;
  try { found = probe.identify(status, body); } catch (e) { return null; }
  if (!found) return null;
  return {
    id: `sweep|${type}|${host}`,
    name: found.name || '',
    vendor: '',
    model: '',
    label: found.name || host,
    host,
    port: probe.port,
    advertisedPort: 0,
    serial: '',
    firmware: found.firmware || '',
    connection: String(type).toLowerCase(),
    catalogId: null,
    linkMode: '',
    // So a UI can say where this came from. An announced printer is a printer
    // that wants to be found; a swept one is a printer we went looking for, and
    // the difference is worth keeping.
    via: 'sweep',
    raw: {},
  };
}

/** The optional second request that learns a durable identity, if the protocol has one. */
function identityProbeFor(type) {
  const p = PROBES[String(type || '').toLowerCase()];
  return p && p.identityPath ? p.identityPath : null;
}

/** Read a durable serial out of that second response. '' when there is none. */
function readIdentitySerial(type, body) {
  const p = PROBES[String(type || '').toLowerCase()];
  if (!p || typeof p.identitySerial !== 'function') return '';
  try { return p.identitySerial(body) || ''; } catch (e) { return ''; }
}

/**
 * Hardware addresses out of the operating system's neighbour table.
 *
 * WHY BOTHER, GIVEN THE SERIAL ABOVE
 *
 * Because only one protocol here has a serial. Moonraker offers
 * `cpu_info.serial_number`; probed live, OctoPrint, PrusaLink and Duet all
 * returned nothing durable. A MAC belongs to the network interface rather than
 * to the software, so it identifies a printer whose protocol will not.
 *
 * It is also the better answer where both exist: `printer-relocate.js` applies a
 * SERIAL match without asking and only proposes a MODEL one, and a MAC is
 * identity in the same sense — a DHCP lease changes the address and cannot
 * change the interface it was handed to.
 *
 * WHY IT DOES NOT REPLACE THE SWEEP
 *
 * The neighbour table is not a directory of the network. It holds hosts this
 * machine has recently spoken to, and nothing else. Measured on the bench LAN
 * while looking for exactly this printer:
 *
 *     256 entries, 230 of them "(incomplete)"  →  26 usable
 *
 * So the sweep is what makes the MAC available, not an alternative to it: probe
 * the subnet, the replies populate the table, then read it. And a MAC can only
 * match a machine whose MAC was recorded while it still worked — it repairs a
 * printer that moved, it cannot find one never seen.
 *
 * ONE PARSER, NOT THREE
 *
 * macOS, Linux `arp -a`, Linux `ip neigh` and Windows `arp -a` print four
 * different layouts, and every one of them puts an IPv4 address and a hardware
 * address on the same line. Matching that pair is enough, and it avoids owning a
 * platform-specific parser for each — the kind that breaks on the platform
 * nobody develops on.
 *
 *   macOS    ? (192.168.68.56) at 40:fd:f3:d9:2a:4c on en0 ifscope [ethernet]
 *   Linux    ? (192.168.68.56) at 40:fd:f3:d9:2a:4c [ether] on eth0
 *   ip neigh 192.168.68.56 dev eth0 lladdr 40:fd:f3:d9:2a:4c REACHABLE
 *   Windows  192.168.68.56        40-fd-f3-d9-2a-4c     dynamic
 */
const IPV4_RE = /\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b/;
const MAC_RE = /\b([0-9a-f]{1,2}(?:[:-][0-9a-f]{1,2}){5})\b/i;

/** Normalise to lower-case colon form, zero-padded, so two spellings compare equal. */
function normalizeMac(value) {
  const m = MAC_RE.exec(String(value || ''));
  if (!m) return '';
  const parts = m[1].split(/[:-]/).map((p) => p.toLowerCase().padStart(2, '0'));
  // All-zero and broadcast are placeholders, not identities.
  const joined = parts.join(':');
  if (joined === '00:00:00:00:00:00' || joined === 'ff:ff:ff:ff:ff:ff') return '';
  return joined;
}

/**
 * Parse whatever the platform's neighbour-table command printed.
 *
 * @returns {Object<string,string>} ip → mac, skipping unresolved entries
 */
function parseArpTable(text) {
  const out = {};
  for (const line of String(text || '').split(/\r?\n/)) {
    if (/incomplete|no entry|failed/i.test(line)) continue;
    const ip = IPV4_RE.exec(line);
    if (!ip) continue;
    const mac = normalizeMac(line.slice(ip.index + ip[1].length));
    if (mac) out[ip[1]] = mac;
  }
  return out;
}

/** Attach hardware addresses to swept records, where the table knows them. */
function withMacs(found, arpTable) {
  const table = arpTable || {};
  return (Array.isArray(found) ? found : []).map((f) => (
    table[f.host] ? { ...f, mac: table[f.host] } : f
  ));
}

/** Connection types this can look for. */
const SWEEPABLE = Object.keys(PROBES);

const api = { PROBES, SWEEPABLE, subnetOf, candidateHosts, identifyResponse, identityProbeFor, readIdentitySerial,
  normalizeMac, parseArpTable, withMacs };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPrinterSweep = api;
