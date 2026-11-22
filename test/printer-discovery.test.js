const { test } = require('node:test');
const assert = require('node:assert/strict');
const M = require('../lib/mdns.js');
const D = require('../lib/printer-discovery.js');

// Real mDNS packets captured from a live LAN carrying a Prusa CORE One and a Snapmaker
// U1, base64-encoded. Fixtures from actual hardware, not hand-written bytes — the whole
// point is that the parser survives what real responders emit.
const PACKETS = require('./fixtures/mdns-real-printers.json')
  .map(b64 => Buffer.from(b64, 'base64'));

const replay = () => D.discoverFromRecords(PACKETS.flatMap(p => M.decodeMessage(p)));

/* ── codec ──────────────────────────────────────────────────────────────── */

/// Read two big-endian bytes WITHOUT `Buffer.readUInt16BE`.
///
/// The codec returns a plain `Uint8Array` now, because the Mac app runs it in
/// JavaScriptCore where `Buffer` does not exist. Asserting through Buffer's own
/// accessor was testing Node's API as much as the wire format; this reads the
/// bytes, which is the thing that actually has to be right.
const be16 = (bytes, off) => (bytes[off] << 8) | bytes[off + 1];

test('encodeQuery builds a well-formed PTR question', () => {
  const q = M.encodeQuery(['_prusalink._tcp.local']);
  assert.ok(q instanceof Uint8Array, 'the codec must not hand back a Node Buffer');
  assert.equal(be16(q, 4), 1, 'QDCOUNT');
  assert.equal(be16(q, 6), 0, 'no answers in a query');
  assert.ok(Buffer.from(q).includes(Buffer.from('_prusalink')), 'service name present');
  assert.equal(q[q.length - 3], M.TYPE.PTR);
  assert.equal(be16(q, q.length - 2), 1, 'QCLASS IN, multicast response');
  const qu = M.encodeQuery(['_x._tcp.local'], { unicast: true });
  assert.equal(be16(qu, qu.length - 2), 0x8001, 'QU bit set when asked');
});

/// A Node `Buffer` still has to decode, because `main.js` hands the socket's
/// datagrams straight in — and a plain array has to work too, because that is
/// what crosses from Swift.
test('the decoder takes a Buffer, a Uint8Array or a plain array alike', () => {
  const packet = PACKETS[0];
  const fromBuffer = M.decodeMessage(packet);
  assert.ok(fromBuffer.length > 0, 'the fixture decoded nothing');
  assert.deepEqual(M.decodeMessage(Uint8Array.from(packet)), fromBuffer);
  assert.deepEqual(M.decodeMessage(Array.from(packet)), fromBuffer);
});

test('decodeMessage never throws on malformed or hostile input', () => {
  // These arrive unauthenticated from the local network, so a crash here is a denial of
  // service triggered by any device on the LAN.
  for (const bad of [
    Buffer.alloc(0), Buffer.alloc(5), Buffer.from('not a dns packet'),
    Buffer.from([0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0xc0, 0x0c]),   // pointer loop
    Buffer.from([0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0xff, 0xff]),   // truncated rdata
    Buffer.concat([Buffer.alloc(12), Buffer.from([0x3f]), Buffer.alloc(4)]), // len > buffer
  ]) {
    assert.deepEqual(M.decodeMessage(bad), [], 'malformed input must yield no records');
  }
  assert.deepEqual(M.decodeMessage(null), []);
  assert.deepEqual(M.decodeMessage('nope'), []);
});

test('a backwards-only name pointer rule prevents an infinite loop', () => {
  // A forward/self pointer is the classic mDNS decompression bomb.
  const evil = Buffer.concat([Buffer.alloc(12), Buffer.from([0xc0, 0x0c])]);
  const [name] = M.readName(evil, 12);
  assert.equal(typeof name, 'string', 'returns rather than hanging');
});

/* ── discovery against real hardware output ─────────────────────────────── */

