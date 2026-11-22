'use strict';
/**
 * Discovery on Windows/Linux: the LAN server says it is here as `_khayt._tcp`
 * over multicast DNS, as the native Mac's Bonjour advert does
 * (docs/LAN_API.md "Discovery — _khayt._tcp"), so a phone or the slicer
 * plugin is shown a list of shops instead of an empty address field.
 *
 *   instance   the shop's own name (settings.shopName), cut to 63 BYTES, "Khayt" if empty
 *   TXT v      the LAN API version, "1"
 *   TXT store  absent: this server does not implement GET /api/store
 *              (the Mac sends store=1 because it does)
 *
 * ONLY WHILE THE SERVER RUNS ON THE LAN: started when the server starts bound
 * to the network, stopped (with a goodbye, TTL 0) when it stops. A
 * loopback-only server is never advertised: a client that found it could
 * never connect to it.
 *
 * The PIN is deliberately not advertised (it can change while the server is
 * up). Nothing here is private: /intake already serves the shop's name.
 *
 * The wire format is lib/mdns.js (pure, tested); this is the small socket
 * part. A socket that cannot bind (another responder holds 5353 without
 * SO_REUSEADDR) costs the advert, never the LAN server.
 *
 * Main process only (node:dgram).
 */
const Mdns = require('../mdns.js');

const SERVICE = '_khayt._tcp';
const SERVICE_FQDN = '_khayt._tcp.local';
const META_FQDN = '_services._dns-sd._udp.local';
const TTL = 4500;

/** What a phone sees in the list: the shop's own name, cut by BYTES to 63, never splitting a character. */
function advertisedName(store) {
  const raw = store && store.settings && typeof store.settings.shopName === 'string' ? store.settings.shopName : '';
  const trimmed = raw.trim();
  if (!trimmed) return 'Khayt';
  const bytes = Buffer.from(trimmed, 'utf8');
  if (bytes.length <= 63) return trimmed;
  let cut = bytes.subarray(0, 63);
  // Walk back until what is left is whole characters again.
  while (cut.length && Buffer.from(cut.toString('utf8'), 'utf8').length !== cut.length) cut = cut.subarray(0, cut.length - 1);
  return cut.toString('utf8') || 'Khayt';
}

/** A host label of our own, so the advert never claims the OS's own `<hostname>.local`. */
function hostLabel(hostname) {
  const base = String(hostname || '').split('.')[0].replace(/[^A-Za-z0-9-]/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
  return (base || 'computer') + '-khayt';
}

/** A private LAN address (RFC 1918). Not CGNAT/Tailscale's 100.64/10, not public. */
const isPrivateV4 = (ip) => /^10\./.test(ip) || /^192\.168\./.test(ip) || /^172\.(1[6-9]|2\d|3[01])\./.test(ip);
/** Interfaces that are never the shop's Wi-Fi: containers, VMs, VPNs. */
const VIRTUAL_IFACE = /^(docker|br-|veth|virbr|vmnet|vboxnet|tun|tap|utun|wg|tailscale|zt|ham)/i;

/** The IPv4 addresses a phone on the Wi-Fi can reach: private, on a real interface (review). */
function lanIPv4(ifaces) {
  const out = [];
  for (const [name, list] of Object.entries(ifaces || {})) {
    if (VIRTUAL_IFACE.test(name)) continue;
    for (const a of list || []) {
      if (a && (a.family === 'IPv4' || a.family === 4) && !a.internal && isPrivateV4(a.address)) out.push(a.address);
    }
  }
  return [...new Set(out)].slice(0, 8);
}

/**
 * @param {object} o
 * @param {function} o.createSocket   () => dgram socket (udp4, reuseAddr)
 * @param {function} o.interfaces     () => os.networkInterfaces()
 * @param {function} o.hostname       () => os.hostname()
 * @param {function} [o.setTimeout]
 * @param {function} [o.now]          ms, for the answer throttle
 */
function createLanAdvertiser({ createSocket, interfaces, hostname, setTimeout: later = setTimeout, now = Date.now }) {
  let sock = null;
  let current = null;    // { instance, host, port, ipv4 }
  let lastAnswer = 0;
  let timers = [];

  const packet = (ttl) => Buffer.from(Mdns.encodeAdvertisement({
    instance: current.instance, service: SERVICE, host: current.host, port: current.port,
    txt: { v: '1' }, ipv4: current.ipv4, ttl,
  }));
  const sendTo = (s, buf, done) => {
    try { s.send(buf, 0, buf.length, Mdns.MDNS_PORT, Mdns.MDNS_ADDR, () => { if (done) done(); }); }
    catch (_) { if (done) done(); }
  };

  /** Is this query about us? */
  function asksForUs(questions) {
    if (!current) return false;
    const inst = `${current.instance}.${SERVICE_FQDN}`.toLowerCase();
    const host = `${current.host}.local`.toLowerCase();
    return questions.some((q) => q.name === SERVICE_FQDN || q.name === META_FQDN || q.name === inst || q.name === host);
  }

  /**
   * Start advertising, or restart with new facts. `bindLan`: the server's own
   * binding; anything but the network ('lan'/'all') advertises nothing.
   * Returns whether an advert was started.
   */
  function start({ store, port, bindLan }) {
    stop();
    if (bindLan !== 'lan' && bindLan !== 'all') return false;
    const ipv4 = lanIPv4(interfaces());
    if (!ipv4.length) return false;
    current = { instance: advertisedName(store), host: hostLabel(hostname()), port, ipv4 };
    let s;
    try { s = createSocket(); } catch (_) { current = null; return false; }
    sock = s;
    s.on('error', () => { if (sock === s) { try { s.close(); } catch (_) { /* gone */ } sock = null; } });
    s.on('message', (msg) => {
      if (sock !== s || !current) return;
      if (!asksForUs(Mdns.decodeQuestions(msg))) return;
      // One answer a second at most, whatever is asked: a storm costs nothing.
      const t = now();
      if (t - lastAnswer < 1000) return;
      lastAnswer = t;
      sendTo(s, packet(TTL));
    });
    try {
      s.bind(Mdns.MDNS_PORT, () => {
        if (sock !== s) return;
        try { s.addMembership(Mdns.MDNS_ADDR); } catch (_) { /* answers still go out */ }
        try { s.setMulticastTTL(255); } catch (_) { /* default */ }
        // Announced twice, a second apart (RFC 6762 §8.3).
        sendTo(s, packet(TTL));
        const t = later(() => { if (sock === s && current) sendTo(s, packet(TTL)); }, 1000);
        if (t && typeof t.unref === 'function') t.unref();
        timers.push(t);
      });
    } catch (_) { sock = null; current = null; return false; }
    return true;
  }

  /** Stop: say goodbye (TTL 0) so clients drop us at once, then close. */
  function stop() {
    for (const t of timers) { try { clearTimeout(t); } catch (_) { /* fired */ } }
    timers = [];
    const s = sock;
    const was = current;
    sock = null;
    current = null;
    if (!s) return;
    if (was) {
      current = was;
      const bye = packet(0);
      current = null;
      sendTo(s, bye, () => { try { s.close(); } catch (_) { /* gone */ } });
    } else {
      try { s.close(); } catch (_) { /* gone */ }
    }
  }

  const advertising = () => (sock && current ? { instance: current.instance, host: current.host, port: current.port } : null);

  return { start, stop, advertising };
}

module.exports = { createLanAdvertiser, advertisedName, hostLabel, lanIPv4, SERVICE, SERVICE_FQDN };
