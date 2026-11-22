'use strict';
/**
 * What a shop is asked to agree to, and — more importantly — what it is NOT.
 *
 * The gate is only worth having if it is rare. A prompt that appears on every
 * release is a prompt everybody learns to click through without reading, which
 * is worse than no prompt at all: it trains the habit and then one day carries
 * something that mattered. So most of these tests are about the section being
 * ABSENT, malformed, or merely mentioned in passing, and the answer in every
 * one of those cases being "no gate".
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { parseMajorChanges, HEADING } = require('../lib/major-changes.js');

test('an ordinary release asks nobody to agree to anything', () => {
  for (const notes of [
    '',
    null,
    undefined,
    '### Fixed\n\n- A photo too big for the cloud is no longer sent and lost.',
    'See [README](https://github.com/KhaytApp/Khayt#readme) for full release notes.',
  ]) {
    const r = parseMajorChanges(notes);
    assert.equal(r.needsConsent, false, JSON.stringify(notes));
    assert.deepEqual(r.items, []);
  }
});

test('a release that declares one is read as a list of sentences', () => {
  const r = parseMajorChanges([
    '## [3.8.0] - 2026-09-09',
    '',
    '### Before you update',
    '',
    '- The buttons on a print file have moved into a ··· menu.',
    '- Folders are called Collections now. Nothing you filed has moved.',
    '',
    '### Fixed',
    '',
    '- Something unrelated.',
  ].join('\n'));
  assert.equal(r.needsConsent, true);
  assert.deepEqual(r.items, [
    'The buttons on a print file have moved into a ··· menu.',
    'Folders are called Collections now. Nothing you filed has moved.',
  ]);
});

test('the list stops at the next heading, and does not swallow the release', () => {
  const r = parseMajorChanges([
    '### Before you update',
    '- One thing.',
    '### Fixed',
    '- Not a thing anyone has to agree to.',
    '- Nor this.',
  ].join('\n'));
  assert.deepEqual(r.items, ['One thing.']);
});

test('an empty section is a drafting mistake, not a gate', () => {
  // Blocking an update on a heading with nothing under it asks somebody to
  // accept the unstated, which is worse than not asking.
  const r = parseMajorChanges('### Before you update\n\n### Fixed\n\n- x');
  assert.equal(r.needsConsent, false);
  assert.deepEqual(r.items, []);
});

test('merely mentioning the phrase does not gate a release', () => {
  const r = parseMajorChanges([
    '### Fixed',
    '- The dialog now says "before you update" in the right language.',
    '- Read this before you update your printer firmware.',
  ].join('\n'));
  assert.equal(r.needsConsent, false);
});

test('HTML notes are read too — GitHub does not always hand back markdown', () => {
  const r = parseMajorChanges(
    '<h3>Before you update</h3><ul><li>The buttons on a print file have moved.</li>'
    + '<li>Folders are called <strong>Collections</strong>.</li></ul><h3>Fixed</h3><ul><li>x</li></ul>');
  assert.equal(r.needsConsent, true);
  assert.deepEqual(r.items, [
    'The buttons on a print file have moved.',
    'Folders are called Collections.',
  ]);
});

test('markdown emphasis and links are stripped — this is a dialog, not a page', () => {
  const r = parseMajorChanges([
    '### Before you update',
    '- **Delete** moved into the `···` menu — see [the notes](https://example.com/x).',
  ].join('\n'));
  assert.deepEqual(r.items, ['Delete moved into the ··· menu — see the notes.']);
});

test('a wrapped bullet stays one change, not two', () => {
  const r = parseMajorChanges([
    '### Before you update',
    '- The buttons on a print file have moved into a ··· menu,',
    '  and Delete now sits under a divider at the bottom of it.',
  ].join('\n'));
  assert.equal(r.items.length, 1);
  assert.match(r.items[0], /divider at the bottom of it\.$/);
});

test('script and style content never reaches the dialog', () => {
  const r = parseMajorChanges(
    '<h3>Before you update</h3><script>alert(1)</script><ul><li>A real change.</li></ul>');
  assert.deepEqual(r.items, ['A real change.']);
  assert.ok(!JSON.stringify(r).includes('alert'));
});

test('the heading is exported, so the changelog and the parser cannot drift', () => {
  // scripts/check-major-changes.js and the CHANGELOG convention both read this
  // rather than each spelling the phrase out.
  assert.equal(HEADING, 'Before you update');
});

test('the notes arrive as RENDERED HTML, and a wrapped item survives it', () => {
  /* THIS IS THE SHAPE PRODUCTION SENDS, and the one the parser could not read.
   *
   * electron-updater takes `releaseNotes` from the GitHub release atom feed,
   * which carries the rendered HTML — not the markdown we wrote. So `stripTags`
   * runs: `<li>` becomes a bare "- " with the text on the FOLLOWING line, at
   * column zero, because the markdown parser consumed the list indentation.
   *
   * The old rule needed two leading spaces to treat a line as a continuation,
   * and an empty bullet marker opened nothing. A multi-line item was therefore
   * dropped ENTIRELY — and a section whose items are all multi-line, which is
   * exactly what CHANGELOG.md holds, parsed to zero items and
   * `needsConsent: false`.
   *
   * The gate would not have appeared on the next release at all. */
  const rendered = [
    '<h3>Before you update</h3>', '<ul>', '<li>',
    '<strong>The box that said "Folder" now says "Group"</strong>, and it means',
    'something on your catalogue too. Nothing is re-filed.',
    '</li>',
    '<li>A second change, on one line.</li>',
    '</ul>',
  ].join('\n');
  const r = parseMajorChanges(rendered);
  assert.equal(r.needsConsent, true, 'the gate vanished on the shape production actually sends');
  assert.equal(r.items.length, 2);
  assert.match(r.items[0], /Folder.*Group.*and it means something on your catalogue too\. Nothing is re-filed\./,
    'the wrapped remainder of the item was lost');
  assert.equal(r.items[1], 'A second change, on one line.');
});

test('markdown and its rendering give the same answer', () => {
  // The two forms must not disagree: CI reads the CHANGELOG, the app reads the
  // release page, and a gate that differs between them is a gate nobody can
  // verify before shipping.
  const md = [
    '### Before you update', '',
    '- **The box that said "Folder" now says "Group"**, and it means',
    '  something on your catalogue too. Nothing is re-filed.',
    '- A second change, on one line.',
  ].join('\n');
  const rendered = [
    '<h3>Before you update</h3>', '<ul>', '<li>',
    '<strong>The box that said "Folder" now says "Group"</strong>, and it means',
    'something on your catalogue too. Nothing is re-filed.',
    '</li>', '<li>A second change, on one line.</li>', '</ul>',
  ].join('\n');
  assert.deepEqual(parseMajorChanges(md), parseMajorChanges(rendered));
});

test('a stray marker with no text is not a change to accept', () => {
  // The empty-bullet rule that makes the above work must not invent items.
  const r = parseMajorChanges('### Before you update\n\n-\n-  \n');
  assert.equal(r.needsConsent, false);
  assert.deepEqual(r.items, []);
});

test('a blank line does not glue two items together', () => {
  const r = parseMajorChanges('### Before you update\n\n- First change.\n\n- Second change.\n');
  assert.deepEqual(r.items, ['First change.', 'Second change.']);
});
