'use strict';
/**
 * Per-printer webcam configuration — URL derivation, provider auto-detect parsing, and
 * the host constraint that keeps the snapshot proxy from becoming an SSRF pivot.
 * Implements the camera half of docs/KHAYT-3.0-WEBCAM-SPEC.md.
 *
 * Pure: no network, no DOM. The actual image fetch happens in the main process, which
 * calls `assertWebcamHostAllowed` before every request.
 *
 * SECURITY NOTE. Unlike outbound webhooks — which are https-only and explicitly BLOCK
 * private/loopback addresses — a webcam lives on the LAN, so private addresses must be
 * allowed. That would be an open SSRF hole if the URL were free-form, so instead the
 * proxy is pinned: a snapshot may only be fetched from the SAME HOST already configured
 * as that machine's printer API. The owner cannot point it at an arbitrary internal
 * service, because the host is not theirs to choose at fetch time.
 */
(function () {
  const STREAM_TYPES = ['mjpeg', 'hls'];
  const TIMELAPSE_MODES = ['host', 'snapshot', 'off'];
  const ROTATIONS = [0, 90, 180, 270];

  function defaultWebcam() {
    return {
      enabled: false, streamUrl: '', snapshotUrl: '', streamType: 'mjpeg',
      flipH: false, flipV: false, rotate: 0, timelapse: 'snapshot', cloudRelay: false,
    };
  }

  /** Normalize whatever the owner typed into an absolute http(s) URL against the printer host. */
  function normalizeWebcamUrl(value, printerApi) {
    const v = String(value || '').trim();
    if (!v) return '';
    if (/^https?:\/\//i.test(v)) return v;
    const host = String((printerApi && printerApi.host) || '').trim();
    if (!host) return '';
    const scheme = /^https:\/\//i.test(host) ? 'https' : 'http';
    const bare = host.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
    const path = v.startsWith('/') ? v : '/' + v;
    return `${scheme}://${bare}${path}`;
  }

  /**
   * Every address a printer of this family might serve a camera on, best first.
   *
   * `deriveWebcamUrls` returns ONE guess, and one guess is demonstrably not
   * enough. Checked against a Snapmaker U1 on stock firmware: the derived
   * `:8080/?action=snapshot` reaches nothing at all — the only open ports are 80,
   * 1884 and 7125 — while the Fluidd/Mainsail nginx on port 80 does have a
   * `/webcam/` route (it answers 502, because on that firmware no camera service
   * runs behind it). Both conventions are real; which one a machine uses depends
   * on whether crowsnest binds publicly or only behind the proxy, and nothing in
   * the printer's answer tells you in advance.
   *
   * So offer both and let a probe decide, rather than picking one and leaving the
   * owner with a camera that is switched on and permanently blank.
   */
  function webcamCandidates(printerApi) {
    const type = String((printerApi && printerApi.type) || '').toLowerCase();
    const host = String((printerApi && printerApi.host) || '').trim();
    if (!host) return [];
    const bare = host.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
    const scheme = /^https:\/\//i.test(host) ? 'https' : 'http';
    const hostNoPort = bare.replace(/:\d+$/, '');
    if (type === 'moonraker') {
      return [
        // crowsnest / mjpg-streamer listening for itself.
        { snapshotUrl: `${scheme}://${hostNoPort}:8080/?action=snapshot`, streamUrl: `${scheme}://${hostNoPort}:8080/?action=stream` },
        // …and the same service behind the Fluidd/Mainsail proxy, on the port the
        // owner has already configured — which is the one that keeps working when
        // crowsnest is bound to localhost.
        { snapshotUrl: `${scheme}://${hostNoPort}/webcam/?action=snapshot`, streamUrl: `${scheme}://${hostNoPort}/webcam/?action=stream` },
      ];
    }
    const one = deriveWebcamUrls(printerApi);
    return (one.snapshotUrl || one.streamUrl) ? [one] : [];
  }

  /**
   * Best-effort defaults per printer family, using each project's documented convention.
   * These are a starting point the owner confirms — never assumed correct.
   */
  function deriveWebcamUrls(printerApi) {
    const type = String((printerApi && printerApi.type) || '').toLowerCase();
    const host = String((printerApi && printerApi.host) || '').trim();
    if (!host) return { snapshotUrl: '', streamUrl: '' };
    const bare = host.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
    const scheme = /^https:\/\//i.test(host) ? 'https' : 'http';
    if (type === 'octoprint') {
      return {
        snapshotUrl: `${scheme}://${bare}/webcam/?action=snapshot`,
        streamUrl: `${scheme}://${bare}/webcam/?action=stream`,
      };
    }
    if (type === 'moonraker') {
      // crowsnest / mjpg-streamer commonly sits on :8080 alongside Moonraker.
      const hostNoPort = bare.replace(/:\d+$/, '');
      return {
        snapshotUrl: `${scheme}://${hostNoPort}:8080/?action=snapshot`,
        streamUrl: `${scheme}://${hostNoPort}:8080/?action=stream`,
      };
    }
    if (type === 'prusalink') {
      // PrusaLink (Buddy firmware, e.g. CORE One) serves the camera from its own HTTP
      // port under /api/v1/cameras. Only a still is offered: there is no documented
      // continuous stream endpoint, and snapshotUrlFor() would refuse a stream anyway.
      return {
        snapshotUrl: `${scheme}://${bare}/api/v1/cameras/snap`,
        streamUrl: '',
      };
    }
    return { snapshotUrl: '', streamUrl: '' };
  }

  /**
   * Parse OctoPrint's GET /api/settings → its configured webcam URLs.
   *
   * THIS READ A COMPATIBILITY SHIM AND CALLED IT THE ANSWER.
   *
   * `webcam.streamUrl`, `webcam.snapshotUrl`, `flipH`, `flipV` and `rotate90` —
   * every field this used to read — are on OctoPrint's own
   * `DEPRECATED_WEBCAM_KEYS` list, in the 1.11 line and the 2.0 line alike.
   * The settings handler sets each of them to `None` on every response and then
   * fills the URLs back in only if the default webcam publishes a `compat`
   * block:
   *
   *     for key in DEPRECATED_WEBCAM_KEYS:
   *         data["webcam"][key] = None
   *     compatWebcam = defaultWebcam.config.compat if defaultWebcam else None
   *     if compatWebcam:
   *         data["webcam"].update({"streamUrl": compatWebcam.stream, …})
   *
   * The bundled classic webcam does publish one, which is why this kept working
   * and why nothing looked wrong. A camera from any other provider plugin does
   * not have to, and then every field here is null and Khayt reports no camera
   * found on a printer that has one. Auto-detect failing silently is a
   * particularly quiet defect: the owner types the URL by hand, decides the
   * button does not work, and never says so.
   *
   * The real answer is `webcam.webcams[]`, which is always present and lists
   * every camera. Each entry carries `name`, `displayName`, `canSnapshot`,
   * `flipH`, `flipV`, `rotate90` and its own `compat: {stream, snapshot}` —
   * so the URLs still come from a compat block, but a per-camera one, and the
   * response also names which camera is the default (`defaultWebcam`) and which
   * takes stills (`snapshotWebcam`).
   *
   * So: prefer the list, pick the camera OctoPrint itself nominates, and keep
   * the old top-level read as the fallback for versions that predate it.
   */
  function parseOctoprintSettings(body, printerApi) {
    const wc = body && body.webcam;
    if (!wc) return null;

    const fromEntry = (cam) => {
      if (!cam) return null;
      const compat = cam.compat || {};
      const snapshotUrl = normalizeWebcamUrl(compat.snapshot || '', printerApi);
      const streamUrl = normalizeWebcamUrl(compat.stream || '', printerApi);
      if (!snapshotUrl && !streamUrl) return null;
      return {
        snapshotUrl, streamUrl,
        flipH: !!cam.flipH, flipV: !!cam.flipV,
        rotate: cam.rotate90 ? 90 : 0,
      };
    };

    const list = Array.isArray(wc.webcams) ? wc.webcams.filter((c) => c && typeof c === 'object') : [];
    if (list.length) {
      const byName = (name) => (name ? list.find((c) => c.name === name) : null);
      // OctoPrint nominates two, and they are not always the same camera: one is
      // the default view, the other is the one it takes stills from. Khayt
      // proxies stills, so the snapshot camera is asked for first.
      const preferred = [
        byName(wc.snapshotWebcam),
        byName(wc.defaultWebcam),
        list.find((c) => c.canSnapshot),
        list[0],
      ];
      for (const cam of preferred) {
        const got = fromEntry(cam);
        if (got) return got;
      }
    }

    // Older OctoPrint, before webcams became a list: the top-level fields were
    // the real thing rather than a shim. Kept for exactly those versions.
    const snapshotUrl = normalizeWebcamUrl(wc.snapshotUrl || wc.snapshot || '', printerApi);
    const streamUrl = normalizeWebcamUrl(wc.streamUrl || wc.stream || '', printerApi);
    if (!snapshotUrl && !streamUrl) return null;
    return { snapshotUrl, streamUrl, flipH: !!wc.flipH, flipV: !!wc.flipV, rotate: wc.rotate90 ? 90 : 0 };
  }

  /** Parse Moonraker's GET /server/webcams/list → the first configured camera. */
  function parseMoonrakerWebcams(body, printerApi) {
    const list = (body && (body.webcams || (body.result && body.result.webcams))) || [];
    const cam = Array.isArray(list) ? list[0] : null;
    if (!cam) return null;
    const snapshotUrl = normalizeWebcamUrl(cam.snapshot_url || cam.snapshotUrl || '', printerApi);
    const streamUrl = normalizeWebcamUrl(cam.stream_url || cam.streamUrl || '', printerApi);
    if (!snapshotUrl && !streamUrl) return null;
    return {
      snapshotUrl, streamUrl,
      flipH: !!(cam.flip_horizontal ?? cam.flipH),
      flipV: !!(cam.flip_vertical ?? cam.flipV),
      rotate: ROTATIONS.includes(+cam.rotation) ? +cam.rotation : 0,
    };
  }

  /**
   * Where to ask a printer what camera it has.
   *
   * Both parsers below have existed, been exported and been unit-tested since
   * the webcam work landed — and nothing ever called them. The tests proved the
   * parsing was right; none of them could notice that no code path asked. This
   * table is the missing half.
   *
   * It matters most on a Snapmaker U1: stock firmware answers
   * /server/webcams/list with an empty list, while the community extended
   * firmware runs a full Moonraker + Fluidd/Mainsail stack and returns a real
   * camera. Same request, and the difference is the firmware, not the adapter.
   */
  const DETECT_PATH = {
    moonraker: '/server/webcams/list',
    octoprint: '/api/settings',
  };

  /** Which endpoint answers "what camera do you have", or '' if the type cannot say. */
  function detectPathFor(printerApi) {
    const type = String((printerApi && printerApi.type) || '').toLowerCase();
    return DETECT_PATH[type] || '';
  }

  /** Absolute URL of that endpoint on the printer's own host. */
  function detectUrlFor(printerApi) {
    const path = detectPathFor(printerApi);
    return path ? normalizeWebcamUrl(path, printerApi) : '';
  }

  /** Hand a fetched body to whichever parser matches the printer. */
  function parseDetected(body, printerApi) {
    const type = String((printerApi && printerApi.type) || '').toLowerCase();
    if (type === 'moonraker') return parseMoonrakerWebcams(body, printerApi);
    if (type === 'octoprint') return parseOctoprintSettings(body, printerApi);
    return null;
  }

  function hostOf(url) {
    try { return new URL(String(url)).hostname.toLowerCase(); } catch { return ''; }
  }

  /** The printer host, with any scheme/port/path stripped. */
  function printerHost(printerApi) {
    const raw = String((printerApi && printerApi.host) || '').trim();
    if (!raw) return '';
    const withScheme = /^https?:\/\//i.test(raw) ? raw : 'http://' + raw;
    return hostOf(withScheme);
  }

  /**
   * Is this a literal address that cannot leave the building?
   *
   * A STRICT ALLOW-LIST, matched against the text of the host, and it is written
   * that way on purpose. `169.254.169.254` is the cloud metadata endpoint; a
   * loopback address reaches whatever admin service happens to be listening on
   * the machine running Khayt; `100.64.0.0/10` is carrier-grade NAT and is also
   * where Alibaba's metadata service lives. None of those are a camera, and none
   * of them are allowed here.
   *
   * Only these are:
   *
   *     10.0.0.0/8      172.16.0.0/12      192.168.0.0/16      fc00::/7
   *
   * A HOSTNAME IS NOT ACCEPTED, only a literal. A name resolves, and what it
   * resolves to can change between the check and the fetch, or differ between
   * the two hosts that run this rule — which is DNS rebinding, and it is exactly
   * the attack a same-host pin was protecting against. The printer's own host may
   * still be a name, because that one is not new trust: it is the address the
   * shop already talks to.
   *
   * Anything the URL parser hands over that is not one of these shapes — an
   * integer form like `2130706433`, a hex form, an IPv4-mapped IPv6 address — is
   * refused rather than decoded. The two hosts do not parse those identically
   * (the Mac's `URL` is a Foundation shim; Node's is WHATWG) and a guard that
   * disagrees with itself across hosts is worse than one that says no.
   */
  function isLanLiteral(host) {
    const h = String(host || '').toLowerCase().replace(/^\[|\]$/g, '');
    const v4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h);
    if (v4) {
      const o = v4.slice(1).map(Number);
      if (o.some((n) => !(n >= 0 && n <= 255))) return false;
      // Leading zeros are an octal invitation; a real address does not have them.
      if (v4.slice(1).some((t) => t.length > 1 && t[0] === '0')) return false;
      if (o[0] === 10) return true;
      if (o[0] === 172 && o[1] >= 16 && o[1] <= 31) return true;
      if (o[0] === 192 && o[1] === 168) return true;
      return false;
    }
    // IPv6 unique-local, fc00::/7 — the first byte is 0xfc or 0xfd. Link-local
    // (fe80::/10) is excluded: it needs a zone index to be meaningful and the
    // two hosts spell that differently.
    if (/^[0-9a-f:]+$/.test(h) && h.includes(':')) return /^f[cd][0-9a-f]{0,2}:/.test(h);
    return false;
  }

  /**
   * THE SSRF GUARD, and it now allows a camera that is its own device.
   *
   * ── WHY IT USED TO BE THE PRINTER'S HOST AND NOTHING ELSE ─────────────────
   *
   * A webcam URL is free text in the shop's book, and a book arrives by restore
   * and by cloud sync — so the address was not necessarily chosen by the person
   * sitting in front of Khayt. Pinning it to the printer's own host made the
   * fetch provably harmless: the only place it could reach was a machine the
   * shop already talks to.
   *
   * ── AND WHY THAT WAS TOO TIGHT ────────────────────────────────────────────
   *
   * Plenty of cameras are not the printer. Measured on this shop's own floor,
   * 2026-09-10: a Buddy3D camera for the Prusa CORE One is a separate Wi-Fi
   * device on its own address, with the printer at `.79` and the camera at
   * `.71`. It is not reachable through PrusaLink at all — the printer never sees
   * its frames. The same is true of any USB camera on a spare Pi, and of every
   * cheap MJPEG camera pointed at a machine that has none of its own.
   *
   * So the rule the shop needs is not "the printer's host" but "somewhere on
   * this network that the owner typed in". That is what this now says:
   *
   *   - the printer's own host, exactly as before, name or address; or
   *   - a LITERAL private address — see `isLanLiteral`, which is an allow-list.
   *
   * The scheme is still http or https, and a name that is not the printer's is
   * still refused. What is given up is the guarantee that the only reachable
   * machine is the printer; what is kept is that no request can leave the local
   * network, reach a metadata service, or be aimed by a name whose meaning can
   * change after the check.
   *
   * REDIRECTS ARE NOT THIS FUNCTION'S JOB and they are not free: a private host
   * may answer 302 to a public one. Electron's proxy passes `redirect: 'manual'`
   * to every camera fetch. The Mac's `URLSession` follows them by default, so
   * `Camera.fetch` re-checks the URL the response actually came from. Both are
   * needed; neither is here, because this rule cannot see a response.
   *
   * Returns { ok, reason }.
   */
  function assertWebcamHostAllowed(url, printerApi) {
    let parsed;
    try { parsed = new URL(String(url)); } catch { return { ok: false, reason: 'invalid_url' }; }
    if (!/^https?:$/i.test(parsed.protocol)) return { ok: false, reason: 'bad_scheme' };
    const target = String(parsed.hostname || '').toLowerCase();
    if (!target) return { ok: false, reason: 'invalid_url' };
    const expected = printerHost(printerApi);
    if (!expected) return { ok: false, reason: 'no_printer_host' };
    if (target === expected) return { ok: true, reason: null };
    if (!isLanLiteral(target)) return { ok: false, reason: 'host_not_on_this_network' };
    return { ok: true, reason: null };
  }

  /** Sanitize an owner-edited webcam block before persisting. */
  function sanitizeWebcam(input, printerApi) {
    const w = input || {};
    return {
      enabled: !!w.enabled,
      snapshotUrl: normalizeWebcamUrl(w.snapshotUrl, printerApi),
      streamUrl: normalizeWebcamUrl(w.streamUrl, printerApi),
      streamType: STREAM_TYPES.includes(w.streamType) ? w.streamType : 'mjpeg',
      flipH: !!w.flipH,
      flipV: !!w.flipV,
      rotate: ROTATIONS.includes(+w.rotate) ? +w.rotate : 0,
      timelapse: TIMELAPSE_MODES.includes(w.timelapse) ? w.timelapse : 'snapshot',
      cloudRelay: !!w.cloudRelay,
    };
  }

  /** CSS transform for the render-time flip/rotate (never re-encodes the image). */
  function renderTransform(webcam) {
    const w = webcam || {};
    const parts = [];
    if (ROTATIONS.includes(+w.rotate) && +w.rotate) parts.push(`rotate(${+w.rotate}deg)`);
    if (w.flipH) parts.push('scaleX(-1)');
    if (w.flipV) parts.push('scaleY(-1)');
    return parts.join(' ');
  }

  /** Is this machine showable at all (either a still or a stream)? */
  function hasCamera(machine) {
    const w = machine && machine.webcam;
    return !!(w && w.enabled && (w.snapshotUrl || w.streamUrl));
  }

  /**
   * The URL the SNAPSHOT proxy may fetch. Deliberately does NOT fall back to streamUrl:
   * an MJPEG stream never terminates, so buffering one as a "snapshot" just accumulates
   * memory until the request times out. A stream is for the <img>/<video> element to
   * consume directly, not for the proxy to buffer.
   */
  function snapshotUrlFor(machine) {
    const w = machine && machine.webcam;
    if (!w || !w.enabled) return '';
    return w.snapshotUrl || '';
  }

  /**
   * The credential headers a snapshot fetch needs, mirroring what the status adapters
   * already send for the same printer type. PrusaLink's camera endpoint is authenticated
   * (401 without a key), so a proxy that sends nothing produces a correct URL that always
   * fails.
   *
   * SAFETY: the caller must have already passed assertWebcamHostAllowed() — these headers
   * carry the owner's printer credential and must only ever reach the printer itself.
   * Returns a plain object (never undefined) so callers can spread it unconditionally.
   */
  function authHeadersFor(printerApi) {
    const p = printerApi || {};
    const type = String(p.type || '').toLowerCase();
    const headers = {};
    if (type === 'octoprint' || type === 'prusalink') {
      if (p.apiKey) headers['X-Api-Key'] = String(p.apiKey);
    } else if (type === 'bambu') {
      if (p.accessCode) headers['Authorization'] = `Bearer ${p.accessCode}`;
    }
    // Moonraker is unauthenticated on the LAN by default (verified on Snapmaker U1
    // firmware 1.5.1), so it needs nothing here.
    return headers;
  }

  /** Largest still image the proxy will accept, in bytes. */
  const MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024;

  /**
   * Decide from the response headers whether to read the body at all — so an oversized
   * or non-image response is rejected BEFORE it is buffered into memory, not after.
   */
  /** Image types a camera may legitimately answer with, matched in full. */
  const SNAPSHOT_TYPE = /^image\/(png|jpe?g|webp|gif|bmp)$/i;

  function checkSnapshotHeaders(status, contentType, contentLength) {
    if (status >= 300 && status < 400) return { ok: false, reason: 'redirect_refused' };
    // A CAMERA WITH NOTHING TO SHOW IS NOT A CAMERA THAT IS BROKEN.
    //
    // PrusaLink documents 204 on /api/v1/cameras/snap as "No Content / No
    // Error" and 503 as the camera being temporarily unavailable — a registered
    // camera that has not captured a frame yet, or is busy. Both used to end up
    // as a failure the tile rendered as "Camera offline", which is the one
    // thing they do not mean: the printer answered, promptly, about a camera it
    // has. 204 in particular slipped past the status check (it is a 2xx) and
    // was caught by the content-type test instead, so a camera warming up
    // reported `not_an_image`.
    if (status === 204 || status === 503) return { ok: false, reason: 'no_frame_yet' };
    if (!(status >= 200 && status < 300)) return { ok: false, reason: `HTTP ${status}` };
    /* The EXACT type, not merely something starting with "image/".
     *
     * A header value may contain a double quote and survives fetch intact, so
     * `image/png" onerror="…` passed a prefix test and was pasted into a data:
     * URL that the renderer put straight into src="…". The attribute closed and
     * the handler ran. Matching the whole value is what makes that impossible;
     * the renderer also runs it through safeImageSrc, and either alone would
     * have been enough, which is why both are here. */
    if (!SNAPSHOT_TYPE.test(String(contentType || '').split(';')[0].trim())) {
      return { ok: false, reason: 'not_an_image' };
    }
    const len = Number(contentLength);
    if (Number.isFinite(len) && len > MAX_SNAPSHOT_BYTES) return { ok: false, reason: 'too_large' };
    return { ok: true, reason: null };
  }

  const api = {
    STREAM_TYPES, TIMELAPSE_MODES, ROTATIONS, SNAPSHOT_TYPE,
    defaultWebcam, normalizeWebcamUrl, deriveWebcamUrls, webcamCandidates,
    parseOctoprintSettings, parseMoonrakerWebcams,
    detectPathFor, detectUrlFor, parseDetected,
    printerHost, assertWebcamHostAllowed, isLanLiteral, sanitizeWebcam, renderTransform, hasCamera,
    snapshotUrlFor, checkSnapshotHeaders, authHeadersFor, MAX_SNAPSHOT_BYTES,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytWebcam = api;
})();
