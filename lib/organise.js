'use strict';
/**
 * Two ways to organise a library of hundreds of things, and one vocabulary for
 * both screens.
 *
 * A shop asked for this as: "groups in files and catalogue so if I have a
 * collection I can group them, for example the Saudi Kings — and categories in
 * files and catalogue to better organise". Two different ideas, and the reason
 * both are needed is that they answer different questions:
 *
 *   A GROUP is a set that belongs together. The seven Saudi Kings are one
 *   collection. You look for the group when you want the set — to find all of
 *   it, or to offer all of it. A thing is in one group or none.
 *
 *   A CATEGORY is what a thing IS. Busts. Functional parts. Toys. You look for
 *   the category when you do not know what you want yet, which is exactly the
 *   state a library of hundreds puts you in.
 *
 * Tags are the third axis and already exist (lib/tags.js): free-form, many per
 * record, for everything that is neither of the above.
 *
 * ── GROUP IS THE FIELD THAT WAS CALLED FOLDER ──────────────────────────────
 * Print files already had `folder`: one name, one per record, typed into a box
 * — a set that belongs together, under a name a shop chose. That IS a group,
 * and re-filing every library to prove a point would be worse than useless.
 *
 * So nothing is migrated. `groupOf()` reads `group` and falls back to `folder`,
 * and `assign()` writes BOTH. The redundancy is deliberate and is the safety
 * property: renderer/bedready-library.js reads `.folder` directly, records
 * written by any earlier build have only `folder`, and a build without this
 * module still shows the right thing. Same discipline as `sourceFile` beside
 * `files[]` in lib/print-file-parts.js.
 *
 * ── ONE SPELLING EACH ──────────────────────────────────────────────────────
 * The rule from lib/tags.js applies with more force here, because these are
 * single-valued and drive a filter: "Saudi Kings" and "saudi kings" would be
 * two groups, each holding part of one collection, and the shop would have to
 * know which of them a given king went into. A name that matches one already in
 * use IS that name and adopts its spelling. Anything else is new and is kept
 * exactly as typed.
 *
 * Pure: no DOM, no fs, no Electron.
 */
