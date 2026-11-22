'use strict';

/**
 * electron-builder config for the BED READY flavor.
 *
 * Bed Ready is the standalone maker app built from this same repo and shared core.
 * This config inherits Khayt's base `build` block (so platform targets, dmg/nsis
 * options, etc. never drift) and overrides only what makes it a separate, smaller
 * product:
 *   - its own appId / productName / output dir / (no) publish target;
 *   - an `afterPack` hook that writes a `flavor` marker file into the packaged
 *     app's resources dir. lib/flavor.js reads it at runtime (via
 *     process.resourcesPath) to route main.js to renderer/bedready.html and skip
 *     business-only main-process wiring. This marker lives ONLY in the build
 *     output — it never modifies the source tree.
 *   - a trimmed `files` glob that EXCLUDES the business renderer modules that
 *     bedready.html does not load — this is what makes the download genuinely
 *     smaller (~0.85 MB of renderer JS never shipped).
 *
 * NOTE: we deliberately do NOT use electron-builder `extraMetadata` to bake the
 * flavor/version — for this repo layout (app at project root) it rewrites the
 * SOURCE package.json in place (strips scripts, injects version) and does not
 * restore it. Instead, Bed Ready's independent version (1.0.0-*) is baked by the
 * scripts/build-bedready.mjs wrapper, which swaps package.json's version for the
 * duration of the electron-builder run and restores the exact source bytes in a
 * finally. The afterPack marker (below) is what routes the runtime to bedready.
 *
 * Build:  npm run pack:bedready            (unpacked, quick — via the wrapper)
 *         npm run dist:bedready:mac:arm64  (installer — via the wrapper)
 * Dev:    npm run start:bedready
 *
 * The build always goes through the wrapper (the npm scripts call
 * scripts/build-bedready.mjs, never electron-builder directly) so the version
 * bake + restore is guaranteed. Branded icons + Sentry/OTel trim are configured
 * below.
 */

const base = require('./package.json').build;

// Business renderer modules that renderer/bedready.html deliberately does NOT
// <script>-include. Excluding them from the package is the size win. Keep this
// list in lockstep with the tags dropped in bedready.html.
const EXCLUDED_BUSINESS_RENDERER = [
  'analytics.js',
  'order-flows.js',
  'integrations.js',
  'invoicing.js',
  'clients.js',
  'operations-extras.js',
  'expenses.js',
  'logs.js',
  'waiting-list.js',
  'views.js',
  'online.js',
];

// The 8 alternate Khayt theme designs. Bed Ready ships ONE bespoke look
// (bedready-theme.css), so their CSS is never linked → exclude it from the
// package. The small per-theme shell JS stays (it's optional-chained and only
// activates for a design Bed Ready never selects). handoff-screens.css and the
// theme registry JS are shared/kept.
const EXCLUDED_THEME_DIRS = [
  'ledger', 'console', 'atelier', 'vitrine', 'cockpit',
  'atlas', 'workbench', 'vivid', 'command',
];

