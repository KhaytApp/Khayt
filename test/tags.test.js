'use strict';
/**
 * One idea, one tag.
 *
 * The tags box is comma-separated free text with nothing to guide it, so
 * "resin", "Resin" and " resin " are three tags, and the filter bar — which
 * keyed on the exact string — showed three chips for one idea, each finding a
 * third of its own files. Nothing errors. The library just stops being
 * searchable, and the more files a shop has the worse it gets.
 *
 * What is deliberately NOT done here is imposing a house style. Lower-casing
 * everything would merge the collisions and also turn "ABS" into "abs" and
 * "PLA+" into "pla+". Being quietly rewritten is worse than being merged with
 * what you meant, so a NEW tag is kept exactly as typed and only a tag that
 * collides with an existing one adopts that one's spelling.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { normaliseTags, tagCounts, hasTag } = require('../lib/tags.js');

test('a tag that already exists adopts the spelling the shop uses', () => {
  assert.deepEqual(normaliseTags('Resin, GIFT', ['resin', 'gift']), ['resin', 'gift']);
  assert.deepEqual(normaliseTags('  resin  ', ['Resin']), ['Resin']);
});

test('a genuinely new tag is kept exactly as typed', () => {
  // Not lower-cased. "ABS" and "PLA+" are how a shop writes them.
  assert.deepEqual(normaliseTags('ABS, PLA+', ['resin']), ['ABS', 'PLA+']);
});

test('the same tag typed twice in two spellings is one tag', () => {
  assert.deepEqual(normaliseTags('resin, Resin, RESIN', []), ['resin']);
  assert.deepEqual(normaliseTags('resin, Resin', ['RESIN']), ['RESIN']);
});

test('blanks, stray commas and whitespace do not become tags', () => {
  assert.deepEqual(normaliseTags('resin, , ,  ,gift,', []), ['resin', 'gift']);
  assert.deepEqual(normaliseTags('', []), []);
  assert.deepEqual(normaliseTags(null, null), []);
  assert.deepEqual(normaliseTags(undefined), []);
});

test('order is what was typed, not what was known', () => {
  assert.deepEqual(normaliseTags('gift, resin', ['resin', 'gift']), ['gift', 'resin']);
});

test('the answer does not depend on the order the known tags arrived in', () => {
  // Two spellings already in use is exactly the drifted state this fixes, so
  // which one wins must be stable rather than a function of collection order.
  const a = normaliseTags('RESIN', ['resin', 'Resin']);
  const b = normaliseTags('RESIN', ['resin', 'Resin']);
  assert.deepEqual(a, b);
  assert.deepEqual(a, ['resin'], 'the first spelling seen is the canonical one');
});

test('an array goes in as readily as the text box', () => {
  assert.deepEqual(normaliseTags(['Resin', 'gift'], ['resin']), ['resin', 'gift']);
});

test('counting folds the spellings and reports the one most used', () => {
  const records = [
    { tags: ['resin', 'gift'] },
    { tags: ['Resin'] },
    { tags: ['resin'] },
    { tags: ['RESIN'] },
  ];
  const counts = tagCounts(records);
  assert.deepEqual(counts, [['resin', 4], ['gift', 1]],
    'four files carry one idea, and the chip should say so with the settled spelling');
});

test('a record naming one tag twice counts once for it', () => {
  assert.deepEqual(tagCounts([{ tags: ['resin', 'Resin'] }]), [['resin', 1]]);
});

test('counting survives records with no tags at all', () => {
  assert.deepEqual(tagCounts([{}, { tags: null }, { tags: [] }, null]), []);
  assert.deepEqual(tagCounts(null), []);
});

test('a filter finds a file whichever way either side spelled it', () => {
  // The point of the whole module: the chip says "resin" and must find the file
  // whose record still says "Resin" from before any of this existed.
  assert.equal(hasTag({ tags: ['Resin'] }, 'resin'), true);
  assert.equal(hasTag({ tags: ['resin'] }, ' RESIN '), true);
  assert.equal(hasTag({ tags: ['resin'] }, 'gift'), false);
  assert.equal(hasTag(null, 'resin'), false);
});
