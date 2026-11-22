const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  sanitizeReleaseNotesHtml,
  formatReleaseNotesText,
  formatReleaseNotesForDisplay,
} = require('../lib/release-notes');

test('sanitizeReleaseNotesHtml removes scripts and inline handlers', () => {
  const input = '<p onclick="alert(1)">Hi</p><script>alert(1)</script>';
  const out = sanitizeReleaseNotesHtml(input);
  assert.match(out, /<p>Hi<\/p>/);
  assert.doesNotMatch(out, /script/i);
  assert.doesNotMatch(out, /onclick/i);
});

test('formatReleaseNotesText converts markdown bullets to a list', () => {
  const html = formatReleaseNotesText('### Fixed\n- One\n- Two');
  assert.match(html, /<h4 class="update-notes-heading">Fixed<\/h4>/);
  assert.match(html, /<ul class="update-notes-list">/);
  assert.match(html, /<li>One<\/li>/);
  assert.match(html, /<li>Two<\/li>/);
});

test('formatReleaseNotesForDisplay falls back when notes are empty', () => {
  const { html, hasContent } = formatReleaseNotesForDisplay('', { version: '2.4.0' });
  assert.equal(hasContent, false);
  assert.match(html, /Khayt 2\.4\.0/);
  assert.match(html, /github\.com/i);
});

/* ────────────────────────────────────────────────────────────────────────────
 * A release body GitHub will actually accept.
 *
 * The v3.7.0 cut failed here, and failed in the worst shape: the tag was
 * created, `gh release create` came back `HTTP 422: body is too long (maximum
 * is 125000 characters)`, no release was made, and every platform job was
 * skipped. From `git ls-remote --tags` the cut looked done and had shipped
 * nothing. 2,357 lines and 152,890 characters, because a stable promotion
 * carries the whole line's entry.
 * ──────────────────────────────────────────────────────────────────────────── */
{
  const { sectionFor, fitForRelease, GITHUB_BODY_LIMIT, DEFAULT_MAX_CHARS } =
    require('../scripts/changelog-section.js');
  const major = require('../lib/major-changes.js');
  const fsx = require('fs');
  const pathx = require('path');
  const CHANGELOG = fsx.readFileSync(pathx.join(__dirname, '..', 'CHANGELOG.md'), 'utf8');

  test('every version in the changelog fits in a GitHub release body', () => {
    // Not just the current one: a re-run or a repaired older release calls the
    // same script, and a limit that only the newest entry respects is a limit
    // nobody is checking.
    const versions = [...CHANGELOG.matchAll(/^##\s+\[([^\]]+)\]/gm)]
      .map((m) => m[1]).filter((v) => v !== 'Unreleased');
    assert.ok(versions.length > 5, 'expected a changelog with history in it');
    for (const v of versions) {
      const body = sectionFor(CHANGELOG, v);
      if (!body) continue;
      const fitted = fitForRelease(body, { version: v });
      assert.ok(fitted.text.length < GITHUB_BODY_LIMIT,
        `${v} is ${fitted.text.length} characters — GitHub refuses the whole request above ${GITHUB_BODY_LIMIT}`);
    }
  });

  test('a truncated entry keeps the consent gate, which lives at the top', () => {
    // THE REASON IT TRUNCATES FROM THE END. `major-changes.js` reads
    // "### Before you update" out of the body to decide whether the update
    // blocks until the shop accepts. Cutting from the front to keep the recent
    // items would silently un-gate a release that moves a shop's data.
    const body = sectionFor(CHANGELOG, '3.7.0');
    assert.ok(body, 'the 3.7.0 entry should exist');
    assert.ok(body.length > DEFAULT_MAX_CHARS, 'this test needs an entry big enough to be cut');
    const fitted = fitForRelease(body, { version: '3.7.0' });
    assert.equal(fitted.truncated, true);

    const before = major.parseMajorChanges(body);
    const after = major.parseMajorChanges(fitted.text);
    assert.equal(after.needsConsent, before.needsConsent);
    assert.deepEqual(after.items, before.items,
      'truncation changed which changes the shop is asked to accept');
  });

  test('an entry that already fits is passed through untouched', () => {
    const small = '### Fixed\n\n- **A small thing.** It was small.\n';
    const fitted = fitForRelease(small, { version: '1.0.0' });
    assert.equal(fitted.truncated, false);
    assert.equal(fitted.text, small);
    assert.equal(fitted.omitted, 0);
  });

  test('it stops at a boundary a reader recognises, not mid-sentence', () => {
    const body = '### Added\n\n'
      + Array.from({ length: 400 }, (_, i) =>
        `- **Item ${i}.** ${'x'.repeat(400)}\n`).join('\n');
    const fitted = fitForRelease(body, { version: '9.9.9', maxChars: 5000 });
    assert.equal(fitted.truncated, true);
    assert.ok(fitted.text.length <= 5000, `got ${fitted.text.length}`);
    // The kept part ends at a bullet boundary, so the last thing before the
    // notice is a complete item rather than half of one.
    const kept = fitted.text.split('\n---\n')[0].trimEnd();
    assert.ok(kept.endsWith('x'.repeat(10)) || /\n$/.test(kept + '\n'),
      'expected the cut to land after a complete item');
    assert.match(fitted.text, /full changelog/);
    assert.match(fitted.text, /CHANGELOG\.md/);
  });

  test('the notice names the version, so a reader knows what is missing', () => {
    const body = 'x'.repeat(200000);
    const fitted = fitForRelease(body, { version: '4.2.0' });
    assert.match(fitted.text, /4\.2\.0/);
    assert.ok(fitted.omitted > 0);
  });
}
