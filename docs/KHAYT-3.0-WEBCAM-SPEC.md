# Webcam & timelapse — per-printer camera feeds + per-print timelapse

**Scope:** show a live camera feed per printer (snapshot in the machine card, full stream on demand) and capture a timelapse per print, viewable in the app over the LAN today and — opt-in, Phase 2 — from anywhere via Cloud. This is a genuine gap: no camera or timelapse exists today.

**Governing principle:** **local-first, opt-in, bandwidth/privacy-aware.** The camera URL is the printer host's own MJPEG/snapshot endpoint, so viewing works on the LAN with **no cloud and no Khayt account**. Cloud/remote viewing is a strictly *additive* layer. Camera is **off by default, opt-in per machine**. Frames/streams are **never forced through Khayt Cloud** — they stay on the LAN unless the owner explicitly opts a machine into the Cloud relay. Same graceful-degradation stance as every cloud-optional feature: no camera URL → the feature is simply absent for that machine; nothing else changes.

---

## 1. Why this fits the existing model

The machine already carries `printerApi = { type, host, port, apiKey, accessCode, printerSlug }` (`renderer/machines.js` ~235; persisted, masked-secret pattern) and is polled every 30 s by `hub:start-printer-polling` → `fetchPrinterStatus(machine)` (`main.js` ~840–950), populating `printerStatusCache[machine.id]` and broadcasting `printer-status-update`. OctoPrint/Moonraker/PrusaLink/etc. — already detected and configured here — **also expose a webcam**: OctoPrint at `/webcam/?action=stream` + `/webcam/?action=snapshot`, Moonraker/Klipper via crowsnest/mjpg-streamer (commonly `:8080/?action=stream` and `/?action=snapshot`). Webcam is the camera-shaped sibling of the status we already fetch — same host, same opt-in config, same poll cadence for snapshots. We reuse all of it rather than building a parallel transport.

---

## 2. Data model

### 2.1 Machine — new `webcam` block on the existing machine object
```
machine.webcam = {
  enabled:    false,           // opt-in per machine; off by default
  streamUrl:  '',              // MJPEG/HLS stream endpoint (full URL or host-relative path)
  snapshotUrl:'',              // still-image endpoint (preferred for cards/timelapse)
  streamType: 'mjpeg',         // 'mjpeg' | 'hls'  (snapshot path is type-independent)
  flipH:      false,
  flipV:      false,
  rotate:     0,               // 0 | 90 | 180 | 270 — render-time transform only
  timelapse:  'snapshot',      // 'host' | 'snapshot' | 'off'  (capture strategy, §5)
  cloudRelay: false            // Phase 2 opt-in; LAN-only until explicitly set
}
```
Stored on the machine like `printerApi`; `snapshotUrl`/`streamUrl` are not secrets (no masking), but **redacted from telemetry** sent to alerts/Cloud unless `cloudRelay` is on.

### 2.2 Order — timelapse reference (per print)
```
order.timelapse = {
  status:    'idle'|'capturing'|'ready'|'failed',
  machineId,                 // captured-from machine
  frameCount,
  source:    'host'|'snapshot',
  filePath,                  // local app-data path to the generated video (mp4)
  thumbPath, durationSec, sizeBytes, createdAt
}
```
Frames live in app-data (`<userData>/timelapse/<orderId>/`), not in the store blob; the order holds only the small ref. Reuses the order as the natural unit of work (one timelapse per print run, like the existing per-order artifacts).

---

## 3. Camera config & detection

