'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { search, coloursOf, toSpool, ageInDays } = require('../lib/filament-catalog');

/** A small catalogue with the shapes that matter, rather than the real 0.78 MB. */
const CAT = {
  generatedAt: '2026-09-11T00:00:00.000Z',
  filaments: [
    { b: 'Bambu Lab', n: 'PLA Matte', m: 'PLA', d: 1.24, t: [190, 230],
      c: [['Charcoal', '#22222A', [1000], 212, 1.75],
          ['Bone White', '#F0EDE5', [1000, 500], 212, 1.75]] },
    { b: 'Bambu Lab', n: 'PLA Basic', m: 'PLA', d: 1.24, t: [190, 230],
      c: [['Black', '#000000', [1000], 212, 1.75]] },
    { b: 'eSUN', n: 'PETG', m: 'PETG', d: 1.27, t: [230, 250],
      c: [['Black', '#101010', [1000], 190, 1.75]] },
    { b: 'Prusa Polymers', n: 'Prusament PLA', m: 'PLA', d: 1.24, t: [215, 225],
      c: [['Galaxy Black', '#1B1B1F', [1000], 201, 1.75]] },
  ],
};

const named = (rows) => rows.map((r) => `${r.filament.b} ${r.filament.n}`);

/* ============================================================
   Matching
   ============================================================ */

test('every term has to land, so typing more words narrows the list', () => {
  // The whole point of the all-terms rule. "bambu" alone is two rows; adding
  // "matte" has to leave one, not score both highly and return both.
  assert.equal(search(CAT, 'bambu').length, 2);
  assert.deepEqual(named(search(CAT, 'bambu matte')), ['Bambu Lab PLA Matte']);
});

test('a brand beats a material that merely contains the letters', () => {
  // "PLA" is three of the four rows. Typing a brand must put that brand first.
  assert.equal(search(CAT, 'esun')[0].filament.b, 'eSUN');
  assert.equal(search(CAT, 'prusament')[0].filament.n, 'Prusament PLA');
});

test('a colour matches, and comes back with the row rather than splitting it', () => {
  const [hit] = search(CAT, 'bambu charcoal');
  assert.equal(hit.filament.n, 'PLA Matte');
  // One filament is one result. The colours that matched ride along so a
  // caller can offer them first instead of listing all 25.
  assert.deepEqual(hit.colours.map((c) => c.name), ['Charcoal']);
});

test('a shorter name that matched outranks a longer one', () => {
  // Typing "PLA" should not put "PLA Matte" above a plain "PLA".
  const first = search(CAT, 'bambu pla')[0];
  assert.equal(first.filament.n, 'PLA Basic',
    'the longer product name won, so the length tiebreak is not working');
});

test('nothing typed is nothing found, not everything', () => {
  assert.deepEqual(search(CAT, ''), []);
  assert.deepEqual(search(CAT, '   '), []);
});

test('a catalogue that is missing or malformed answers empty', () => {
  assert.deepEqual(search(null, 'pla'), []);
  assert.deepEqual(search({}, 'pla'), []);
  assert.deepEqual(search({ filaments: 'not a list' }, 'pla'), []);
});

/* ============================================================
   The fallback, which is where the judgement is
   ============================================================ */

test('a colour this product does not have drops the word, not the search', () => {
  // Bambu's PLA Matte has no "Black" — its blacks are Charcoal and Bone White.
  // Returning nothing would tell the shop Khayt does not have the filament.
  const rows = search(CAT, 'bambu matte black');
  assert.deepEqual(named(rows), ['Bambu Lab PLA Matte']);
  assert.deepEqual(rows[0].unmatched, ['black'],
    'the dropped word has to be reported or the result is a lie');
});

test('the BRAND is never the word that gets dropped', () => {
  // The failure this pins: scoring each removal and taking the best answered
  // "bambu matte black" with a different manufacturer's PLA, because dropping
  // the brand left terms another product matched better. A result in the wrong
  // brand is worse than no result — the shop is holding a spool with the brand
  // printed on it.
  const rows = search(CAT, 'bambu matte black');
  assert.ok(rows.every((r) => r.filament.b === 'Bambu Lab'));
});

