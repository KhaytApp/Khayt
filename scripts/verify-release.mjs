#!/usr/bin/env node
/**
 * Verify a PUBLISHED release the way a shop receives it: download the build,
 * launch it, and see whether it runs.
 *
 * Everything else stops short of this. The unit suite and every e2e run against
 * the source tree; CI proves the source is good. The release workflow proves the
 * files uploaded. Between them sits the packaging step, and a mistake there —
 * a file excluded from `build.files`, a module that only resolves from the repo
 * root, an asar path that differs from the dev path — produces a build that fails
 * for every user and for nobody testing it.
 *
 * v3.5.1 added lib/branch-summary.js, a NEW top-level require in main.js. If
 * `lib/**` had not been in the packaging allowlist, main would have thrown at
 * startup: green CI, green e2e, and an app that does not open. That is the class
 * of failure this closes.
 *
 * Usage:
 *   node scripts/verify-release.mjs v3.5.1        # download and check that tag
 *   node scripts/verify-release.mjs --app /path/to/Khayt.app
 *   node scripts/verify-release.mjs --app build/Khayt-3.9.0.AppImage --version 3.9.0
 *   node scripts/verify-release.mjs --app build/linux-unpacked
 *   node scripts/verify-release.mjs --app build/Khayt-Setup-3.9.0.exe --version 3.9.0
 *
 * The tag form checks the build for the platform it runs on: the arm64 .app on
 * macOS, the x64 AppImage on Linux (extracted, so it needs no FUSE), and on
 * Windows the Setup installer, INSTALLED silently into a scratch folder first —
 * so on Windows the installer itself is under test, not only what it carries.
 *
 * ── Why Linux, and why in release.yml ──────────────────────────────────────
 *
 * This used to be macOS-only and run by hand after publishing. v3.8.0 shipped
 * with no macOS build at all, so the one launch check this repo had could not
 * run — `Khayt-3.8.0-arm64-mac.zip` was a 404 — and a Windows/Linux-only
 * release went out with NOTHING having opened the packaged app. A check that
 * cannot run looks exactly like one that passed.
 *
 * So `build-linux` in release.yml now runs this against the AppImage it just
 * built, under xvfb, before `publish` makes the release public. The Linux
 * package is built from the same `build.files` allowlist and the same asar as
 * every other platform, so the packaging class this exists for (a module in the
 * repo but not in the build) shows up here whichever platforms a release has.
 * `build-windows` does the same with the NSIS installer it just built: installs
 * it silently, then launches what it installed. That is the fault class Linux
 * cannot see — an installer that does not install, or installs something that
 * does not start.
 *
 * PROVEN, on an unsigned local build (`electron-builder --mac --dir` with
 * `-c.mac.identity=null`), by removing lib/branch-summary.js from the packaged
 * asar: exit 1 and `Cannot find module './lib/branch-summary'`.
 *
 * Do NOT test it by tampering with a SIGNED build. Repacking the asar breaks the
 * signature, macOS then refuses to run the app at all — exit 137, no stderr, and
 * a "Khayt is damaged" dialog at whoever is at the keyboard — and the script
 * fails for a reason that has nothing to do with the missing file. That looks
 * like a pass and is not one.
 *
 * Note the real failure shape: Electron STARTS, main.js throws, and no window
 * ever appears, so playwright only reports a timeout waiting for a window. The
 * diagnosis below is what turns that into the cause.
 */
import { _electron as electron } from 'playwright-core';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

/**
 * ── Two flavours, and the one that needed this more ────────────────────────
 *
 * Bed Ready ships from this repo as a second flavour, and until now this script
 * could not look at it — which is backwards, because Bed Ready's packaging can
 * fail in a way Khayt's cannot.
 *
 * `lib/flavor.js` resolves the flavour in three steps: KHAYT_FLAVOR, then a
 * `flavor` marker file that `electron-builder.bedready.js`'s afterPack hook
 * writes into the packaged app's Resources, then a DEFAULT OF 'khayt'.
 *
 * The shipped build has no env var, so it depends entirely on that marker.
 *
 * WHAT ACTUALLY HAPPENS WITHOUT IT, measured rather than reasoned about — I had
 * written the opposite here first. Deleting the marker from the published
 * 1.2.0 bundle and launching it does NOT produce a working Khayt. The app never
 * opens a window at all: `electron.launch: Timeout 120000ms exceeded`. The cause
 * is that a Bed Ready bundle contains exactly ONE entry document —
 * `/renderer/bedready.html`, confirmed by listing the asar — so falling back to
 * `entryHtml: 'index.html'` points at a file that is not there.
 *
 * That is a better failure than the one I assumed, and it is still worth a check
 * here, for the reason `launchDiagnosis()` further down already exists: "Timeout
 * 120000ms exceeded" is the least useful sentence available, and a missing
 * module, a bad signature and a crashed GPU all read the same. This names the
 * cause in one line, before anything is launched.
 *
 * The genuinely silent direction is the other one — a KHAYT build that picked up
 * a marker — which is why that case is checked too rather than ignored.
 *
 * Either way the marker is invisible to every other check here.
 * `test:e2e:bedready` sets KHAYT_FLAVOR=bedready and so exercises step 1, never
 * the marker; the marker exists ONLY in build output, which no test in this repo
 * has ever seen.
 */
