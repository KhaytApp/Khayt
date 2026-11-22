const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
  sectionFor, fitForRelease, withoutMaintainerNotes, DEFAULT_MAX_CHARS,
} = require('../scripts/changelog-section.js');

const CHANGELOG = fs.readFileSync(path.join(__dirname, '..', 'CHANGELOG.md'), 'utf8');

/**
 * A release body has a hard ceiling, and what gets cut to fit is a decision.
 *
 * 3.8.0's entry came to 126,885 characters against a 120,000 budget and GitHub's
 * 125,000 hard limit. The default is `fitForRelease`, which trims from the END —
 * and the end of that entry is the tail of `### Fixed`. Fourteen entries would
 * have gone, among them "Break-even was telling shops to bill LESS than they
 * must", "The cash-flow chart counted a deposit as the whole job" and "A quote
 * counted as lifetime value".
 *
 * Money bugs are the last thing a release should quietly stop mentioning. So the
 * entries addressed to whoever maintains this repo come out first: the author
 * marks them `(Maintainers)` or `(Repo)` precisely to say they are not for a
 * shop, and in 3.8.0 they were 22,000 characters of the overflow.
 */

test('maintainer-marked entries do not reach a shop', () => {
  const body = [
    '### Fixed', '',
    '- **A real fix a shop can act on.** Body.', '',
    '- **(Maintainers) The release script ran a comment.** Body.', '',
    '- **(Repo) `KhaytCore` is flagged as shared.** Body.', '',
    '- **Another real one.** Body.', '',
  ].join('\n');
  const out = withoutMaintainerNotes(body);
  assert.equal(out.removed, 2);
  assert.match(out.text, /A real fix a shop can act on/);
  assert.match(out.text, /Another real one/);
  assert.doesNotMatch(out.text, /\(Maintainers\)/);
  assert.doesNotMatch(out.text, /\(Repo\)/);
});

test('a multi-line maintainer entry goes whole, not just its first line', () => {
  const body = [
    '### Changed', '',
    '- **(Maintainers) A lead that wraps across',
    '  two lines.** And a body paragraph that',
    '  also wraps.', '',
    '- **A shop-facing one.** Kept.', '',
  ].join('\n');
  const out = withoutMaintainerNotes(body);
  assert.equal(out.removed, 1);
  assert.doesNotMatch(out.text, /wraps across/);
  assert.doesNotMatch(out.text, /body paragraph/);
  assert.match(out.text, /A shop-facing one/);
});

test('a subsection emptied of every bullet does not ship as a bare heading', () => {
  const body = [
    '### Added', '',
    '- **(Maintainers) Only this.** Body.', '',
    '### Fixed', '',
    '- **A real one.** Body.', '',
  ].join('\n');
  const out = withoutMaintainerNotes(body);
  assert.doesNotMatch(out.text, /### Added/, 'an empty "### Added" heading would ship with nothing under it');
  assert.match(out.text, /### Fixed/);
});

/**
 * The guard that matters: this shapes the RELEASE BODY only. `sectionFor` feeds
 * the update-consent gate, and what a shop is asked to agree to must stay
 * exactly what CHANGELOG.md says — including anything under `### Before you
 * update`, which is the whole point of that gate.
 */
test('sectionFor is left alone, so the consent gate reads the file as written', () => {
  const raw = sectionFor(CHANGELOG, '3.8.0');
  assert.ok(raw, '3.8.0 has no section');
  const maintainerBullets = (raw.match(/^- \*\*\((?:Maintainers|Repo)\)/gm) || []).length;
  assert.ok(maintainerBullets > 0,
    'sectionFor no longer returns maintainer entries — the filter has leaked into the '
    + 'function the consent gate reads');
});

test("3.8.0's release body fits without trimming a single shop-facing entry", () => {
  const raw = sectionFor(CHANGELOG, '3.8.0');
  assert.ok(raw, '3.8.0 has no section');
  const shopFacing = withoutMaintainerNotes(raw);
  const fitted = fitForRelease(shopFacing.text, { version: '3.8.0' });
  assert.equal(fitted.truncated, false,
    `3.8.0's notes are ${shopFacing.text.length} characters after lifting `
    + `${shopFacing.removed} maintainer entries, still over the ${DEFAULT_MAX_CHARS} budget. `
    + 'The overflow would be trimmed from the END, which is inside "### Fixed".');
});

/* ────────────────────────────────────────────────────────────────────────────
 * A RELATIVE LINK IS RELATIVE TO THE REPOSITORY IT IS READ IN.
 *
 * The notes are written in this repository's CHANGELOG.md and published on a
 * release in KhaytApp/khayt-mac. Every Mac alpha so far has opened with
 * `[VERSIONING.md](./VERSIONING.md)`, which on that release page resolves to
 * https://github.com/KhaytApp/khayt-mac/blob/main/VERSIONING.md — a 404,
 * verified against the live page. Nobody reported it; a dead link in release
 * notes reads as the reader's own mistake.
 * ──────────────────────────────────────────────────────────────────────────── */

const { withAbsoluteLinks } = require('../scripts/changelog-section.js');

test('a relative link becomes absolute against the repository it was written in', () => {
  assert.equal(
    withAbsoluteLinks('see [VERSIONING.md](./VERSIONING.md)'),
    'see [VERSIONING.md](https://github.com/KhaytApp/Khayt/blob/main/VERSIONING.md)');
  assert.equal(
    withAbsoluteLinks('[the spec](docs/KHAYT-3.0-QC-SPEC.md)'),
    '[the spec](https://github.com/KhaytApp/Khayt/blob/main/docs/KHAYT-3.0-QC-SPEC.md)');
});

test('a link that already goes somewhere is left exactly as written', () => {
  for (const line of [
    '[releases](https://github.com/khaytapp/Khayt/releases)',
    '[mail](mailto:hi@khaytapp.com)',
    '[same-protocol](//example.test/x)',
    '[within the page](#before-you-update)',
  ]) {
    assert.equal(withAbsoluteLinks(line), line, line);
  }
});

test('the link text and a title are untouched', () => {
  assert.equal(
    withAbsoluteLinks('[VERSIONING.md](./VERSIONING.md "how versions work")'),
    '[VERSIONING.md](https://github.com/KhaytApp/Khayt/blob/main/VERSIONING.md "how versions work")');
});

test('the real alpha.26 section comes out with a link that resolves', () => {
  // The section as shipped, through the same call the release lane makes.
  const fs = require('fs');
  const path = require('path');
  const text = fs.readFileSync(path.join(__dirname, '..', 'CHANGELOG.md'), 'utf8');
  const section = sectionFor(text, '4.0.0-alpha.26');
  assert.ok(section, 'the alpha.26 section is gone');
  const out = withAbsoluteLinks(section);
  assert.doesNotMatch(out, /\]\(\.\//, 'a relative link survived into the release body');
  assert.match(out, /https:\/\/github\.com\/KhaytApp\/Khayt\/blob\/main\/VERSIONING\.md/);
});
