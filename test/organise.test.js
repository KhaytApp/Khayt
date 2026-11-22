'use strict';
/**
 * Groups and categories — the rules, on their own.
 *
 * The wiring is guarded separately (test/organise-wiring.test.js and
 * scripts/e2e-organise-smoke.mjs), because this codebase's signature failure is
 * a module that is right and reachable from nothing.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const O = require('../lib/organise.js');

test('a record filed before groups existed is already in one', () => {
  // `folder` is where groups used to live. Nothing is migrated; it is read.
  assert.equal(O.groupOf({ folder: 'Saudi Kings' }), 'Saudi Kings');
  assert.equal(O.groupOf({ group: 'Saudi Kings' }), 'Saudi Kings');
  /* FOLDER wins where both exist and disagree, and that is a sync decision
   * rather than a preference. This asserted the opposite — that `group` wins,
   * "it is the field being written now" — which was true of this app and false
   * of the older build a shop may still be running on a second machine. That
   * build writes `folder` alone, so `group` winning meant a rename made there
   * never reached here. See the cross-version test below. */
  assert.equal(O.groupOf({ group: 'stale', folder: 'Kings' }), 'Kings');
  // The key's PRESENCE decides, not its truthiness: clearing the box on the old
  // build leaves folder:'' and that empty string is the instruction.
  assert.equal(O.groupOf({ group: 'Saudi Kings', folder: '' }), '');
  assert.equal(O.groupOf({}), '');
  assert.equal(O.groupOf(null), '');
});

test('filing a record writes the old field too', () => {
  // renderer/bedready-library.js reads `.folder` directly, and so does every
  // build older than this one. Writing only `group` would file a record
  // somewhere half the app cannot see.
  const patch = O.assign({}, { group: 'Saudi Kings' });
  assert.equal(patch.group, 'Saudi Kings');
  assert.equal(patch.folder, 'Saudi Kings', 'the old field was left behind');
});

test('a field not named in the patch is not touched', () => {
  // `assign(rec, {category})` must not clear a group by omission — that would
  // make every edit dialog that sets one field a dialog that empties the other.
  const patch = O.assign({ group: 'Saudi Kings' }, { category: 'Busts' });
  assert.deepEqual(Object.keys(patch), ['category']);
  // …but an empty string IS an instruction: the shop cleared the box.
  const cleared = O.assign({ group: 'Saudi Kings' }, { group: '' });
  assert.equal(cleared.group, '');
  assert.equal(cleared.folder, '');
});

test('a name that matches one in use adopts its spelling', () => {
  const known = ['Saudi Kings', 'Busts'];
  assert.equal(O.unify('saudi kings', known), 'Saudi Kings');
  assert.equal(O.unify('  SAUDI   KINGS  ', known), 'Saudi Kings');
  // Anything else is new and is kept exactly as typed. This normalises
  // collisions; it does not impose a house style.
  assert.equal(O.unify('DnD minis', known), 'DnD minis');
  assert.equal(O.unify('', known), '');
  assert.equal(O.unify('   ', known), '');
});

test('one collection is one chip, however it has been spelled', () => {
  const recs = [
    { folder: 'Saudi Kings' }, { group: 'saudi kings' }, { group: 'Saudi Kings' },
    { group: 'Dragons' },
  ];
  // The count is the real one, not one spelling's share — that is the whole
  // point. A shop with a split group finds a third of its own collection.
  assert.deepEqual(O.counts(recs, 'group'), [['Saudi Kings', 3], ['Dragons', 1]]);
  // The label is the spelling used most, since that is the one they settled on.
  assert.deepEqual(O.counts([{ group: 'kings' }, { group: 'Kings' }, { group: 'Kings' }], 'group'),
    [['Kings', 3]]);
});

test('print files and products count as one library', () => {
  // A shop with "Saudi Kings" in both screens has ONE group, not two. Both are
  // records with a name on them, so both are read by the same rule.
  const printFile = { id: 'PF1', sourceFile: {}, folder: 'Saudi Kings' };
  const product = { id: 'PROD1', nameEn: 'King Abdulaziz bust', group: 'Saudi Kings' };
  assert.deepEqual(O.counts([printFile, product], 'group'), [['Saudi Kings', 2]]);
});

test('a name is trimmed, collapsed and capped', () => {
  assert.equal(O.normalise('  Saudi   Kings \n'), 'Saudi Kings');
  assert.equal(O.normalise('x'.repeat(200)).length, O.MAX);
  assert.equal(O.normalise(null), '');
  assert.equal(O.normalise(undefined), '');
  // Capping must not leave trailing space where the cut landed mid-gap.
  assert.equal(O.normalise('y'.repeat(O.MAX - 1) + '  tail').endsWith(' '), false);
});