const FLAVORS = {
  khayt: {
    repo: 'KhaytApp/Khayt',
    tagPrefix: 'v',
    asset: (v) => `Khayt-${v}-arm64-mac.zip`,
    bundle: 'Khayt.app',
    binary: 'Khayt',
    // electron-builder names the Linux executable after package.json `name`.
    // Confirmed from the v3.8.0 .deb: /opt/Khayt/khayt beside resources/app.asar.
    linuxAsset: (v) => `Khayt-${v}.AppImage`,
    linuxBinary: 'khayt',
    // productName + .exe, beside resources/ — the layout NSIS installs.
    winAsset: (v) => `Khayt-Setup-${v}.exe`,
    winBinary: 'Khayt.exe',
    // A Khayt build must NOT carry the marker; if it does, the two flavours'
    // afterPack hooks have crossed and Khayt would boot as Bed Ready.
    marker: null,
    shellClass: 'khayt-app',
    expectApp: null,        // <html data-app> is absent on Khayt
  },
  bedready: {
    repo: 'KhaytApp/bedready',
    tagPrefix: 'bedready-v',
    asset: (v) => `BedReady-${v}-mac-arm64.zip`,
    bundle: 'Bed Ready.app',
    binary: 'Bed Ready',
    // Not wired: Bed Ready's Linux build has never been looked inside here, and
    // guessing its executable name would be a check that fails for the wrong
    // reason. Say so instead.
    linuxAsset: null,
    linuxBinary: null,
    winAsset: null,
    winBinary: null,
    marker: 'bedready',
    shellClass: 'khayt-app',   // the shared shell; the flavour shows in <html data-app>
    expectApp: 'bedready',
  },
};

const args = process.argv.slice(2);
const flag = (name) => { const i = args.indexOf(name); return i === -1 ? null : args[i + 1]; };
let appPath = flag('--app');
const tag = appPath ? null : args.find((a) => !a.startsWith('--'));
/** The version the build must report. Implied by a tag; given with --app. */
const expectVersion = flag('--version');

if (!tag && !appPath) {
  console.error('usage: node scripts/verify-release.mjs <tag> | --app <.app | .AppImage | linux-unpacked dir> [--version X]');
  console.error('       tags: v3.7.0-beta.8 (Khayt) | bedready-v1.2.0 (Bed Ready)');
  process.exit(2);
}

/** Which product this invocation is about, from the tag or the bundle name. */
const flavorKey = (tag ? tag.startsWith('bedready-') : /Bed Ready\.app\/?$/.test(appPath))
  ? 'bedready' : 'khayt';
const F = FLAVORS[flavorKey];
const REPO = F.repo;
/** The version inside the tag, whichever prefix it carries. */
const tagVersion = tag ? tag.replace(/^bedready-/, '').replace(/^v/, '') : expectVersion;
const linux = process.platform === 'linux';
const windows = process.platform === 'win32';
console.log(`Verifying ${flavorKey === 'bedready' ? 'Bed Ready' : 'Khayt'} ${tag || appPath}`);

const fail = (msg) => { console.error(`\n✗ ${msg}`); process.exit(1); };
const ok = (msg) => console.log(`  ✓ ${msg}`);

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-verify-'));

