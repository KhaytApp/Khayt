/**
 * A workflow file that does not parse is a zero-second red build.
 *
 * GitHub does not tell you it is a syntax error — the run appears, fails in 0s
 * with no job output, and `gh pr checks` reports "no checks reported on the
 * branch", which reads like CI has not started yet rather than like a mistake.
 *
 * The specific trap, hit while adding the keyboard e2e step:
 *
 *     - name: E2E smoke (keyboard: modal focus, trap, Escape)
 *
 * An unquoted `: ` inside a YAML scalar starts a mapping, so the step — and the
 * whole file — fails to parse. Quoting the value fixes it.
 *
 * Deliberately NOT a real YAML parse: js-yaml is not a declared devDependency
 * here (it is only transitively present), and a guard that depends on a package
 * nobody installed on purpose is the kind that breaks on a clean `npm ci` for
 * reasons unrelated to what it checks. This tests the one hazard that has
 * actually bitten, with no dependencies at all.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

const DIR = path.join(__dirname, '..', '.github', 'workflows');

function workflows() {
  if (!fs.existsSync(DIR)) return [];
  return fs.readdirSync(DIR).filter((f) => f.endsWith('.yml') || f.endsWith('.yaml'));
}

/** `key: value` lines whose value holds an unquoted `: `. */
function unquotedColonScalars(src) {
  const bad = [];
  src.split('\n').forEach((line, i) => {
    const m = line.match(/^\s*-?\s*(name|title|description):\s+(.*)$/);
    if (!m) return;
    const value = m[2].trim();
    if (!value || value.startsWith('"') || value.startsWith("'") || value.startsWith('|') || value.startsWith('>')) return;
    if (/:\s/.test(value)) bad.push(`${i + 1}: ${line.trim().slice(0, 90)}`);
  });
  return bad;
}

test('the check can see the workflow files', () => {
  // Guards the guard: an empty list would make every assertion below vacuous.
  const files = workflows();
  assert.ok(files.length >= 2, `expected several workflows, found ${files.length}`);
});

test('no workflow scalar contains an unquoted colon', () => {
  const offenders = [];
  for (const f of workflows()) {
    for (const hit of unquotedColonScalars(fs.readFileSync(path.join(DIR, f), 'utf8'))) {
      offenders.push(`${f}:${hit}`);
    }
  }
  assert.deepEqual(offenders, [],
    `quote these values — an unquoted ": " starts a mapping and the file stops parsing:\n  ${offenders.join('\n  ')}`);
});

test('the rule recognises the shapes it is meant to', () => {
  assert.equal(unquotedColonScalars('      - name: E2E smoke (keyboard: focus)').length, 1, 'unquoted colon is caught');
  assert.equal(unquotedColonScalars('      - name: "E2E smoke (keyboard: focus)"').length, 0, 'quoting fixes it');
  assert.equal(unquotedColonScalars("      - name: 'a: b'").length, 0, 'single quotes too');
  assert.equal(unquotedColonScalars('      - name: Plain step name').length, 0, 'ordinary names pass');
  assert.equal(unquotedColonScalars('        run: xvfb-run -a npm run x').length, 0, 'run: is not a scalar we police');
  assert.equal(unquotedColonScalars('      - name: Ratio 16:9 kept').length, 0,
    'a colon with no following space is not a mapping and must not be flagged');
});

test('every workflow declares a name and at least one job', () => {
  // A cheap structural sanity check that needs no YAML parser: both keys are
  // required, and their absence usually means a botched edit.
  for (const f of workflows()) {
    const src = fs.readFileSync(path.join(DIR, f), 'utf8');
    assert.match(src, /^name:\s*\S/m, `${f} has no top-level name`);
    assert.match(src, /^jobs:\s*$/m, `${f} declares no jobs`);
  }
});

/**
 * Every platform must publish an update manifest.
 *
 * electron-updater cannot offer an update without a `latest-*.yml` feed on the
 * release, and v3.2.0, v3.3.0 and v3.4.0 all shipped without `latest-linux.yml`.
 * The app checks on every platform with no gating, so on Linux that check asked
 * for a file that was not there. Nothing failed loudly; Linux users were simply
 * never offered an update, for three releases.
 *
 * A correction to how that was first explained here: `--publish never` does NOT
 * suppress the manifest. It only skips uploading — the file was written on every
 * run and left on the runner, because the upload step globbed `*.AppImage` and
 * `*.deb` and nothing else. Bed Ready proves it: it builds with `never`
 * (scripts/build-bedready.mjs) and its releases carry latest-linux.yml.
 *
 * So this check is about the manifest REACHING the release, and `--publish
 * always` is the simplest way to guarantee that — it is what the other two
 * platforms already do. `never` remains legitimate for a store package the store
 * updates itself, so it follows the same shape as the other allowlists here:
 * permitted, with the reason written down next to it.
 */
const PUBLISH_NEVER_IS_DELIBERATE = {
  appx: 'Microsoft Store package — Partner Center signs and the Store updates it, so there is no self-update feed to write',
};

test('no platform build silently skips its update feed', () => {
  const src = fs.readFileSync(path.join(DIR, 'release.yml'), 'utf8');
  const builds = [...src.matchAll(/npx electron-builder ([^\n]*)/g)].map((m) => m[1].trim());
  assert.ok(builds.length >= 3, `expected several electron-builder invocations, found ${builds.length}`);

  const offenders = builds
    .filter((cmd) => /--publish\s+never/.test(cmd))
    .filter((cmd) => !Object.keys(PUBLISH_NEVER_IS_DELIBERATE).some((k) => cmd.includes(k)));

  assert.deepEqual(offenders, [],
    'these build without an update feed — use `--publish always`, or add the target to '
    + `PUBLISH_NEVER_IS_DELIBERATE with the reason:\n  ${offenders.join('\n  ')}`);
});

test('every allowlisted exception still exists in the workflow', () => {
  // A reason left behind for a target that is gone is how an allowlist quietly
  // grows into a place where real problems hide.
  const src = fs.readFileSync(path.join(DIR, 'release.yml'), 'utf8');
  for (const target of Object.keys(PUBLISH_NEVER_IS_DELIBERATE)) {
    assert.ok(src.includes(target), `${target} is allowlisted but no longer built`);
  }
});
