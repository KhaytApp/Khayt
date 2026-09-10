'use strict';

/**
 * Fetching a still frame from a printer's camera, on the main process's behalf.
 *
 * Lifted out of main.js unchanged. It exists in the main process at all because
 * the renderer cannot reach a camera on the LAN under the app's CSP, and because
 * a camera's address is a shop secret that should not be handed to a page.
 *
 * Three dependencies: `ipcMain`, `path`, and `lanServerStore` for the machine
 * records that hold each camera's address.
 */

function registerWebcamProxy({ ipcMain, path, lanServerStore }) {
  // ── Webcam snapshot proxy ───────────────────────────────────────────────────
  // A webcam lives on the LAN, so unlike outbound webhooks we CANNOT blanket-block private
  // addresses here. The safety property instead is that the URL is pinned: a snapshot may
  // only be fetched from the same host already configured as that machine's printer API, so
  // this cannot be used as an SSRF pivot to arbitrary internal services.
  /**
   * Ask a printer what camera it has, instead of making the owner type two URLs.
   *
   * lib/webcam.js has been able to read both Moonraker's and OctoPrint's answers
   * since the webcam feature landed, and nothing ever asked them — the parsers
   * were exported and unit-tested with no caller anywhere in the product.
   *
   * Reads only. Same host pinning as the snapshot proxy below: the URL is derived
   * from the machine's OWN printerApi and never taken from the renderer, so this
   * cannot be pointed at an arbitrary address.
   */
  ipcMain.handle('hub:webcam-detect', async (_e, { machineId } = {}) => {
    try {
      const Webcam = require('../webcam.js');
      const machines = (lanServerStore && lanServerStore.machines) || [];
      const m = machines.find(x => x && x.id === machineId);
      if (!m) return { ok: false, error: 'unknown_machine' };
      const url = Webcam.detectUrlFor(m.printerApi);
      // Duet, PrusaLink and Bambu publish no equivalent list; say so rather than
      // guessing a path and reporting the 404 as "no camera".
      if (!url) return { ok: false, error: 'unsupported_printer' };
      const res = await fetch(url, {
        redirect: 'manual',
        headers: Webcam.authHeadersFor(m.printerApi),
        signal: AbortSignal.timeout(6000),
      });
      if (!res.ok) return { ok: false, error: `http_${res.status}` };
      const body = await res.json().catch(() => null);
      if (!body) return { ok: false, error: 'bad_response' };
      const found = Webcam.parseDetected(body, m.printerApi);
      // A Snapmaker U1 on STOCK firmware lands here: the endpoint exists and
      // answers with an empty list. That is a real answer — "this printer has no
      // camera registered" — not a failure, and the caller says so.
      if (!found) return { ok: false, error: 'no_camera_registered' };
      const guard = Webcam.assertWebcamHostAllowed(found.snapshotUrl || found.streamUrl, m.printerApi);
      if (!guard.ok) return { ok: false, error: guard.reason };
      return { ok: true, webcam: found };
    } catch (e) {
      return { ok: false, error: String((e && e.message) || e) };
    }
  });

  /**
   * Try the addresses a camera might be on, and report which one actually answers.
   *
   * Filling a GUESS and ticking "enabled" produces a machine card with a camera
   * tile that says "Camera offline" forever. Observed on the bench: a Snapmaker U1
   * had `webcam.enabled = true` pointing at `:8080/?action=snapshot`, an address
   * where nothing on that printer has ever listened.
   *
   * The toast said "check the preview", which is not a substitute — by then the box
   * is already ticked, and an owner who does not look has saved a camera that
   * cannot work. A probe is a second of waiting and turns the guess into an answer.
   *
   * SAFETY: candidates are derived from the machine's OWN stored printerApi and
   * every one is put through the same assertWebcamHostAllowed guard the snapshot
   * proxy uses. Nothing from the renderer reaches fetch(), so this is not an SSRF
   * pivot for the same reason that one is not.
   */
  ipcMain.handle('hub:webcam-probe', async (_e, { machineId } = {}) => {
    try {
      const Webcam = require('../webcam.js');
      const machines = (lanServerStore && lanServerStore.machines) || [];
      const m = machines.find(x => x && x.id === machineId);
      if (!m) return { ok: false, error: 'unknown_machine' };
      const candidates = Webcam.webcamCandidates(m.printerApi);
      if (!candidates.length) return { ok: true, found: null, tried: [] };
      const tried = [];
      for (const cand of candidates) {
        const url = cand.snapshotUrl;
        if (!url) continue;
        const guard = Webcam.assertWebcamHostAllowed(url, m.printerApi);
        if (!guard.ok) { tried.push({ url, error: guard.reason }); continue; }
        try {
          // Shorter than the snapshot proxy's timeout on purpose: this runs up to
          // twice with an owner waiting on it, and a candidate that has to be
          // waited four seconds for is not the one to configure.
          const res = await fetch(url, {
            redirect: 'manual',
            headers: Webcam.authHeadersFor(m.printerApi),
            signal: AbortSignal.timeout(3000),
          });
          const pre = Webcam.checkSnapshotHeaders(res.status, res.headers.get('content-type'), res.headers.get('content-length'));
          if (!pre.ok) { tried.push({ url, error: pre.reason, status: res.status }); continue; }
          // Headers can promise an image the body does not deliver. Read it, since
          // the whole value of a probe is that it is not another guess.
          const buf = Buffer.from(await res.arrayBuffer());
          if (!buf.length || buf.length > Webcam.MAX_SNAPSHOT_BYTES) { tried.push({ url, error: 'bad_size' }); continue; }
          return { ok: true, found: cand, tried };
        } catch (e) {
          tried.push({ url, error: String((e && e.message) || e) });
        }
      }
      return { ok: true, found: null, tried };
    } catch (e) {
      return { ok: false, error: String((e && e.message) || e) };
    }
  });

  ipcMain.handle('hub:webcam-snapshot', async (_e, { machineId } = {}) => {
    try {
      const Webcam = require('../webcam.js');
      const machines = (lanServerStore && lanServerStore.machines) || [];
      const m = machines.find(x => x && x.id === machineId);
      if (!m) return { ok: false, error: 'unknown_machine' };
      if (!Webcam.hasCamera(m)) return { ok: false, error: 'camera_off' };
      // Snapshot ONLY — never fall back to streamUrl. An MJPEG stream has no end, so
      // buffering one here would just accumulate memory until the timeout fires.
      const url = Webcam.snapshotUrlFor(m);
      if (!url) return { ok: false, error: 'no_snapshot_url' };
      const guard = Webcam.assertWebcamHostAllowed(url, m.printerApi);
      if (!guard.ok) return { ok: false, error: guard.reason };
      // Cameras behind an authenticated API need the machine's own credential — PrusaLink
      // returns 401 for /api/v1/cameras/snap without one, so an unauthenticated proxy
      // derives a perfectly correct URL that can never load. Only ever sent to the pinned
      // printer host checked immediately above, never to an arbitrary URL.
      const res = await fetch(url, {
        redirect: 'manual',
        headers: Webcam.authHeadersFor(m.printerApi),
        signal: AbortSignal.timeout(6000),
      });
      // Decide from headers BEFORE reading the body, so an oversized or non-image response
      // is refused without being buffered into memory first.
      const pre = Webcam.checkSnapshotHeaders(res.status, res.headers.get('content-type'), res.headers.get('content-length'));
      if (!pre.ok) return { ok: false, error: pre.reason };
      const buf = Buffer.from(await res.arrayBuffer());
      // Backstop for a response that declared no content-length.
      if (buf.length > Webcam.MAX_SNAPSHOT_BYTES) return { ok: false, error: 'too_large' };
      // Re-derive from the validated value rather than re-reading the header:
      // whatever reaches the renderer must be something checkSnapshotHeaders
      // actually approved, not the printer's original string.
      const type = String(res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
      if (!Webcam.SNAPSHOT_TYPE.test(type)) return { ok: false, error: 'not_an_image' };
      return { ok: true, dataUrl: `data:${type};base64,${buf.toString('base64')}` };
    } catch (e) {
      return { ok: false, error: String((e && e.message) || e) };
    }
  });
}

module.exports = { registerWebcamProxy };