if (tag && (linux || windows)) {
  const assetFor = windows ? F.winAsset : F.linuxAsset;
  if (!assetFor) fail(`no ${windows ? 'Windows' : 'Linux'} build is wired up for ${flavorKey} here`);
  const asset = assetFor(tagVersion);
  const url = `https://github.com/${REPO}/releases/download/${tag}/${asset}`;
  console.log(`Downloading ${asset} …`);
  try {
    execFileSync('curl', ['-fsSL', '-o', path.join(work, asset), url], { stdio: 'pipe' });
  } catch {
    fail(`could not download ${url}\n  A published release must carry ${asset}.`);
  }
  appPath = path.join(work, asset);
  ok(`downloaded ${asset}`);
} else if (tag) {
  const asset = F.asset(tagVersion);
  const url = `https://github.com/${REPO}/releases/download/${tag}/${asset}`;
  console.log(`Downloading ${asset} …`);
  try {
    execFileSync('curl', ['-fsSL', '-o', path.join(work, 'mac.zip'), url], { stdio: 'pipe' });
  } catch {
    fail(`could not download ${url}\n  A published release must carry ${asset}.`);
  }
  execFileSync('unzip', ['-q', path.join(work, 'mac.zip'), '-d', work]);
  appPath = path.join(work, F.bundle);
  ok(`downloaded and unpacked ${asset}`);
}

/**
 * An AppImage is unpacked rather than mounted: `--appimage-extract` needs no
 * FUSE, which a CI runner may not have, and it yields the same tree the mounted
 * image would run from — the one the .deb installs to /opt/Khayt.
 */
if (/\.AppImage$/.test(appPath)) {
  fs.chmodSync(appPath, 0o755);
  try {
    execFileSync(path.resolve(appPath), ['--appimage-extract'], { cwd: work, stdio: 'pipe' });
  } catch (e) {
    fail(`could not extract ${appPath}: ${String((e && e.stderr) || e).slice(0, 300)}`);
  }
  appPath = path.join(work, 'squashfs-root');
  ok('extracted the AppImage');
}

/**
 * A Windows installer is RUN, silently, into a scratch folder — the step a shop
 * takes and the one no other check here has ever taken. NSIS wants `/D=` last
 * and unquoted, so the arguments are passed verbatim.
 */
if (/Setup-.*\.exe$/i.test(appPath)) {
  if (!windows) fail('a Windows installer can only be checked on Windows');
  const dest = path.join(work, 'installed');
  try {
    execFileSync(path.resolve(appPath), ['/S', `/D=${dest}`],
      { stdio: 'pipe', windowsVerbatimArguments: true, timeout: 300_000 });
  } catch (e) {
    fail(`the installer did not finish: ${String((e && e.stderr) || e).slice(0, 300)}`);
  }
  appPath = dest;
  ok('the installer ran silently');
}

/**
 * Where an Electron build keeps its parts. A macOS bundle nests them under
 * Contents/; a Linux build (linux-unpacked, an extracted AppImage, /opt/Khayt)
 * is flat: the executable beside `resources/`.
 */
const isMacBundle = /\.app\/?$/.test(appPath);
const flatBinary = windows ? F.winBinary : F.linuxBinary;
if (!isMacBundle && !flatBinary) fail(`no ${windows ? 'Windows' : 'Linux'} build is wired up for ${flavorKey} here`);
const binary = isMacBundle
  ? path.join(appPath, 'Contents', 'MacOS', F.binary)
  : path.join(appPath, flatBinary);
const resourcesDir = isMacBundle
  ? path.join(appPath, 'Contents', 'Resources')
  : path.join(appPath, 'resources');
if (!fs.existsSync(binary)) fail(`no executable at ${binary}`);

/**
 * The flavour marker, checked before anything is launched.
 *
 * Checked here rather than only at runtime because the runtime symptom is a
 * working app that is the WRONG app, and "it opened fine" is exactly how that
 * ships. The file is the mechanism; the runtime assertion further down is the
 * consequence. Both, because either alone reads as fine.
 */
const markerPath = path.join(resourcesDir, 'flavor');
const markerValue = fs.existsSync(markerPath)
  ? fs.readFileSync(markerPath, 'utf8').trim().toLowerCase() : null;
if (F.marker) {
  if (markerValue === null) {
    fail(`no flavor marker in ${F.bundle}/Contents/Resources.\n` +
      `  lib/flavor.js then falls back to 'khayt' and asks for renderer/index.html,\n` +
      `  which a Bed Ready bundle does not contain — so the app opens no window at\n` +
      `  all and the only symptom is a launch timeout. Check the afterPack hook in\n` +
      `  electron-builder.bedready.js.`);
  }
  if (markerValue !== F.marker) {
    fail(`the flavor marker says '${markerValue}', expected '${F.marker}'`);
  }
  ok(`the flavor marker says ${markerValue}`);
} else if (markerValue !== null) {
  fail(`a Khayt build carries a flavor marker saying '${markerValue}' — the two\n` +
    `  afterPack hooks have crossed, and this build would boot as that flavour.`);
} else {
  ok('no flavor marker, which is correct for Khayt');
}

