'use strict';

/**
 * Minimal Bambu Lab LAN client (main-process, Node-only).
 *
 * Bambu printers expose NO HTTP REST API on the local network — they speak:
 *   • MQTT over TLS on :8883  (status push + commands)   — this file
 *   • FTPS (implicit TLS) on :990  (upload .3mf/.gcode)  — lib/bambu-ftp.js
 *
 * Rather than pull in the `mqtt` package, we hand-roll the tiny slice of
 * MQTT 3.1.1 we need (CONNECT / SUBSCRIBE / PUBLISH / PINGREQ / DISCONNECT),
 * consistent with the codebase's no-SDK approach (see lib/s3.js, VAPID). The
 * wire codec is pure + unit-tested; only fetchBambuStatus()/bambuSendPrint()
 * touch a real TLS socket.
 *
 * Auth: MQTT username is always "bblp"; the password is the printer's LAN
 * "Access Code", shown on the printer screen in the LAN-only Mode area. Topics
 * are scoped by the device serial: device/{serial}/report (subscribe) +
 * /request (publish).
 *
 * TWO SWITCHES, NOT ONE — and the second is the one that is usually off.
 *
 * LAN-only Mode is what most guides tell you to turn on, and it is not enough.
 * Bambu gates the MQTT channel, FTP and the live stream behind a separate
 * **Developer Mode** toggle, in the same settings menu, added because the
 * protocols are unofficial and unsupported. Their own wiki is explicit that this
 * "must be manually enabled on the printer".
 *
 * The failure mode is why this note is here rather than in a doc: with LAN mode
 * on and Developer Mode off, the printer ACCEPTS the TLS connection and the
 * CONNACK, and then never answers. Nothing is refused, so there is no error to
 * report — the poll simply runs out its 8 seconds. Any message that names IP,
 * access code and LAN mode is then listing three things that are all correct.
 *
 * Menu paths and minimum firmware, per Bambu:
 *
 *   X1 / X1C / X1E      Settings → LAN Mode            01.08.03.00
 *   P1P / P1S           Settings → WLAN/Network        01.08.02.00
 *   A1 / A1 mini        Settings → WLAN/Network        01.05.00.00
 *   H2D / P2 series     Settings → LAN Mode            01.01.00.01
 *
 * Developer Mode also takes the printer OFF Bambu Cloud — it is LAN-only by
 * definition, which is worth saying out loud before a shop flips it.
 */

const MQTT_DEFAULT_PORT = 8883;

// ---- pure MQTT 3.1.1 wire codec (no I/O) -----------------------------------

/** Encode the MQTT "Remaining Length" variable-byte integer. */
function encodeRemainingLength(n) {
  if (n < 0) throw new Error('negative length');
  const out = [];
  do {
    let b = n % 128;
    n = Math.floor(n / 128);
    if (n > 0) b |= 0x80;
    out.push(b);
  } while (n > 0);
  return Buffer.from(out);
}

/** Decode a Remaining Length starting at `offset`. → { value, bytes } or null if incomplete. */
function decodeRemainingLength(buf, offset) {
  let multiplier = 1, value = 0, bytes = 0;
  for (;;) {
    if (offset + bytes >= buf.length) return null; // need more data
    const b = buf[offset + bytes];
    value += (b & 0x7f) * multiplier;
    bytes += 1;
    if ((b & 0x80) === 0) break;
    multiplier *= 128;
    if (multiplier > 128 * 128 * 128) throw new Error('malformed remaining length');
  }
  return { value, bytes };
}

/** Length-prefixed UTF-8 string (2-byte big-endian length + bytes). */
function mqttString(s) {
  const b = Buffer.from(String(s), 'utf8');
  const len = Buffer.alloc(2);
  len.writeUInt16BE(b.length, 0);
  return Buffer.concat([len, b]);
}

/** Build a fixed header for a packet given its (type<<4|flags) byte + body. */
function packet(typeFlags, body) {
  return Buffer.concat([Buffer.from([typeFlags]), encodeRemainingLength(body.length), body]);
}

