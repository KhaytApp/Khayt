const Module = require('module');
const origRequire = Module.prototype.require;
Module.prototype.require = function (id) {
  if (id === 'electron-updater') {
    const autoUpdater = {
      autoDownload: false,
      autoInstallOnAppQuit: true,
      allowPrerelease: false,
      on() {},
      checkForUpdates: () => ({ catch() {} }),
      downloadUpdate: async () => {},
      quitAndInstall() {},
    };
    return { autoUpdater };
  }
  return origRequire.apply(this, arguments);
};

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  registerUpdater,
  applyUpdateOptions,
  isVersionNewer,
  isPrereleaseVersion,
  interpretUpdateCheckResult,
  explainUpdateError,
  canSelfUpdate,
  updateFeedPresent,
} = require('../lib/updater');

/**
 * The app compares versions twice, with two different implementations, and both
 * have to agree or an update disappears without a word.
 *
 * electron-updater decides first, in `AppUpdater.isUpdateAvailable`, with
 * `semver.gt(latest, current)`. `isVersionNewer` below then decides again, as
 * the filter in `interpretUpdateCheckResult`. A disagreement is silent in
 * whichever direction it goes: electron-updater offers a release and this filter
 * discards it (the user is told they are up to date, and they are not), or this
 * filter would accept something electron-updater never surfaces (a branch that
 * cannot run).
 *
 * So the property is not "this function looks right", it is "this function
 * agrees with the one on the other side of the pipeline". `semver` is not a
 * declared dependency — it arrives with electron-updater, which is the point:
 * the version under test is the version the updater is using.
 */
const semver = require('semver');

test('isVersionNewer agrees with semver on every shape this repo has shipped', () => {
  const vs = [
    '2.1.0', '2.2.0', '3.2.0', '3.5.1', '3.5.3', '3.6.0',
    '3.6.0-beta.1', '3.6.0-beta.9', '3.6.0-beta.10', '3.6.0-beta.19',
    '3.6.0-rc.1', '3.6.0-rc.4',
    '3.7.0', '3.7.0-alpha.1', '3.7.0-beta.1', '3.7.0-beta.2', '3.7.0-beta.9',
    '3.7.0-beta.10', '3.7.0-beta.11', '3.7.0-rc.1',
    '1.0.0', '1.0.0-beta.9', '1.1.0', '1.2.0', '4.0.0',
  ];
  const mismatches = [];
  for (const a of vs) {
    for (const b of vs) {
      if (isVersionNewer(a, b) !== semver.gt(a, b)) mismatches.push(`${a} vs ${b}`);
    }
  }
  assert.deepEqual(mismatches, [], `these pairs disagree with semver: ${mismatches.join(', ')}`);
});

test('a two-digit prerelease outranks a one-digit one', () => {
  // The gap this fills: every prerelease case here compared single digits, and
  // the one that looked like an exception — rc.1 vs beta.9 — is decided by the
  // TAG, not the number. So nothing exercised the boundary, and the 3.7.0 line
  // crossed it on 2026-08-27 with beta.10. A lexicographic compare ranks
  // "10" below "9", and every beta user would quietly stop being offered
  // updates: no error, no event, just an app that says it is up to date.
  //
  // It is correct — comparePrerelease parses numeric identifiers with parseInt.
  // Checked rather than assumed, and now pinned, because the risk is not today's
  // code, it is the next edit to it.
  assert.equal(isVersionNewer('3.7.0-beta.10', '3.7.0-beta.9'), true);
  assert.equal(isVersionNewer('3.7.0-beta.9', '3.7.0-beta.10'), false);
  assert.equal(isVersionNewer('3.7.0-beta.10', '3.7.0-beta.2'), true);
  assert.equal(isVersionNewer('3.7.0-beta.2', '3.7.0-beta.10'), false);
  // The 3.6.0 line ran to beta.19 in the field, so this has been relied on
  // before it was ever tested.
  assert.equal(isVersionNewer('3.6.0-beta.19', '3.6.0-beta.9'), true);
  assert.equal(isVersionNewer('3.6.0-beta.9', '3.6.0-beta.19'), false);
  // And the graduation still works from a two-digit prerelease.
  assert.equal(isVersionNewer('3.7.0', '3.7.0-beta.10'), true);
  assert.equal(isVersionNewer('3.7.0-beta.10', '3.7.0'), false);
});

