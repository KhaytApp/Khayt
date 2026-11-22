'use strict';

/**
 * Finding printers on the network: mDNS/Bonjour browsing and the SDCP UDP sweep.
 *
 * Lifted out of main.js unchanged. Discovery is a self-contained concern — it
 * listens, collects candidates and answers "what is out there" — and it is not
 * how any printer is then TALKED to, which lives in the per-protocol adapters.
 *
 * Three dependencies: `app` (to stop browsing before quit), `ipcMain`, and the
 * SDCP client whose UDP broadcast finds resin machines.
 *
 * RETURNS the two functions the rest of the main process still calls.
 *
 * That is not decoration, and it is the thing an extraction is easy to get
 * wrong: counting what a section CONSUMES says nothing about what it PROVIDES.
 * This section reads only three names from main.js, which made it look like the
 * safest thing in the file — while `scanForPrinters` and `sweepForPrinters` were
 * called from four places elsewhere, including the automatic poll. Moving them
 * into a closure and stopping there would have left those four sites throwing
 * ReferenceError the first time a shop looked for a printer, with `node --check`
 * perfectly happy about it.
 */

function registerPrinterDiscovery({ app, ipcMain, sdcpClient }) {
  // ── Printer discovery (mDNS) ────────────────────────────────────────────────
  // Owner-initiated LAN scan: multicast a DNS-SD query for the printer service types and
  // collect answers for a few seconds. Nothing leaves the local network, nothing runs on a
  // timer, and nothing is written to the store — the renderer shows candidates and the
  // owner picks. See lib/mdns.js for why this is hand-rolled rather than a dependency.
  /**
   * One LAN scan, shared by "add a printer" and "find the one that moved".
   *
   * Extracted rather than copied: both callers need the same retransmit schedule
   * and the same multicast membership, and a second copy would drift from this one
   * the first time either was tuned.
   */
  function scanForPrinters(timeoutMs) {
    const dgram = require('dgram');
    const Mdns = require('../mdns.js');
    const Discovery = require('../printer-discovery.js');
    // Bounded so a wedged socket can't hold the dialog open indefinitely.
    const window_ = Math.max(2000, Math.min(15000, Number(timeoutMs) || 6000));

    return new Promise((resolve) => {
      let socket;
      let settled = false;
      const records = [];
      const finish = (result) => {
        if (settled) return;
        settled = true;
        try { socket && socket.close(); } catch { /* already closed */ }
        resolve(result);
      };
      try {
        socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
      } catch (e) {
        return finish({ ok: false, error: 'socket_failed', detail: String(e.message || e) });
      }
      socket.on('error', (e) => finish({ ok: false, error: 'socket_error', detail: String(e.message || e) }));
      socket.on('message', (msg) => {
        try { records.push(...Mdns.decodeMessage(msg)); } catch { /* ignore junk */ }
      });
      socket.bind(Mdns.MDNS_PORT, () => {
        // Joining the group is what makes this reliable: some responders (the Prusa CORE
        // One among them) only ever answer by multicast and ignore the unicast-response
        // bit, so a query-and-listen-on-our-own-port scan silently misses them.
        try { socket.addMembership(Mdns.MDNS_ADDR); } catch { /* not fatal */ }
        const query = Mdns.encodeQuery(Discovery.SERVICE_NAMES);
        const send = () => {
          try { socket.send(query, 0, query.length, Mdns.MDNS_PORT, Mdns.MDNS_ADDR); } catch { /* closed */ }
        };
        // Retransmit: responders suppress answers they have already given recently, so a
        // single query can miss a printer that replied moments ago. Observed on real
        // hardware — one query found the Snapmaker but not the Prusa.
        [0, 900, 2200, 4000].filter(d => d < window_).forEach(d => setTimeout(send, d));
        setTimeout(async () => {
          let printers = [];
          try { printers = Discovery.discoverFromRecords(records); } catch { printers = []; }
          // Elegoo resin printers do not speak mDNS at all — SDCP discovery is a
          // UDP broadcast on its own port. Run alongside rather than instead, and
          // never let it fail the scan that already worked.
          try { printers = printers.concat(await scanForSdcp(Math.min(3000, window_))); } catch { /* mDNS results stand */ }
          finish({ ok: true, printers });
        }, window_);
      });
    });
  }

  /**
   * Shout on the LAN and see which Elegoo mainboards answer.
   *
   * A different mechanism from the mDNS scan above and therefore a different
   * socket: SDCP discovery is a plain UDP broadcast of one magic string, and the
   * mainboard replies with a JSON blob naming itself. See lib/sdcp.js.
   *
   * The reply carries the MAINBOARD ID, which is the part that makes this worth
   * having rather than a nicety — it is the printer's address on the protocol,
   * every frame is topic-addressed by it, and it is printed nowhere on the machine.
   * Without a scan a shop cannot configure one of these at all.
   *
   * Parsing is lib/sdcp-client.js's `collectDiscovered`, which is tested; this
   * function is only the socket. Answers are mapped into the same shape the mDNS
   * results use so the picker in the machine dialog needs no special case.
   */
  function scanForSdcp(timeoutMs) {
    const dgram = require('dgram');
    const sdcp = require('../sdcp.js');
    const window_ = Math.max(1000, Math.min(8000, Number(timeoutMs) || 3000));
    return new Promise((resolve) => {
      const replies = [];
      let socket;
      let settled = false;
      const finish = () => {
        if (settled) return;
        settled = true;
        try { socket && socket.close(); } catch { /* already closed */ }
        let found = [];
        try { found = sdcpClient.collectDiscovered(replies); } catch { found = []; }
        resolve(found.map((f) => ({
          id: `sdcp|${f.mainboardId}`,
          name: f.name || f.model || 'Elegoo printer',
          vendor: f.brand || 'ELEGOO',
          model: f.model || '',
          label: f.name || '',
          host: f.ip,
          port: sdcp.WEBSOCKET_PORT,
          advertisedPort: sdcp.WEBSOCKET_PORT,
          // Carried as `serial` because that is the field the machine dialog
          // already binds and saves, and on this protocol it is the same idea.
          serial: f.mainboardId,
          firmware: f.firmwareVersion || '',
          connection: 'sdcp',
          catalogId: null,
          linkMode: '',
          raw: f,
        })));
      };
      try {
        socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
      } catch { return resolve([]); }
      socket.on('error', finish);
      socket.on('message', (msg) => { replies.push(msg); });
      socket.bind(() => {
        try { socket.setBroadcast(true); } catch { /* not fatal */ }
        const magic = Buffer.from(sdcp.DISCOVERY_MAGIC);
        const send = () => {
          try { socket.send(magic, 0, magic.length, sdcp.DISCOVERY_PORT, '255.255.255.255'); } catch { /* closed */ }
        };
        // Retransmitted for the same reason the mDNS query is: a single datagram
        // is lost often enough on a busy wireless network to matter.
        [0, 700, 1600].filter((d) => d < window_).forEach((d) => setTimeout(send, d));
        setTimeout(finish, window_);
      });
    });
  }

  ipcMain.handle('hub:discover-printers', async (_e, { timeoutMs } = {}) => scanForPrinters(timeoutMs));

  /**
   * Find a configured printer that changed address.
   *
   * A DHCP lease moves overnight and Khayt goes on polling a host that answers
   * nothing. The owner is shown "offline" — the same words as a printer that is
   * switched off, and a completely different fix. What makes it worth an endpoint
   * rather than a shrug is that some of what polling does cannot be caught up on:
   * captureCompletion freezes a job's real filament and duration on the edge out
   * of printing, so every print that finishes against a stale address is a
   * measurement that no longer exists.
   *
   * Writes NOTHING, exactly like discovery above: this returns proposals and the
   * renderer saves whatever the owner accepts. That matters more here than there,
   * because the field being rewritten is where the app will later send print
   * commands — so a wrong guess applied silently would send a job to the wrong
   * machine. lib/printer-relocate.js only marks a move as applicable without
   * asking when the printer announced a serial that was already recorded for it.
   */
  /**
   * Ask the subnet directly for a printer that is not announcing itself.
   *
   * mDNS finds printers that want to be found. The Snapmaker U1 does not: browsed
   * on its own LAN while printing, `_moonraker._tcp` and `_octoprint._tcp` both
   * returned nothing, while mDNS itself happily turned up a NAS and an HP laser.
   * So `scanForPrinters` handed `planRelocations` an empty list, and the one
   * printer the relocation feature was written for could never be relocated.
   *
   * Bounded on purpose — see lib/printer-sweep.js. Only the /24 the machine was
   * already on, only ports Khayt speaks, one short request each, and every target
   * still passes `isAllowedPrinterHost`, so this cannot be pointed off the LAN.
   */
  async function sweepForPrinters(machineList, timeoutMs) {
    const Sweep = require('../printer-sweep.js');
    const list = Array.isArray(machineList) ? machineList : [];
    const budget = Math.max(1500, Math.min(20000, Number(timeoutMs) || 8000));
    const perRequest = 1200;
    const CONCURRENCY = 24;

    // One sweep per subnet, however many machines live on it.
    const subnets = new Map();
    for (const m of list) {
      const host = m && m.printerApi && m.printerApi.host;
      const type = String((m && m.printerApi && m.printerApi.type) || '').toLowerCase();
      if (!host || !Sweep.PROBES[type]) continue;
      const net = Sweep.subnetOf(String(host).replace(/^\w+:\/\//, '').split(':')[0]);
      if (!net) continue;
      const key = `${net.prefix}|${type}`;
      if (!subnets.has(key)) subnets.set(key, { host, type });
    }
    if (!subnets.size) return [];

    const deadline = Date.now() + budget;
    const found = [];

    const probeOne = async (type, host) => {
      if (!isAllowedPrinterHost(host)) return null;
      const probe = Sweep.PROBES[type];
      try {
        const res = await fetch(`http://${host}:${probe.port}${probe.path}`, {
          redirect: 'manual', signal: AbortSignal.timeout(perRequest),
        });
        let body = null;
        try { body = await res.json(); } catch (e) { /* status alone may identify */ }
        return Sweep.identifyResponse(type, host, res.status, body);
      } catch (e) { return null; }
    };

    for (const { host, type } of subnets.values()) {
      const hosts = Sweep.candidateHosts(String(host).replace(/^\w+:\/\//, '').split(':')[0]);
      for (let i = 0; i < hosts.length && Date.now() < deadline; i += CONCURRENCY) {
        const batch = hosts.slice(i, i + CONCURRENCY);
        const hits = (await Promise.all(batch.map((h) => probeOne(type, h)))).filter(Boolean);
        found.push(...hits);
      }
    }

    // A durable identity, taken while the printer is answering — the only moment
    // one is available. Moonraker carries a board serial; the hardware address
    // covers the protocols that carry nothing.
    for (const f of found) {
      const path = Sweep.identityProbeFor(f.connection);
      if (!path) continue;
      try {
        const res = await fetch(`http://${f.host}:${f.port}${path}`, { signal: AbortSignal.timeout(perRequest) });
        f.serial = Sweep.readIdentitySerial(f.connection, await res.json()) || '';
      } catch (e) { /* identity is a bonus, never a requirement */ }
    }
    return Sweep.withMacs(found, await readNeighbourTable());
  }

  /**
   * The operating system's neighbour table, for hardware addresses.
   *
   * Four platforms print four layouts and lib/printer-sweep.js parses all of them
   * with one rule, so this only has to pick a command. It runs AFTER the sweep, on
   * purpose: the table holds hosts this computer has spoken to recently and
   * nothing else — measured on the bench, 230 of 256 entries were "(incomplete)"
   * — so the probes are what put the printer in it.
   */
  function readNeighbourTable() {
    const { execFile } = require('child_process');
    const cmd = process.platform === 'win32' ? ['arp', ['-a']] : ['arp', ['-an']];
    return new Promise((resolve) => {
      try {
        execFile(cmd[0], cmd[1], { timeout: 2500, windowsHide: true }, (err, stdout) => {
          if (err && !stdout) return resolve({});
          try { resolve(require('../printer-sweep.js').parseArpTable(stdout || '')); }
          catch (e) { resolve({}); }
        });
      } catch (e) { resolve({}); }
    });
  }

  return { scanForPrinters, sweepForPrinters };
}

module.exports = { registerPrinterDiscovery };
