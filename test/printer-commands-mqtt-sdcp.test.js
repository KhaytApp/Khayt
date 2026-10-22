const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildCommand } = require('../lib/printer-commands.js');
const sdcp = require('../lib/sdcp.js');

/**
 * Bambu and Elegoo SDCP job control, against the documented shapes.
 *
 * Bambu: OpenBambuAPI mqtt.md, `print.stop` / `print.pause` / `print.resume`:
 *   {"print":{"sequence_id":"0","command":"pause","param":""}}  ("param … Always empty")
 * SDCP: cbd-tech SDCP v3.0.0, "Pause Printing(Cmd: 129)", "Stop Printing(Cmd: 130)",
 * "Continue Printing(Cmd: 131)": { Id, Data: { Cmd, Data: {}, RequestID, MainboardID,
 * TimeStamp, From: 0 }, Topic: "sdcp/request/<MainboardID>" }.
 *
 * No printer of either kind is on the bench, so the documents ARE the fixture,
 * and the bytes are pinned exactly: a reordered key is harmless to a JSON
 * parser and still a different message from the one the document shows.
 */

const MQTT = { transports: ['mqtt'] };

test('Bambu pause / resume / cancel are print.pause / print.resume / print.stop, byte for byte', () => {
  assert.equal(buildCommand('bambu', 'pause', null, { ...MQTT, sequenceId: 7 }).mqtt.payload,
    '{"print":{"sequence_id":"7","command":"pause","param":""}}');
  assert.equal(buildCommand('bambu', 'resume', null, { ...MQTT, sequenceId: 8 }).mqtt.payload,
    '{"print":{"sequence_id":"8","command":"resume","param":""}}');
  // Cancel is `stop`. Bambu has no other verb for ending a job.
  assert.equal(buildCommand('bambu', 'cancel', null, { ...MQTT, sequenceId: '9' }).mqtt.payload,
    '{"print":{"sequence_id":"9","command":"stop","param":""}}');
});

test('the Bambu descriptor names its verb and sequence so the reply can be matched', () => {
  const d = buildCommand('bambu', 'cancel', null, { ...MQTT, sequenceId: 12 });
  assert.deepEqual(Object.keys(d), ['mqtt']);
  assert.equal(d.mqtt.topic, 'request');
  assert.equal(d.mqtt.command, 'stop');
  assert.equal(d.mqtt.sequenceId, '12');
  assert.equal(d.method, undefined);
  assert.equal(d.path, undefined);
  // No sequence given: "0", as both reference clients send.
  assert.equal(buildCommand('bambu', 'pause', null, MQTT).mqtt.sequenceId, '0');
});

test('a sequence id that is not a whole number is refused, never interpolated', () => {
  for (const bad of ['1"},"x":{"', '-1', '1.5', 'abc', '', '12345678901']) {
    const d = buildCommand('bambu', 'pause', null, { ...MQTT, sequenceId: bad });
    assert.ok(d.unsupported, `built a payload for sequence ${JSON.stringify(bad)}`);
  }
});

test('SDCP pause / stop / continue are Cmd 129 / 130 / 131 in the spec envelope', () => {
  const opts = { transports: ['sdcp'], mainboardId: 'ffffffff', requestId: '000000000001d354', timestamp: 1687069655 };
  const expect = (cmd) => JSON.stringify({
    Id: '',
    Data: { Cmd: cmd, Data: {}, RequestID: '000000000001d354', MainboardID: 'ffffffff', TimeStamp: 1687069655, From: 0 },
    Topic: 'sdcp/request/ffffffff',
  });
  assert.equal(buildCommand('sdcp', 'pause', null, opts).sdcp.frame, expect(129));
  assert.equal(buildCommand('sdcp', 'cancel', null, opts).sdcp.frame, expect(130));
  assert.equal(buildCommand('sdcp', 'resume', null, opts).sdcp.frame, expect(131));
  // And literally, once, so the test does not only agree with itself.
  assert.equal(buildCommand('sdcp', 'pause', null, opts).sdcp.frame,
    '{"Id":"","Data":{"Cmd":129,"Data":{},"RequestID":"000000000001d354","MainboardID":"ffffffff","TimeStamp":1687069655,"From":0},"Topic":"sdcp/request/ffffffff"}');
  assert.equal(sdcp.CMD.PAUSE, 129);
  assert.equal(sdcp.CMD.STOP, 130);
  assert.equal(sdcp.CMD.RESUME, 131);
});

test('SDCP carries its command and request id for matching the Ack', () => {
  const d = buildCommand('sdcp', 'cancel', null, { transports: ['sdcp'], mainboardId: 'abc', requestId: 'r-1', timestamp: 1 });
  assert.equal(d.sdcp.cmd, 130);
  assert.equal(d.sdcp.requestId, 'r-1');
  assert.equal(d.method, undefined);
});