test('isVersionNewer compares dotted versions', () => {
  assert.equal(isVersionNewer('2.3.2', '2.3.1'), true);
  assert.equal(isVersionNewer('2.3.1', '2.3.2'), false);
  assert.equal(isVersionNewer('2.3.1', '2.3.1'), false);
});

test('isVersionNewer treats a stable release as newer than its prerelease', () => {
  // The beta→stable graduation: a 2.4.0-beta.2 user must be offered final 2.4.0.
  assert.equal(isVersionNewer('2.4.0', '2.4.0-beta.2'), true);
  assert.equal(isVersionNewer('2.4.0-beta.2', '2.4.0'), false);
  // Prerelease ordering within the same number.
  assert.equal(isVersionNewer('2.4.0-beta.2', '2.4.0-beta.1'), true);
  assert.equal(isVersionNewer('2.4.0-beta.1', '2.4.0-beta.2'), false);
  assert.equal(isVersionNewer('2.4.0-rc.1', '2.4.0-beta.9'), true);
  // A newer number still wins regardless of prerelease tags.
  assert.equal(isVersionNewer('2.4.1', '2.4.0-beta.2'), true);
  assert.equal(isVersionNewer('2.4.0-beta.1', '2.4.0-beta.1'), false);
});

test('isPrereleaseVersion detects beta, rc, and alpha tags', () => {
  assert.equal(isPrereleaseVersion('2.4.0-beta.1'), true);
  assert.equal(isPrereleaseVersion('2.4.0-rc.1'), true);
  assert.equal(isPrereleaseVersion('2.3.2'), false);
});

test('interpretUpdateCheckResult ignores prerelease offers unless allowBeta', () => {
  const blocked = interpretUpdateCheckResult({
    isPackaged: true,
    currentVersion: '2.3.2',
    updateInfo: { version: '2.4.0-beta.1' },
    allowBeta: false,
  });
  assert.equal(blocked.status, 'not-available');
  assert.equal(blocked.latestVersion, '2.3.2');

  const allowed = interpretUpdateCheckResult({
    isPackaged: true,
    currentVersion: '2.3.2',
    updateInfo: { version: '2.4.0-beta.1' },
    allowBeta: true,
  });
  assert.equal(allowed.status, 'available');
  assert.equal(allowed.version, '2.4.0-beta.1');
});

test('applyUpdateOptions stores allowBeta preference', () => {
  assert.deepEqual(applyUpdateOptions({ allowBeta: false }), { allowBeta: false });
  assert.deepEqual(applyUpdateOptions({ allowBeta: true }), { allowBeta: true });
});

test('interpretUpdateCheckResult handles dev, available, and up to date', () => {
  assert.equal(
    interpretUpdateCheckResult({ isPackaged: false, currentVersion: '2.3.2' }).status,
    'dev',
  );
  const available = interpretUpdateCheckResult({
    isPackaged: true,
    currentVersion: '2.3.1',
    updateInfo: { version: '2.3.2', releaseNotes: '- Bug fix', releaseDate: '2026-06-05' },
  });
  assert.equal(available.status, 'available');
  assert.equal(available.version, '2.3.2');
  assert.equal(available.releaseNotes, '- Bug fix');
  assert.equal(
    interpretUpdateCheckResult({
      isPackaged: true,
      currentVersion: '2.3.2',
      updateInfo: { version: '2.3.2' },
    }).status,
    'not-available',
  );
});

test('interpretUpdateCheckResult never offers a downgrade (guards the auto update-available gate)', () => {
  // Running a prerelease; /releases/latest resolves to an OLDER stable → must NOT offer it,
  // even with beta updates enabled. This is what the gated auto event relies on.
  assert.equal(
    interpretUpdateCheckResult({
      isPackaged: true,
      currentVersion: '3.1.0-beta.3',
      updateInfo: { version: '3.0.0' },
      allowBeta: true,
    }).status,
    'not-available',
  );
  // Same number, older prerelease offered while on a newer prerelease → not an update.
  assert.equal(
    interpretUpdateCheckResult({
      isPackaged: true,
      currentVersion: '3.1.0-beta.3',
      updateInfo: { version: '3.1.0-beta.2' },
      allowBeta: true,
    }).status,
    'not-available',
  );
  // A genuinely newer prerelease with beta on → available.
  assert.equal(
    interpretUpdateCheckResult({
      isPackaged: true,
      currentVersion: '3.1.0-beta.3',
      updateInfo: { version: '3.1.0-beta.4' },
      allowBeta: true,
    }).status,
    'available',
  );
});