test('membership ignores spelling on both sides', () => {
  const recs = [{ group: 'Saudi Kings' }, { folder: 'saudi kings' }, { group: 'Dragons' }];
  assert.equal(O.membersOf(recs, 'group', 'SAUDI KINGS').length, 2);
  assert.equal(O.isIn(recs[0], 'group', 'saudi kings'), true);
  // "unfiled" is not a group. Asking for '' must not match every unfiled record.
  assert.equal(O.isIn({ group: '' }, 'group', ''), false);
  assert.equal(O.membersOf(recs, 'group', '').length, 0);
});

test('an unknown field answers nothing rather than guessing', () => {
  assert.deepEqual(O.counts([{ group: 'x' }], 'tags'), []);
  assert.equal(O.isIn({ group: 'x' }, 'tags', 'x'), false);
});

test('a package that follows a group grows with it', () => {
  // The whole reason to build a package from a group rather than from ticked
  // checkboxes: a bundle froze at the moment it was made, so the eighth king
  // joined the collection and the package silently stayed at seven.
  const products = [
    { id: 'p1', group: 'Saudi Kings' },
    { id: 'p2', group: 'saudi kings' },   // the other spelling still counts
    { id: 'p3', group: 'Dragons' },
  ];
  const pkg = { id: 'BND1', name: 'Saudi Kings', group: 'Saudi Kings' };
  assert.deepEqual(O.setMembers(pkg, products).map((p) => p.id), ['p1', 'p2']);
  products.push({ id: 'p4', group: 'Saudi Kings' });
  assert.deepEqual(O.setMembers(pkg, products).map((p) => p.id), ['p1', 'p2', 'p4'],
    'a package that follows a group did not pick up a new member');
});

test('a package pinned to ids still works and is not migrated', () => {
  // Every bundle that exists today is this shape.
  const products = [{ id: 'p1' }, { id: 'p2' }, { id: 'p3' }];
  const pinned = { id: 'BND2', name: 'Desk set', productIds: ['p1', 'p3'] };
  assert.deepEqual(O.setMembers(pinned, products).map((p) => p.id), ['p1', 'p3']);
  assert.equal(O.followsGroup(pinned), false);
  assert.equal(O.followsGroup({ group: 'Saudi Kings' }), true);
  // A pinned id that no longer exists is simply absent, not a hole in the list.
  assert.deepEqual(O.setMembers({ productIds: ['p1', 'gone'] }, products).map((p) => p.id), ['p1']);
});

test('an empty or missing set holds nothing rather than everything', () => {
  const products = [{ id: 'p1', group: 'X' }, { id: 'p2' }];
  assert.deepEqual(O.setMembers(null, products), []);
  assert.deepEqual(O.setMembers({}, products), []);
  // A group nobody is in is empty — NOT "every product with no group".
  assert.deepEqual(O.setMembers({ group: 'Nobody' }, products), []);
  assert.deepEqual(O.setMembers({ group: '' }, products), []);
});

test('a rename on an older build is not silently ignored', () => {
  /* Sync merges whole records, last-writer-wins, so a record edited on a
   * machine still running v3.7.0-beta.24 arrives carrying `group` — a field
   * that build does not understand and never updates — while its edit dialog
   * has written `rec.folder`. Reading `group` first meant the rename never
   * reached the updated machine.
   *
   * Reproduced before it was changed: "Saudi Monarchs" on disk, "Saudi Kings"
   * on screen, for ever. */
  const rec = {};
  Object.assign(rec, O.assign(rec, { group: 'Saudi Kings' }));
  assert.equal(rec.folder, 'Saudi Kings');
  rec.folder = 'Saudi Monarchs';                       // the old build renames
  assert.equal(O.groupOf(rec), 'Saudi Monarchs', 'the older build is the authority');
  rec.folder = '';                                     // the old build clears it
  assert.equal(O.groupOf(rec), '', 'an empty folder is an instruction, not an absence');
});

test('a product has no folder of its own and falls through', () => {
  // Nothing before this ever filed a product, so there is no older writer to
  // defer to and no divergence to guard against.
  assert.equal(O.groupOf({ id: 'P1', group: 'Saudi Kings' }), 'Saudi Kings');
  assert.equal(O.groupOf({ id: 'P2' }), '');
});

test('assign never writes one of the pair without the other', () => {
  // `folder` is authoritative, which is only safe while nothing writes `group`
  // alone. If a later change does, this is where it is caught.
  const patch = O.assign({}, { group: 'Saudi Kings' });
  assert.equal(patch.group, patch.folder, 'the two fields disagree the moment they are written');
  const cleared = O.assign({ folder: 'x', group: 'x' }, { group: '' });
  assert.equal(cleared.group, cleared.folder);
});
