const { test } = require('node:test');
const assert = require('node:assert/strict');
const W = require('../lib/webcam.js');

const OCTO = { type: 'octoprint', host: '192.168.1.50' };
const MOON = { type: 'moonraker', host: '192.168.1.60:7125' };

test('defaultWebcam is off with no URLs', () => {
  const d = W.defaultWebcam();
  assert.equal(d.enabled, false);
  assert.equal(d.snapshotUrl, '');
  assert.equal(d.cloudRelay, false, 'never relays to cloud by default');
});

test('deriveWebcamUrls follows each project’s documented convention', () => {
  const o = W.deriveWebcamUrls(OCTO);
  assert.equal(o.snapshotUrl, 'http://192.168.1.50/webcam/?action=snapshot');
  assert.equal(o.streamUrl, 'http://192.168.1.50/webcam/?action=stream');
  const m = W.deriveWebcamUrls(MOON);
  assert.equal(m.snapshotUrl, 'http://192.168.1.60:8080/?action=snapshot', 'moonraker cam sits on :8080');
  const p = W.deriveWebcamUrls({ type: 'prusalink', host: '192.168.68.70' });
  assert.equal(p.snapshotUrl, 'http://192.168.68.70/api/v1/cameras/snap', 'PrusaLink serves stills on its own port');
  assert.equal(p.streamUrl, '', 'no documented continuous stream endpoint — do not invent one');
  assert.deepEqual(W.deriveWebcamUrls({ type: 'bambu', host: '1.2.3.4' }), { snapshotUrl: '', streamUrl: '' });
  assert.deepEqual(W.deriveWebcamUrls({ type: 'octoprint' }), { snapshotUrl: '', streamUrl: '' }, 'no host → nothing');
});

test('normalizeWebcamUrl resolves relative paths against the printer host', () => {
  assert.equal(W.normalizeWebcamUrl('/webcam/?action=snapshot', OCTO), 'http://192.168.1.50/webcam/?action=snapshot');
  assert.equal(W.normalizeWebcamUrl('webcam/?action=snapshot', OCTO), 'http://192.168.1.50/webcam/?action=snapshot');
  assert.equal(W.normalizeWebcamUrl('http://other.local/cam', OCTO), 'http://other.local/cam', 'absolute kept as-is');
  assert.equal(W.normalizeWebcamUrl('', OCTO), '');
  assert.equal(W.normalizeWebcamUrl('/cam', {}), '', 'no host → cannot resolve');
});

test('parseOctoprintSettings prefers the webcams list over the deprecated shim', () => {
  // Every top-level field the old parser read — streamUrl, snapshotUrl, flipH,
  // flipV, rotate90 — is on OctoPrint's own DEPRECATED_WEBCAM_KEYS list, in the
  // 1.11 line and the 2.0 line alike. The settings handler nulls each of them
  // on every response and fills the URLs back in ONLY if the default webcam
  // publishes a `compat` block. The bundled classic webcam does, which is why
  // this kept working; a camera from any other provider need not, and then
  // Khayt reported no camera on a printer that has one.
  const body = {
    webcam: {
      // the shim, nulled by OctoPrint when no compat block exists
      streamUrl: null, snapshotUrl: null, flipH: null, flipV: null, rotate90: null,
      defaultWebcam: 'front', snapshotWebcam: 'front',
      webcams: [{
        name: 'front', displayName: 'Front', canSnapshot: true,
        flipH: true, flipV: false, rotate90: true,
        compat: { stream: '/webcam/?action=stream', snapshot: '/webcam/?action=snapshot' },
        provider: 'classicwebcam',
      }],
    },
  };
  const out = W.parseOctoprintSettings(body, OCTO);
  assert.equal(out.snapshotUrl, 'http://192.168.1.50/webcam/?action=snapshot');
  assert.equal(out.streamUrl, 'http://192.168.1.50/webcam/?action=stream');
  assert.equal(out.flipH, true);
  assert.equal(out.rotate, 90);
});