test('write-update-backup copies store file when json is __COPY_STORE__', async () => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-upd-'));
  const storePath = path.join(tmp, 'store.json');
  const backupsPath = path.join(tmp, 'backups');
  fs.mkdirSync(backupsPath);
  fs.writeFileSync(storePath, '{"encrypted":true}', 'utf8');

  const handlers = {};
  const ipcMain = {
    handle: (channel, fn) => { handlers[channel] = fn; },
  };

  registerUpdater({
    app: { isPackaged: false, getVersion: () => '2.3.2' },
    fs,
    ipcMain,
    BrowserWindow: { getAllWindows: () => [] },
    encryptForDisk: (d) => d,
    dataFilePath: () => storePath,
    backupsDir: () => backupsPath,
  });

  const fn = handlers['hub:write-update-backup'];
  assert.ok(fn);
  const res = await fn({}, '__COPY_STORE__', '2.2.3');
  assert.equal(res.ok, true);
  assert.equal(res.copied, true);
  const files = fs.readdirSync(backupsPath);
  assert.equal(files.length, 1);
  assert.match(files[0], /^pre-update-v2\.2\.3-/);
  assert.equal(fs.readFileSync(path.join(backupsPath, files[0]), 'utf8'), '{"encrypted":true}');
});

/**
 * Linux installs that cannot replace themselves.
 *
 * electron-updater only updates AppImage on Linux — it detects that via the
 * APPIMAGE environment variable and declines otherwise. A .deb install therefore
 * gets a check that succeeds with NO updateInfo, which fell through to
 * "not-available": the app told the user they were on the latest version while a
 * newer one existed.
 *
 * That was unreachable while no latest-linux.yml was ever published — the check
 * failed earlier, for a different reason. Publishing the manifest (so AppImage
 * users can finally update at all) is exactly what made it reachable, which is
 * why the two changes belong together.
 */
test('a .deb install is told to download, not that it is up to date', () => {
  const r = interpretUpdateCheckResult({
    isPackaged: true,
    currentVersion: '3.4.0',
    updateInfo: undefined,      // what an inactive updater returns
    selfUpdatable: false,
  });
  assert.equal(r.status, 'manual', 'must not claim "not-available"');
  assert.match(r.message, /cannot update itself/i);
  assert.ok(r.releasesUrl, 'and must say where to get it');
});

test('an install that CAN self-update is unaffected', () => {
  const r = interpretUpdateCheckResult({
    isPackaged: true,
    currentVersion: '3.3.0',
    updateInfo: { version: '3.4.0' },
    selfUpdatable: true,
  });
  assert.equal(r.status, 'available');
  assert.equal(r.version, '3.4.0');
});

test('selfUpdatable defaults to true, so existing callers are unchanged', () => {
  const r = interpretUpdateCheckResult({
    isPackaged: true, currentVersion: '3.3.0', updateInfo: { version: '3.4.0' },
  });
  assert.equal(r.status, 'available');
});

test('the unpackaged dev message still wins over the manual one', () => {
  // Running from source is not a .deb problem, and saying "download the latest
  // version" to someone with the repo open would be nonsense.
  const r = interpretUpdateCheckResult({
    isPackaged: false, currentVersion: '3.4.0', selfUpdatable: false,
  });
  assert.equal(r.status, 'dev');
});

test('canSelfUpdate: only Linux without AppImage or Snap is excluded', () => {
  assert.equal(canSelfUpdate('darwin', {}), true, 'macOS always can');
  assert.equal(canSelfUpdate('win32', {}), true, 'Windows always can');
  assert.equal(canSelfUpdate('linux', { APPIMAGE: '/opt/Khayt.AppImage' }), true, 'AppImage can');
  assert.equal(canSelfUpdate('linux', { SNAP: '/snap/khayt' }), true, 'Snap updates itself via the store');
  assert.equal(canSelfUpdate('linux', {}), false, 'a .deb cannot');
});

/**
 * A build with no update feed.
 *
 * electron-builder bakes app-update.yml from the `publish` config. A `--dir`
 * build never gets one — and the bundle it produces is still
 * app.isPackaged === true, so it took the packaged path, asked electron-updater
 * to read a file that was not there, and showed the owner:
 *
 *   ENOENT: no such file or directory, open
 *   '/Applications/Bed Ready.app/Contents/Resources/app-update.yml'
 *
 * A path they cannot act on, and no statement of what is actually wrong. The
 * state — this install cannot update itself — was already understood here and
 * already worded for a human; it was only ever reached on Linux .deb builds.
 */
