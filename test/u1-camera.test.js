'use strict';
// Keeping a Snapmaker U1 camera awake, and its chamber light: lib/webcam.js run
// against the shared vectors the Mac's U1CameraTests also read.
const test = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/webcam.js');
const V = require('./fixtures/u1-camera-vectors.json');

test('keepAwakeFor: only a Snapmaker monitor still on Moonraker, on the API host', () => {
  for (const c of V.keepAwake) {
    const got = W.keepAwakeFor(c.machine);
    assert.equal(got ? got.wsUrl : null, c.want, c.why);
    if (got) {
      assert.equal(got.method, 'camera.start_monitor');
      assert.equal(got.renewMs, 60000);
      assert.equal(got.deadlineMs, 2000);
    }
  }
});

test('keepAwakeRequest builds the one frame, with a positive integer id', () => {
  for (const c of V.request) assert.equal(W.keepAwakeRequest(c.id), c.want, String(c.id));
});

test('keepAwakeReply reads only the reply to our id', () => {
  for (const c of V.reply) assert.equal(W.keepAwakeReply(c.text, c.id), c.want, c.text);
});

test('the socket allow-list is camera.start_monitor and nothing else', () => {
  for (const c of V.wsMethods) assert.equal(W.wsMethodAllowed(c.method), c.want, c.method);
  assert.deepEqual([...W.WS_METHODS], ['camera.start_monitor']);
  assert.ok(Object.isFrozen(W.WS_METHODS));
  // Every frame the builder can produce passes the gate.
  assert.ok(W.wsMethodAllowed(JSON.parse(W.keepAwakeRequest(1)).method));
});

test('chamber light: two scripts, and the gate allows exactly those', () => {
  for (const c of V.lightScript) assert.equal(W.chamberLightScript(c.on), c.want, String(c.on));
  for (const c of V.scriptAllowed) assert.equal(W.scriptAllowed(c.script), c.want, c.script);
});

test('chamberLightFor: query and script on the printer API, Moonraker only', () => {
  for (const c of V.lightFor) {
    const got = W.chamberLightFor(c.machine);
    assert.deepEqual(got ? { queryUrl: got.queryUrl, scriptUrl: got.scriptUrl } : null, c.want);
  }
});

test('parseChamberLight: on, off, or null when there is no such light', () => {
  for (const c of V.lightState) assert.equal(W.parseChamberLight(c.body), c.want, c.why);
});
