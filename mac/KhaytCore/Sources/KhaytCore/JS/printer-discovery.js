'use strict';
/**
 * Turn raw mDNS records into "here is a printer you can add", so the owner never types an
 * IP address. Pure: the socket work lives in main.js and hands its records here.
 *
 * The service list and the TXT keys below are what real hardware actually advertises —
 * verified on a Prusa CORE One (_prusalink._tcp) and a Snapmaker U1 (_snapmaker._tcp),
 * not taken from documentation.
 */
(function () {
  let catalog = null;
  try { catalog = require('./printer-catalog.js'); } catch { /* renderer supplies it */ }

  /**
   * Service types worth asking about. `connection` is the Khayt printerApi type to
   * pre-select; null means Khayt can identify the printer but cannot talk to it yet, and
   * the UI says so rather than pretending.
   */
  const SERVICES = [
    { service: '_prusalink._tcp.local', vendor: 'Prusa',      connection: 'prusalink' },
    { service: '_octoprint._tcp.local', vendor: null,         connection: 'octoprint' },
    { service: '_moonraker._tcp.local', vendor: null,         connection: 'moonraker' },
    // Snapmaker's U1 runs Klipper and exposes a STANDARD, unauthenticated Moonraker API
    // — verified against U1 firmware 1.5.1: /server/info reports klippy_connected, and
    // Khayt's existing moonraker adapter query returns real print_stats. The service
    // advertises its MQTT port (1884), which is NOT where the HTTP API lives, so the
    // connection port is overridden to Moonraker's own.
    { service: '_snapmaker._tcp.local', vendor: 'Snapmaker',  connection: 'moonraker', connectionPort: 7125 },
    { service: '_bambulab._tcp.local',  vendor: 'Bambu Lab',  connection: 'bambu' },
  ];

  const SERVICE_NAMES = SERVICES.map(s => s.service);

  /** TXT keys different vendors use for the same idea. */
  const TXT_MODEL = ['machine_type', 'model', 'device_model', 'MODEL', 'ty'];
  const TXT_SERIAL = ['sn', 'serial', 'serial_number', 'SN'];
  const TXT_VERSION = ['version', 'fw', 'firmware', 'sw_ver'];
  const TXT_NAME = ['device_name', 'name', 'hostname'];

  function pick(txt, keys) {
    for (const k of keys) {
      if (txt && txt[k]) return String(txt[k]);
    }
    return '';
  }

  /**
   * Collapse a flat record list into one entry per service instance, merging the PTR
   * (which instances exist), SRV (host + port), TXT (metadata) and A (address) records
   * that arrive in separate packets.
   */
  function collectDevices(records) {
    const instances = new Map();  // instance name → partial device
    const addresses = new Map();  // hostname → ipv4

    const ensure = (instance) => {
      if (!instances.has(instance)) instances.set(instance, { instance, txt: {} });
      return instances.get(instance);
    };

    for (const r of (records || [])) {
      if (!r || !r.name) continue;
      if (r.type === 1 && r.a) addresses.set(r.name.toLowerCase(), r.a);
      if (r.type === 12 && r.ptr) { ensure(r.ptr).service = r.name; }
      if (r.type === 16 && r.txt) { Object.assign(ensure(r.name).txt, r.txt); }
      if (r.type === 33 && r.srv) {
        const d = ensure(r.name);
        d.port = r.srv.port;
        d.target = r.srv.target;
      }
    }

    const out = [];
    for (const d of instances.values()) {
      // A device is only useful if we can reach it. Prefer the TXT-advertised address
      // (the Snapmaker publishes ip=…), then the resolved A record for its SRV target.
      const host = d.txt.ip || addresses.get(String(d.target || '').toLowerCase()) || d.target || '';
      if (!host) continue;
      // The service may be known from the PTR, or inferred from the instance suffix when
      // only SRV/TXT arrived (responders are not obliged to repeat the PTR).
      const service = d.service
        || SERVICE_NAMES.find(s => String(d.instance).toLowerCase().endsWith(s)) || '';
      out.push({ ...d, host, service });
    }
    return out;
  }

  /** The label before the service suffix: "U1._snapmaker._tcp.local" → "U1". */
  function instanceLabel(instance) {
    const s = String(instance || '');
    const cut = s.indexOf('._');
    return cut > 0 ? s.slice(0, cut) : s;
  }

  /**
   * Build the record the "add machine" dialog consumes. Everything is a SUGGESTION the
   * owner confirms — discovery never silently writes a machine.
   */
  function toDiscoveredPrinter(device, opts) {
    if (!device || !device.host) return null;
    // Only services we actually asked about. We listen on the multicast group, so every
    // announcement on the LAN arrives here — without this filter a "find my printers"
    // scan happily lists the owner's lightbulbs, speakers and TV. Observed, not theorised:
    // a Philips Hue bridge showed up as a printer during live testing.
    const def = SERVICES.find(s => s.service === device.service);
    if (!def) return null;
    const txt = device.txt || {};
    const model = pick(txt, TXT_MODEL);
    const label = pick(txt, TXT_NAME) || instanceLabel(device.instance);

    // Match the advertised model against the built-in spec catalog, so bed size, nozzle
    // and power come along for free instead of being typed in.
    const cat = (opts && opts.catalog) || catalog;
    let match = null;
    if (cat && typeof cat.search === 'function') {
      // PrusaLink advertises no model — only a hostname like "prusa-core-one". Split on
      // separators so the catalog's token search can see "prusa core one", and fall back
      // from the advertised model to that hostname.
      for (const q of [model, label]) {
        const query = String(q || '').replace(/[-_.]+/g, ' ').trim();
        if (!query) continue;
        const hits = cat.search(query) || [];
        match = hits.length === 1 ? hits[0]
          : (hits.find(h => norm(h.name) === norm(query)) || null);
        if (match) break;
      }
    }

    return {
      id: `${device.service}|${device.instance}`,
      name: match ? match.name : (model || label),
      vendor: def.vendor || (match ? match.vendor : ''),
      model: model || (match ? match.model : ''),
      label,
      host: device.host,
      // The advertised SRV port is what the service announces, which is not always where
      // the API Khayt speaks actually listens (see Snapmaker above).
      port: def.connectionPort || device.port || 0,
      advertisedPort: device.port || 0,
      serial: pick(txt, TXT_SERIAL),
      firmware: pick(txt, TXT_VERSION),
      // null connection = identified but not controllable; the UI must not offer "connect".
      connection: def.connection || null,
      catalogId: match ? match.id : null,
      // Snapmaker's link_mode tells us whether the printer is bound to the vendor cloud
      // (wan) or reachable locally (lan). In wan mode its local broker is silent, so a
      // status adapter would connect and then sit there receiving nothing.
      linkMode: txt.link_mode || '',
      raw: txt,
    };
  }

  function norm(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, ''); }

  /** Full pipeline: raw records → deduped, sorted, addable printers. */
  function discoverFromRecords(records, opts) {
    const seen = new Set();
    const out = [];
    for (const device of collectDevices(records)) {
      const p = toDiscoveredPrinter(device, opts);
      if (!p) continue;
      const key = p.serial ? 'sn:' + p.serial : 'host:' + p.host + ':' + p.port;
      if (seen.has(key)) continue;  // one printer answering on two services
      seen.add(key);
      out.push(p);
    }
    return out.sort((a, b) => String(a.name).localeCompare(String(b.name)));
  }

  const api = {
    SERVICES, SERVICE_NAMES,
    collectDevices, toDiscoveredPrinter, discoverFromRecords, instanceLabel,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytPrinterDiscovery = api;
})();