test('a full match reports nothing unmatched', () => {
  const [hit] = search(CAT, 'bambu matte charcoal');
  assert.deepEqual(hit.unmatched, []);
});

test('a query that shares no product with itself is answered with no', () => {
  // Better than a row assembled from half of it.
  assert.deepEqual(search(CAT, 'zzzz'), []);
  assert.deepEqual(search(CAT, 'aaa bbb ccc'), []);
});

test('only the trailing words are dropped, never the first', () => {
  const rows = search(CAT, 'esun zzzz yyyy');
  assert.deepEqual(named(rows), ['eSUN PETG']);
  assert.deepEqual(rows[0].unmatched, ['zzzz', 'yyyy']);
});

test('the spaces a paste carries do not break the match', () => {
  // A product name copied from a web page arrives with a non-breaking space in
  // it and matches nothing, which looks like a missing filament.
  assert.equal(search(CAT, 'eSUN PETG').length, 1);
  assert.equal(search(CAT, 'eSUN PETG').length, 1);
});

/* ============================================================
   Filling a spool
   ============================================================ */

test('toSpool fills what the catalogue knows and nothing else', () => {
  const f = CAT.filaments[0];
  const colour = coloursOf(f)[0];
  const out = toSpool(f, colour, 1000);

  assert.equal(out.material, 'Bambu Lab PLA Matte',
    'the shop reads the product name off the label, not the bare type');
  assert.equal(out.materialType, 'PLA');
  assert.equal(out.colourVariant, 'Charcoal');
  assert.equal(out.color, '#22222A');
  assert.equal(out.spoolWeight, 1000);
  assert.equal(out.weight, 1000, 'a new spool is a full spool');
  assert.equal(out.emptySpoolWeight, 212);
  assert.equal(out.diameter, 1.75);
  assert.equal(out.density, 1.24);
});

test('toSpool NEVER invents what only the shop knows', () => {
  // Cost, when it was opened, whether it has been dried, where it is stored.
  // A manufacturer's page cannot know any of them, and a filled-in zero is
  // worse than a blank field because it looks typed.
  const out = toSpool(CAT.filaments[0], coloursOf(CAT.filaments[0])[0], 1000);
  for (const key of ['cost', 'openedAt', 'driedAt', 'storage', 'vatAmount', 'id']) {
    assert.equal(key in out, false, `${key} was invented`);
  }
});

test('a colour sold in one size needs no choice made for it', () => {
  const f = CAT.filaments[0];
  const one = coloursOf(f)[0];          // [1000]
  const two = coloursOf(f)[1];          // [1000, 500]
  assert.equal(toSpool(f, one).spoolWeight, 1000, 'one size is not a question');
  assert.equal(toSpool(f, two).spoolWeight, undefined,
    'two sizes must not be guessed between');
  assert.equal(toSpool(f, two, 500).spoolWeight, 500);
});

test('a filament with no colour chosen still fills what it can', () => {
  const out = toSpool(CAT.filaments[0]);
  assert.equal(out.material, 'Bambu Lab PLA Matte');
  assert.equal(out.density, 1.24);
  assert.equal('color' in out, false);
  assert.equal('weight' in out, false);
});

test('nothing at all is an answer, not a throw', () => {
  assert.deepEqual(toSpool(null), {});
  assert.deepEqual(coloursOf(null), []);
  assert.deepEqual(coloursOf({}), []);
});

/* ============================================================
   How old the snapshot is
   ============================================================ */

test('the age is reported so a stale list does not look like a missing filament', () => {
  const now = Date.parse('2026-09-21T00:00:00.000Z');
  assert.equal(ageInDays(CAT, now), 10);
});

test('an age that cannot be worked out is null, not zero', () => {
  // Zero would claim the snapshot is fresh.
  assert.equal(ageInDays({}, Date.now()), null);
  assert.equal(ageInDays({ generatedAt: 'not a date' }, Date.now()), null);
  assert.equal(ageInDays(null, Date.now()), null);
});

test('a snapshot from the future is not reported as negative', () => {
  const now = Date.parse('2026-09-01T00:00:00.000Z');
  assert.equal(ageInDays(CAT, now), 0);
});