test('REAL PACKETS: both printers on the LAN are discovered', () => {
  const found = replay();
  assert.equal(found.length, 2, `expected 2 printers, got ${found.map(p => p.name).join(', ')}`);
  const [prusa, snap] = found;

  assert.equal(prusa.name, 'Prusa CORE One');
  assert.equal(prusa.host, '192.168.68.70');
  assert.equal(prusa.port, 80);
  assert.equal(prusa.connection, 'prusalink', 'PrusaLink is a type Khayt can drive');
  assert.equal(prusa.catalogId, 'prusa-core-one', 'matched to the spec catalog');

  assert.equal(snap.name, 'Snapmaker U1');
  assert.equal(snap.host, '192.168.68.66');
  assert.equal(snap.serial, '8110026060810400D73X');
  assert.equal(snap.firmware, '1.5.1');
  assert.equal(snap.catalogId, 'snapmaker-u1');
  // The U1 runs Klipper and serves a standard Moonraker API, so Khayt's existing
  // adapter drives it — verified live against firmware 1.5.1.
  assert.equal(snap.connection, 'moonraker');
  assert.equal(snap.port, 7125, 'Moonraker port, NOT the advertised MQTT port');
  assert.equal(snap.advertisedPort, 1884, 'what the service actually announced');
  // link_mode=wan does NOT prevent local control: Moonraker answered while in wan mode.
  assert.equal(snap.linkMode, 'wan');
});

test('PrusaLink advertises no model, so the hostname is matched instead', () => {
  // _prusalink._tcp carries no machine_type TXT — all we get is "prusa-core-one".
  // Without splitting on hyphens the catalog's token search finds nothing.
  const prusa = replay().find(p => p.connection === 'prusalink');
  assert.equal(prusa.model, 'CORE One', 'model recovered from the hostname');
  assert.equal(prusa.vendor, 'Prusa');
});

test('only requested services are returned — a scan must not list the owner’s lightbulbs', () => {
  // Discovery listens on the multicast group, so EVERY announcement on the LAN arrives:
  // during live testing a Philips Hue bridge and a HomeKit accessory were both collected
  // and reported as printers. This is that regression.
  const noise = [
    { name: '_hue._tcp.local', type: 12, ptr: 'Hue Bridge - A726A5._hue._tcp.local' },
    { name: 'Hue Bridge - A726A5._hue._tcp.local', type: 33, srv: { port: 443, target: 'hue.local' } },
    { name: 'hue.local', type: 1, a: '192.168.68.60' },
    { name: '_hap._tcp.local', type: 12, ptr: 'Philips Hue HomeKit._hap._tcp.local' },
    { name: 'Philips Hue HomeKit._hap._tcp.local', type: 33, srv: { port: 8080, target: 'hue.local' } },
    { name: '_airplay._tcp.local', type: 12, ptr: 'Living Room TV._airplay._tcp.local' },
    { name: 'Living Room TV._airplay._tcp.local', type: 33, srv: { port: 7000, target: 'tv.local' } },
    { name: 'tv.local', type: 1, a: '192.168.68.61' },
  ];
  const withNoise = D.discoverFromRecords([
    ...PACKETS.flatMap(p => M.decodeMessage(p)),
    ...noise,
  ]);
  assert.equal(withNoise.length, 2, `non-printers leaked in: ${withNoise.map(p => p.name).join(', ')}`);
  for (const p of withNoise) {
    assert.ok(!/hue|homekit|tv/i.test(p.name), `not a printer: ${p.name}`);
  }
});

test('one printer answering on two services is reported once', () => {
  const recs = PACKETS.flatMap(p => M.decodeMessage(p));
  const dupe = [
    { name: '_octoprint._tcp.local', type: 12, ptr: 'dupe._octoprint._tcp.local' },
    { name: 'dupe._octoprint._tcp.local', type: 33, srv: { port: 80, target: 'x.local' } },
    { name: 'dupe._octoprint._tcp.local', type: 16, txt: { sn: '8110026060810400D73X' } },
    { name: 'x.local', type: 1, a: '192.168.68.99' },
  ];
  // Same serial as the Snapmaker → same physical printer, deduped by serial.
  const found = D.discoverFromRecords([...recs, ...dupe]);
  assert.equal(found.length, 2, 'serial dedupe failed');
});

test('a device with no reachable address is dropped', () => {
  const found = D.discoverFromRecords([
    { name: '_octoprint._tcp.local', type: 12, ptr: 'ghost._octoprint._tcp.local' },
    { name: 'ghost._octoprint._tcp.local', type: 16, txt: { model: 'Ghost' } },
  ]);
  assert.deepEqual(found, [], 'nothing to connect to → not offered');
});

test('the advertised port is not assumed to be the API port', () => {
  // Snapmaker announces its MQTT port (1884); Moonraker listens on 7125. Using the
  // advertised port would produce a machine that can never connect.
  const snap = replay().find(p => p.vendor === 'Snapmaker');
  assert.notEqual(snap.port, snap.advertisedPort);
  // Services with no override still use whatever they advertised.
  const prusa = replay().find(p => p.vendor === 'Prusa');
  assert.equal(prusa.port, prusa.advertisedPort);
});