test('OctoPrint names the still camera separately, and it wins', () => {
  // defaultWebcam is the one shown; snapshotWebcam is the one stills come from,
  // and they are not always the same camera. Khayt proxies stills.
  const cam = (name, snap) => ({
    name, displayName: name, canSnapshot: true, flipH: false, flipV: false, rotate90: false,
    compat: { stream: `/${name}/stream`, snapshot: snap },
  });
  const out = W.parseOctoprintSettings({
    webcam: { defaultWebcam: 'wide', snapshotWebcam: 'macro', webcams: [cam('wide', '/wide/snap'), cam('macro', '/macro/snap')] },
  }, OCTO);
  assert.equal(out.snapshotUrl, 'http://192.168.1.50/macro/snap');

  // With nothing nominated, the first camera that can take a still is used
  // rather than simply the first camera.
  const noSnap = { name: 'stream-only', canSnapshot: false, compat: { stream: '/s/stream', snapshot: '' } };
  const out2 = W.parseOctoprintSettings({ webcam: { webcams: [noSnap, cam('macro', '/macro/snap')] } }, OCTO);
  assert.equal(out2.snapshotUrl, 'http://192.168.1.50/macro/snap');
});

test('a webcams list carrying no usable URL falls through rather than winning empty', () => {
  // A provider that publishes no compat block exposes no URL anywhere in
  // OctoPrint's API. That is a real limit, not a parse failure — but it must
  // not shadow an older OctoPrint whose top-level fields ARE the real thing.
  const body = {
    webcam: {
      streamUrl: '/webcam/?action=stream', snapshotUrl: '/webcam/?action=snapshot',
      webcams: [{ name: 'nocompat', canSnapshot: true }],
    },
  };
  const out = W.parseOctoprintSettings(body, OCTO);
  assert.equal(out.snapshotUrl, 'http://192.168.1.50/webcam/?action=snapshot', 'the legacy fallback still answers');

  assert.equal(W.parseOctoprintSettings({ webcam: { webcams: [{ name: 'x' }] } }, OCTO), null, 'and nothing anywhere is null, not a throw');
  assert.equal(W.parseOctoprintSettings({ webcam: { webcams: 'not-a-list' } }, OCTO), null);
  assert.equal(W.parseOctoprintSettings({ webcam: { webcams: [null, 7] } }, OCTO), null);
});

test('parseOctoprintSettings reads the reported webcam config', () => {
  const out = W.parseOctoprintSettings({ webcam: { snapshotUrl: '/webcam/?action=snapshot', streamUrl: '/webcam/?action=stream', flipH: true, rotate90: true } }, OCTO);
  assert.equal(out.snapshotUrl, 'http://192.168.1.50/webcam/?action=snapshot');
  assert.equal(out.flipH, true);
  assert.equal(out.rotate, 90);
  assert.equal(W.parseOctoprintSettings({}, OCTO), null);
  assert.equal(W.parseOctoprintSettings({ webcam: {} }, OCTO), null, 'no urls → null');
});

test('parseMoonrakerWebcams reads the first registered camera', () => {
  const body = { result: { webcams: [{ snapshot_url: '/webcam?action=snapshot', stream_url: '/webcam?action=stream', flip_horizontal: true, rotation: 180 }] } };
  const out = W.parseMoonrakerWebcams(body, MOON);
  assert.equal(out.snapshotUrl, 'http://192.168.1.60:7125/webcam?action=snapshot');
  assert.equal(out.flipH, true);
  assert.equal(out.rotate, 180);
  assert.equal(W.parseMoonrakerWebcams({ result: { webcams: [] } }, MOON), null);
  assert.equal(W.parseMoonrakerWebcams({}, MOON), null);
});

test('SSRF GUARD: a camera may be the printer, or a literal address on this network', () => {
  assert.equal(W.assertWebcamHostAllowed('http://192.168.1.50/webcam/?action=snapshot', OCTO).ok, true);

  // ── THIS ONE CHANGED, AND ON PURPOSE ─────────────────────────────────────
  //
  // `http://192.168.1.99/other-device` used to be in the list below, refused
  // for being a host that is not the printer's. It is allowed now, because a
  // camera on its own address is the ordinary case and not an attack: measured
  // on a real floor, a Buddy3D camera for a Prusa CORE One sits at .71 with the
  // printer at .79 and is not reachable through the printer at all.
  assert.equal(W.assertWebcamHostAllowed('http://192.168.1.99/other-device', OCTO).ok, true,
    'a second device on the same private network is a camera, not a pivot');

  // Everything that can leave the building, or reach something that is not a
  // camera, is still refused.
  for (const evil of [
    'http://127.0.0.1:8080/admin',                // whatever is listening here
    'http://169.254.169.254/latest/meta-data/',   // cloud metadata
    'http://[fd00::1]@evil.example.com/',         // userinfo dressed as a LAN host
    'http://100.100.100.200/latest/meta-data/',   // Alibaba metadata, inside CGNAT
    'http://internal.corp/secrets',               // a NAME is not a literal
    'https://evil.example.com/collect',
    'http://8.8.8.8/',
    'http://2130706433/',                         // 127.0.0.1 as an integer
    'http://0177.0.0.1/',                         // and as octal
    'http://172.32.0.1/',                         // just outside 172.16.0.0/12
  ]) {
    const r = W.assertWebcamHostAllowed(evil, OCTO);
    assert.equal(r.ok, false, `SSRF NOT BLOCKED: ${evil}`);
  }
  assert.equal(W.assertWebcamHostAllowed('file:///etc/passwd', OCTO).ok, false, 'non-http scheme refused');
  assert.equal(W.assertWebcamHostAllowed('not a url', OCTO).reason, 'invalid_url');
  assert.equal(W.assertWebcamHostAllowed('http://x/y', {}).reason, 'no_printer_host');
});

