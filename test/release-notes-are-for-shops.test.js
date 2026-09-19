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
