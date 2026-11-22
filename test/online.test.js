const { test } = require('node:test');
const assert = require('node:assert/strict');

const { applyOnlineLanPrefs, intakeUrlFromBase } = require('../renderer/online.js');

test('applyOnlineLanPrefs enables LAN bind when online is on', () => {
  const out = applyOnlineLanPrefs({ enabled: false, port: 3219, bindLan: false }, true);
  assert.equal(out.enabled, true);
  assert.equal(out.bindLan, true);
  assert.equal(out.port, 3219);
});

test('applyOnlineLanPrefs leaves LAN unchanged when online is off', () => {
  const lan = { enabled: true, bindLan: true };
  const out = applyOnlineLanPrefs(lan, false);
  assert.deepEqual(out, lan);
});

test('intakeUrlFromBase appends /intake', () => {
  assert.equal(intakeUrlFromBase('http://192.168.1.10:3219'), 'http://192.168.1.10:3219/intake');
  assert.equal(intakeUrlFromBase('http://192.168.1.10:3219/'), 'http://192.168.1.10:3219/intake');
});