test('an SDCP printer with no mainboard id is refused before anything is built', () => {
  assert.match(buildCommand('sdcp', 'pause', null, { transports: ['sdcp'] }).unsupported, /mainboard ID/);
  assert.match(buildCommand('sdcp', 'pause', null, { transports: ['sdcp'], mainboardId: '  ' }).unsupported, /mainboard ID/);
});

test('a caller that speaks only HTTP never receives an MQTT or SDCP descriptor', () => {
  for (const type of ['bambu', 'sdcp']) {
    for (const cmd of ['pause', 'resume', 'cancel']) {
      for (const transports of [undefined, [], ['http'], 'mqtt']) {
        const d = buildCommand(type, cmd, null, { transports, mainboardId: 'x' });
        assert.ok(d.unsupported, `${type} ${cmd} transports=${JSON.stringify(transports)} was built`);
      }
    }
  }
  // Speaking one transport does not unlock the other.
  assert.ok(buildCommand('sdcp', 'pause', null, { transports: ['mqtt'], mainboardId: 'x' }).unsupported);
  assert.ok(buildCommand('bambu', 'pause', null, { transports: ['sdcp'] }).unsupported);
});

test('opts.transports: absent means [\'http\'] (unsupported); naming the transport yields the descriptor', () => {
  // The desktop lane's contract: main.js passes no transports and must keep
  // getting { unsupported } for Bambu and SDCP, since it shows buttons whenever
  // `unsupported` is falsy and can perform only HTTP descriptors.
  for (const cmd of ['pause', 'resume', 'cancel']) {
    assert.ok(buildCommand('bambu', cmd).unsupported);
    assert.ok(buildCommand('bambu', cmd, null, {}).unsupported);
    assert.ok(buildCommand('bambu', cmd, null, { transports: ['http'] }).unsupported);
    assert.ok(buildCommand('sdcp', cmd, null, { mainboardId: 'ffffffff' }).unsupported);
    assert.ok(buildCommand('sdcp', cmd, null, { transports: ['http'], mainboardId: 'ffffffff' }).unsupported);

    const b = buildCommand('bambu', cmd, null, { transports: ['http', 'mqtt'], sequenceId: 1 });
    assert.equal(b.unsupported, undefined);
    assert.ok(b.mqtt && b.mqtt.payload);
    const e = buildCommand('sdcp', cmd, null, { transports: ['http', 'sdcp'], mainboardId: 'ffffffff' });
    assert.equal(e.unsupported, undefined);
    assert.ok(e.sdcp && e.sdcp.frame);
  }
  // HTTP protocols are untouched by transports.
  assert.deepEqual(buildCommand('moonraker', 'pause', null, { transports: ['mqtt'] }),
    { method: 'POST', path: '/printer/print/pause' });
});

const { buildControl, SPEEDS } = require('../lib/printer-commands.js');

test('Bambu speed presets are print.print_speed with the level as a string (OpenBambuAPI)', () => {
  assert.deepEqual({ ...SPEEDS }, { 1: 'silent', 2: 'standard', 3: 'sport', 4: 'ludicrous' });
  for (const level of [1, 2, 3, 4]) {
    const d = buildControl('bambu', 'speed', level, { transports: ['mqtt'], sequenceId: 4 });
    assert.equal(d.mqtt.payload, `{"print":{"sequence_id":"4","command":"print_speed","param":"${level}"}}`);
    assert.equal(d.mqtt.section, 'print');
    assert.equal(d.mqtt.command, 'print_speed');
  }
  for (const bad of [0, 5, 2.5, '2; M112', null, 'sport']) {
    assert.ok(buildControl('bambu', 'speed', bad, { transports: ['mqtt'] }).unsupported, String(bad));
  }
});

test('the chamber light is system.ledctrl chamber_light, flashing fields always present (ha-bambulab values)', () => {
  assert.equal(buildControl('bambu', 'light', 'on', { transports: ['mqtt'], sequenceId: 9 }).mqtt.payload,
    '{"system":{"sequence_id":"9","command":"ledctrl","led_node":"chamber_light","led_mode":"on","led_on_time":500,"led_off_time":500,"loop_times":0,"interval_time":0}}');
  const off = buildControl('bambu', 'light', 'off', { transports: ['mqtt'], sequenceId: 10 });
  assert.match(off.mqtt.payload, /"led_mode":"off"/);
  assert.equal(off.mqtt.section, 'system');
  assert.equal(off.mqtt.command, 'ledctrl');
  assert.ok(buildControl('bambu', 'light', 'flashing', { transports: ['mqtt'] }).unsupported);
});

test('controls share the transports gate, and no other protocol has them', () => {
  assert.ok(buildControl('bambu', 'speed', 2).unsupported);
  assert.ok(buildControl('bambu', 'light', 'on', { transports: ['http'] }).unsupported);
  assert.ok(buildControl('moonraker', 'speed', 2, { transports: ['http', 'mqtt'] }).unsupported);
  assert.ok(buildControl('bambu', 'fan', 1, { transports: ['mqtt'] }).unsupported);
  assert.equal(buildCommand('bambu', 'pause', null, { transports: ['mqtt'] }).mqtt.section, 'print');
});
