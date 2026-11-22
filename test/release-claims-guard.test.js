const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { checkReleaseClaims, TRACKED, compare, sameLine } = require('../scripts/check-release-claims.js');

/**
 * Four release docs claimed four different "latest" versions on 2026-08-27, and
 * all four were found by a human re-reading them at cut time. These tests pin
 * down that the guard FAILS on each of those four shapes — a check nobody has
 * seen fail is indistinguishable from a check that cannot fail — and, just as
 * importantly, that it stays quiet on the prose those files are actually full
 * of: the open line's own name, the bump table's hypothetical `4.0.0`, Electron
 * version numbers, and paragraphs that quote the rule while explaining it.
 *
 * The first draft failed on six lines of correct prose. That version would have
 * been muted within a week, which is the failure mode this repo has already seen
 * with guards that nag.
 */

const made = [];
process.on('exit', () => {
  for (const d of made) fs.rmSync(d, { recursive: true, force: true });
});

/** A fixture repo: package.json plus whatever the case needs in each doc. */
function fixture(version, files) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'release-claims-'));
  made.push(dir);
  fs.mkdirSync(path.join(dir, 'docs'));
  fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ version }));
  for (const rel of TRACKED) {
    // Default body: names the current version, claims nothing. Cases override.
    const body = Object.prototype.hasOwnProperty.call(files, rel)
      ? files[rel]
      : `# ${rel}\n\nThis cut is ${version}.\n`;
    fs.writeFileSync(path.join(dir, rel), body);
  }
  return dir;
}

const CURRENT = '3.7.0-beta.10';
const claim = (v) => `**The newest *published* pre-release is \`v${v}\`** and here is why.`;

test('a repo whose docs agree passes', () => {
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim('3.7.0-beta.9')}\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

test('the real repo passes', () => {
  // The guard is only worth having if it is green on the tree it ships in.
  assert.deepEqual(checkReleaseClaims().failures, []);
});

test('VERSIONING six cuts behind: a doc that never names the current version', () => {
  const dir = fixture(CURRENT, {
    'VERSIONING.md': '# Khayt versioning\n\nLatest pre-release is `v3.7.0-beta.3`.\n',
  });
  const { failures } = checkReleaseClaims(dir);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /VERSIONING\.md: never mentions 3\.7\.0-beta\.10/);
});

test('ROADMAP naming two newest-published releases at once', () => {
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim('3.7.0-beta.9')}\n\n${claim('3.7.0-beta.8')}\n`,
  });
  const { failures } = checkReleaseClaims(dir);
  // Two failures, and both are true: the file makes the claim twice, AND the two
  // claims name different releases. The duplicate rule exists because the second
  // one alone would go quiet the moment somebody duplicated a paragraph without
  // changing the version in it.
  assert.equal(failures.length, 2);
  assert.match(failures.join('\n'), /claims a "newest published" release 2 times/);
  assert.match(failures.join('\n'), /disagree about which release is newest/);
});

test('two files quietly disagreeing about which release is newest', () => {
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim('3.7.0-beta.9')}\n`,
    'docs/RELEASE-HOLD.md': `Cutting ${CURRENT}.\n\n${claim('3.7.0-beta.8')}\n`,
  });
  const { failures } = checkReleaseClaims(dir);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /disagree about which release is newest/);
  assert.match(failures[0], /3\.7\.0-beta\.9/);
  assert.match(failures[0], /3\.7\.0-beta\.8/);
});

test('a doc that has run ahead of the version bump', () => {
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}, and next week 3.7.0-beta.11 lands.\n`,
  });
  const { failures } = checkReleaseClaims(dir);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /names 3\.7\.0-beta\.11, newer than/);
});

test('a claim with no version anywhere near it is refused', () => {
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\nThe newest published pre-release is the one on the releases page.\n`,
  });
  const { failures } = checkReleaseClaims(dir);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /names no version/);
});

// ── The quiet half: what it must NOT fire on ────────────────────────────────

