'use strict';
(function () {

/**
 * Flavor — which product this build is: Khayt (the full business app) or
 * Bed Ready (the standalone maker app). ONE repo, one shared core; the flavor
 * decides which entry HTML loads, the window branding, and whether business-only
 * main-process code is wired up.
 *
 * Resolution order (first match wins):
 *   1. process.env.KHAYT_FLAVOR — explicit override for dev / CI
 *      (e.g. `KHAYT_FLAVOR=bedready npm start`).
 *   2. A `flavor` marker file in the packaged app's resources dir, written by the
 *      electron-builder `afterPack` hook (see electron-builder.bedready.js). This
 *      lives ONLY in the build output — it never touches the source tree — so the
 *      shipped Bed Ready build identifies itself without an env var. In dev,
 *      process.resourcesPath points at Electron's own resources (no marker), so
 *      this cleanly falls through to the default.
 *   3. Default 'khayt' — so the existing Khayt build/behaviour is unchanged.
 *
 * Main-process only (uses `process`/`require`). Not loaded in the sandboxed
 * renderer. Pure aside from those reads, so it can be unit-checked.
 */

const FLAVOR_MARKER = 'flavor'; // filename in Resources/, written by afterPack

function resolveFlavor() {
  try {
    const env = String((process && process.env && process.env.KHAYT_FLAVOR) || '').toLowerCase();
    if (env === 'bedready' || env === 'khayt') return env;
  } catch (_) { /* no process — fall through */ }

  try {
    const fs = require('fs');
    const path = require('path');
    if (process && process.resourcesPath) {
      const marker = path.join(process.resourcesPath, FLAVOR_MARKER);
      if (fs.existsSync(marker)) {
        const v = String(fs.readFileSync(marker, 'utf8')).trim().toLowerCase();
        if (v === 'bedready' || v === 'khayt') return v;
      }
    }
  } catch (_) { /* no fs / not packaged — fall through */ }

  return 'khayt';
}

const FLAVOR = resolveFlavor();

const api = {
  FLAVOR,
  isBedReady: FLAVOR === 'bedready',
  isKhayt: FLAVOR === 'khayt',
  /** Entry HTML for this flavor, relative to renderer/. */
  entryHtml: FLAVOR === 'bedready' ? 'bedready.html' : 'index.html',
  /** Human-facing product name for window title / branding. */
  productName: FLAVOR === 'bedready' ? 'Bed Ready' : 'Khayt',
};

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytFlavor = api;

})();
