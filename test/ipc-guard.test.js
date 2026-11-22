const { test } = require('node:test');
const assert = require('node:assert/strict');
const { hubIpcDenied, DENY_NULL } = require('../lib/ipc-guard');

test('hubIpcDenied matches load-store corrupt shape', () => {
  const d = hubIpcDenied('hub:load-store');
  assert.equal(d.__corrupt, true);
  assert.equal(d.error, 'unauthorized_sender');
});

test('hubIpcDenied returns null for sensitive file channels', () => {
  assert.equal(hubIpcDenied('hub:restore-backup'), null);
  assert.equal(hubIpcDenied('hub:write-status-page'), null);
  assert.ok(DENY_NULL.has('hub:write-status-page'));
});

test('hubIpcDenied returns ok:false for network channels', () => {
  const d = hubIpcDenied('hub:send-email');
  assert.equal(d.ok, false);
  assert.equal(d.error, 'unauthorized_sender');
});
