/**
 * A camera's Content-Type header is attacker-controlled input.
 *
 * The snapshot proxy is careful in every other respect — it pins the request to
 * the printer's own host, refuses redirects, checks headers before buffering the
 * body, and caps the size. Then it built a `data:` URL out of the header the
 * device sent:
 *
 *     data:${type.split(';')[0]};base64,${bytes}
 *
 * and renderer/machines.js put that straight into `src="…"` — while the branch
 * two lines above it escaped `streamUrl` properly. A device answering the
 * snapshot URL with
 *
 *     Content-Type: image/png" onerror="…
 *
 * passed the prefix-only check, survived fetch with the quote intact (verified
 * against a real HTTP server, not assumed), closed the src attribute, and got an
 * onerror handler executed in a renderer that holds window.hubAPI.
 *
 * Reachable by whatever answers on the printer's host and port: a compromised or
 * hostile printer, or anything able to take that address on the shop's LAN.
 *
 * Both layers are tested because either alone would have prevented it, and a
 * defence that exists in one place is one edit from not existing.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/webcam.js');
const U = require('../renderer/util.js');

const HOSTILE = 'image/png" onerror="PWNED';

test('a Content-Type that is not exactly an image type is refused', () => {
  assert.equal(W.checkSnapshotHeaders(200, HOSTILE, '100').ok, false);
  assert.equal(W.checkSnapshotHeaders(200, HOSTILE, '100').reason, 'not_an_image');
  // …and single quotes, and a trailing payload after a legitimate-looking type.
  assert.equal(W.checkSnapshotHeaders(200, "image/png' onerror='x", '100').ok, false);
  assert.equal(W.checkSnapshotHeaders(200, 'image/png<script>', '100').ok, false);
  assert.equal(W.checkSnapshotHeaders(200, 'text/html', '100').ok, false);
});

test('the types a real camera sends still work', () => {
  for (const t of ['image/png', 'image/jpeg', 'image/jpg', 'image/webp', 'image/gif', 'IMAGE/PNG']) {
    assert.equal(W.checkSnapshotHeaders(200, t, '100').ok, true, `${t} must be accepted`);
  }
  // A parameter is legitimate and must not be mistaken for an injection.
  assert.equal(W.checkSnapshotHeaders(200, 'image/jpeg; charset=binary', '100').ok, true);
  assert.equal(W.checkSnapshotHeaders(200, ' image/png ', '100').ok, true, 'whitespace is not an attack');
});

test('the responses that mean "not yet" still mean that', () => {
  // Regression guard for the behaviour this file must not have broken: a camera
  // warming up is not a camera that is offline.
  assert.equal(W.checkSnapshotHeaders(204, 'image/png', '0').reason, 'no_frame_yet');
  assert.equal(W.checkSnapshotHeaders(503, 'image/png', '0').reason, 'no_frame_yet');
  assert.equal(W.checkSnapshotHeaders(302, 'image/png', '0').reason, 'redirect_refused');
});

test('the renderer refuses the crafted data URL independently', () => {
  assert.equal(U.safeImageSrc(`data:${HOSTILE};base64,iVBORw0KGgo=`), '',
    'safeImageSrc requires ;base64, immediately after a known type');
  assert.match(U.safeImageSrc('data:image/png;base64,iVBORw0KGgo='), /^data:image\/png;base64,/);
});

test('the snapshot tile uses that helper rather than the raw value', () => {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'machines.js'), 'utf8');
  assert.doesNotMatch(src, /<img src="\$\{r\.dataUrl\}"/,
    'the camera tile must not interpolate the proxy\'s data URL unescaped');
  assert.match(src, /safeImageSrc\(r\.dataUrl\)/);
});

test('the proxy sends only a type it validated', () => {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', 'lib', 'main', 'webcam-proxy.js'), 'utf8');
  assert.match(src, /Webcam\.SNAPSHOT_TYPE\.test\(type\)/,
    'the data URL must be built from an approved type, not from the header again');
});