test('the allow-list is the three private ranges and unique-local v6, and nothing beside', () => {
  for (const yes of ['10.0.0.1', '10.255.255.254', '172.16.0.1', '172.31.255.254',
                     '192.168.0.1', '192.168.255.254', 'fd00::1', 'fc00::abcd']) {
    assert.equal(W.isLanLiteral(yes), true, `should be a LAN literal: ${yes}`);
  }
  for (const no of ['11.0.0.1', '172.15.255.255', '172.32.0.1', '192.169.0.1',
                    '127.0.0.1', '0.0.0.0', '169.254.1.1', '100.64.0.1',
                    '8.8.8.8', '::1', 'fe80::1', 'printer.local', '',
                    '192.168.01.1', '192.168.0.256', '2130706433']) {
    assert.equal(W.isLanLiteral(no), false, `must NOT be a LAN literal: ${no}`);
  }
});

test('the printer may still be named, but nothing else may', () => {
  // The printer's host is not new trust — it is the address the shop already
  // talks to — so a name is fine there and only there.
  const named = { type: 'octoprint', host: 'printer.local' };
  assert.equal(W.assertWebcamHostAllowed('http://printer.local/webcam/?action=snapshot', named).ok, true);
  assert.equal(W.assertWebcamHostAllowed('http://camera.local/snapshot', named).ok, false,
    'a second NAME could resolve anywhere, and to somewhere else after the check');
  assert.equal(W.assertWebcamHostAllowed('http://192.168.4.4/snapshot', named).ok, true,
    'but a literal on the network is fine even when the printer is named');
});

test('port and scheme still do not matter; the host still does', () => {
  // Same host on the camera's own port is legitimate (Moonraker cam on :8080).
  assert.equal(W.assertWebcamHostAllowed('http://192.168.1.60:8080/?action=snapshot', MOON).ok, true);
  // A different PRIVATE host is now allowed; a public one on any port is not.
  assert.equal(W.assertWebcamHostAllowed('http://192.168.1.61:7125/?action=snapshot', MOON).ok, true);
  assert.equal(W.assertWebcamHostAllowed('http://203.0.113.9:8080/?action=snapshot', MOON).ok, false);
});

test('sanitizeWebcam clamps enums and normalizes URLs', () => {
  const s = W.sanitizeWebcam({ enabled: 1, snapshotUrl: '/cam', streamType: 'evil', rotate: 47, timelapse: 'evil', cloudRelay: 'yes' }, OCTO);
  assert.equal(s.enabled, true);
  assert.equal(s.snapshotUrl, 'http://192.168.1.50/cam');
  assert.equal(s.streamType, 'mjpeg', 'unknown stream type clamped');
  assert.equal(s.rotate, 0, 'invalid rotation clamped');
  assert.equal(s.timelapse, 'snapshot');
  assert.equal(s.cloudRelay, true);
});

test('renderTransform builds a CSS transform without re-encoding', () => {
  assert.equal(W.renderTransform({ rotate: 90, flipH: true }), 'rotate(90deg) scaleX(-1)');
  assert.equal(W.renderTransform({ flipV: true }), 'scaleY(-1)');
  assert.equal(W.renderTransform({ rotate: 0 }), '');
  assert.equal(W.renderTransform(null), '');
});