// The version inside the bundle must match the tag. A mismatch means the tag was
// cut before the bump landed, which auto-update would then read as "no update".
const asarPath = path.join(resourcesDir, 'app.asar');
if (!fs.existsSync(asarPath)) fail('no app.asar in the bundle');
let packagedVersion = null;
// The library first: electron-builder already installs it. Shelling out to
// `npx` found nothing on Windows, where npx is npx.cmd and execFileSync will
// not run a .cmd — so this check was silently skipped on every Windows run.
try {
  const asar = await import('@electron/asar');
  const read = asar.extractFile || (asar.default && asar.default.extractFile);
  packagedVersion = JSON.parse(read(asarPath, 'package.json').toString('utf8')).version;
} catch {
  try {
    execFileSync('npx', ['--yes', '@electron/asar', 'extract-file', asarPath, 'package.json'],
      { cwd: work, stdio: 'pipe', shell: windows });
    packagedVersion = JSON.parse(fs.readFileSync(path.join(work, 'package.json'), 'utf8')).version;
  } catch { /* reported below */ }
}
if (packagedVersion) ok(`package.json inside the bundle says ${packagedVersion}`);
else console.log('  … could not read package.json from the asar (skipping that check; the running app is still asked)');
if (tagVersion && packagedVersion && packagedVersion !== tagVersion) {
  fail(`expected ${tagVersion} but the bundle contains ${packagedVersion} — the tag was cut before the version bump`);
}

/**
 * Why the app refused to start.
 *
 * Playwright reports "Process failed to launch!" and nothing else, which is the
 * least useful sentence available: a missing module, a bad signature and a
 * crashed GPU all read the same. Running the binary directly and keeping its
 * stderr turns that into the actual reason — for the fault this script exists to
 * catch, the line is `Cannot find module './lib/…'`.
 */
//
// stderr goes to a FILE and the whole process group is killed, because the
// obvious version — execFileSync with a pipe and a timeout — hung a Linux
// runner for three hours on a build missing a module. The timeout killed the
// app, but Chromium's crashpad_handler inherits the pipe and outlives it, and
// execFileSync waits for every holder to close it. A launch check that hangs
// on the exact build it exists to catch blocks the release instead of
// failing it.
/**
 * Kill a process and everything it started. POSIX signals a process group
 * (hence `detached` on the diagnosis run); Windows has no groups to signal, and
 * taskkill /T walks the tree instead.
 */
function killTree(pid, isGroupLeader) {
  if (!pid) return;
  if (windows) {
    try { execFileSync('taskkill', ['/pid', String(pid), '/T', '/F'], { stdio: 'ignore' }); } catch { /* gone */ }
    return;
  }
  try { process.kill(isGroupLeader ? -pid : pid, 'SIGKILL'); } catch { /* gone */ }
}

async function launchDiagnosis() {
  const probe = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-probe-'));
  const errFile = path.join(probe, 'stderr.txt');
  const fd = fs.openSync(errFile, 'w');
  let child;
  try {
    child = spawn(binary, [`--user-data-dir=${probe}`], {
      detached: true,            // its own process group, so its helpers die with it
      stdio: ['ignore', 'ignore', fd],
      env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1' },
    });
  } finally {
    fs.closeSync(fd);
  }
  await new Promise((resolve) => {
    const t = setTimeout(resolve, 15_000);
    child.on('exit', () => { clearTimeout(t); resolve(); });
    child.on('error', () => { clearTimeout(t); resolve(); });
  });
  killTree(child.pid, true);
  const err = fs.readFileSync(errFile, 'utf8').trim();
  if (!err) return null;   // it said nothing; the failure was elsewhere
  const lines = err.split('\n').filter(Boolean);
  // The module-resolution failure is the one worth naming outright.
  const missing = lines.find((l) => /Cannot find module/.test(l));
  return { missing, tail: lines.slice(0, 12).join('\n    ') };
}

console.log('Launching the packaged app …');
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-verify-data-'));
const problems = [];
let app;

/**
 * The app playwright launched can still be up behind a main-process error
 * dialog. It must not hold the display, or keep this process alive, while the
 * diagnosis runs.
 */
function killLaunched() {
  try { const p = app && app.process(); if (p && p.pid) killTree(p.pid, false); } catch { /* gone */ }
}

// A launch failure surfaces as an uncaught exception from inside playwright, not
// only as a rejection, so the diagnosis has to be reachable from both.
process.on('uncaughtException', async (e) => {
  killLaunched();
  const why = await launchDiagnosis();
  console.error(`\n✗ the packaged app did not come up: ${e && e.message ? e.message : e}`);
  if (why && why.missing) {
    console.error(`\n  ${why.missing}`);
    console.error('  A file is in the repo but not in the build. Check "files" in');
    console.error('  package.json → build, then re-cut the release.');
  } else if (why) {
    console.error('\n  stderr from the app:\n    ' + why.tail);
  }
  process.exit(1);
});