/** CONNECT with username + password, clean session. */
function encodeConnect(clientId, username, password, keepalive = 60) {
  const varHeader = Buffer.concat([
    mqttString('MQTT'),       // protocol name
    Buffer.from([0x04]),      // protocol level 4 (3.1.1)
    Buffer.from([0xc2]),      // flags: username|password|clean-session
    (() => { const k = Buffer.alloc(2); k.writeUInt16BE(keepalive, 0); return k; })(),
  ]);
  const payload = Buffer.concat([mqttString(clientId), mqttString(username), mqttString(password)]);
  return packet(0x10, Buffer.concat([varHeader, payload]));
}

/** SUBSCRIBE to one topic at QoS 0. */
function encodeSubscribe(packetId, topic) {
  const pid = Buffer.alloc(2); pid.writeUInt16BE(packetId, 0);
  const body = Buffer.concat([pid, mqttString(topic), Buffer.from([0x00])]);
  return packet(0x82, body); // SUBSCRIBE requires flags 0010
}

/** PUBLISH at QoS 0 (no packet id). */
function encodePublish(topic, payloadStr) {
  const body = Buffer.concat([mqttString(topic), Buffer.from(String(payloadStr), 'utf8')]);
  return packet(0x30, body);
}

const PINGREQ = Buffer.from([0xc0, 0x00]);
const DISCONNECT = Buffer.from([0xe0, 0x00]);

/**
 * Pull complete MQTT packets out of a rolling buffer.
 * → { packets: [{ type, flags, body }], rest: Buffer } (rest = leftover bytes).
 */
function parsePackets(buf) {
  const packets = [];
  let off = 0;
  while (off < buf.length) {
    const first = buf[off];
    const rl = decodeRemainingLength(buf, off + 1);
    if (!rl) break; // incomplete length field
    const headerLen = 1 + rl.bytes;
    const total = headerLen + rl.value;
    if (off + total > buf.length) break; // body not fully arrived
    packets.push({ type: first >> 4, flags: first & 0x0f, body: buf.slice(off + headerLen, off + total) });
    off += total;
  }
  return { packets, rest: buf.slice(off) };
}

/** Decode a PUBLISH body (QoS 0) → { topic, payload(string) }. */
function decodePublish(body) {
  // A PUBLISH with remaining-length 0 or 1 is malformed but trivially sendable — and
  // tls.connect here uses rejectUnauthorized:false, so ANY host at the printer's IP can
  // send one. readUInt16BE(0) on a 0/1-byte body threw a RangeError straight out of the
  // socket 'data' listener, which main.js's uncaughtException handler then filed as a
  // spurious crash report; finish() never ran, so the poll hung for its full 8s and
  // surfaced the connection timeout (see the Developer Mode note above) instead of a
  // protocol error. Return null and let the caller ignore the packet.
  if (!body || body.length < 2) return null;
  const tlen = Math.min(body.readUInt16BE(0), Math.max(0, body.length - 2));
  const topic = body.slice(2, 2 + tlen).toString('utf8');
  const payload = body.slice(2 + tlen).toString('utf8');
  return { topic, payload };
}

// ---- Bambu report parsing --------------------------------------------------

// The report parsing lives in `lib/bambu-report.js` — the Mac app runs it in
// JavaScriptCore, which cannot load THIS file (Buffer is in its module scope
// from the first line). Required, not copied: two apps disagreeing about
// whether a printer is printing is exactly what a shared module prevents.
const { bambuStateLabel, parseBambuReport } = require('./bambu-report');

// ---- live TLS connection ---------------------------------------------------

/**
 * Connect over MQTT/TLS, run `onReady(send, topics)` once subscribed, and
 * resolve with whatever `onMessage(topic, payload, resolve)` produces. Closes
 * the socket on resolve/reject/timeout. `tls` is injected for testability.
 */