test('hasCamera requires opt-in AND a URL', () => {
  assert.equal(W.hasCamera({ webcam: { enabled: true, snapshotUrl: 'http://x/y' } }), true);
  assert.equal(W.hasCamera({ webcam: { enabled: false, snapshotUrl: 'http://x/y' } }), false, 'off means off');
  assert.equal(W.hasCamera({ webcam: { enabled: true } }), false, 'enabled but no URL → nothing to show');
  assert.equal(W.hasCamera({}), false);
});

/* ── Snapshot proxy hardening ───────────────────────────────────── */

test('snapshotUrlFor never falls back to the stream (an MJPEG stream has no end)', () => {
  const streamOnly = { webcam: { enabled: true, snapshotUrl: '', streamUrl: 'http://192.168.1.50/webcam/?action=stream' } };
  assert.equal(W.hasCamera(streamOnly), true, 'the card can still show a stream');
  assert.equal(W.snapshotUrlFor(streamOnly), '', 'but the proxy refuses to buffer it as a snapshot');
  const both = { webcam: { enabled: true, snapshotUrl: 'http://h/s', streamUrl: 'http://h/st' } };
  assert.equal(W.snapshotUrlFor(both), 'http://h/s');
  assert.equal(W.snapshotUrlFor({ webcam: { enabled: false, snapshotUrl: 'http://h/s' } }), '', 'off means off');
  assert.equal(W.snapshotUrlFor({}), '');
});

test('checkSnapshotHeaders rejects oversized responses BEFORE the body is read', () => {
  const big = String(W.MAX_SNAPSHOT_BYTES + 1);
  assert.deepEqual(W.checkSnapshotHeaders(200, 'image/jpeg', big), { ok: false, reason: 'too_large' });
  assert.equal(W.checkSnapshotHeaders(200, 'image/jpeg', String(W.MAX_SNAPSHOT_BYTES)).ok, true, 'at the cap is fine');
});

test('checkSnapshotHeaders enforces image content-type, success status and no redirects', () => {
  assert.equal(W.checkSnapshotHeaders(200, 'image/jpeg', '1024').ok, true);
  assert.equal(W.checkSnapshotHeaders(200, 'image/png; charset=binary', null).ok, true, 'params tolerated');
  assert.deepEqual(W.checkSnapshotHeaders(302, 'image/jpeg', '10'), { ok: false, reason: 'redirect_refused' });
  assert.deepEqual(W.checkSnapshotHeaders(200, 'text/html', '10'), { ok: false, reason: 'not_an_image' });
  assert.deepEqual(W.checkSnapshotHeaders(200, null, '10'), { ok: false, reason: 'not_an_image' }, 'missing type is not an image');
  assert.equal(W.checkSnapshotHeaders(404, 'image/jpeg', '10').ok, false);
  assert.equal(W.checkSnapshotHeaders(500, 'image/jpeg', '10').reason, 'HTTP 500');
});

test('a camera with nothing to show yet is not a camera that is broken', () => {
  // PrusaLink documents 204 on /api/v1/cameras/snap as "No Content / No Error"
  // and 503 as temporarily unavailable: a registered camera that has not
  // captured a frame, or is busy. The tile rendered both as "Camera offline",
  // which is the one thing they do not mean — the printer answered, promptly,
  // about a camera it has.
  assert.deepEqual(W.checkSnapshotHeaders(204, null, null), { ok: false, reason: 'no_frame_yet' });
  assert.deepEqual(W.checkSnapshotHeaders(503, null, null), { ok: false, reason: 'no_frame_yet' });

  // 204 is a 2xx, so it used to pass the status check and get caught by the
  // content-type test instead — a camera warming up reported `not_an_image`.
  assert.notEqual(W.checkSnapshotHeaders(204, null, null).reason, 'not_an_image');

  // A genuine failure must not be softened into "warming up".
  assert.equal(W.checkSnapshotHeaders(404, 'image/jpeg', '10').reason, 'HTTP 404');
  assert.equal(W.checkSnapshotHeaders(500, 'image/jpeg', '10').reason, 'HTTP 500');
  assert.equal(W.checkSnapshotHeaders(200, 'text/html', '10').reason, 'not_an_image');
});

test('checkSnapshotHeaders allows a missing content-length (body cap is the backstop)', () => {
  assert.equal(W.checkSnapshotHeaders(200, 'image/jpeg', null).ok, true);
  assert.equal(W.checkSnapshotHeaders(200, 'image/jpeg', 'not-a-number').ok, true);
});

