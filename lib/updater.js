'use strict';

const fs = require('fs');
const path = require('path');
const { autoUpdater } = require('electron-updater');
const { safeJsonParse } = require('./safe-json');
const { formatReleaseNotesForDisplay } = require('./release-notes');
const { parseMajorChanges } = require('./major-changes');
const { normalizeStoreSnapshot } = require('./store-validate');
const { MAX_STORE_BYTES } = require('./store-io');
const { isBedReady, productName } = require('./flavor');

// Bed Ready ships from this same repo but on its OWN release lane: the public
// KhaytApp/bedready repo (wired as the `publish` provider in
// electron-builder.bedready.js, so app-update.yml points there — NOT at Khayt's
// feed). The manual "get the latest build" link points at that repo's releases.
const RELEASES_URL = isBedReady
  ? 'https://github.com/KhaytApp/bedready/releases/latest'
  : 'https://github.com/khaytapp/Khayt/releases/latest';

// electron-updater logs nothing unless given a logger, which made a stalled
// download undiagnosable in the field: no feed URL, no chosen asset, no byte
// counts, nothing. console goes to the packaged app's stderr, which is
// reachable via `Console.app` or by launching the binary from a terminal.
// Deliberately not electron-log — that is another dependency in the auto-update
// path, which is the one path that must not acquire new failure modes.
autoUpdater.logger = {
  info:  (m) => console.log('[updater]', m),
  warn:  (m) => console.warn('[updater]', m),
  error: (m) => console.error('[updater]', m),
  debug: () => {},
};

autoUpdater.autoDownload = false;
autoUpdater.autoInstallOnAppQuit = true;
// Never auto-offer an older release as an "update" (electron-updater can emit a
// downgrade when the running build is a prerelease and /releases/latest is stable).
autoUpdater.allowDowngrade = false;

/** @param {string} v */
function isPrereleaseVersion(v) {
  return /-(alpha|beta|rc)(\.|$)/i.test(String(v || ''));
}

/** @param {string} v */
function versionParts(v) {
  return String(v || '').split('-')[0].split('.').map((n) => parseInt(n, 10) || 0);
}

/** Prerelease tag after the first '-', or '' for a stable release. */
function prereleaseTag(v) {
  const s = String(v || '');
  const i = s.indexOf('-');
  return i < 0 ? '' : s.slice(i + 1);
}

