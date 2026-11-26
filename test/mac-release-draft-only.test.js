'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

/* ────────────────────────────────────────────────────────────────────────────
 * mac/release-local.sh --draft-only must STOP at the draft: nothing signed,
 * nothing public, no install told. The one thing that makes a Mac release
 * public is dispatching mac-publish.yml, so these tests RUN the real script,
 * in a throwaway repository, with every outside tool replaced by a stand-in
 * that records what it was asked (gh, xcrun, plutil, ditto, stat, sleep) and
 * a make-app.sh that builds nothing. What gh was asked is the proof.
 * ──────────────────────────────────────────────────────────────────────────── */

const SCRIPT = path.join(__dirname, '..', 'mac', 'release-local.sh');
const skip = process.platform === 'win32' ? 'needs bash' : false;

function sh(file, body) { fs.writeFileSync(file, '#!/bin/bash\n' + body); fs.chmodSync(file, 0o755); }

function rig({ draft } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-release-test-'));
  const repo = path.join(root, 'repo'), bin = path.join(root, 'bin'), log = path.join(root, 'gh.log');
  fs.mkdirSync(path.join(repo, 'mac'), { recursive: true });
  fs.mkdirSync(path.join(repo, 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(repo, 'lib'), { recursive: true });
  fs.mkdirSync(path.join(repo, 'mac/KhaytCore/Sources/KhaytCore/JS'), { recursive: true });
  fs.mkdirSync(bin);
  fs.copyFileSync(SCRIPT, path.join(repo, 'mac/release-local.sh'));
  fs.writeFileSync(path.join(repo, 'mac/version.json'), JSON.stringify({ version: '4.0.0-beta.99', build: 999 }));
  fs.writeFileSync(path.join(repo, 'lib/release-gates.json'), '{}\n');
  fs.writeFileSync(path.join(repo, 'mac/KhaytCore/Sources/KhaytCore/JS/release-gates.json'), '{}\n');
  sh(path.join(repo, 'mac/sync-js.sh'), 'exit 0\n');
  // Builds nothing: a bundle with the right shape, and a mark that it ran.
  sh(path.join(repo, 'mac/make-app.sh'), [
    `echo "make-app $*" >> "${log}"`,
    'mkdir -p mac/dist/Khayt.app/Contents/MacOS mac/dist/Khayt.app/Contents/Frameworks/Sparkle.framework',
    'printf "#!/bin/bash\\nexit 0\\n" > mac/dist/Khayt.app/Contents/MacOS/Khayt; chmod +x mac/dist/Khayt.app/Contents/MacOS/Khayt',
    'touch mac/dist/Khayt.app/Contents/Info.plist', '',
  ].join('\n'));
  fs.writeFileSync(path.join(repo, 'scripts/write-release-gates.js'), 'process.exit(0)\n');
  fs.writeFileSync(path.join(repo, 'scripts/changelog-section.js'), 'console.log("notes")\n');
  fs.writeFileSync(path.join(repo, 'scripts/changelog-fold.js'), 'process.exit(0)\n');
  const git = (...a) => execFileSync('git', a, { cwd: repo, stdio: 'pipe' });
  git('init', '-q', '-b', 'main'); git('-c', 'user.email=t@t', '-c', 'user.name=t', 'add', '-A');
  git('-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '-m', 'fixture');
  execFileSync('git', ['clone', '-q', '--bare', repo, path.join(root, 'origin.git')]);
  git('remote', 'add', 'origin', path.join(root, 'origin.git')); git('fetch', '-q', 'origin');
  // gh: records every call; a draft exists only when asked to; a new publish run appears after a dispatch.
  sh(path.join(bin, 'gh'), [
    `echo "gh $*" >> "${log}"`,
    'case "$*" in',
    `  "release view"*) ${draft ? 'echo true' : 'exit 1'} ;;`,
    '  "run list"*"--status"*) ;;',
    `  "run list"*) if [ -f "${root}/dispatched" ]; then echo 2; else echo 1; fi ;;`,
    `  "workflow run"*) touch "${root}/dispatched" ;;`,
    'esac', 'exit 0', '',
  ].join('\n'));
  sh(path.join(bin, 'xcrun'), `echo "xcrun $*" >> "${log}"\nexit 0\n`);
  sh(path.join(bin, 'plutil'), 'case "$*" in *CFBundleVersion*) echo 999 ;; *SUFeedURL*) echo https://example.com/appcast.xml ;; *SUPublicEDKey*) echo KEY ;; esac\n');
  sh(path.join(bin, 'ditto'), 'touch "${@: -1}"\n');
  sh(path.join(bin, 'stat'), 'echo 123\n');
  sh(path.join(bin, 'sleep'), 'exit 0\n');
  const run = (...args) => {
    const r = spawnSync('bash', [path.join(repo, 'mac/release-local.sh'), ...args], {
      cwd: repo, encoding: 'utf8',
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, KHAYT_RELEASE_DIR: path.join(root, 'wt'), RELEASE_SHA: '' },
    });
    const calls = fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : '';
    return { code: r.status, out: r.stdout + r.stderr, calls };
  };
  return { run, cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

test('--draft-only builds, uploads the draft, and dispatches nothing', { skip }, () => {
  const r = rig();
  try {
    const { code, out, calls } = r.run('--draft-only');
    assert.equal(code, 0, out);
    assert.match(calls, /make-app/, 'it did not build');
    assert.match(calls, /gh release create v4\.0\.0-beta\.99 \S+ --repo KhaytApp\/khayt-mac --draft/);
    assert.match(calls, /gh release upload v4\.0\.0-beta\.99 lib\/release-gates\.json/);
    assert.doesNotMatch(calls, /workflow run/, 'a draft-only run dispatched the publish');
    assert.doesNotMatch(calls, /run watch/);
    assert.match(out, /stopped at the draft/);
    assert.match(out, /release-local\.sh --publish/, 'it should say how to publish later');
  } finally { r.cleanup(); }
});

test('--publish builds nothing, needs the draft, and is what dispatches', { skip }, () => {
  const none = rig({ draft: false });
  try {
    const { code, out, calls } = none.run('--publish');
    assert.notEqual(code, 0);
    assert.match(out, /no draft of v4\.0\.0-beta\.99 to publish/);
    assert.doesNotMatch(calls, /workflow run|make-app|release create/);
  } finally { none.cleanup(); }
  const r = rig({ draft: true });
  try {
    const { code, out, calls } = r.run('--publish');
    assert.equal(code, 0, out);
    assert.match(calls, /gh workflow run mac-publish\.yml -R KhaytApp\/Khayt --ref main -f tag=v4\.0\.0-beta\.99 -f prerelease=true -f publish_appcast=true/);
    assert.doesNotMatch(calls, /make-app|release create|release upload|notarytool/, 'publishing built or uploaded something');
  } finally { r.cleanup(); }
});

test('with neither, it still does both, as before; the two together are refused; an unknown option is refused', { skip }, () => {
  const r = rig();
  try {
    const { code, out, calls } = r.run();
    assert.equal(code, 0, out);
    assert.match(calls, /release create/);
    assert.match(calls, /workflow run mac-publish\.yml/);
  } finally { r.cleanup(); }
  for (const args of [['--draft-only', '--publish'], ['--draftonly']]) {
    const x = rig();
    try {
      const { code, calls } = x.run(...args);
      assert.notEqual(code, 0, args.join(' '));
      assert.doesNotMatch(calls, /workflow run|release create/, args.join(' '));
    } finally { x.cleanup(); }
  }
});

test('the script dispatches in one place only', () => {
  const s = fs.readFileSync(SCRIPT, 'utf8');
  assert.equal((s.match(/gh workflow run/g) || []).length, 1);
  assert.match(s, /publish\(\) \{[\s\S]*gh workflow run mac-publish\.yml/);
});
