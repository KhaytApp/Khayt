'use strict';
(function (global) {

/**
 * Finding a filament somebody else has already written down.
 *
 * A shop adding a spool types a brand, a material, a colour, a full-spool
 * weight and a diameter — five things that are public knowledge about a product
 * with a barcode on it. `assets/filament-catalog.json` is 1,945 of them from
 * the Open Filament Database (MIT), and this is the matching.
 *
 * ── WHAT THIS IS FOR, AND WHAT IT IS NOT ───────────────────────────────────
 *
 * It fills a form. It is NOT a source of truth about the spool on the shelf:
 * the shop's own cost, what it actually weighs today, when it was opened and
 * whether it has been dried are facts about that spool and nothing here knows
 * them. `toSpool` therefore returns only the fields the catalogue can speak
 * for, and the caller merges — so a figure the shop has already corrected is
 * never overwritten by a manufacturer's nominal one.
 *
 * ── WHY THE MATCH IS NOT A SUBSTRING TEST ──────────────────────────────────
 *
 * "pla" appears in 700 of these. A shop typing it wants its own brand first,
 * not alphabetical order, and a shop typing "bambu pla matte black" wants one
 * row. So terms are matched independently and scored: an exact field beats a
 * prefix, a prefix beats a contains, brand and name beat material, and every
 * term has to match something or the row is out. That last rule is what makes
 * typing more words narrow the list rather than widen it.
 *
 * Pure: takes the catalogue and a query, returns rows. No fetch, no fs.
 */

const NBSP = /[\u00A0\u2007\u202F]/g;

/** Lowercased, trimmed, and with the spaces a paste can carry made ordinary. */
function norm(v) {
  return String(v == null ? '' : v).replace(NBSP, ' ').trim().toLowerCase();
}

function terms(query) {
  return norm(query).split(/\s+/).filter(Boolean);
}

/**
 * How well one term matches one field. 0 is no match at all.
 *
 * The gap between the tiers matters more than the numbers: a brand's exact name
 * has to outrank a material that merely contains the letters, however many
 * other terms also hit.
 */
function scoreField(term, value, weight) {
  const v = norm(value);
  if (!v || !term) return 0;
  if (v === term) return 12 * weight;
  if (v.startsWith(term)) return 8 * weight;
  // Word-start anywhere: "matte" in "PLA Matte" is a better hit than the "at"
  // inside "Saturated".
  if (v.includes(' ' + term)) return 6 * weight;
  if (v.includes(term)) return 3 * weight;
  return 0;
}

/**
 * Search the catalogue, best first.
 *
 * Colours are searched too — "bambu pla matte black" should find the black of
 * the matte PLA rather than every colour of it — but a colour hit does not
 * split the row: one filament is one result, carrying the colours that matched
 * so a caller can offer them first.
 *
 * @param {object} catalog  the parsed `filament-catalog.json`
 * @param {string} query
 * @param {{limit?: number}} [opts]
 * @returns {Array<{filament: object, score: number, colours: object[],
 *                   unmatched: string[]}>}
 */
function search(catalog, query, opts) {
  const want = terms(query);
  if (!want.length) return [];
  const hits = matchAll(catalog, want, opts);
  if (hits.length) return hits;

  // NOTHING MATCHED EVERY TERM. Rather than an empty list, find the largest
  // subset of the query that does match and say which words were dropped.
  //
  // Dropping only words that match NOTHING in the catalogue is not enough, and
  // that was the first attempt: "bambu pla matte black" returns nothing because
  // Bambu's PLA Matte has no colour called Black — its blacks are Charcoal and
  // Dark Chocolate — but "black" matches plenty of OTHER filaments, so it never
  // looked useless. What is useless is the word IN THIS COMBINATION.
  //
  // So: drop words FROM THE END. People type a filament general to specific —
  // brand, then product, then colour — so the last word is the one that narrows
  // and the first is the one that must not be lost.
  //
  // Taking whichever removal scored highest instead was the second attempt, and
  // it answered "bambu pla matte black" with Matter3D's PLA: dropping the brand
  // left three terms that some other product matched better than Bambu's PLA
  // Matte matched two. A result in the wrong brand is worse than no result —
  // the shop is looking at a spool with the brand printed on it.
  //
  // One word only. A query whose last two words share no product with the rest
  // is better answered with "no" than with a row assembled from half of it.
  for (let i = want.length - 1; i > 0; i--) {
    const kept = want.slice(0, i);
    const found = matchAll(catalog, kept, opts);
    if (!found.length) continue;
    return found.map((hit) => (
      Object.assign({}, hit, { unmatched: want.slice(i) })
    ));
  }
  return [];
}

/** Rows matching EVERY term, best first. */
function matchAll(catalog, want, opts) {
  const list = (catalog && Array.isArray(catalog.filaments)) ? catalog.filaments : [];
  const limit = (opts && opts.limit > 0) ? opts.limit : 20;
  const out = [];
  for (const f of list) {
    if (!f) continue;
    let total = 0;
    let missed = false;
    const hitColours = new Set();

    for (const term of want) {
      let best = 0;
      best = Math.max(best, scoreField(term, f.b, 3));   // brand
      best = Math.max(best, scoreField(term, f.n, 3));   // product name
      best = Math.max(best, scoreField(term, f.m, 2));   // material
      for (let i = 0; i < (f.c || []).length; i++) {
        const hit = scoreField(term, f.c[i][0], 2);      // colour name
        if (hit > 0) hitColours.add(i);
        best = Math.max(best, hit);
      }
      // EVERY TERM HAS TO LAND. Without this, "bambu pla matte black" scores
      // every Bambu PLA highly on three terms and the fourth is free — so the
      // more the shop types, the less the list narrows, which is the opposite
      // of what typing is for.
      if (best === 0) { missed = true; break; }
      total += best;
    }
    if (missed) continue;

    // A shorter name that matched is a closer match than a longer one: typing
    // "PLA" should not put "PLA Silk Rainbow Gradient" above "PLA".
    total -= Math.min(4, norm(f.n).length / 20);
    out.push({
      filament: f,
      score: total,
      colours: [...hitColours].map((i) => colourAt(f, i)).filter(Boolean),
      unmatched: [],
    });
  }

  out.sort((a, b) => b.score - a.score
    || norm(a.filament.b).localeCompare(norm(b.filament.b))
    || norm(a.filament.n).localeCompare(norm(b.filament.n)));
  return out.slice(0, limit);
}

/** One colour of a filament, as a named record rather than a positional row. */
function colourAt(filament, index) {
  const row = filament && Array.isArray(filament.c) ? filament.c[index] : null;
  if (!row) return null;
  return {
    name: String(row[0] || ''),
    hex: String(row[1] || ''),
    weights: Array.isArray(row[2]) ? row[2].slice() : [],
    emptySpoolWeight: row[3] > 0 ? Number(row[3]) : null,
    diameter: row[4] > 0 ? Number(row[4]) : null,
  };
}

/** Every colour of a filament. */
function coloursOf(filament) {
  const n = filament && Array.isArray(filament.c) ? filament.c.length : 0;
  const out = [];
  for (let i = 0; i < n; i++) {
    const c = colourAt(filament, i);
    if (c) out.push(c);
  }
  return out;
}

/**
 * The spool fields this catalogue can speak for.
 *
 * ONLY those. A spool's cost, what it weighs today, when it was opened and
 * whether it has been dried are facts about the roll in the shop's hand; a
 * manufacturer's page does not know them and this must not invent them. The
 * caller merges this over an empty draft, never over a filled one.
 *
 * `material` is the brand's own product name rather than the bare type, because
 * that is what a shop reads off the label and what it will look for on the
 * shelf — "Bambu PLA Matte", not "PLA". The bare type is carried alongside for
 * anything matching on material.
 *
 * @param {object} filament
 * @param {object} [colour]  one of `coloursOf(filament)`
 * @param {number} [weight]  which of the colour's spool weights, in grams
 */
function toSpool(filament, colour, weight) {
  if (!filament) return {};
  const out = {};
  const label = [filament.b, filament.n].filter(Boolean).join(' ').trim();
  if (label) out.material = label;
  if (filament.m) out.materialType = String(filament.m);
  if (filament.d > 0) out.density = Number(filament.d);

  if (colour) {
    if (colour.name) out.colourVariant = colour.name;
    if (colour.hex) out.color = colour.hex;
    if (colour.diameter > 0) out.diameter = colour.diameter;
    // The figure a scale reading is useless without.
    if (colour.emptySpoolWeight > 0) out.emptySpoolWeight = colour.emptySpoolWeight;

    const weights = Array.isArray(colour.weights) ? colour.weights : [];
    const picked = weight > 0 ? Number(weight)
      : (weights.length === 1 ? weights[0] : null);
    if (picked > 0) {
      out.spoolWeight = picked;
      // A NEW SPOOL IS A FULL SPOOL, and nothing else here can say what is on
      // this one. The caller drops it for a roll that is already open.
      out.weight = picked;
    }
  }
  return out;
}

/**
 * How old this snapshot is, in days, or null when it does not say.
 *
 * Shown rather than hidden: a catalogue that quietly ages looks like a
 * catalogue that is missing a filament the shop just bought.
 */
function ageInDays(catalog, now) {
  const at = catalog && catalog.generatedAt ? Date.parse(catalog.generatedAt) : NaN;
  const nowMs = typeof now === 'number' ? now
    : (now instanceof Date ? now.getTime() : Date.now());
  if (!Number.isFinite(at) || !Number.isFinite(nowMs)) return null;
  return Math.max(0, (nowMs - at) / 86400000);
}

const api = { search, coloursOf, colourAt, toSpool, ageInDays };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytFilamentCatalog = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