(function (global) {

  /** Longest a name may be. Long enough for "Saudi Kings — full set", short
   *  enough that a filter chip is still a chip. */
  const MAX = 60;

  const key = (s) => String(s == null ? '' : s).trim().toLowerCase();

  /** Trim, collapse runs of space, cap. Never null; '' means "not set". */
  function normalise(raw) {
    return String(raw == null ? '' : raw).replace(/\s+/g, ' ').trim().slice(0, MAX).trim();
  }

  /**
   * The name this record is filed under, whichever field holds it.
   *
   * ── `folder` WINS, AND THAT IS A SYNC DECISION ─────────────────────────────
   * `assign()` writes both fields to the same value, so on any record this app
   * has written they agree and the order would not matter. It matters for a shop
   * running TWO machines where only one has updated.
   *
   * Sync merges whole records, last-writer-wins (lib/sync.js: `arr[i] =
   * incoming`), so a record edited on the older build arrives carrying every
   * field it does not understand — including `group`. And that build's edit
   * dialog writes `rec.folder` and nothing else. Reading `group` first therefore
   * meant: rename a group on the old laptop, sync, and the new machine goes on
   * showing the old name for ever, because its `group` is stale and wins.
   *
   * Reproduced before changing it — "Saudi Monarchs" on disk, "Saudi Kings" on
   * screen.
   *
   * So the field the OLDER build writes is the authority. The key's PRESENCE is
   * what decides, not its truthiness: a shop clearing the box on the old build
   * leaves `folder: ''`, and that empty string is the instruction.
   *
   * A product has no `folder` of its own — nothing before this ever filed one —
   * so it falls through to `group`.
   */
  const groupOf = (rec) => normalise(
    rec && typeof rec.folder === 'string' ? rec.folder : (rec && rec.group));

  /** What this record IS. New; there is no older field to fall back to. */
  const categoryOf = (rec) => normalise(rec && rec.category);

  const FIELD = { group: groupOf, category: categoryOf };

  /**
   * Reconcile a typed name against the ones already in use.
   *
   * @param {string} raw            what was typed
   * @param {string[]} [known]      every name already in use, any order
   * @returns {string} '' when nothing was typed; otherwise the existing
   *   spelling where one matches, else exactly what was typed.
   */
  function unify(raw, known) {
    const want = normalise(raw);
    if (!want) return '';
    const kk = key(want);
    for (const k of (known || [])) {
      // First spelling seen wins, so the answer does not depend on the order a
      // caller happened to collect the shop's names in.
      if (key(k) === kk) return normalise(k);
    }
    return want;
  }

  /**
   * Distinct names across records, most-used first, folded by case.
   *
   * The label is the spelling used MOST, since that is the one the shop has
   * settled on, and the count is the real one rather than one spelling's share.
   * Reads print files and products alike — both are just records with a name on
   * them, and a shop that has "Saudi Kings" in each should see one group.
   *
   * @param {object[]} records
   * @param {'group'|'category'} field
   * @returns {Array<[string, number]>} [label, count]
   */
  function counts(records, field) {
    const read = FIELD[field];
    if (!read) return [];
    const byKey = new Map();                   // key -> Map(spelling -> count)
    for (const r of (records || [])) {
      const name = read(r);
      if (!name) continue;
      const kk = key(name);
      if (!byKey.has(kk)) byKey.set(kk, new Map());
      const spellings = byKey.get(kk);
      spellings.set(name, (spellings.get(name) || 0) + 1);
    }
    const rows = [];
    for (const spellings of byKey.values()) {
      let total = 0, best = '', bestN = -1;
      for (const [s, n] of spellings) {
        total += n;
        if (n > bestN) { bestN = n; best = s; }
      }
      rows.push([best, total]);
    }
    rows.sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
    return rows;
  }

  /** Every name in use for a field, most-used first — what the box offers. */
  const known = (records, field) => counts(records, field).map(([label]) => label);

  /**
   * The fields to merge onto a record to file it.
   *
   * A patch rather than a mutation, so the caller decides when the record
   * changes and sequences the save and the redraw — same shape as
   * lib/print-file-parts.js.
   *
   * Only the keys asked for are returned, so `assign(rec, {category: 'Busts'})`
   * cannot clear a group by omission. Passing '' DOES clear one: that is a shop
   * emptying the box, which has to mean something.
   *
   * `folder` is written alongside `group` — see the header. Not the other way
   * round: nothing but this module should have to know that `folder` is where
   * groups used to live.
   */
  function assign(rec, patch, knownNames) {
    const out = {};
    const kn = knownNames || {};
    if (patch && Object.prototype.hasOwnProperty.call(patch, 'group')) {
      const g = unify(patch.group, kn.group);
      out.group = g;
      out.folder = g;
    }
    if (patch && Object.prototype.hasOwnProperty.call(patch, 'category')) {
      out.category = unify(patch.category, kn.category);
    }
    return out;
  }

  /** Is this record filed under that name, whatever either side's spelling? */
  const isIn = (rec, field, name) => {
    const read = FIELD[field];
    if (!read) return false;
    return key(read(rec)) === key(name) && !!key(name);
  };

  /** Everything in one group or category, in the order given. */
  const membersOf = (records, field, name) =>
    (records || []).filter((r) => isIn(r, field, name));

  /**
   * What a saved set actually holds.
   *
   * A shop asked for a collection it could "offer as a package". Khayt already
   * had one — a bundle: a named list of product ids, quotable in one tap — but
   * the only way to build it was to tick seven checkboxes, and it FROZE at that
   * moment. Add an eighth king to the collection and the package silently
   * remains seven.
   *
   * So a set may FOLLOW A GROUP instead of pinning ids, and then its members are
   * whatever is in that group when you ask. That is what a group is for: adding
   * a king to the Saudi Kings adds him to the Saudi Kings package, with nothing
   * to remember.
   *
   * The pinned form still works and is what every existing bundle uses. Nothing
   * is migrated.
   *
   * @param {{group?: string, productIds?: string[]}} saved
   * @param {object[]} records  the products (or print files) to look in
   * @returns {object[]} in the order the records are given
   */
  function setMembers(saved, records) {
    if (!saved) return [];
    if (saved.group) return membersOf(records, 'group', saved.group);
    const ids = new Set(saved.productIds || []);
    return (records || []).filter((r) => r && ids.has(r.id));
  }

  /** Does this set follow a group rather than a frozen list of ids? */
  const followsGroup = (saved) => !!(saved && saved.group);

  const api = { MAX, normalise, unify, counts, known, assign, groupOf, categoryOf, isIn, membersOf, setMembers, followsGroup, nameKey: key };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytOrganise = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