/** Semver prerelease precedence: returns >0 if `a` is higher, <0 if lower, 0 if equal. */
function comparePrerelease(a, b) {
  if (a === b) return 0;
  const pa = a.split('.');
  const pb = b.split('.');
  const len = Math.max(pa.length, pb.length);
  for (let i = 0; i < len; i++) {
    const x = pa[i];
    const y = pb[i];
    if (x === undefined) return -1; // shorter set of identifiers is lower precedence
    if (y === undefined) return 1;
    const xn = /^\d+$/.test(x);
    const yn = /^\d+$/.test(y);
    if (xn && yn) {
      const d = parseInt(x, 10) - parseInt(y, 10);
      if (d !== 0) return d < 0 ? -1 : 1;
    } else if (xn !== yn) {
      return xn ? -1 : 1; // numeric identifiers rank lower than alphanumeric
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}

/**
 * True when `latest` is strictly greater than `current` (semver-aware).
 * Numeric parts compare first; on a tie a stable release outranks any
 * prerelease of the same number (e.g. 2.4.0 > 2.4.0-beta.2 > 2.4.0-beta.1).
 */
function isVersionNewer(latest, current) {
  const a = versionParts(latest);
  const b = versionParts(current);
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i++) {
    if ((a[i] || 0) > (b[i] || 0)) return true;
    if ((a[i] || 0) < (b[i] || 0)) return false;
  }
  // Numeric parts equal — compare prerelease precedence.
  const pa = prereleaseTag(latest);
  const pb = prereleaseTag(current);
  if (pa === pb) return false;
  if (!pa) return true;   // latest is the stable release of the same number → newer
  if (!pb) return false;  // latest is a prerelease of an already-released number → not newer
  return comparePrerelease(pa, pb) > 0;
}

/**
 * @param {{ isPackaged: boolean, currentVersion: string, updateInfo?: { version?: string }, error?: unknown, allowBeta?: boolean }} input
 */
/**
 * Can this install replace itself?
 *
 * electron-updater only updates AppImage on Linux — it detects that through the
 * APPIMAGE environment variable, and `isUpdaterActive()` returns false without
 * it. A `.deb` install therefore gets a check that resolves with NO updateInfo,
 * which used to fall through to "not-available" and tell the user they were on
 * the latest version. That was untrue whenever a newer one existed, and it
 * became reachable the moment latest-linux.yml started being published.
 *
 * Snap has its own update mechanism and is excluded for the same reason
 * electron-updater excludes it: the store handles it, so saying anything here
 * would be wrong in the other direction.
 */
function canSelfUpdate(platform = process.platform, env = process.env, feedPresent = true) {
  // No app-update.yml, no update check — on any platform. electron-builder bakes
  // that file from the `publish` config, and a `--dir` build never gets one; the
  // resulting bundle is still app.isPackaged === true, so it took the packaged
  // path, asked electron-updater to read a file that was not there, and showed
  // the owner a raw
  //     ENOENT: no such file or directory, open '.../Resources/app-update.yml'
  // which names a path they cannot act on and does not say what is wrong. This
  // install simply cannot update itself, which is a state already understood
  // here and already worded for a human.
  if (!feedPresent) return false;
  if (platform !== 'linux') return true;
  return !!env.APPIMAGE || !!env.SNAP;
}

/** Is the update feed electron-builder bakes at packaging time actually present? */
function updateFeedPresent(resourcesPath = process.resourcesPath, exists = fs.existsSync) {
  if (!resourcesPath) return false;
  try { return !!exists(path.join(resourcesPath, 'app-update.yml')); } catch (_) { return false; }
}

/**
 * Turn an update-check failure into something a shop can act on.
 *
 * The old branch was `String(error?.message || error)` — the library's own words,
 * verbatim, on the dashboard. That is the same defect the printer audit found in
 * #769, where OctoPrint's 409 (which means "no printer is connected to me", most
 * of a normal day) reached the shop as `HTTP 409`. Here the commonest case by far
 * is a laptop with no internet, and what it printed was:
 *
 *     ⚠ Update check failed: getaddrinfo ENOTFOUND github.com
 *
 * which names a hostname, a syscall, and nothing the owner of a print shop can
 * do. The second commonest is a release whose platform manifest is missing, and
 * that one printed a full URL.
 *
 * DISPATCH IS ON `code`, NOT ON THE MESSAGE TEXT. `builder-util-runtime`'s
 * `newError` sets `error.code` to a stable identifier, and its `HttpError` sets
 * both `code = HTTP_ERROR_<n>` and `statusCode`. Matching on those is matching on
 * what the library MEANS; matching on the sentence would break the first time it
 * was reworded, silently, back to showing nothing useful.
 *
 * AN UNRECOGNISED ERROR KEEPS ITS RAW MESSAGE. That is deliberate and it is the
 * carrier audit's rule: an unreadable thing must not be answered as though it
 * were handled. Inventing a friendly sentence for a fault nobody has classified
 * hides a real problem behind a reassuring one, and the shop then reports "it
 * says something went wrong" with nothing to chase.
 *
 * The raw text is never thrown away either — it comes back as `detail`, so the
 * explanation is what is read and the original is still there to be quoted.
 *
 * @returns {{ message: string, detail: string|null }}
 */
function explainUpdateError(error) {
  const raw = String(error?.message || error || 'Update check failed');
  const code = String(error?.code || '');
  const status = Number(error?.statusCode);
  const say = (message) => ({ message, detail: raw });

  // Offline, DNS, a captive portal, a dropped connection. Node and Chromium
  // spell these differently and they all mean the same thing to a shop.
  const NETWORK = ['ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED', 'ECONNRESET',
    'ETIMEDOUT', 'ENETUNREACH', 'EHOSTUNREACH', 'ERR_INTERNET_DISCONNECTED'];
  if (NETWORK.includes(code) || /^net::ERR_/.test(code) || /net::ERR_/.test(raw)) {
    return say(`Could not reach GitHub to check for updates — this usually means no internet connection. ${productName} will try again later.`);
  }

  if (Number.isFinite(status)) {
    // Not a fault of this install, and not the shop's to fix. GitHub rate-limits
    // unauthenticated callers per IP, so a busy office network can hit it.
    if (status === 403 || status === 429) {
      return say('GitHub is temporarily refusing update checks from this network. It usually clears within an hour.');
    }
    if (status >= 500) {
      return say('GitHub is having trouble right now, so the update check could not finish. Nothing is wrong with this install.');
    }
  }

  switch (code) {
    // electron-updater asks GitHub for /releases/latest, which GitHub computes
    // while IGNORING prereleases. On a line that has only ever had betas that
    // endpoint 404s, and the library says "No published versions on GitHub" with
    // the release sitting right there. See mustAllowPrerelease().
    case 'ERR_UPDATER_NO_PUBLISHED_VERSIONS':
      return say(`No stable release has been published for this version line yet. If you are running a beta, turn on beta updates in Settings so ${productName} looks at the beta channel.`);
    // The release exists and does not carry an update manifest for this
    // platform. Real here rather than theoretical: cuts are routinely Windows +
    // Linux only, and macOS is served by a manifest carried forward from an
    // earlier release. If that carry ever failed, this is what a mac user sees.
    case 'ERR_UPDATER_CHANNEL_FILE_NOT_FOUND':
      return say('The latest release does not include an update file for this platform yet. That is a problem with the release rather than with this install — try again later, or download it manually.');
    case 'ERR_UPDATER_INVALID_RELEASE_FEED':
      return say(`GitHub returned a release list ${productName} could not read. That is usually temporary.`);
    case 'ERR_UPDATER_INVALID_VERSION':
      return say(`This build reports a version ${productName} cannot compare against the published releases, so it cannot tell whether an update exists.`);
    default:
      // Deliberately unexplained — see the note above.
      return { message: raw, detail: null };
  }
}

function interpretUpdateCheckResult({ isPackaged, currentVersion, updateInfo, error, allowBeta = false, selfUpdatable = true }) {
  // Checked before the error branch: on a .deb the check does not fail, it just
  // comes back empty, so an error is not what needs explaining.
  if (isPackaged && !selfUpdatable) {
    return {
      status: 'manual',
      currentVersion,
      releasesUrl: RELEASES_URL,
      message: `This install cannot update itself — download the latest version from ${RELEASES_URL}.`,
    };
  }
  if (!isPackaged) {
    return {
      status: 'dev',
      currentVersion,
      releasesUrl: RELEASES_URL,
      message: isBedReady
        ? `In-app updates work in the installed Bed Ready app. Get the latest build at ${RELEASES_URL}.`
        : 'In-app updates work in the installed Khayt app. Download the latest release from GitHub, or build/install the DMG.',
    };
  }
  if (error) {
    const { message, detail } = explainUpdateError(error);
    return { status: 'error', currentVersion, message, detail };
  }
  const latest = updateInfo?.version;
  if (latest && !allowBeta && isPrereleaseVersion(latest)) {
    return {
      status: 'not-available',
      currentVersion,
      latestVersion: currentVersion,
    };
  }
  if (latest && isVersionNewer(latest, currentVersion)) {
    const releaseNotes = typeof updateInfo?.releaseNotes === 'string'
      ? updateInfo.releaseNotes
      : '';
    return {
      status: 'available',
      currentVersion,
      version: latest,
      releaseDate: updateInfo?.releaseDate || null,
      releaseNotes,
      /* THE GATE HAS TO TRAVEL WITH EVERY ROUTE TO THE MODAL, NOT ONE OF THEM.
       *
       * This returned no `majorChanges`, and renderer/update-ui.js does
       * `majorChanges: info.majorChanges || null` — so a manual "Check for
       * updates" opened the modal ungated, consent panel absent, Download live.
       *
       * It was masked only by ordering: the `update-available` event usually
       * reaches the renderer first and a latch suppresses the duplicate. That
       * masking fails on macOS, where closing the window and reopening it from
       * the dock leaves the updater's listeners bound to a destroyed window —
       * so the manual check becomes the ONLY path, and it was the ungated one. */
      majorChanges: parseMajorChanges(releaseNotes),
    };
  }
  return {
    status: 'not-available',
    currentVersion,
    latestVersion: latest || currentVersion,
  };
}

/**
 * Auto-updater event wiring and hub:*-update* IPC handlers.
 * @param {{ app: import('electron').App, fs: typeof import('fs'), ipcMain: import('electron').IpcMain, BrowserWindow: typeof import('electron').BrowserWindow, encryptForDisk: Function, dataFilePath: () => string, backupsDir: () => string }} deps
 */
/** @type {{ allowBeta: boolean }} */
let updatePrefs = { allowBeta: false };

/**
 * The version this build IS. Set by registerUpdater; '' before that, which reads as
 * "not a prerelease" and so changes nothing for anyone.
 */
let runningVersion = '';

/**
 * Must this build accept prerelease releases, whatever the preference says?
 *
 * Yes, when the build is itself a prerelease — because then nothing else can ever be an
 * update for it. Every release newer than 1.0.0-beta.9 on that line is 1.0.0-beta.10 and
 * up, all of them prereleases; refusing prereleases leaves the app looking only at
 * `/releases/latest`, which GitHub computes while ignoring prereleases and which
 * therefore answers with something OLDER than what is already installed. When no
 * non-prerelease exists at all, that endpoint 404s and electron-updater reports "No
 * published versions on GitHub" — with the release sitting right there, assets and all.
 *
 * This is what stranded Bed Ready. registerUpdater set the flavour default correctly,
 * and then app-boot.js pushed the user's `betaUpdates` preference — false by default —
 * straight over it a moment after boot, so the intent below never survived startup.
 *
 * The preference keeps its meaning: it governs whether a STABLE build opts into the beta
 * lane. It just cannot strand a beta build on a channel that has nothing newer for it.
 */
function mustAllowPrerelease() {
  return updatePrefs.allowBeta || isPrereleaseVersion(runningVersion);
}

/** @param {{ allowBeta?: boolean }} opts */
function applyUpdateOptions(opts = {}) {
  if (typeof opts.allowBeta === 'boolean') {
    updatePrefs.allowBeta = opts.allowBeta;
  }
  autoUpdater.allowPrerelease = mustAllowPrerelease();
  return { ...updatePrefs };
}

function registerUpdater({ app, fs, ipcMain, BrowserWindow, encryptForDisk, dataFilePath, backupsDir, writeStoreToDisk }) {
  // What this build is decides whether it can accept prereleases; see
  // mustAllowPrerelease(). Deliberately NOT keyed on the flavour any more: keying it on
  // Bed Ready made a future 1.0.0 stable go on following the beta lane for ever, and it
  // did not survive the renderer pushing the user's preference at boot regardless.
  runningVersion = app.getVersion();
  applyUpdateOptions({});

  function setupAutoUpdater(win) {
    autoUpdater.on('update-available', (info) => {
      if (!win || win.isDestroyed()) return;
      // Gate the automatic event through the SAME logic as the manual check so the
      // update modal only auto-pops for a genuinely newer, allowed release. Without
      // this, electron-updater's raw event can prompt a beta when beta updates are
      // off, or even offer a downgrade — the "glitchy" repeated/incorrect prompts.
      const interpreted = interpretUpdateCheckResult({
        isPackaged: true,
        currentVersion: app.getVersion(),
        updateInfo: info,
        // The same value that let the check FIND this release, not the raw preference —
        // otherwise a beta build resolves 1.0.0-beta.10 and then discards it here as
        // "prerelease not allowed", which is the filter at line 166.
        allowBeta: mustAllowPrerelease(),
      });
      if (interpreted.status !== 'available') return;
      const notes = typeof info.releaseNotes === 'string' ? info.releaseNotes : '';
      /* A release may declare the changes somebody has to agree to before it is
       * allowed to happen — see lib/major-changes.js. Parsed HERE rather than in
       * the renderer so the answer travels with the offer: a renderer that had
       * to ask for it separately could show the download button first and the
       * warning second, which is the wrong order for a gate. */
      win.webContents.send('update-available', {
        version:      info.version,
        releaseDate:  info.releaseDate,
        releaseNotes: notes,
        majorChanges: parseMajorChanges(notes)
      });
    });

    autoUpdater.on('update-not-available', (info) => {
      if (!win || win.isDestroyed()) return;
      win.webContents.send('update-not-available', {
        version: info.version,
      });
    });

    autoUpdater.on('download-progress', (progress) => {
      if (!win || win.isDestroyed()) return;
      win.webContents.send('update-download-progress', {
        percent:        Math.round(progress.percent),
        transferred:    progress.transferred,
        total:          progress.total,
        bytesPerSecond: progress.bytesPerSecond
      });
    });

    autoUpdater.on('update-downloaded', (info) => {
      if (!win || win.isDestroyed()) return;
      win.webContents.send('update-downloaded', { version: info.version });
    });

    autoUpdater.on('error', (err) => {
      console.error('[updater]', err?.message || err);
      if (!win || win.isDestroyed()) return;
      win.webContents.send('update-error', { message: String(err?.message || err || 'Unknown update error') });
    });

    // Poll once shortly after boot. Both flavors have a publish feed baked in
    // (Khayt → KhaytApp/Khayt, Bed Ready → KhaytApp/bedready via app-update.yml),
    // so each checks its OWN release lane.
    // Skipped on an install that cannot replace itself (a .deb): the check can
    // only come back empty there, and a pointless network call on every launch
    // is not worth the log line it produces.
    if (app.isPackaged && canSelfUpdate(process.platform, process.env, updateFeedPresent())) {
      setTimeout(() => autoUpdater.checkForUpdates().catch(() => {}), 12_000);
    }
  }

  ipcMain.handle('hub:start-update-download', async () => {
    try {
      await autoUpdater.downloadUpdate();
      return { ok: true };
    } catch (err) {
      const message = String(err?.message || err || 'Download failed');
      console.error('[updater] downloadUpdate failed:', message);
      const win = BrowserWindow.getAllWindows()[0];
      if (win && !win.isDestroyed()) win.webContents.send('update-error', { message });
      return { ok: false, error: message };
    }
  });

  ipcMain.handle('hub:install-update', async (_e, storeSnapshot) => {
    // Renderer should flush via hub:save-store before calling this. Re-writing the full
    // snapshot here duplicated encrypt+write and could hang the UI on large stores.
    if (storeSnapshot && typeof storeSnapshot === 'object' && storeSnapshot.__forceFlush) {
      // THROUGH THE SHARED WRITER, not a copy of it.
      //
      // This used to write the store by hand:
      //
      //     const tmp = fp + '.tmp';
      //     await fs.promises.writeFile(tmp, serialized, 'utf8');
      //     await fs.promises.rename(tmp, fp);
      //
      // Four things wrong with that, all of them at the one moment the binary is
      // about to be replaced and the app cannot try again:
      //
      //   * NO FSYNC. writeFile then rename leaves the bytes in the page cache;
      //     a power loss during the install can leave an empty or partial store.
      //     atomicWriteStore fsyncs the temp before swapping it in.
      //   * NO .prev GENERATION. The rename overwrote the primary without
      //     rotating it, so the rollback copy crash recovery reads was left
      //     describing a store two saves old.
      //   * THE BARE `fp.tmp` NAME, which recoverStoreRaw scans as a legacy
      //     recovery candidate — so an interrupted flush left a file that the
      //     next launch would consider restoring from.
      //   * OUTSIDE THE WRITE CHAIN. A renderer save already queued could land
      //     between this rename and its own, crossing two generations. Exactly
      //     the race fixed for every LAN endpoint in #898.
      //
      // The renderer is supposed to have flushed via hub:save-store already, so
      // a failure here is logged and the install still proceeds — but it is
      // logged loudly, because it means the last edits are only as durable as
      // that earlier save.
      try {
        const draft = { ...storeSnapshot };
        delete draft.__forceFlush;
        const { normalized, errors } = normalizeStoreSnapshot(draft);
        if (errors?.length) {
          console.error('[update] flush-save skipped: invalid snapshot', errors);
        } else if (typeof writeStoreToDisk === 'function') {
          await writeStoreToDisk(normalized);
        } else {
          console.error('[update] flush-save skipped: no writer was provided');
        }
      } catch (e) {
        console.error('[update] flush-save FAILED — the last edits rest on the earlier save:', e?.message);
      }
    }
    setTimeout(() => autoUpdater.quitAndInstall(false, true), 150);
  });

  ipcMain.handle('hub:set-update-options', async (_e, opts) => {
    return { ok: true, ...applyUpdateOptions(opts || {}) };
  });

  ipcMain.handle('hub:check-for-updates', async () => {
    const currentVersion = app.getVersion();
    if (!app.isPackaged) {
      return interpretUpdateCheckResult({ isPackaged: false, currentVersion });
    }
    try {
      const result = await autoUpdater.checkForUpdates();
      const interpreted = interpretUpdateCheckResult({
        isPackaged: true,
        currentVersion,
        updateInfo: result?.updateInfo,
        // The same value that let the check FIND this release, not the raw preference —
        // otherwise a beta build resolves 1.0.0-beta.10 and then discards it here as
        // "prerelease not allowed", which is the filter at line 166.
        allowBeta: mustAllowPrerelease(),
        selfUpdatable: canSelfUpdate(process.platform, process.env, updateFeedPresent()),
      });
      if (interpreted.status === 'error') {
        const win = BrowserWindow.getAllWindows()[0];
        if (win && !win.isDestroyed()) {
          win.webContents.send('update-error', { message: interpreted.message });
        }
      }
      return interpreted;
    } catch (err) {
      console.error('[updater] checkForUpdates failed:', err?.message || err);
      const interpreted = interpretUpdateCheckResult({
        isPackaged: true,
        currentVersion,
        error: err,
      });
      const win = BrowserWindow.getAllWindows()[0];
      if (win && !win.isDestroyed()) {
        win.webContents.send('update-error', { message: interpreted.message });
      }
      return interpreted;
    }
  });

  ipcMain.handle('hub:format-release-notes', (_e, releaseNotes, opts) =>
    formatReleaseNotesForDisplay(releaseNotes, opts || {}));

  ipcMain.handle('hub:write-update-backup', async (_e, jsonString, newVersion) => {
    const safeVer  = String(newVersion || 'unknown').replace(/[^a-zA-Z0-9._-]/g, '');
    // The owner's calendar day — this ends up in a filename they scan through
    // later ("which backup is from the day it broke?"), and a UTC day labels an
    // early-morning backup with yesterday's date in the Gulf.
    const now      = new Date();
    const dateStr  = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
    const filename = `pre-update-v${safeVer}-${dateStr}.json`;
    const fullPath = path.join(backupsDir(), filename);
    const storePath = dataFilePath();

    // Fast path: copy the on-disk store (already encrypted) — avoids multi‑MB IPC + re-encrypt.
    if (!jsonString || jsonString === '__COPY_STORE__') {
      try {
        if (!fs.existsSync(storePath)) return { ok: false, error: 'no store file' };
        await fs.promises.copyFile(storePath, fullPath);
        return { ok: true, path: fullPath, copied: true };
      } catch (e) {
        return { ok: false, error: String(e?.message || e) };
      }
    }

    if (typeof jsonString !== 'string' || jsonString.length > MAX_STORE_BYTES) {
      return { ok: false, error: 'invalid' };
    }
    let parsed;
    try { parsed = safeJsonParse(jsonString); } catch { return { ok: false, error: 'bad json' }; }
    try {
      await fs.promises.writeFile(fullPath, JSON.stringify(encryptForDisk(parsed)), 'utf8');
      return { ok: true, path: fullPath };
    } catch (e) {
      return { ok: false, error: String(e?.message || e) };
    }
  });

  return { setupAutoUpdater };
}

module.exports = {
  registerUpdater,
  applyUpdateOptions,
  isVersionNewer,
  isPrereleaseVersion,
  interpretUpdateCheckResult,
  explainUpdateError,
  canSelfUpdate,
  updateFeedPresent,
  RELEASES_URL,
};
