'use strict';
/**
 * Pause / resume / cancel on a Bambu from the Windows/Linux app.
 *
 * The Mac has sent these since PrinterControl.swift; this app polled a Bambu
 * and could only watch. The bytes come from lib/printer-commands.js (shared),
 * and the answer is read the way the Mac's BambuSession reads it: confirmed,
 * refused in the printer's words, or sent-but-unconfirmed. The TLS socket is a
 * fake here: the bench has no Bambu.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const bambu = require('../lib/bambu.js');
const PC = require('../lib/printer-commands.js');

test('commandReply matches the verb and sequence, and reads the result', () => {
  const q = { command: 'pause', sequenceId: '42' };
  assert.deepEqual(bambu.commandReply('{"print":{"command":"pause","sequence_id":"42","result":"SUCCESS"}}', q), { ok: true });
  assert.deepEqual(bambu.commandReply('{"print":{"command":"pause","sequence_id":42,"result":"fail","reason":"no job"}}', q), { ok: false, reason: 'no job' });
  // another request's reply, another verb, a plain status push: not the answer
  assert.equal(bambu.commandReply('{"print":{"command":"pause","sequence_id":"41","result":"success"}}', q), null);
  assert.equal(bambu.commandReply('{"print":{"command":"resume","sequence_id":"42","result":"success"}}', q), null);
  assert.equal(bambu.commandReply('{"print":{"command":"push_status","gcode_state":"RUNNING"}}', q), null);
  assert.equal(bambu.commandReply('not json', q), null);
  // no sequence id on the reply: matched on the verb alone
  assert.deepEqual(bambu.commandReply('{"print":{"command":"pause","result":"success"}}', q), { ok: true });
});

/** A fake printer: CONNACK, SUBACK, then whatever `reply` says to a PUBLISH. */
function fakeTls(reply) {
  const published = [];
  return {
    published,
    connect(_opts, onConnect) {
      const s = new EventEmitter();
      s.write = (buf) => {
        const type = buf[0] >> 4;
        if (type === 1) setImmediate(() => s.emit('data', Buffer.from([0x20, 0x02, 0x00, 0x00])));     // CONNACK ok
        else if (type === 8) setImmediate(() => s.emit('data', Buffer.from([0x90, 0x03, 0x00, 0x01, 0x00]))); // SUBACK
        else if (type === 3) {
          const { packets } = bambu.parsePackets(buf);
          const msg = bambu.decodePublish(packets[0].body);
          published.push(msg);
          const out = reply(JSON.parse(msg.payload));
          if (out) setImmediate(() => s.emit('data', bambu.encodePublish('device/SN1/report', JSON.stringify(out))));
        }
        return true;
      };
      s.end = () => {}; s.destroy = () => {};
      setImmediate(onConnect);
      return s;
    },
  };
}

const build = (cmd, seq) => PC.buildCommand('bambu', cmd, null, { transports: ['mqtt'], sequenceId: seq }).mqtt;

test('a confirmed pause resolves ok, and the shared bytes go to the request topic', async () => {
  const tls = fakeTls((p) => ({ print: { ...p.print, result: 'success' } }));
  const r = await bambu.bambuSendCommand({ host: 'h', accessCode: 'x', serial: 'SN1', tls, mqtt: build('pause', '7') });
  assert.deepEqual(r, { ok: true });
  assert.equal(tls.published[0].topic, 'device/SN1/request');
  assert.deepEqual(JSON.parse(tls.published[0].payload), { print: { sequence_id: '7', command: 'pause', param: '' } });
});

test('cancel is sent as Bambu\'s "stop", and a refusal carries the printer\'s reason', async () => {
  const tls = fakeTls((p) => ({ print: { ...p.print, result: 'fail', reason: 'printer busy' } }));
  const r = await bambu.bambuSendCommand({ host: 'h', accessCode: 'x', serial: 'SN1', tls, mqtt: build('cancel', '8') });
  assert.equal(JSON.parse(tls.published[0].payload).print.command, 'stop');
  assert.equal(r.ok, false);
  assert.match(r.error, /printer busy/);
});

test('no reply after sending is unconfirmed, not "failed"', async () => {
  const tls = fakeTls(() => null);
  const r = await bambu.bambuSendCommand({ host: 'h', accessCode: 'x', serial: 'SN1', tls, mqtt: build('resume', '9'), timeoutMs: 50 });
  assert.equal(r.ok, false);
  assert.equal(r.unconfirmed, true);
  assert.match(r.error, /did not confirm/);
});

test('the desktop offers Bambu and SDCP controls now', () => {
  const src = require('fs').readFileSync(require('path').join(__dirname, '..', 'renderer', 'machines.js'), 'utf8');
  assert.match(src, /transports: \['http', 'mqtt', 'sdcp'\]/);
  for (const cmd of ['pause', 'resume', 'cancel']) {
    assert.ok(PC.supports('bambu', cmd, { transports: ['http', 'mqtt', 'sdcp'] }), 'bambu ' + cmd);
    assert.ok(PC.supports('sdcp', cmd, { transports: ['http', 'mqtt', 'sdcp'] }), 'sdcp ' + cmd);
  }
});
