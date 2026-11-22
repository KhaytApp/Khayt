/**
 * Grouping consumables, asked for by a user: categories, and a way to see one
 * at a time.
 *
 * A consumable had one boolean, `isPackaging` — packaging, and everything else.
 *
 * The failures worth testing all look like data loss rather than like bugs: an
 * item that vanishes behind a filter, a category that splits across three
 * spellings of the same word, and a selected category that no longer exists.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  categories, filterByCategory, resolveSelection, suggestions, categoryOf, UNCATEGORISED,
} = require('../lib/consumable-categories.js');

const c = (name, category) => (category === undefined ? { name } : { name, category });

test('uncategorised items are a category, not a gap', () => {
  // If they were only reachable through "All", they would disappear the moment
  // anyone filtered — and an item you cannot see is an item you buy twice.
  const items = [c('Screws', 'Fasteners'), c('Tape'), c('Bolts', 'Fasteners')];
  const cats = categories(items);
  assert.deepEqual(cats.map((x) => x.label), ['Fasteners', UNCATEGORISED]);
  assert.deepEqual(filterByCategory(items, UNCATEGORISED).map((x) => x.name), ['Tape']);
});

test('uncategorised sorts last — it is a leftover, not a heading', () => {
  const cats = categories([c('a'), c('b', 'Zinc'), c('c', 'Alpha')]);
  assert.equal(cats[cats.length - 1].key, UNCATEGORISED);
  assert.deepEqual(cats.slice(0, 2).map((x) => x.label), ['Alpha', 'Zinc']);
});

test('one shelf is one category, however it was typed', () => {
  // Three spellings would fill the picker with near-duplicates and split the
  // list between them.
  const items = [c('a', 'Screws'), c('b', 'screws '), c('c', ' SCREWS'), c('d', 'Screws  ')];
  const cats = categories(items);
  assert.equal(cats.length, 1, `expected one category, got ${cats.map((x) => x.label)}`);
  assert.equal(cats[0].count, 4);
  assert.equal(filterByCategory(items, 'screws').length, 4);
  assert.equal(filterByCategory(items, 'SCREWS').length, 4);
});

test('a double space inside a name is the same category', () => {
  // trim() already handles the ends, so only INTERNAL spacing exercises the
  // collapse — and a stray double-tap of the space bar is exactly how a shop
  // ends up with two "Print Bed" shelves it cannot tell apart on screen.
  const items = [c('a', 'Print Bed'), c('b', 'Print  Bed'), c('c', 'Print\tBed')];
  const cats = categories(items);
  assert.equal(cats.length, 1, `expected one category, got ${JSON.stringify(cats.map((x) => x.label))}`);
  assert.equal(cats[0].count, 3);
  assert.equal(filterByCategory(items, 'Print  Bed').length, 3);
});

test('the spelling shown is the shop\'s own, not a normalised one', () => {
  const cats = categories([c('a', 'Screws'), c('b', 'screws')]);
  assert.equal(cats[0].label, 'Screws', 'the display name was rewritten');
});

test('an empty selection means everything', () => {
  const items = [c('a', 'X'), c('b')];
  for (const sel of ['', null, undefined]) {
    assert.equal(filterByCategory(items, sel).length, 2, String(sel));
  }
});

test('a selection that no longer exists falls back to All', () => {
  // Recategorise the last item in a category while it is selected: the list
  // would go empty under a heading still naming it, which reads as data loss.
  const before = [c('a', 'Magnets')];
  assert.equal(resolveSelection(before, 'Magnets'), 'Magnets');
  const after = [c('a', 'Fasteners')];
  assert.equal(resolveSelection(after, 'Magnets'), '', 'a stale filter was kept and hides everything');
  assert.equal(resolveSelection([], 'Magnets'), '');
});

test('the uncategorised selection survives only while something is uncategorised', () => {
  assert.equal(resolveSelection([c('a')], UNCATEGORISED), UNCATEGORISED);
  assert.equal(resolveSelection([c('a', 'X')], UNCATEGORISED), '',
    'the uncategorised filter stuck around with nothing in it');
});

test('categories are derived, so one cannot outlive its last item', () => {
  // A stored list would still offer "Magnets" here.
  assert.deepEqual(categories([c('a', 'Magnets')]).map((x) => x.label), ['Magnets']);
  assert.deepEqual(categories([c('a', '')]).map((x) => x.label), [UNCATEGORISED]);
  assert.deepEqual(categories([]), []);
});

test('a whitespace-only category is not a category', () => {
  const items = [c('a', '   '), c('b', '\t')];
  assert.deepEqual(categories(items).map((x) => x.key), [UNCATEGORISED]);
  assert.equal(categoryOf(items[0]), UNCATEGORISED);
});

test('suggestions offer what the shop already uses, and never the leftover bucket', () => {
  const items = [c('a', 'Fasteners'), c('b'), c('c', 'Adhesives')];
  assert.deepEqual(suggestions(items), ['Adhesives', 'Fasteners']);
});

test('counts are per category and add up to the item total', () => {
  const items = [c('a', 'X'), c('b', 'x'), c('c', 'Y'), c('d')];
  const cats = categories(items);
  assert.equal(cats.reduce((s, x) => s + x.count, 0), items.length,
    'an item is in two categories or none');
});

test('junk in, no throw out', () => {
  for (const bad of [null, undefined, 'nope', 42, [null, undefined, {}]]) {
    assert.doesNotThrow(() => categories(bad), JSON.stringify(bad));
    assert.doesNotThrow(() => filterByCategory(bad, 'x'));
    assert.doesNotThrow(() => resolveSelection(bad, 'x'));
  }
  assert.deepEqual(categories([null, undefined]), []);
  assert.equal(categoryOf(null), UNCATEGORISED);
});