test('a build without an update feed cannot self-update, on any platform', () => {
  assert.equal(canSelfUpdate('darwin', {}, true), true, 'a normal mac build is fine');
  assert.equal(canSelfUpdate('darwin', {}, false), false, 'no feed, no check');
  assert.equal(canSelfUpdate('win32', {}, false), false);
  // Even the Linux formats that CAN self-update need the feed to be there.
  assert.equal(canSelfUpdate('linux', { APPIMAGE: '/x' }, false), false);
  assert.equal(canSelfUpdate('linux', { APPIMAGE: '/x' }, true), true);
  // The pre-existing Linux rule is untouched.
  assert.equal(canSelfUpdate('linux', {}, true), false, 'a .deb still cannot');
});

test('a missing feed is reported as "download it yourself", not as an ENOENT', () => {
  const r = interpretUpdateCheckResult({
    isPackaged: true, currentVersion: '1.0.0-beta.1', selfUpdatable: false,
  });
  assert.equal(r.status, 'manual');
  assert.match(r.message, /cannot update itself/i);
  assert.ok(r.releasesUrl, 'and it says where to get one');
  assert.ok(!/ENOENT|app-update\.yml|Resources/i.test(r.message),
    'no file paths in something a shop owner reads');
});

test('the feed probe answers false rather than throwing', () => {
  // resourcesPath is undefined outside a packaged app, and a probe that throws
  // there would take the whole update check down with it.
  assert.equal(updateFeedPresent(null), false);
  assert.equal(updateFeedPresent(undefined), false);
  assert.equal(updateFeedPresent('/nope/does/not/exist'), false);
  assert.equal(updateFeedPresent('/tmp', () => { throw new Error('EACCES'); }), false);
  assert.equal(updateFeedPresent('/tmp', () => true), true);
});


/*
 * ── What the shop is told when the check fails ─────────────────────────────
 *
 * The errors below are not invented. They are constructed the way
 * builder-util-runtime constructs them — `newError(message, code)` sets `.code`,
 * and `HttpError` sets `.code = HTTP_ERROR_<n>` plus `.statusCode` — and the
 * codes are the ones electron-updater actually throws, read out of
 * GitHubProvider.js and AppUpdater.js.
 *
 * That distinction is the whole reason #764 existed: the first Repetier fix
 * asserted against a payload the device does not send, so it passed while the
 * defect stayed.
 */

/** As builder-util-runtime's newError() builds it. */
const libError = (message, code) => Object.assign(new Error(message), { code });

/** As builder-util-runtime's HttpError builds it. */
const httpError = (statusCode, message) =>
  Object.assign(new Error(message || `HTTP error: ${statusCode}`), {
    name: 'HttpError', statusCode, code: `HTTP_ERROR_${statusCode}`,
  });

test('no internet is explained, not spelled out in syscalls', () => {
  // The commonest failure by a distance, and what it used to print:
  //   ⚠ Update check failed: getaddrinfo ENOTFOUND github.com
  for (const code of ['ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED', 'ETIMEDOUT', 'ENETUNREACH']) {
    const r = explainUpdateError(libError('getaddrinfo ENOTFOUND github.com', code));
    assert.match(r.message, /could not reach github/i, `${code} should be explained`);
    assert.doesNotMatch(r.message, /getaddrinfo|ENOTFOUND/);
  }
  // Chromium spells it differently and means the same thing.
  const chromium = explainUpdateError(new Error('net::ERR_INTERNET_DISCONNECTED'));
  assert.match(chromium.message, /could not reach github/i);
});

test('GitHub rate-limiting is not reported as a fault of this install', () => {
  // GitHub rate-limits unauthenticated callers per IP, so a busy office network
  // reaches this without anything being wrong anywhere.
  for (const status of [403, 429]) {
    const r = explainUpdateError(httpError(status));
    assert.match(r.message, /temporarily refusing|clears within an hour/i);
  }
  const server = explainUpdateError(httpError(503));
  assert.match(server.message, /nothing is wrong with this install/i);
});

