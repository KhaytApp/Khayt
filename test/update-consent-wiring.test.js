'use strict';
/**
 * The consent gate is four pieces in four files, and it is worth nothing unless
 * all four are connected.
 *
 *   scripts/changelog-section.js  puts the version's notes INTO the release
 *   lib/major-changes.js          reads "Before you update" out of them
 *   lib/updater.js                sends the verdict WITH the update offer
 *   renderer/update-ui.js         disables the download until it is accepted
 *
 * Each is tested on its own elsewhere. What is pinned here is that they are
 * wired to each other, because every one of them can pass its own tests while
 * the gate quietly does nothing — the release notes could go back to being a
 * link, or the renderer could render the checkbox and never read it.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

test('the release carries its own notes, not a link to them', () => {
  const wf = read('.github/workflows/release.yml');
  assert.match(wf, /scripts\/changelog-section\.js/,
    'the release body is not built from the CHANGELOG, so the app has nothing to show');
  assert.match(wf, /--notes-file/);
  // The old body was the same sentence on every release ever published, and it
  // is what made the update dialog say "Release notes were not included".
  const createBlock = wf.slice(wf.indexOf('gh release create'), wf.indexOf('gh release create') + 400);
  assert.doesNotMatch(createBlock, /--notes "See \[README\]/,
    'the release is being created with the boilerplate note again');
});

/** A release-creating job, sliced structurally: it ends at the next job, found
 *  by indentation. Slicing to the next `gh release create` ended it early,
 *  because that phrase appears in a comment above the command it names. */
function releaseJob(wf, stepName) {
  const at = wf.indexOf(stepName);
  assert.ok(at > -1, `the step "${stepName}" is gone`);
  const rest = wf.slice(at);
  const nextJob = rest.slice(1).search(/\n {2}[a-z][\w-]*:\n/);
  return nextJob === -1 ? rest : rest.slice(0, nextJob + 1);
}

test('BOTH lanes build their notes from the CHANGELOG', () => {
  /* Bed Ready passed one fixed sentence — "See the Khayt CHANGELOG for what
   * changed" — so its releases carried no `Before you update` section, EVER.
   * parseMajorChanges finds no heading and returns needsConsent:false, and Bed
   * Ready runs the identical renderer and updater. Its shops were the ones being
   * asked to install a change nobody had shown them: unconditionally, for a
   * whole flavour, while the Khayt lane's gate was being carefully repaired.
   *
   * And its job had no `actions/checkout` either — the same fault as
   * v3.7.0-beta.24, sitting in the second lane the whole time. */
  const wf = read('.github/workflows/release.yml');
  for (const [lane, jobStart] of [['Khayt', '  create-release:'], ['Bed Ready', '  bedready-release:']]) {
    const job = releaseJob(wf, jobStart);
    assert.ok(job.includes('node scripts/changelog-section.js'),
      `the ${lane} lane does not build its notes from the CHANGELOG — its releases can never be gated`);
    assert.ok(job.includes('--notes-file'),
      `the ${lane} lane passes a fixed --notes string rather than the file it just built`);
    assert.ok(job.includes('actions/checkout'),
      `the ${lane} lane has no checkout, so changelog-section.js will fail "file not found" and fall back silently`);
    assert.ok(job.indexOf('actions/checkout') < job.indexOf('node scripts/changelog-section.js'),
      `the ${lane} lane checks out AFTER it needs the repo`);
  }
});

test('the job that builds the notes has the repo they come from', () => {
  /* v3.7.0-beta.24 published the boilerplate line despite all of this being in
   * place, because the "Create GitHub Release" job had never needed a checkout
   * — it only ran `gh`. `node scripts/changelog-section.js` failed with "file
   * not found", the guard fell through to its fallback, and the release said
   * "See README" like every release before it.
   *
   * The script was right and the call was right. The job they ran in had no
   * repo, which no test could see because every test here reads the repo it is
   * already standing in. */
  const wf = read('.github/workflows/release.yml');
  const at = wf.indexOf('name: Create GitHub Release');
  assert.ok(at > -1, 'the release-creating job is gone');
  /* The job ends at the next JOB, found structurally — a line at job indent.
   * Slicing to the next `gh release create` ended the job early, because that
   * phrase appears in a comment above the command it names. */
  const rest = wf.slice(at);
  const nextJob = rest.slice(1).search(/\n {2}[a-z][\w-]*:\n/);
  const job = nextJob === -1 ? rest : rest.slice(0, nextJob + 1);
  assert.match(job, /uses: actions\/checkout/,
    'the job builds the release notes from CHANGELOG.md but never checks the repo out');
  /* Anchored on the INVOCATION, `node scripts/changelog-section.js`, not on the
   * bare filename — the comment explaining this very fix names the file, sits
   * above the checkout, and made the first version of this assertion fail
   * against prose rather than against code. Fourth time today a source-text
   * test matched the wrong thing; they match what you write about the code as
   * readily as the code. */
  assert.ok(job.indexOf('actions/checkout') < job.indexOf('node scripts/changelog-section.js'),
    'the checkout has to come before the script that needs it');
});

test('the updater parses the notes and sends the verdict with the offer', () => {
  const src = read('lib/updater.js');
  assert.match(src, /require\('\.\/major-changes'\)/);
  const send = src.slice(src.indexOf("send('update-available'"), src.indexOf("send('update-available'") + 500);
  assert.match(send, /majorChanges: parseMajorChanges\(notes\)/,
    'the offer goes out without the verdict, so the renderer cannot gate on it');
});

test('the download is what is gated, and it is gated on the checkbox', () => {
  const src = read('renderer/update-ui.js');
  assert.match(src, /majorChanges: info\.majorChanges/, 'the verdict is dropped on arrival');
  assert.match(src, /data-upd="download"\$\{gated \? ' disabled' : ''\}/,
    'the download button is not disabled for a gated release');
  assert.match(src, /download\.disabled = !accept\.checked/,
    'ticking the box does not enable the download');

  /* Gating the INSTALL instead would be no gate at all: autoInstallOnAppQuit is
   * true, so a downloaded update lands on the next quit whether or not anybody
   * pressed anything. This asserts the reason still holds. */
  assert.match(read('lib/updater.js'), /autoUpdater\.autoInstallOnAppQuit = true/);
  assert.match(read('lib/updater.js'), /autoUpdater\.autoDownload = false/);
});

test('an ordinary release is not gated — the rarity is the point', () => {
  const src = read('renderer/update-ui.js');
  // `gated` must be false unless the section exists AND lists something.
  assert.match(src, /const gated = !!\(major && major\.needsConsent && Array\.isArray\(major\.items\) && major\.items\.length\)/,
    'the gate condition has loosened — a prompt on every release is one nobody reads');
});

test('the consent wording is translated, not English in nine languages', () => {
  for (const loc of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const src = read(`renderer/locales/${loc}.js`);
    for (const key of ['upd.consent_head', 'upd.consent_accept', 'upd.intro_consent']) {
      assert.match(src, new RegExp(`"${key.replace('.', '\\.')}":\\s*"`), `${loc} has no ${key}`);
    }
  }
});