try {
  app = await electron.launch({
    executablePath: binary,
    args: [`--user-data-dir=${userData}`],
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1' },
    timeout: 120_000,
  });
  const page = await app.firstWindow();
  page.on('pageerror', (e) => problems.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') problems.push('console.error: ' + m.text().slice(0, 200)); });

  await page.waitForSelector(`.${F.shellClass}`, { timeout: 90_000 });
  ok('the window opened');

  /*
   * The consequence of the marker, asserted independently of it — a build could
   * carry the right marker and still load the wrong entry document.
   *
   * The signal is `<html data-app>`, which is what the APP ITSELF uses:
   * themes.js and shell.js both decide the flavour with
   * `document.documentElement.dataset.app === 'bedready'`. Using the same
   * predicate means this cannot disagree with the running app about what the
   * running app is.
   *
   * It was `.bedready-ui` first, and that was wrong twice over. `bedready-ui` is
   * a THEME body class, not a flavour marker — it sits in themes.js's list
   * beside khayt-workbench and khayt-command — and `renderer/index.html` ships
   * with it on `<body>` too. Worse, themes.js TOGGLES it off once it runs, so
   * the answer depended on whether this evaluate landed before or after that:
   * v3.6.0 passed and v3.7.0-beta.8 failed, on the same correct build shape. A
   * check that reports a shipped release as the wrong app, intermittently, is
   * worse than no check.
   */
  const runningApp = await page.evaluate(() => document.documentElement.dataset.app || null);
  if (runningApp !== F.expectApp) {
    fail(`the packaged app reports <html data-app=${JSON.stringify(runningApp)}>, ` +
      `expected ${JSON.stringify(F.expectApp)} — it opened as the wrong flavour`);
  }
  ok(`it opened as ${runningApp === 'bedready' ? 'Bed Ready' : 'Khayt'} (data-app=${runningApp})`);

  // Booting is not enough: the renderer must actually render, and the main
  // process must answer. A packaging fault often shows as a blank shell.
  await page.waitForFunction(
    () => (document.querySelector('#dashboardContent')?.innerHTML?.length || 0) > 100,
    { timeout: 90_000 },
  );
  ok('the dashboard rendered');

  const reported = await page.evaluate(() => window.hubAPI.appVersion());
  if (tagVersion && reported !== tagVersion) fail(`the running app reports ${reported}, not ${tagVersion}`);
  ok(`the running app reports ${reported}`);

  // One round trip per process boundary — preload bridge and main handler. If a
  // lib/ module failed to package, main would have died before answering.
  //
  // What counts as healthy is "it ANSWERED", not "it answered with data". This
  // launches against a fresh --user-data-dir, so there is no store yet and
  // loadStore correctly resolves to null. The old check was `!store`, which
  // treats that null as a dead main process — so this assertion could never
  // pass, on any release, however good the build. Verified 2026-07-31 against
  // v3.5.2 and v3.6.0-beta.1: both return null on a clean profile and a 33-key
  // object on a populated one.
  const store = await page.evaluate(async () => {
    try {
      const v = await window.hubAPI.loadStore();
      return { answered: true, type: v === null ? 'null' : typeof v };
    } catch (e) {
      return { answered: false, error: String((e && e.message) || e) };
    }
  });
  if (!store.answered) fail(`hub:load-store threw — ${store.error}`);
  else if (store.type !== 'object' && store.type !== 'null') {
    fail(`hub:load-store returned ${store.type} — the main process is not healthy`);
  }
  ok(`the main process answers IPC (fresh profile → ${store.type})`);
} catch (e) {
  killLaunched();
  const why = await launchDiagnosis();
  console.error(`\n✗ the packaged app did not come up: ${e && e.message ? e.message : e}`);
  if (why && why.missing) {
    console.error(`\n  ${why.missing}`);
    console.error('  A file is in the repo but not in the build. Check "files" in');
    console.error('  package.json → build, then re-cut the release.');
  } else if (why) {
    console.error('\n  stderr from the app:\n    ' + why.tail);
  }
  process.exit(1);
} finally {
  if (app) await app.close().catch(() => {});
}

if (problems.length) {
  console.error('\n✗ the app ran but reported errors:');
  for (const p of problems.slice(0, 10)) console.error('    ' + p);
  process.exit(1);
}

console.log(`\n✅ ${tag || appPath} runs as published.`);
