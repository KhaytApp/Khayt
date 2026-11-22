/**
 * A prerelease build has to accept prereleases, or it can never update.
 *
 * Bed Ready ships on a beta line, and every release on that line is marked pre-release on
 * GitHub. `/releases/latest` is computed while IGNORING prereleases, so an app that
 * refuses prereleases is pointed at either something OLDER than what is installed, or —
 * when no stable release exists at all — at a 404, which electron-updater reports as
 * "No published versions on GitHub" with the release sitting right there, assets and all.
 *
 * registerUpdater set the flavour default correctly. Then renderer/app-boot.js pushed the
 * user's `betaUpdates` preference — false by default — over it a moment after boot, and
 * the intent never survived startup. Verified against live GitHub with electron-updater's
 * own GitHubProvider: with allowPrerelease false it resolves 1.0.0-beta.7 while beta.9 is
 * published, which is exactly what the app and the website were both reporting.
 */
const Module = require('module');

// Keep a handle on the stub so the test can read what lib/updater.js set on it.
const autoUpdater = {
  autoDownload: false,
  autoInstallOnAppQuit: true,
  allowPrerelease: false,
  allowDowngrade: false,
  logger: null,
  on() {},
  checkForUpdates: async () => ({ updateInfo: {} }),
  downloadUpdate: async () => {},
  quitAndInstall() {},
};
const origRequire = Module.prototype.require;
Module.prototype.require = function (id) {
  if (id === 'electron-updater') return { autoUpdater };
  return origRequire.apply(this, arguments);
};

const { test } = require('node:test');
const assert = require('node:assert/strict');
const updater = require('../lib/updater');

Module.prototype.require = origRequire;

/** Boot the updater as main.js does, for a build of the given version. */
function boot(version) {
  autoUpdater.allowPrerelease = false;
  updater.registerUpdater({
    app: { getVersion: () => version, on() {}, whenReady: () => Promise.resolve() },
    fs: require('fs'),
    ipcMain: { handle() {}, on() {} },
    BrowserWindow: { getAllWindows: () => [], fromWebContents: () => null },
    encryptForDisk: (s) => s,
    dataFilePath: () => '/tmp/khayt-test-store.json',
    backupsDir: () => '/tmp',
  });
}

test('a beta build accepts prereleases even with the preference off', () => {
  boot('1.0.0-beta.9');
  assert.equal(autoUpdater.allowPrerelease, true, 'a beta build must start out accepting prereleases');

  // This is the call that broke it: app-boot.js pushes settings.betaUpdates, false by default.
  updater.applyUpdateOptions({ allowBeta: false });
  assert.equal(autoUpdater.allowPrerelease, true,
    'the renderer pushing betaUpdates=false must not strand a beta build on the stable channel');
});

test('a stable build follows the preference, both ways', () => {
  boot('1.0.0');
  assert.equal(autoUpdater.allowPrerelease, false, 'a stable build defaults to the stable channel');

  updater.applyUpdateOptions({ allowBeta: true });
  assert.equal(autoUpdater.allowPrerelease, true, 'opting into betas must work on a stable build');

  updater.applyUpdateOptions({ allowBeta: false });
  assert.equal(autoUpdater.allowPrerelease, false, 'opting back out must work too');
});

test('1.0.0 stable is not offered the beta it succeeds', () => {
  // The hazard in keying this on the flavour: Bed Ready would have gone on accepting
  // prereleases after 1.0 shipped, and 1.0.0-beta.9 is the newest entry in its feed.
  boot('1.0.0');
  updater.applyUpdateOptions({ allowBeta: false });
  const r = updater.interpretUpdateCheckResult({
    isPackaged: true,
    currentVersion: '1.0.0',
    updateInfo: { version: '1.0.0-beta.9' },
    allowBeta: false,
  });
  assert.equal(r.status, 'not-available', '1.0.0-beta.9 is not an update for 1.0.0');
});

test('a beta build is still offered the next beta', () => {
  boot('1.0.0-beta.9');
  updater.applyUpdateOptions({ allowBeta: false });
  const r = updater.interpretUpdateCheckResult({
    isPackaged: true,
    currentVersion: '1.0.0-beta.9',
    updateInfo: { version: '1.0.0-beta.10' },
    // The effective value the app now passes — not the raw preference, which would
    // discard the very release the check just found.
    allowBeta: true,
  });
  assert.equal(r.status, 'available');
  assert.equal(r.version, '1.0.0-beta.10');
});

test('a beta build is offered the stable release of its own line', () => {
  boot('1.0.0-beta.9');
  const r = updater.interpretUpdateCheckResult({
    isPackaged: true, currentVersion: '1.0.0-beta.9',
    updateInfo: { version: '1.0.0' }, allowBeta: true,
  });
  assert.equal(r.status, 'available', '1.0.0 is newer than 1.0.0-beta.9');
});

test('an older release is never an update', () => {
  boot('1.0.0-beta.9');
  const r = updater.interpretUpdateCheckResult({
    isPackaged: true, currentVersion: '1.0.0-beta.9',
    updateInfo: { version: '1.0.0-beta.7' }, allowBeta: true,
  });
  assert.equal(r.status, 'not-available', 'beta.7 must never be offered to beta.9');
});
