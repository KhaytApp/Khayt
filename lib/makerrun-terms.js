'use strict';
(function (global) {

/**
 * MakerRun's vocabularies, and how they meet the print-file record's.
 *
 * PURE: no fetch, no fs, no DOM. Loaded two ways on purpose — required by
 * lib/makerrun-catalog.js and lib/makerrun-publish.js in the main process, and
 * as a plain <script> in renderer/bedready.html, where the publish form needs
 * the same lists to build its menus. One copy, so the menu the user picks from
 * and the allowlist main checks against cannot drift apart.
 *
 * ── WHERE THESE COME FROM ─────────────────────────────────────────────────
 *
 * CATEGORIES   makerrun/src/lib/categories.ts → CATEGORIES (value + English label).
 *              The values are what the database and `?category=` hold and
 *              never change; only the label is translated, on MakerRun's side.
 * MATERIALS    makerrun/src/lib/api/validate.ts → MATERIALS (server-validated).
 * LICENCES     makerrun/src/app/[locale]/(library)/upload/page.tsx → LICENSES,
 *              the strings the website's own upload form offers. The API stores
 *              `license` as free text, so publishing one of these is what keeps
 *              a listing made from Bed Ready readable by every other client.
 *
 * These are copies of another repository's lists. Nothing compares the two
 * halves automatically; test/makerrun-catalog.test.js pins the copies so a
 * change here is at least a deliberate one.
 */

const CATEGORIES = [
  { value: 'art', label: 'Art & design' },
  { value: 'toys-games', label: 'Toys & games' },
  { value: 'gadgets', label: 'Gadgets' },
  { value: 'household', label: 'Household' },
  { value: 'tools', label: 'Tools' },
  { value: 'miniatures', label: 'Miniatures' },
  { value: 'fashion', label: 'Fashion & costumes' },
  { value: 'hobby-diy', label: 'Hobby & DIY' },
  { value: 'sports-outdoors', label: 'Sports & outdoors' },
  { value: 'education', label: 'Educational' },
  { value: 'printer', label: '3D-printer parts' },
  { value: 'models', label: 'Models & vehicles' },
  { value: 'seasonal', label: 'Seasonal & holiday' },
  { value: 'other', label: 'Other' },
];
const CATEGORY_VALUES = CATEGORIES.map((c) => c.value);

const MATERIALS = ['rigid', 'flexible', 'multi'];

const LICENCES = [
  'CC-BY-4.0',
  'CC-BY-SA-4.0',
  'CC-BY-NC-4.0',
  'CC-BY-NC-SA-4.0',
  'CC0-1.0',
  'Standard Digital File (MakerWorld)',
  'All rights reserved',
];

const str = (v) => (typeof v === 'string' ? v.trim() : '');

/**
 * A MakerRun licence string → the print-file record's licence id
 * (lib/model-licence.js: own, cc0, cc-by, cc-by-sa, cc-by-nd, cc-by-nc,
 * cc-by-nc-sa, cc-by-nc-nd, commercial).
 *
 * `null` means "Not recorded", and that is the honest answer for anything this
 * cannot read with certainty — "All rights reserved", a MakerWorld standard
 * licence, free text. Guessing would put a wrong licence on a shop's record,
 * which is worse than none: the raw string is kept beside it on
 * `rec.makerrun.license` so nothing is lost.
 *
 * Versions are dropped because the record's ids are version-free: the
 * NonCommercial / ShareAlike / NoDerivatives clauses mean the same thing in
 * every version of Creative Commons, and those clauses are all the record says.
 */
function toRecordLicence(mr) {
  const k = str(mr).toLowerCase();
  if (!k) return null;
  if (k === 'cc0' || k === 'cc0-1.0' || k === 'cc0 1.0') return 'cc0';
  const m = /^cc[- ]by((?:[- ](?:nc|sa|nd))*)(?:[- ]\d+(?:\.\d+)?)?$/.exec(k);
  if (!m) return null;
  const parts = m[1].split(/[- ]/).filter(Boolean);
  const id = ['cc-by'].concat(parts).join('-');
  return ['cc-by', 'cc-by-sa', 'cc-by-nd', 'cc-by-nc', 'cc-by-nc-sa', 'cc-by-nc-nd'].indexOf(id) !== -1 ? id : null;
}

/**
 * A record licence id → the MakerRun string to publish under, or `null` when
 * the record's licence is not one MakerRun offers — and then the user must pick
 * from LICENCES rather than have one chosen for them.
 *
 * Deliberately NOT mapped:
 *   own         "my own work" says who made it, not what others may do with it.
 *   cc-by-nd,   MakerRun's upload form does not offer the NoDerivatives
 *   cc-by-nc-nd licences for hosted files.
 *   commercial  bought from a designer. Re-publishing a purchased model is the
 *               one thing that licence almost certainly does not allow, so the
 *               form asks rather than carrying it across.
 */
const TO_MAKERRUN = {
  'cc0': 'CC0-1.0',
  'cc-by': 'CC-BY-4.0',
  'cc-by-sa': 'CC-BY-SA-4.0',
  'cc-by-nc': 'CC-BY-NC-4.0',
  'cc-by-nc-sa': 'CC-BY-NC-SA-4.0',
};
function toMakerRunLicence(recId) {
  const k = str(recId).toLowerCase();
  return Object.prototype.hasOwnProperty.call(TO_MAKERRUN, k) ? TO_MAKERRUN[k] : null;
}

/**
 * May a print be sold under this licence? `true`, `false`, or `null` for
 * "read the licence" — the same three answers, and the same table, as
 * makerrun/src/lib/license-terms.ts. The v1 DesignDTO does not carry
 * `commercialUse` (only /api/library does), so the catalogue works it out here.
 * A `true` is only ever about the commercial clause; attribution, share-alike
 * and no-derivatives still bind.
 */
const TERMS = {
  'cc0-1.0': true, 'cc0': true, 'unlicense': true, 'mit': true, 'bsd-3-clause': true, 'apache-2.0': true,
  'cc-by-4.0': true, 'cc-by-sa-4.0': true, 'cc-by-nd-4.0': true,
  'cc-by-nc-4.0': false, 'cc-by-nc-sa-4.0': false, 'cc-by-nc-nd-4.0': false,
  'all rights reserved': false, 'arr': false,
};
function commercialUse(licence) {
  const k = str(licence).toLowerCase();
  if (!k) return null;
  if (Object.prototype.hasOwnProperty.call(TERMS, k)) return TERMS[k];
  if (/^cc-by(-[a-z]+)*-\d/.test(k)) return !/\bnc\b/.test(k);
  return null;
}

const categoryLabel = (v) => { const c = CATEGORIES.find((x) => x.value === v); return c ? c.label : ''; };

const api = {
  CATEGORIES, CATEGORY_VALUES, MATERIALS, LICENCES,
  toRecordLicence, toMakerRunLicence, commercialUse, categoryLabel,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.BedReadyMakerRunTerms = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