test('a snapshot fetch carries the machine’s own printer credential', () => {
  // PrusaLink's camera endpoint 401s without a key, so an unauthenticated proxy derives
  // a correct URL that can never load — verified against a real CORE One.
  assert.deepEqual(W.authHeadersFor({ type: 'prusalink', apiKey: 'K1' }), { 'X-Api-Key': 'K1' });
  assert.deepEqual(W.authHeadersFor({ type: 'octoprint', apiKey: 'K2' }), { 'X-Api-Key': 'K2' });
  assert.deepEqual(W.authHeadersFor({ type: 'bambu', accessCode: 'AC' }), { Authorization: 'Bearer AC' });
  // Moonraker is unauthenticated on the LAN — sending nothing is correct, not an omission.
  assert.deepEqual(W.authHeadersFor({ type: 'moonraker' }), {});
  // Never leak a credential to a type that did not configure one, and never return
  // undefined (callers spread the result).
  assert.deepEqual(W.authHeadersFor({ type: 'prusalink' }), {}, 'no key configured → no header');
  assert.deepEqual(W.authHeadersFor(null), {});
  assert.deepEqual(W.authHeadersFor({ type: 'bambu', apiKey: 'WRONG' }), {}, 'bambu uses accessCode, not apiKey');
});

/**
 * The half that was missing.
 *
 * parseMoonrakerWebcams and parseOctoprintSettings were exported and tested
 * from the day the webcam feature landed, and NOTHING in the product ever
 * called either of them. The tests above proved the parsing was correct; not
 * one of them could notice there was no caller. These cover the route from a
 * printer to a parser, which is the part that did not exist.
 */
test('a printer is asked at the endpoint its own project documents', () => {
  assert.equal(W.detectUrlFor({ type: 'moonraker', host: '192.168.1.9:7125' }),
    'http://192.168.1.9:7125/server/webcams/list');
  assert.equal(W.detectUrlFor({ type: 'octoprint', host: '192.168.1.8' }),
    'http://192.168.1.8/api/settings');
  // https must survive; a shop using TLS on the LAN must not be downgraded.
  assert.equal(W.detectUrlFor({ type: 'moonraker', host: 'https://printer.local' }),
    'https://printer.local/server/webcams/list');
});

test('printers with nothing to ask return no URL rather than a guessed path', () => {
  // Duet, PrusaLink and Bambu publish no equivalent list. Inventing a path
  // would turn "we cannot ask" into a 404 reported as "no camera".
  for (const type of ['duet', 'prusalink', 'bambu', 'none', '']) {
    assert.equal(W.detectPathFor({ type, host: '1.2.3.4' }), '', `${type} should have no detect path`);
    assert.equal(W.detectUrlFor({ type, host: '1.2.3.4' }), '');
  }
});

test('the reply is routed to the parser that matches the printer', () => {
  const moon = { type: 'moonraker', host: '10.0.0.5' };
  const octo = { type: 'octoprint', host: '10.0.0.6' };
  const moonBody = { result: { webcams: [{ snapshot_url: '/webcam/?action=snapshot', rotation: 180 }] } };
  const octoBody = { webcam: { snapshotUrl: '/webcam/?action=snapshot', streamUrl: '/webcam/?action=stream' } };

  assert.equal(W.parseDetected(moonBody, moon).rotate, 180);
  assert.ok(W.parseDetected(octoBody, octo).streamUrl);
  // Cross-wiring must yield nothing, not a half-parsed object: an OctoPrint
  // body through the Moonraker parser has no `webcams` key at all.
  assert.equal(W.parseDetected(octoBody, moon), null);
  assert.equal(W.parseDetected(moonBody, octo), null);
});

test('a Snapmaker U1 on stock firmware answers, and the answer is "none"', () => {
  // The endpoint exists on stock and returns an empty list. That is a real
  // reply meaning the printer has no camera registered — distinct from a
  // printer that cannot be asked at all, which returns no URL above. The
  // community extended firmware runs a full Moonraker stack and fills this in.
  const u1 = { type: 'moonraker', host: '192.168.68.42:7125' };
  assert.ok(W.detectUrlFor(u1), 'a U1 can always be asked');
  assert.equal(W.parseDetected({ result: { webcams: [] } }, u1), null, 'stock: nothing registered');

  const extended = { result: { webcams: [{ snapshot_url: '/webcam/?action=snapshot', stream_url: '/webcam/?action=stream' }] } };
  const found = W.parseDetected(extended, u1);
  assert.ok(found && found.snapshotUrl.startsWith('http://192.168.68.42:7125/'),
    'extended: a real camera, resolved against the printer host');
});

