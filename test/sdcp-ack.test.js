const { test } = require('node:test');
const assert = require('node:assert/strict');
const { takeAck } = require('../lib/sdcp-reply.js');

// The reply shape from cbd-tech SDCP v3.0.0, "Pause Printing(Cmd: 129)".
const reply = (over = {}) => ({
  Id: 'xxx',
  Data: { Cmd: 129, Data: { Ack: 0 }, RequestID: '000000000001d354', MainboardID: 'ffffffff', TimeStamp: 1687069655, ...over },
  Topic: 'sdcp/response/ffffffff',
});

test('Ack 0 on the matching command is success', () => {
  assert.deepEqual(takeAck(reply(), 'ffffffff', 129, '000000000001d354'), { ok: true });
});

test('a non-zero Ack is the printer refusing, in the spec words', () => {
  assert.deepEqual(takeAck(reply({ Data: { Ack: 1 } }), 'ffffffff', 129, '000000000001d354'),
    { ok: false, ack: 1, error: 'Busy' });
  const odd = takeAck(reply({ Data: { Ack: 42 } }), 'ffffffff', 129, '000000000001d354');
  assert.equal(odd.ok, false);
  assert.match(odd.error, /Ack 42/);
});

test('another command, another request, a status push or another board is not this answer', () => {
  assert.equal(takeAck(reply({ Cmd: 130 }), 'ffffffff', 129, '000000000001d354'), null);
  assert.equal(takeAck(reply({ RequestID: 'someone-else' }), 'ffffffff', 129, '000000000001d354'), null);
  assert.equal(takeAck({ ...reply(), Topic: 'sdcp/status/ffffffff' }, 'ffffffff', 129, 'x'), null);
  assert.equal(takeAck(reply({ MainboardID: 'other' }), 'ffffffff', 129, '000000000001d354'), null);
});

test('an error frame for this board is a refusal, not silence', () => {
  const r = takeAck({ Data: { ErrorMessage: 'nope', MainboardID: 'ffffffff' }, Topic: 'sdcp/error/ffffffff' }, 'ffffffff', 129, 'x');
  assert.deepEqual(r, { ok: false, ack: null, error: 'nope' });
});