function _withConnection({ host, port, accessCode, serial, timeoutMs = 8000, tls }, onMessage, onReady) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (err, val) => {
      if (settled) return; settled = true;
      clearTimeout(timer);
      try { socket.write(DISCONNECT); } catch { /* ignore */ }
      try { socket.end(); socket.destroy(); } catch { /* ignore */ }
      err ? reject(err) : resolve(val);
    };
    // Naming Developer Mode first is deliberate: a timeout here means the socket
    // opened and the printer said nothing, which is what Developer Mode being off
    // looks like. A wrong access code is refused with a CONNACK, and a wrong IP
    // fails to connect at all — neither of those lands on this line.
    const timer = setTimeout(() => finish(new Error(
      'Bambu did not answer. The printer accepted the connection but sent nothing, which is what happens when '
      + 'Developer Mode is off — LAN-only Mode alone does not open MQTT. Turn on BOTH on the printer '
      + '(Settings → LAN Mode, or WLAN/Network on P1/A1), then check the IP and access code.'
    )), timeoutMs);

    const reportTopic = `device/${serial}/report`;
    const requestTopic = `device/${serial}/request`;
    const socket = tls.connect({ host, port, rejectUnauthorized: false, servername: undefined, timeout: timeoutMs }, () => {
      socket.write(encodeConnect(`khayt-${Math.floor(Date.now() % 1e7).toString(36)}`, 'bblp', String(accessCode || '')));
    });
    socket.on('error', (e) => finish(new Error(`Bambu connection failed: ${e.message}`)));

    let buf = Buffer.alloc(0);
    const send = (b) => socket.write(b);
    socket.on('data', (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      const { packets, rest } = parsePackets(buf);
      buf = rest;
      for (const pk of packets) {
        if (pk.type === 2) { // CONNACK
          const code = pk.body.length >= 2 ? pk.body[1] : 0xff;
          if (code !== 0) return finish(new Error(`Bambu rejected the access code (CONNACK ${code})`));
          send(encodeSubscribe(1, reportTopic));
        } else if (pk.type === 9) { // SUBACK → ready
          try { onReady(send, { reportTopic, requestTopic }); } catch (e) { return finish(e); }
        } else if (pk.type === 3) { // PUBLISH
          // Inside the try: decodePublish is parsing bytes from the network.
          try {
            const decoded = decodePublish(pk.body);
            if (decoded) onMessage(decoded.topic, decoded.payload, (val) => finish(null, val));
          } catch (e) { return finish(e); }
        }
      }
    });
  });
}

/** Poll a Bambu printer's status (one-shot: connect → pushall → first snapshot). */
async function fetchBambuStatus(opts) {
  const tls = opts.tls || require('node:tls');
  return _withConnection({ ...opts, tls },
    (topic, payload, done) => { const s = parseBambuReport(payload); if (s) done(s); },
    (send, { requestTopic }) => {
      send(encodePublish(requestTopic, JSON.stringify({ pushing: { sequence_id: '0', command: 'pushall' } })));
    });
}

/**
 * Tell a Bambu printer to start an already-uploaded file (via FTPS) from its
 * SD/cache. `fileName` is the name on the printer (e.g. "khayt-xxxx.3mf").
 */
async function bambuSendPrint(opts) {
  const tls = opts.tls || require('node:tls');
  const { fileName } = opts;
  const cmd = {
    print: {
      sequence_id: '0', command: 'project_file', param: 'Metadata/plate_1.gcode',
      url: `file:///sdcard/${fileName}`, subtask_name: fileName,
      use_ams: false, timelapse: false, bed_leveling: true, flow_cali: false, vibration_cali: false, layer_inspect: false,
    },
  };
  return _withConnection({ ...opts, tls },
    (topic, payload, done) => {
      // Ack any report after we publish the command.
      try { const o = JSON.parse(payload); if (o && o.print) done({ ok: true, fileName }); } catch { /* ignore */ }
    },
    (send, { requestTopic }) => {
      send(encodePublish(requestTopic, JSON.stringify(cmd)));
      // Resolve shortly even without an explicit ack — the command is fire-and-forget.
      setTimeout(() => { try { send(PINGREQ); } catch { /* ignore */ } }, 200);
    });
}

module.exports = {
  MQTT_DEFAULT_PORT,
  // pure codec (unit-tested)
  encodeRemainingLength, decodeRemainingLength, mqttString,
  encodeConnect, encodeSubscribe, encodePublish, parsePackets, decodePublish,
  bambuStateLabel, parseBambuReport,
  PINGREQ, DISCONNECT,
  // live
  fetchBambuStatus, bambuSendPrint,
};
