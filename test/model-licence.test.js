/**
 * Where a model came from, and what its licence lets a shop do.
 *
 * A print shop's library holds work it made and models it downloaded, and they
 * look identical in a grid. The difference decides whether a print may be SOLD
 * — most of what is on the model sites is Creative Commons and a large share of
 * that is NonCommercial, which is the licence that makes selling a print of it
 * a breach rather than a favour.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const L = require('../lib/model-licence.js');

// ── the question a shop is actually asking ────────────────────────────────

test('a NonCommercial licence may not be sold, whatever else it allows', () => {
  for (const id of ['cc-by-nc', 'cc-by-nc-sa', 'cc-by-nc-nd']) {
    assert.equal(L.sellable(id), false, `${id} was reported as sellable`);
  }
});

test('the permissive ones may be', () => {
  for (const id of ['own', 'cc0', 'cc-by', 'cc-by-sa', 'cc-by-nd', 'commercial']) {
    assert.equal(L.sellable(id), true, `${id} was reported as not sellable`);
  }
});

// THE DESIGN DECISION, and the easy one to get wrong. A shop that has not
// filled this in must not be told it may not sell its own work — and must not
// be told it may, either. `null` is a different sentence on screen.
test('unrecorded is null, which is not no', () => {
  for (const missing of ['', null, undefined, '   ', 'whatever the site said']) {
    assert.equal(L.sellable(missing), null, `${JSON.stringify(missing)} was decided rather than left open`);
  }
  // And the shape says so too, so a caller cannot mistake one for the other.
  assert.equal(L.standing({}).known, false);
  assert.equal(L.standing({ licence: 'cc-by-nc' }).known, true);
});

test('a licence is recognised however it was typed', () => {
  assert.equal(L.sellable('CC-BY-NC'), false);
  assert.equal(L.sellable('  cc0  '), true);
});

// ── the other two questions ───────────────────────────────────────────────

test('attribution is required by every CC licence and by none of the others', () => {
  for (const id of ['cc-by', 'cc-by-sa', 'cc-by-nd', 'cc-by-nc']) {
    assert.equal(L.needsAttribution(id), true, `${id} should require credit`);
  }
  for (const id of ['own', 'cc0', 'commercial']) {
    assert.equal(L.needsAttribution(id), false, `${id} should not`);
  }
  // Not knowing is not a duty to credit somebody unnamed.
  assert.equal(L.needsAttribution(''), false);
});

test('no-derivatives is kept apart from non-commercial', () => {
  // An ND model may be sold as printed and may not be altered. Folding the two
  // together would refuse a sale the licence allows.
  assert.equal(L.sellable('cc-by-nd'), true);
  assert.equal(L.allowsDerivatives('cc-by-nd'), false);
  assert.equal(L.allowsDerivatives('cc-by'), true);
  assert.equal(L.allowsDerivatives(''), null, 'unrecorded is not a refusal here either');
});

// ── the list a shop picks from ────────────────────────────────────────────

test('every licence in the list can be looked up by its own id', () => {
  const all = L.list();
  assert.ok(all.length >= 9);
  for (const entry of all) {
    assert.equal(typeof L.sellable(entry.id), 'boolean',
      `${entry.id} is offered in the menu and cannot be resolved`);
  }
  // The list is a copy: a caller that edits it cannot change what the rule says.
  all[0].commercial = false;
  assert.equal(L.sellable('own'), true, 'the table was mutable from outside');
});

// ── the library-wide answer ───────────────────────────────────────────────

test('notForSale names only what is recorded as non-commercial', () => {
  const library = [
    { id: 'a', licence: 'cc-by-nc' },
    { id: 'b', licence: 'cc-by' },
    { id: 'c' },                       // nobody has said
    { id: 'd', licence: 'own' },
    { id: 'e', licence: 'cc-by-nc-nd' },
  ];
  assert.deepEqual(L.notForSale(library).map((r) => r.id), ['a', 'e']);
});

// A warning about every model is a warning nobody reads — and a library where
// nothing has been filled in is the normal state of one that just imported.
test('a library with no licences recorded raises nothing at all', () => {
  assert.deepEqual(L.notForSale([{}, {}, {}]), []);
  assert.deepEqual(L.notForSale(null), []);
  assert.deepEqual(L.notForSale('nonsense'), []);
});

test('standing carries the source through, trimmed', () => {
  const s = L.standing({ licence: 'cc-by', source: '  https://example.com/thing  ' });
  assert.equal(s.source, 'https://example.com/thing');
  assert.equal(s.sellable, true);
  assert.equal(s.attribution, true);
});
