#!/usr/bin/env node
/**
 * Downloads and extracts the Electron binary. This is not a convenience wrapper
 * around Electron's own installer — as of Electron 42.0.0 the npm package ships
 * no `postinstall` at all (41.x had `postinstall: node install.js`; 42.x has no
 * `scripts` field), so `npm install electron` puts the JS on disk and never
 * fetches the ~150MB binary. Nothing else downloads it. If this script goes, so
 * does the binary.
 *
 * Extraction is system `unzip` on Unix and PowerShell `Expand-Archive` on
 * Windows — no third-party extractor, on any supported platform.
 */
const fs = require('fs');
const path = require('path');
const { execSync, spawnSync } = require('child_process');

const root = path.join(__dirname, '..');
const electronDir = path.join(root, 'node_modules', 'electron');
const pathTxt = path.join(electronDir, 'path.txt');

function platformPath() {
  const p = process.env.ELECTRON_INSTALL_PLATFORM || process.platform;
  if (p === 'darwin' || p === 'mas') return 'Electron.app/Contents/MacOS/Electron';
  if (p === 'win32') return 'electron.exe';
  if (p === 'linux' || p === 'freebsd' || p === 'openbsd') return 'electron';
  throw new Error('Unsupported platform: ' + p);
}

function resolveArch() {
  let arch = process.env.ELECTRON_INSTALL_ARCH || process.arch;
  const platform = process.env.ELECTRON_INSTALL_PLATFORM || process.platform;
  if (
    platform === 'darwin' &&
    process.platform === 'darwin' &&
    arch === 'x64' &&
    !process.env.ELECTRON_INSTALL_ARCH
  ) {
    try {
      const out = execSync('sysctl -in sysctl.proc_translated', { encoding: 'utf8' });
      if (out.trim() === '1') arch = 'arm64';
    } catch { /* Intel Mac or sysctl unavailable */ }
  }
  return arch;
}

function hasUnzip() {
  const r = spawnSync('unzip', ['-v'], { stdio: 'ignore' });
  return r.status === 0;
}

function extractZipArchive(zipPath, distDir) {
  fs.mkdirSync(distDir, { recursive: true });
  const platform = process.env.ELECTRON_INSTALL_PLATFORM || process.platform;
  const unix =
    platform === 'darwin' ||
    platform === 'mas' ||
    platform === 'linux' ||
    platform === 'freebsd' ||
    platform === 'openbsd';

  if (unix) {
    if (!hasUnzip()) {
      const hint =
        platform === 'darwin' || platform === 'mas'
          ? 'On macOS install Command Line Tools:\n  xcode-select --install'
          : 'On Linux install unzip (e.g. apt install unzip).';
      throw new Error('`unzip` is required but not found in PATH.\n' + hint);
    }
    console.log('Extracting with unzip…');
    const r = spawnSync('unzip', ['-o', '-q', zipPath, '-d', distDir], { stdio: 'inherit' });
    if (r.error) throw r.error;
    if (r.status !== 0) {
      throw new Error('unzip failed with exit code ' + (r.status ?? 'unknown'));
    }
    return;
  }

  if (platform === 'win32') {
    const ps = [
      'powershell',
      '-NoProfile',
      '-Command',
      `Expand-Archive -Force -LiteralPath '${zipPath.replace(/'/g, "''")}' -DestinationPath '${distDir.replace(/'/g, "''")}'`,
    ];
    const r = spawnSync(ps[0], ps.slice(1), { stdio: 'inherit' });
    if (r.status !== 0) {
      throw new Error('Expand-Archive failed with exit code ' + (r.status ?? r.error?.message ?? 'unknown'));
    }
    return;
  }

  // Unreachable: platformPath() runs first and throws for anything not handled
  // above. Kept total rather than falling through, so a new platform fails here
  // saying why instead of at the missing-binary check further on.
  throw new Error('Unsupported platform for extraction: ' + platform);
}