test('the open line, a hypothetical major and Electron are not release claims', () => {
  // Every one of these failed the first draft. `3.7.0` outranks `3.7.0-beta.10`
  // in semver and is on every page as the name of the line being built; `4.0.0`
  // is in VERSIONING's bump table; `42.8.1` is Electron.
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `The 3.7.0 line is open, cutting ${CURRENT}. Electron 42.2.0 → 42.8.1.\n`,
    'VERSIONING.md': `Major bump: 3.x.x → 4.0.0. This cut is ${CURRENT}.\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

test('quoting the rule is not asserting it', () => {
  // ROADMAP carries a paragraph explaining that only one paragraph may make the
  // claim. Counting that explanation as a second claim would make the file
  // unfixable without deleting the explanation.
  const dir = fixture(CURRENT, {
    'ROADMAP.md':
      `Cutting ${CURRENT}.\n\n${claim('3.7.0-beta.9')}\n\n` +
      `*(#772 said it had collapsed the duplicated "newest published" paragraphs to one. It had not.)*\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

test('a claim whose version wrapped onto the next line is still found', () => {
  // ROADMAP's own claim is split exactly this way. A same-line-only search finds
  // nothing and passes silently, which is worse than failing.
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n**The newest *published* pre-release is\n\`v3.7.0-beta.9\`** (2026-08-27) — tagged from \`b587777\`.\n`,
    'docs/RELEASE-HOLD.md': `Cutting ${CURRENT}.\n\n${claim('3.7.0-beta.9')}\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

test('the line name before the claim is not mistaken for the claimed version', () => {
  // ROADMAP's paragraph opens "The 3.7.0 line is open. The newest *published*
  // pre-release is\n`v3.7.0-beta.10`". Reading the whole line returns `3.7.0` —
  // the name of the line, not a release — and two files could then "agree" on
  // that while disagreeing about the version each actually names.
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `The 3.7.0 line is open. The newest *published* pre-release is\n\`v${CURRENT}\`** (2026-08-27).\n`,
    'docs/RELEASE-HOLD.md': `Cutting ${CURRENT}.\n\n${claim(CURRENT)}\n`,
  });
  const { failures, claims } = checkReleaseClaims(dir);
  assert.deepEqual(failures, []);
  assert.deepEqual([...new Set(claims.map((c) => c.version))], [CURRENT]);
});

test('history is not a claim — old versions may be named freely', () => {
  const dir = fixture(CURRENT, {
    'ROADMAP.md':
      `Cutting ${CURRENT}. The 3.6.0 line ran beta.1–beta.19 then rc.1–rc.4; ` +
      `v3.6.0 shipped stable, superseding v3.5.3 and v3.2.0.\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

// ── The stable channel ──────────────────────────────────────────────────────

const stableRow = (v) => `| **Stable** | \`v${v}\` | [Latest release](x) | Default |`;

test('the files must agree on which release is stable', () => {
  // The drift this exists for happens on PROMOTION DAY: four files each carry
  // the fact in their own wording, all have to change at once, and the person
  // doing it is thinking about the release rather than the prose.
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim(CURRENT)}\n\n**Stable is v3.6.0** (2026-08-21).\n`,
    'VERSIONING.md': `This cut is ${CURRENT}.\n\n- **Stable:** \`3.5.x\` — latest tag **v3.5.3**.\n`,
  });
  const { failures } = checkReleaseClaims(dir);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /disagree about which release is stable/);
  assert.match(failures[0], /ROADMAP\.md:5 says 3\.6\.0/);
  assert.match(failures[0], /VERSIONING\.md:3 says 3\.5\.3/);
});

test('nothing may be called stable before the bump that creates it', () => {
  // Promoting the docs ahead of the version is the same trap as the beta.4 day,
  // pointed the other way: the file says a release exists that does not.
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim(CURRENT)}\n\n**Stable is v3.7.0** (today).\n`,
    'VERSIONING.md': `This cut is ${CURRENT}.\n\n${stableRow('3.7.0')}\n`,
  });
  const { failures } = checkReleaseClaims(dir);
  // They AGREE with each other and are both wrong, which is why the second rule
  // is not redundant with the first.
  assert.ok(!failures.some((f) => /disagree about which release is stable/.test(f)));
  assert.equal(failures.length, 2);
  for (const f of failures) assert.match(f, /calls 3\.7\.0 stable, but package\.json is 3\.7\.0-beta\.10/);
});

test('prose about stability is not a claim about the stable release', () => {
  // All three of these are real lines from these files. A case-insensitive match
  // would read every one as a claim and demand a version from it.
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim(CURRENT)}\n\n**Stable is v3.6.0**.\n`,
    'VERSIONING.md':
      `This cut is ${CURRENT}. ${stableRow('3.6.0')}\n\n` +
      `from a **stable** version it bumps the minor and starts at beta.1\n` +
      `**stable** installers stay on the last published stable\n` +
      `they have been in **stable v3.6.0** since 2026-08-21\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

test('the stable claim survives wrapping onto the next line', () => {
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim(CURRENT)}\n\n**Stable is\nv3.6.0** (2026-08-21) — promoted from rc.4.\n`,
    'VERSIONING.md': `This cut is ${CURRENT}. ${stableRow('3.6.0')}\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

// ── Bed Ready's separate line ───────────────────────────────────────────────

test('the files must agree on the current Bed Ready release', () => {
  // Bed Ready's version is typed into a workflow input at release time and
  // committed nowhere, so these files are the only record of it. After a cut,
  // one of them gets updated and the other does not.
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim(CURRENT)}\n\nBed Ready is current: \`1.2.0\`.\n`,
    'VERSIONING.md': `This cut is ${CURRENT}. Bed Ready: **1.1.0 shipped**.\n`,
  });
  const { failures } = checkReleaseClaims(dir);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /disagree about the current Bed Ready release/);
  assert.match(failures[0], /ROADMAP\.md tops out at 1\.2\.0/);
  assert.match(failures[0], /VERSIONING\.md tops out at 1\.1\.0/);
});

