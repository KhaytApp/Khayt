/**
 * The Microsoft Store listing builder.
 *
 * Everything here protects one thing: a submission that gets rejected is not a
 * failed build, it is a silent multi-hour delay discovered by a human reading a
 * rejection email. So the limits are checked before anything is sent, and these
 * tests check the checker — a validator that accepts everything is worse than
 * none, because it is trusted.
 *
 * The real listing is validated separately by `npm run store:check` in CI; this
 * file drives the edge cases that the real listing (deliberately) does not hit.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');

let mod;
test('load the ESM builder', async () => {
  mod = await import('../scripts/build-store-metadata.mjs');
});

const listing = (over = {}) => ({
  description: 'A real description.',
  shortDescription: 'Short.',
  features: ['One'],
  searchTerms: ['3D printing'],
  additionalSystemRequirements: 'Windows 10.',
  copyrightAndTrademark: '© Khayt.',
  developedBy: 'Khayt',
  screenshots: [{ file: 'a.png', caption: 'A' }],
  ...over,
});

test('a listing within every limit has no problems', () => {
  assert.deepEqual(mod.validateListing(listing(), 'Fixed things.'), []);
});

test('an over-long description is caught, with the overshoot named', () => {
  const problems = mod.validateListing(listing({ description: 'x'.repeat(10_001) }), 'ok');
  assert.equal(problems.length, 1);
  assert.match(problems[0], /description is 10001 characters, limit is 10000 \(over by 1\)/);
});

test('an empty description is caught as missing, not merely short', () => {
  const problems = mod.validateListing(listing({ description: '   ' }), 'ok');
  assert.ok(problems.some((p) => /description is required/.test(p)), problems.join('; '));
});

test('each limit is enforced independently', () => {
  const cases = [
    [{ shortDescription: 'x'.repeat(256) }, /shortDescription is 256/],
    [{ additionalSystemRequirements: 'x'.repeat(201) }, /additionalSystemRequirements is 201/],
    [{ copyrightAndTrademark: 'x'.repeat(201) }, /copyrightAndTrademark is 201/],
    [{ developedBy: 'x'.repeat(256) }, /developedBy is 256/],
    [{ features: Array(21).fill('f') }, /21 features, limit is 20/],
    [{ features: ['x'.repeat(201)] }, /feature 1 .* is 201 characters/],
    [{ searchTerms: Array(8).fill('t') }, /8 search terms, limit is 7/],
    [{ searchTerms: ['x'.repeat(41)] }, /search term 1 .* is 41 characters/],
    [{ screenshots: [] }, /at least one screenshot is required/],
    [{ screenshots: Array(11).fill({ file: 'a.png', caption: 'c' }) }, /11 screenshots, limit is 10/],
    [{ screenshots: [{ file: 'a.png', caption: 'x'.repeat(201) }] }, /screenshot 1 caption is 201/],
  ];
  for (const [over, expected] of cases) {
    const problems = mod.validateListing(listing(over), 'ok');
    assert.ok(problems.some((p) => expected.test(p)),
      `expected ${expected} among: ${problems.join('; ') || '(none)'}`);
  }
});

test("the search-terms word budget is counted across all terms, not per term", () => {
  // 7 terms of 3 words each = 21, exactly at the limit.
  const atLimit = Array(7).fill('one two three');
  assert.deepEqual(mod.validateListing(listing({ searchTerms: atLimit }), 'ok'), []);

  const over = [...Array(6).fill('one two three'), 'one two three four'];
  const problems = mod.validateListing(listing({ searchTerms: over }), 'ok');
  assert.ok(problems.some((p) => /22 words across all terms, limit is 21/.test(p)), problems.join('; '));
});

test('an over-long "what\'s new" is caught', () => {
  const problems = mod.validateListing(listing(), 'x'.repeat(1501));
  assert.ok(problems.some((p) => /what's new is 1501 characters, limit is 1500/.test(p)), problems.join('; '));
});

test('a named screenshot with no file on disk is caught', () => {
  const dir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'shots-'));
  fs.writeFileSync(path.join(dir, 'present.png'), '');
  const problems = mod.validateListing(
    listing({ screenshots: [{ file: 'present.png', caption: 'a' }, { file: 'gone.png', caption: 'b' }] }),
    'ok',
    { screenshotDir: dir },
  );
  assert.equal(problems.length, 1);
  assert.match(problems[0], /screenshot file is missing: gone\.png/);
});

test('changelogSection pulls one version and stops at the next heading', () => {
  const md = [
    '# Changelog', '', '## [Unreleased]', '', '- pending', '',
    '## [3.6.0] - 2026-08-13', '', '### Fixed', '- the real one', '',
    '## [3.5.3] - 2026-08-01', '', '- older',
  ].join('\n');
  const section = mod.changelogSection(md, '3.6.0');
  assert.match(section, /the real one/);
  assert.doesNotMatch(section, /older/);
  assert.doesNotMatch(section, /pending/);
  assert.equal(mod.changelogSection(md, '9.9.9'), null);
});

test('a prerelease version matches its own section, not the stable prefix', () => {
  const md = '## [3.6.0-rc.1] - 2026-08-12\n\n- candidate\n\n## [3.6.0] - 2026-08-13\n\n- stable\n';
  assert.match(mod.changelogSection(md, '3.6.0-rc.1'), /candidate/);
  assert.match(mod.changelogSection(md, '3.6.0'), /stable/);
});

test('markdown becomes the plain text the Store renders', () => {
  const out = mod.markdownToPlainText(
    '### Fixed\n\n- **Bold** and *italic* and `code`\n- A [link](https://example.test) stays as text\n\n![img](x.png)\n',
  );
  assert.match(out, /^Fixed/);
  assert.match(out, /• Bold and italic and code/);
  assert.match(out, /A link stays as text/);
  assert.doesNotMatch(out, /\*\*|\]\(|!\[/);
});

test("what's new always fits, and always points at the full notes", () => {
  const long = Array(40).fill('A paragraph that is reasonably long and says something.').join('\n\n');
  const out = mod.buildWhatsNew(long, '3.6.0');
  assert.ok(out.length <= mod.LIMITS.whatsNew, `got ${out.length}`);
  assert.match(out, /releases\/tag\/v3\.6\.0/);
  // Trimmed on a paragraph boundary, so it never ends mid-sentence.
  assert.doesNotMatch(out.split('\n\nFull release notes')[0], /[a-z,]$/);
});

test("what's new degrades to a generic line when the version has no section", () => {
  const out = mod.buildWhatsNew(null, '3.6.0');
  assert.match(out, /Maintenance and stability/);
  assert.match(out, /releases\/tag\/v3\.6\.0/);
});

test('a single unbroken paragraph is cut on a sentence boundary', () => {
  const oneParagraph = Array(60).fill('This sentence is here to take up room.').join(' ');
  const out = mod.buildWhatsNew(oneParagraph, '1.0.0');
  assert.ok(out.length <= mod.LIMITS.whatsNew, `got ${out.length}`);
  assert.match(out.split('\n\nFull release notes')[0], /room\.$/);
});

test('merging into a baseline replaces our fields and preserves everything else', () => {
  const baseline = {
    id: 'sub-1',
    ageRatings: { esrb: 'Everyone' },
    listings: { 'en-us': { description: 'OLD', features: ['old'], images: [{ id: 'keep-me' }] } },
    pricing: { priceId: 'Free' },
  };
  const { merged, replaced } = mod.mergeIntoBaseline(baseline, {
    description: 'NEW',
    features: ['new'],
  });
  assert.equal(replaced, 2);
  assert.equal(merged.listings['en-us'].description, 'NEW');
  assert.deepEqual(merged.listings['en-us'].features, ['new']);
  // Untouched keys survive — this is what stops an automated metadata update
  // from resetting age ratings, pricing or existing images.
  assert.deepEqual(merged.listings['en-us'].images, [{ id: 'keep-me' }]);
  assert.deepEqual(merged.ageRatings, { esrb: 'Everyone' });
  assert.deepEqual(merged.pricing, { priceId: 'Free' });
  assert.equal(baseline.listings['en-us'].description, 'OLD', 'the baseline must not be mutated');
});

test('a baseline that shares no fields reports zero replacements', () => {
  const { replaced } = mod.mergeIntoBaseline({ somethingElse: 1 }, { description: 'NEW' });
  assert.equal(replaced, 0, 'zero is the signal the shape changed');
});

test('the shipped listing.json is valid and its screenshots exist', () => {
  const root = path.join(__dirname, '..');
  const dir = path.join(root, 'store', 'microsoft');
  const real = JSON.parse(fs.readFileSync(path.join(dir, 'listing.json'), 'utf8'));
  const whatsNew = mod.buildWhatsNew(
    mod.changelogSection(fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8'), '3.6.0-rc.1'),
    '3.6.0-rc.1',
  );
  const problems = mod.validateListing(real, whatsNew, { screenshotDir: path.join(dir, 'screenshots') });
  assert.deepEqual(problems, [], problems.join('\n  '));
});