test('a missing platform manifest says whose problem it is', () => {
  // Live concern rather than hypothetical: cuts here are routinely Windows +
  // Linux only and macOS is served by a manifest carried forward from an earlier
  // release, so a failed carry lands exactly here.
  const r = explainUpdateError(libError(
    'Cannot find latest-mac.yml in the latest release artifacts (https://github.com/…): HttpError: 404',
    'ERR_UPDATER_CHANNEL_FILE_NOT_FOUND'));
  assert.match(r.message, /problem with the release rather than with this install/i);
  assert.doesNotMatch(r.message, /https:\/\//, 'a URL is not something a shop can act on');
});

test('"No published versions on GitHub" points at the beta setting', () => {
  // The library says this when /releases/latest 404s, which is what GitHub
  // answers for a line that has only ever had prereleases — with the release
  // sitting right there. See mustAllowPrerelease().
  const r = explainUpdateError(libError('No published versions on GitHub', 'ERR_UPDATER_NO_PUBLISHED_VERSIONS'));
  assert.match(r.message, /beta updates in Settings/i);
});

test('an unrecognised error keeps its own words', () => {
  // The carrier audit's rule, applied here: something nobody has classified must
  // not be answered as though it were handled. A friendly sentence over an
  // unknown fault hides a real problem behind a reassuring one, and then the
  // report is "it says something went wrong" with nothing to chase.
  const r = explainUpdateError(new Error('EPERM: operation not permitted, rename'));
  assert.equal(r.message, 'EPERM: operation not permitted, rename');
  assert.equal(r.detail, null, 'no explanation means there is nothing to keep separately');
});

test('the raw message survives every explanation', () => {
  // Explaining must not destroy what somebody would quote in a bug report.
  const raw = 'getaddrinfo ENOTFOUND github.com';
  const r = explainUpdateError(libError(raw, 'ENOTFOUND'));
  assert.equal(r.detail, raw);
  assert.notEqual(r.message, raw);
});

test('interpretUpdateCheckResult carries the explanation and the detail', () => {
  const res = interpretUpdateCheckResult({
    isPackaged: true,
    currentVersion: '3.7.0-beta.10',
    error: libError('getaddrinfo ENOTFOUND github.com', 'ENOTFOUND'),
  });
  assert.equal(res.status, 'error');
  assert.match(res.message, /could not reach github/i);
  assert.equal(res.detail, 'getaddrinfo ENOTFOUND github.com');
});

test('a bare string error still produces something sayable', () => {
  const r = explainUpdateError('something broke');
  assert.equal(r.message, 'something broke');
  const empty = explainUpdateError(undefined);
  assert.equal(empty.message, 'Update check failed');
});

test('Bed Ready\'s update explanations name Bed Ready, not Khayt', () => {
  // Bed Ready loads this same updater (its own feed, its own update UI), and these
  // sentences reach its Settings screen. They were written with "Khayt" spelled in,
  // so a Bed Ready user checking for updates offline was told "Khayt will try again
  // later". The flavor is fixed when lib/flavor.js loads, so run it in a child.
  const { execFileSync } = require('child_process');
  const script = `
    const Module = require('module');
    const orig = Module.prototype.require;
    Module.prototype.require = function (id) {
      if (id === 'electron-updater') return { autoUpdater: { on() {} } };
      return orig.apply(this, arguments);
    };
    const { explainUpdateError } = require(${JSON.stringify(path.join(__dirname, '..', 'lib', 'updater'))});
    const err = (code, extra) => Object.assign(new Error('x'), { code }, extra);
    const out = ['ENOTFOUND', 'ERR_UPDATER_NO_PUBLISHED_VERSIONS', 'ERR_UPDATER_INVALID_RELEASE_FEED',
      'ERR_UPDATER_INVALID_VERSION', 'ERR_UPDATER_CHANNEL_FILE_NOT_FOUND']
      .map((c) => explainUpdateError(err(c)).message);
    out.push(explainUpdateError(err('', { statusCode: 503 })).message);
    process.stdout.write(JSON.stringify(out));`;
  const messages = JSON.parse(execFileSync(process.execPath, ['-e', script], {
    env: { ...process.env, KHAYT_FLAVOR: 'bedready' }, encoding: 'utf8',
  }));
  for (const m of messages) assert.doesNotMatch(m, /Khayt/, m);
  assert.ok(messages.some((m) => /Bed Ready/.test(m)), 'at least one sentence names the app');
});
