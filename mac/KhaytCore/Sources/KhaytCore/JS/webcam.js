'use strict';
/**
 * Per-printer webcam configuration — URL derivation, provider auto-detect parsing, and
 * the host constraint that keeps the snapshot proxy from becoming an SSRF pivot.
 * Implements the camera half of docs/KHAYT-3.0-WEBCAM-SPEC.md.
 *
 * Pure: no network, no DOM. The actual image fetch happens in the main process, which
 * calls `assertSameHostAsPrinter` before every request.
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
   * THE SSRF GUARD. A snapshot/stream may only be fetched from the same host already
   * configured as this machine's printer API. Returns { ok, reason }.
   */
  function assertSameHostAsPrinter(url, printerApi) {
    const target = hostOf(url);
    if (!target) return { ok: false, reason: 'invalid_url' };
    const expected = printerHost(printerApi);
    if (!expected) return { ok: false, reason: 'no_printer_host' };
    if (target !== expected) return { ok: false, reason: 'host_mismatch' };
    if (!/^https?:$/i.test((() => { try { return new URL(url).protocol; } catch { return ''; } })())) {
      return { ok: false, reason: 'bad_scheme' };
    }
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
   * SAFETY: the caller must have already passed assertSameHostAsPrinter() — these headers
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
    printerHost, assertSameHostAsPrinter, sanitizeWebcam, renderTransform, hasCamera,
    snapshotUrlFor, checkSnapshotHeaders, authHeadersFor, MAX_SNAPSHOT_BYTES,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') globalThis.KhaytWebcam = api;
})();