- **Auto-suggest:** when `printerApi.type` is `octoprint`, query `GET /api/settings` and read `webcam.streamUrl` / `webcam.snapshotUrl` (OctoPrint reports them); for `moonraker`, query `GET /server/webcams/list` (Moonraker's webcam registry) and offer the configured cams. Pre-fill the fields; owner confirms. Detection is best-effort — failure just falls back to manual.
- **Manual URL:** always available — paste a stream URL and/or snapshot URL for **generic MJPEG / snapshot** cameras (ESP32-CAM, mjpg-streamer, RTSP-via-restreamer producing HLS). Host-relative paths resolve against `printerApi.host` + the webcam port.
- **Defaults by type:** OctoPrint → `:80/webcam/?action={stream,snapshot}`; Moonraker → `:8080/?action={stream,snapshot}`; generic → blank, manual. Owner can override.
- **Test button:** mirrors the existing API `btnTestApi` (`renderer/machines.js` ~257) — fetch one snapshot, show a thumbnail + OK/fail, the same UX as the live-API test.
- **Host validation:** webcam host runs through the **same `isAllowedPrinterHost()` guard** (`lib/host-guard.js`) — RFC1918 / link-local only — so the snapshot proxy cannot be turned into an SSRF to public/metadata endpoints, identical to `fetchPrinterStatus`.

---

## 4. Live view UX

- **Machine card (default):** when `webcam.enabled`, the card shows a **periodic snapshot** (not a live stream) refreshed on the existing ~30 s poll tick, alongside the current status line. Cheap, LAN-only, no persistent connection. `flip/rotate` applied via CSS transform at render time.
- **Live monitoring view:** the same snapshot, refreshed faster (e.g. 2–5 s) while the view is focused; integrates with the live-status surface referenced in the Phase 2 spec.
- **Full stream on demand:** click the snapshot → modal opens the **live MJPEG/HLS stream** (`<img src=streamUrl>` for MJPEG, `<video>`+hls.js for HLS). The stream connection exists **only while the modal is open** — bandwidth-aware by construction. Closing tears it down.
- **No-camera machines:** card renders exactly as today; zero visual change.
- **Offline:** snapshot fetch fails → show the last good frame dimmed + a small "camera offline" badge; never block the card or the status poll.

---

## 5. Timelapse

Two strategies, selected per machine (`webcam.timelapse`):

- **`host` (preferred when available):** delegate to the host's own timelapse. OctoPrint records a timelapse per print and exposes it at `GET /api/timelapse` (rendered MP4 list); on print completion, download the matching file and link it to the order. Zero frame management on our side, best quality. Moonraker has no native timelapse in core (the moonraker-timelapse plugin is optional) → fall back to `snapshot` unless the plugin is detected.
- **`snapshot` (universal fallback):** during a print, the poll loop pulls a frame from `snapshotUrl` on each tick (or a configurable interval) into `<userData>/timelapse/<orderId>/`. Print boundaries come from the status we already track: start when the active order's machine goes `printing` with progress rising; stop at `completed`/`finished`/cancel. On stop, **assemble frames into an MP4** (bundled ffmpeg, off the main thread) → write `order.timelapse.filePath` + thumbnail, set `status:'ready'`.
- **Linking:** the timelapse attaches to the **order**, viewable from the order detail and the machine card's recent-prints; a finished print shows a "timelapse ready" affordance.
- **Retention:** size cap + count cap in settings (default e.g. keep last N, prune oldest); large-file handling in §7.

---

## 6. Remote viewing

- **LAN-first (today):** because `streamUrl`/`snapshotUrl` point at the printer host on the LAN, the iOS companion in **LAN mode** (Phase 2 spec A1) renders the snapshot/stream directly — no Khayt server in the path. Free, private, no cloud.
- **Cloud relay (Phase 2, opt-in per machine — `webcam.cloudRelay`):** off-network viewing needs a relay because the printer host isn't internet-reachable. The desktop (the single connected node, Phase 2 A2) **pushes periodic snapshots** to the Cloud for relay-enabled machines; the phone/portal reads those. Default to **snapshots, not full stream** (bandwidth + cost); full live stream over Cloud is a later, explicitly-opted, possibly metered tier.
- **Privacy:** frames leave the LAN **only** when `cloudRelay` is set per machine, mirroring the AI spec's "leaves only when you say so." Cloud relays the per-machine snapshot the desktop chose to publish; it is never an open proxy into the LAN camera. Cloud off → remote camera simply unavailable; LAN unaffected.

---

## 7. Integration points (exact files/functions)

- **`renderer/machines.js`** — extend the machine edit modal (the `pro-only` API `<details>`, ~194–230) with a **Webcam** sub-block: enable toggle, stream/snapshot URL, streamType, flip/rotate, timelapse mode, detect + test buttons. Init `draft.webcam` defaults in `onMount` (~235, next to `printerApi`). Add the snapshot `<img>` + offline badge to the machine card render (`renderMachines`, ~18).
- **`main.js`** — add a **snapshot proxy** IPC handler (e.g. `hub:get-webcam-snapshot`) that fetches `snapshotUrl` through `isAllowedPrinterHost()` and returns image bytes (avoids renderer CORS, §8); add timelapse frame capture inside/alongside the `poll()` loop (~850) keyed off print state; add `hub:render-timelapse` (ffmpeg) and `hub:get-timelapse`. Reuse `defaultPrinterPort`/host-guard.
- **`lib/printer-alerts.js`** — no behavior change; the existing prev/curr status snapshot (~115) already gives the print-boundary transitions timelapse capture keys off. Optionally include a snapshot thumbnail URL in alert payloads (LAN-only).
- **Phase 2 (`docs/KHAYT-3.0-PHASE2-SPEC.md`)** — Cloud relay rides the desktop-as-single-node sync path; per-order timelapse ref piggybacks on the order projection (consented fields only).

---

## 8. Edge cases

- **Camera offline / host down:** snapshot/stream fail → last-good-frame + "offline" badge; status poll and the rest of the card are unaffected. Failed timelapse frames are skipped, not fatal.
- **Auth:** some webcams need the API key/Basic auth — pass `printerApi` creds via the **main-process** fetch (snapshot proxy), keeping secrets out of the renderer/DOM.
- **CORS:** direct `<img src>` MJPEG works cross-origin; *snapshot fetch for timelapse and the card thumbnail goes through the main-process proxy* so renderer CORS never blocks it.
- **Large files:** timelapse MP4s can be tens of MB — store in app-data (not the store blob, not exports), enforce retention caps, render off the main thread, and **never** auto-push video over Cloud (snapshots only by default).
- **Mixed content / HTTPS:** printer hosts are plain HTTP on the LAN; the proxy keeps the renderer from making blocked mixed-content requests.
- **Bandwidth:** card uses slow polled snapshots; full stream only while a modal is open; Cloud relay is snapshot-default and opt-in.

---

## 9. Test plan & DoD

- **Detection:** stubbed OctoPrint `/api/settings` and Moonraker `/server/webcams/list` → fields auto-fill; failure → manual fields, no crash.
- **Snapshot proxy:** a fake snapshot host returns an image → proxy returns bytes; a public/metadata host is **rejected** by `isAllowedPrinterHost` (reuse host-guard tests).
- **Card render:** `webcam.enabled` machine shows a snapshot with flip/rotate applied; offline host → last-good + badge; non-camera machine renders identically to today (assert no change).
- **Stream lifecycle:** opening the modal starts the stream, closing tears it down (no lingering connection).
- **Timelapse (snapshot mode):** simulated print (printing→completed via status cache) captures frames → ffmpeg renders an MP4 → `order.timelapse.status` becomes `ready` with a valid file + thumb; retention cap prunes oldest.
- **Timelapse (host mode):** stubbed OctoPrint `/api/timelapse` → file linked to the order on completion.
- **Privacy/Cloud-off:** with `cloudRelay` off, assert no frame leaves the LAN; with Cloud disconnected, remote camera unavailable and LAN behavior unchanged.

**DoD:** an owner can enable a camera per printer (auto-suggested or manual), see a live snapshot in the machine card and a full stream on demand — entirely over the LAN with no cloud — and get a per-print timelapse linked to the order. With no camera URL, the app is unchanged. Frames leave the LAN only for machines the owner explicitly opts into the Cloud relay.
