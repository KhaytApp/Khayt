'use strict';

(function () {

/**
 * Searching, filtering and sorting a design library.
 *
 * Pure on purpose. The Bed Ready library panel is a self-contained IIFE in the
 * renderer with no test harness of its own, so the part with actual logic in it
 * — which of 400 designs match "bracket", and in what order — lives here where
 * it can be tested without a DOM. The panel keeps the drawing.
 *
 * An item is whatever makerrun.com's /api/library returns; the fields this cares
 * about are `title`, `slug`, `fileType`, `filename` and `downloadUrl`. Anything
 * else rides along untouched, so a new field on the server does not need a
 * change here.
 */

/** File kinds a MakerRun design can be, matching lib/makerrun-library.js extFor(). */
const FILE_TYPES = ['3mf', 'stl', 'obj', 'step'];

/**
 * The type of one item, normalised.
 *
 * Mirrors extFor() in lib/makerrun-library.js — including its default. An item
 * with no usable type IS downloaded as .3mf, so calling it anything else here
 * would filter on a lie: the user would tick "3MF" and not see a file that will
 * arrive as a 3MF.
 */
function typeOf(item) {
  const declared = item && item.fileType ? String(item.fileType).toLowerCase() : '';
  if (FILE_TYPES.includes(declared)) return declared;
  const name = item && item.filename ? String(item.filename) : '';
  const dot = name.lastIndexOf('.');
  const ext = dot === -1 ? '' : name.slice(dot + 1).toLowerCase();
  return FILE_TYPES.includes(ext) ? ext : '3mf';
}

/** A design with no downloadUrl is link-only — age-gated or off-site. */
const isDownloadable = (item) => !!(item && item.downloadUrl);

/** What a user reads on the card, and therefore what they expect search to match. */
const labelOf = (item) => String((item && (item.title || item.slug)) || '');

/**
 * Case- and accent-insensitive haystack for one item.
 *
 * Normalised to NFD with combining marks stripped so that searching "e" finds
 * "Étagère" — a library of user-uploaded designs is not going to be ASCII, and a
 * search that only matches exact accents is a search people stop using.
 */
function haystack(item) {
  const s = `${labelOf(item)} ${(item && item.slug) || ''} ${(item && item.filename) || ''}`;
  return s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();
}

function normalizeQuery(q) {
  return String(q == null ? '' : q).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().trim();
}

const SORTS = ['name', 'name-desc', 'type'];

/**
 * Filter and sort in one pass.
 *
 * @param {Array} items
 * @param {object} opts
 *   query          free text; every whitespace-separated word must match
 *   types          array of file types to keep; empty/absent means all
 *   downloadableOnly  hide link-only designs
 *   sort           'name' | 'name-desc' | 'type'
 */
function browse(items, opts = {}) {
  const list = Array.isArray(items) ? items.filter((i) => i && typeof i === 'object') : [];
  const words = normalizeQuery(opts.query).split(/\s+/).filter(Boolean);
  const types = Array.isArray(opts.types) ? opts.types.filter((t) => FILE_TYPES.includes(t)) : [];

  const out = list.filter((item) => {
    if (opts.downloadableOnly && !isDownloadable(item)) return false;
    if (types.length && !types.includes(typeOf(item))) return false;
    if (!words.length) return true;
    // EVERY word must appear — typing more narrows, which is what a search box
    // that filters (rather than ranks) has to do to feel predictable.
    const hay = haystack(item);
    return words.every((w) => hay.includes(w));
  });

  const byName = (a, b) => labelOf(a).localeCompare(labelOf(b), undefined, { sensitivity: 'base', numeric: true });
  const sort = SORTS.includes(opts.sort) ? opts.sort : 'name';
  if (sort === 'name') out.sort(byName);
  else if (sort === 'name-desc') out.sort((a, b) => byName(b, a));
  else if (sort === 'type') {
    // Group by type, then by name inside each group — a sort that leaves the
    // second key to chance reorders the grid on every keystroke.
    out.sort((a, b) => (typeOf(a) === typeOf(b) ? byName(a, b) : typeOf(a).localeCompare(typeOf(b))));
  }
  return out;
}

/**
 * Counts for the filter controls, computed from the WHOLE library rather than
 * the filtered view — a chip that renumbers as you type it cannot be aimed at.
 */
function facets(items) {
  const list = Array.isArray(items) ? items.filter((i) => i && typeof i === 'object') : [];
  const types = {};
  let downloadable = 0;
  for (const item of list) {
    const t = typeOf(item);
    types[t] = (types[t] || 0) + 1;
    if (isDownloadable(item)) downloadable++;
  }
  return {
    total: list.length,
    downloadable,
    linkOnly: list.length - downloadable,
    types,
    // Only the kinds actually present, in a fixed order, so the row of chips
    // does not reshuffle between refreshes.
    presentTypes: FILE_TYPES.filter((t) => types[t] > 0),
  };
}

const api = { browse, facets, typeOf, isDownloadable, labelOf, FILE_TYPES, SORTS };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytLibraryBrowse = api;

})();