test('older Bed Ready releases may be discussed freely', () => {
  // Both files legitimately talk about history — 1.0.0's nine-day gap, the
  // `bedready-v1.0.0` updater trap — and VERSIONING carries an EXAMPLE command
  // that types a version. Only the highest in each file is read as the claim, so
  // none of that fires.
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim(CURRENT)}\n\nBed Ready is current: \`1.2.0\`; it sat on 1.0.0 for nine days.\n`,
    'VERSIONING.md': `This cut is ${CURRENT}. Bed Ready 1.2.0 shipped; 1.1.0 was before it, 1.0.0 before that.\n\n    Bed Ready version: 1.0.1\n\nDo not tag bedready-v1.0.0 here.\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

test('a file that never mentions Bed Ready is not stale about it', () => {
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}.\n\n${claim(CURRENT)}\n\nBed Ready is current: \`1.2.0\`.\n`,
  });
  const { failures, bedready } = checkReleaseClaims(dir);
  assert.deepEqual(failures, []);
  assert.deepEqual(Object.keys(bedready), ['ROADMAP.md']);
});

test('a Khayt version can never be mistaken for a Bed Ready one', () => {
  // The rule rests on Khayt being 3.x and Bed Ready 1.x. Assert it rather than
  // rely on it: a `1.` prefix test that also matched Khayt would make every file
  // "disagree" the moment Khayt reached 1.x, which it never will — but the
  // reason it is safe should be written down where it can fail.
  assert.ok(CURRENT.startsWith('3.'));
  const dir = fixture(CURRENT, {
    'ROADMAP.md': `Cutting ${CURRENT}. Bed Ready is current: \`1.2.0\`.\n\n${claim(CURRENT)}\n`,
    'VERSIONING.md': `This cut is ${CURRENT}, superseding 3.6.0 and 3.5.3. Bed Ready 1.2.0.\n`,
  });
  assert.deepEqual(checkReleaseClaims(dir).failures, []);
});

// ── The comparison the rules rest on ────────────────────────────────────────

test('a stable release outranks every prerelease of the same core', () => {
  assert.ok(compare('3.7.0', '3.7.0-beta.10') > 0);
  assert.ok(compare('3.7.0-rc.1', '3.7.0-beta.99') > 0);
  assert.ok(compare('3.7.0-beta.10', '3.7.0-beta.9') > 0);
  assert.equal(compare('3.6.0', '3.6.0'), 0);
  assert.ok(compare('3.6.0', '3.7.0-beta.1') < 0);
});

test('sameLine is only true for two prereleases of one core', () => {
  assert.equal(sameLine('3.7.0-beta.11', '3.7.0-beta.10'), true);
  assert.equal(sameLine('3.7.0', '3.7.0-beta.10'), false);
  assert.equal(sameLine('4.0.0', '3.7.0-beta.10'), false);
  assert.equal(sameLine('42.8.1', '3.7.0-beta.10'), false);
});