/*
 * One guess is not enough, and a guess must not switch a camera on.
 *
 * Checked against a Snapmaker U1 on stock firmware, mid-print, on 2026-08-24:
 *
 *   /server/webcams/list          → {"webcams": []}   (auto-detect, correctly, finds nothing)
 *   :8080/?action=snapshot        → nothing listening; the only open ports are 80, 1884, 7125
 *   port 80 /webcam/?action=…     → 502 from the Fluidd/Mainsail nginx — the route exists,
 *                                   no camera service runs behind it on this firmware
 *
 * So the address `deriveWebcamUrls` derives for a Moonraker printer is one of two
 * real conventions, and on this machine it is the wrong one. The machine had
 * `webcam.enabled = true` pointing at it, which is why its card showed a tile
 * reading "Camera offline" indefinitely: an unverified guess had been switched on.
 */

test('webcamCandidates offers both Moonraker camera conventions, best first', () => {
  const c = W.webcamCandidates({ type: 'moonraker', host: '192.168.68.56', port: 7125 });
  assert.equal(c.length, 2, 'only one Moonraker convention was offered');
  // crowsnest listening for itself…
  assert.equal(c[0].snapshotUrl, 'http://192.168.68.56:8080/?action=snapshot');
  assert.equal(c[0].streamUrl, 'http://192.168.68.56:8080/?action=stream');
  // …and the same service behind the Fluidd/Mainsail proxy, which keeps working
  // when crowsnest is bound to localhost.
  assert.equal(c[1].snapshotUrl, 'http://192.168.68.56/webcam/?action=snapshot');
  assert.equal(c[1].streamUrl, 'http://192.168.68.56/webcam/?action=stream');
});

test('the API port is never carried into a camera URL', () => {
  // 7125 is Moonraker's, and a camera has never been on it. A candidate built by
  // pasting the configured port onto the host would probe the printer's own API
  // and get a JSON 404 that is not an image — a wasted probe that also looks like
  // a camera failure.
  for (const host of ['192.168.68.56:7125', 'http://192.168.68.56:7125', 'http://192.168.68.56:7125/']) {
    const c = W.webcamCandidates({ type: 'moonraker', host, port: 7125 });
    assert.ok(!c.some((x) => x.snapshotUrl.includes(':7125')), `API port leaked into a candidate from ${host}`);
    assert.equal(c[0].snapshotUrl, 'http://192.168.68.56:8080/?action=snapshot');
  }
});

test('candidates stay inside the host pinning that makes the proxy safe', () => {
  // Every candidate is fetched through assertWebcamHostAllowed, so one that could
  // not pass it would be a hole rather than a dead end.
  const api = { type: 'moonraker', host: '192.168.68.56', port: 7125 };
  for (const c of W.webcamCandidates(api)) {
    assert.equal(W.assertWebcamHostAllowed(c.snapshotUrl, api).ok, true, c.snapshotUrl);
    assert.equal(W.assertWebcamHostAllowed(c.streamUrl, api).ok, true, c.streamUrl);
  }
});

test('families with a single documented convention still offer exactly that one', () => {
  const p = W.webcamCandidates({ type: 'prusalink', host: '192.168.68.70' });
  assert.deepEqual(p, [{ snapshotUrl: 'http://192.168.68.70/api/v1/cameras/snap', streamUrl: '' }]);
  const o = W.webcamCandidates({ type: 'octoprint', host: '192.168.68.60' });
  assert.equal(o.length, 1);
  assert.equal(o[0].snapshotUrl, 'http://192.168.68.60/webcam/?action=snapshot');
});

test('nothing to guess yields nothing to probe, rather than a junk URL', () => {
  assert.deepEqual(W.webcamCandidates({ type: 'bambu', host: '1.2.3.4' }), [],
    'a family with no documented camera convention produced a candidate');
  assert.deepEqual(W.webcamCandidates({ type: 'moonraker' }), [], 'no host → nothing');
  assert.deepEqual(W.webcamCandidates(null), []);
  assert.deepEqual(W.webcamCandidates({}), []);
});