module.exports = {
  ...base,

  appId: 'app.bedready.desktop',
  productName: 'Bed Ready',

  // Register the `bedready://` URL scheme so the website's sign-in handoff
  // (bedready://auth#access_token=…&refresh_token=…) actually routes to the app.
  // At build time electron-builder bakes this into the macOS Info.plist
  // (CFBundleURLTypes) and the Windows NSIS installer / Linux .desktop handler.
  // main.js also calls app.setAsDefaultProtocolClient('bedready') at runtime, but
  // on macOS LaunchServices only honours the scheme when it's declared here.
  protocols: [{ name: 'Bed Ready', schemes: ['bedready'] }],

  // Separate output dir so Bed Ready artifacts never clobber Khayt's build/.
  directories: {
    ...base.directories,
    output: 'build-bedready',
  },

  // Bed Ready's own release lane: the public KhaytApp/bedready repo (downloads
  // only — the source stays in KhaytApp/Khayt). Setting this makes electron-builder
  // bake `app-update.yml` into the app AND emit the update-feed metadata
  // (latest-mac.yml / latest.yml / latest-linux.yml + .blockmap) alongside the
  // installers, which is what electron-updater needs to auto-update the app.
  // Uploading is done by the release step (CI for win/linux, local for the signed
  // mac build) — not by electron-builder (we pass --publish never at build time).
  publish: [{ provider: 'github', owner: 'KhaytApp', repo: 'bedready' }],

  // NOTE: we intentionally do NOT try to set `updaterCacheDirName` here. It is a computed
  // getter in electron-builder 26 (derived from the package `name`, "khayt-updater") and is
  // NOT a valid config property — setting it fails schema validation and breaks every dist
  // build. Consequence: a machine with BOTH Khayt and Bed Ready shares one electron-updater
  // cache (~/Library/Caches/khayt-updater). This is a benign known-minor — the cached update
  // files are named per-artifact (BedReady-… vs Khayt-…) so blobs never collide; the only
  // shared file is update-info.json, whose worst case is one app re-checking/re-downloading an
  // update. Not worth the fragile afterPack app-update.yml rewrite it would take to change.

  // Write the flavor marker into the packaged app's resources dir (build output
  // only — never the source tree). lib/flavor.js reads it via process.resourcesPath.
  afterPack: async (context) => {
    const fs = require('fs');
    const path = require('path');
    let resourcesDir;
    try {
      resourcesDir = context.packager.getResourcesDir(context.appOutDir);
    } catch (_) {
      // Fallback: derive per platform. mac bundles into <productName>.app/Contents/Resources.
      if (context.electronPlatformName === 'darwin') {
        const appName = `${context.packager.appInfo.productFilename}.app`;
        resourcesDir = path.join(context.appOutDir, appName, 'Contents', 'Resources');
      } else {
        resourcesDir = path.join(context.appOutDir, 'resources');
      }
    }
    fs.writeFileSync(path.join(resourcesDir, 'flavor'), 'bedready\n', 'utf8');
  },

  files: [
    'main.js',
    'preload.js',
    'lib/**/*',
    'renderer/**/*',
    'assets/**/*',
    'package.json',
    // Ship the Bed Ready entry, not Khayt's — and drop the business renderer JS.
    '!renderer/index.html',
    ...EXCLUDED_BUSINESS_RENDERER.map((f) => `!renderer/${f}`),
    // Drop the 8 alternate theme designs' CSS (bespoke look ships instead).
    ...EXCLUDED_THEME_DIRS.map((d) => `!renderer/themes/${d}/*.css`),
    '!renderer/themes/theme-picker.css',
    // Bed Ready does not initialise Sentry (main.js gates it behind !isBedReady),
    // so the crash-reporter SDK and its OpenTelemetry tree are dead weight — drop
    // them for a ~55 MB smaller install. Safe: the ENTIRE @sentry / @opentelemetry
    // / @fastify/otel subtree reaches the app ONLY via @sentry/electron (verified
    // with `npm why`), which Bed Ready never loads. The `**/` variants catch the
    // nested copies electron-builder hoists under intermediate packages.
    '!node_modules/@sentry/**',
    '!node_modules/@sentry-internal/**',
    '!node_modules/@opentelemetry/**',
    '!node_modules/@fastify/otel/**',
    '!node_modules/**/@sentry/**',
    '!node_modules/**/@sentry-internal/**',
    '!node_modules/**/@opentelemetry/**',
    '!node_modules/**/@fastify/otel/**',
  ],

  // Bed Ready branded icons (spectrum print-bed mark).
  // Space-free, platform+arch-tagged artifact names so the download URLs on the
  // website are stable and predictable (GitHub munges spaces in asset URLs).
  mac: { ...(base.mac || {}), icon: 'assets/bedready.icns', artifactName: 'BedReady-${version}-mac-${arch}.${ext}' },
  // Drop the appx target — the Microsoft Store package needs a signing cert we
  // don't ship for the public beta. Bed Ready's Windows download is the NSIS
  // installer + a portable .exe (neither needs a cert to produce).
  win: { ...(base.win || {}), icon: 'assets/bedready-512.png', target: ['nsis', 'portable'] },
  linux: {
    ...(base.linux || {}), icon: 'assets/bedready-512.png', target: ['AppImage', 'deb'],
    category: 'Graphics',
    description: 'Desktop 3D-printing maker app — convert, recolour, preview and queue your prints.',
    artifactName: 'BedReady-${version}-linux-${arch}.${ext}',
  },

  dmg: {
    ...(base.dmg || {}),
    title: 'Bed Ready ${version}',
    artifactName: 'BedReady-${version}-mac-${arch}.${ext}',
  },

  nsis: {
    ...(base.nsis || {}),
    shortcutName: 'Bed Ready',
    artifactName: 'BedReady-${version}-win-${arch}-Setup.${ext}',
  },

  portable: {
    artifactName: 'BedReady-${version}-win-${arch}-portable.${ext}',
  },
};