function postExtract(electronDir, distDir, platPath, version) {
  const srcTypeDef = path.join(distDir, 'electron.d.ts');
  const targetTypeDef = path.join(electronDir, 'electron.d.ts');
  if (fs.existsSync(srcTypeDef)) {
    fs.renameSync(srcTypeDef, targetTypeDef);
  }

  const distExe = path.join(distDir, platPath);
  if (!fs.existsSync(distExe)) {
    throw new Error(
      'Electron binary not found after extract: ' + distExe + '\n' +
      'Check that `unzip` is available (macOS: xcode-select --install).'
    );
  }

  fs.writeFileSync(path.join(distDir, 'version'), 'v' + version);
  fs.writeFileSync(pathTxt, platPath);
}

/**
 * The electron spec this repo already declares: the lockfile's exact version if
 * there is one, otherwise the range from package.json. Never a bare `electron`,
 * which resolves to whatever is newest on the registry rather than to what CI
 * installs from the lockfile.
 */
function declaredElectronSpec(pkgPath) {
  const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
  const range = (pkg.devDependencies && pkg.devDependencies.electron)
    || (pkg.dependencies && pkg.dependencies.electron);
  if (!range) return null;

  try {
    const lock = JSON.parse(fs.readFileSync(path.join(root, 'package-lock.json'), 'utf8'));
    const pinned = lock.packages && lock.packages['node_modules/electron'];
    if (pinned && pinned.version) return 'electron@' + pinned.version;
  } catch {
    // No lockfile, or one old enough to predate `packages` — the declared range
    // still holds this to the major the repo expects.
  }
  return 'electron@' + range;
}

function ensureElectronPackage() {
  if (fs.existsSync(electronDir)) return;

  const pkgPath = path.join(root, 'package.json');
  if (!fs.existsSync(pkgPath)) {
    console.error('Run this from the Khayt project root (where package.json lives).');
    process.exit(1);
  }

  const spec = declaredElectronSpec(pkgPath);
  if (!spec) {
    console.error('package.json does not declare electron. Run: npm install');
    process.exit(1);
  }

  // `--no-save`: this only repopulates node_modules, so it has no business
  // rewriting the manifest. `install electron --save-dev` resolved to the newest
  // release and wrote it back, so a fresh worktree silently bumped package.json
  // and the lockfile, then ran its e2e against a different Electron than the one
  // `npm ci` gives CI.
  console.log(`node_modules/electron is missing — installing ${spec}…\n`);
  const r = spawnSync('npm', ['install', spec, '--no-save'], {
    cwd: root,
    stdio: 'inherit',
    env: process.env,
  });
  if (r.status !== 0) {
    console.error('\nFailed. From the project folder run: npm install');
    process.exit(1);
  }
  if (!fs.existsSync(electronDir)) {
    console.error('\nStill missing node_modules/electron after npm install.');
    console.error('Try: rm -rf node_modules package-lock.json && npm install');
    process.exit(1);
  }
}

async function main() {
  ensureElectronPackage();

  const { version } = require(path.join(electronDir, 'package.json'));
  const platPath = platformPath();
  const distDir = path.join(electronDir, 'dist');
  const distExe = path.join(distDir, platPath);

  if (fs.existsSync(pathTxt) && fs.existsSync(distExe)) {
    console.log('Electron already installed.');
    return;
  }

  console.log(`Installing Electron ${version} for ${process.platform}-${resolveArch()}…`);
  console.log('(About 150MB — can take several minutes on a slow connection.)\n');

  const { downloadArtifact } = require('@electron/get');

  const zipPath = await downloadArtifact({
    version,
    artifactName: 'electron',
    platform: process.env.ELECTRON_INSTALL_PLATFORM || process.platform,
    arch: resolveArch(),
    checksums: require(path.join(electronDir, 'checksums.json')),
  });

  if (fs.existsSync(distDir)) {
    fs.rmSync(distDir, { recursive: true, force: true });
  }
  extractZipArchive(zipPath, distDir);
  postExtract(electronDir, distDir, platPath, version);

  console.log('\nSuccess. Run: npm start\n');
}

main().catch((err) => {
  console.error('\nElectron install failed:\n', err.message || err);
  console.error('\nTry a mirror (then run this script again):');
  console.error('  export ELECTRON_MIRROR=https://npmmirror.com/mirrors/electron/');
  console.error('\nIf extraction failed, check that `unzip` is on PATH (macOS: xcode-select --install).');
  process.exit(1);
});
