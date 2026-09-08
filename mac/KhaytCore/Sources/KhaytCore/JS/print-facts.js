'use strict';
/**
 * What a print file says about itself: the printer it was set up for, how thick
 * the layers are, what it is made of, whether it has support.
 *
 * This is not a slicer and it does not estimate anything. Every answer is
 * something a slicer already wrote into the file, or it is null. In particular
 * there is NO print time and NO filament weight here: those only exist in a
 * SLICED 3MF, and of 43 real files in this shop's library 39 carry full
 * settings and not one carries usable slice output. A field that is empty on
 * every real file is worse than no field, because it teaches people the panel
 * is broken.
 *
 * TWO CONFIG DIALECTS, AND THEY DISAGREE ON THE KEY NAMES.
 *
 *   Orca/Bambu  `Metadata/project_settings.config`, JSON, arrays per slot:
 *               sparse_infill_density, enable_support, filament_type[]
 *   PrusaSlicer `Metadata/Slic3r_PE.config` (or `Prusa_Slicer.config`), INI:
 *               fill_density, support_material, filament_type
 *
 * The Prusa names were read off this Mac's own PrusaSlicer profiles rather than
 * remembered, because `fill_density` and `sparse_infill_density` are the same
 * idea under two names and guessing which is which produces a panel that is
 * confidently blank.
 *
 * Pure: strings in, a plain object out. No DOM, no Buffer, no zip. Never throws
 * — a config it cannot parse yields nulls, because a file being strange must
 * not stop a preview from showing the picture.
 */
(function (global) {

// Wrapped, like every module KhaytCore bundles: they share one JavaScriptCore
// context, so a top-level `const api` here would collide with another module's.
// See test/bundled-modules-are-wrapped.test.js.

/** A number from a string, or null. Never NaN. */
function num(v) {
  if (v == null) return null;
  const n = parseFloat(String(v));
  return Number.isFinite(n) ? n : null;
}

/** A percentage as it was written ("15%"), normalised, or null. */
function pct(v) {
  if (v == null) return null;
  const s = String(v).trim();
  if (!s) return null;
  const n = parseFloat(s);
  if (!Number.isFinite(n)) return null;
  return n + '%';
}

/** Slicers write "0" and "1"; a shop reads yes and no. */
function bool(v) {
  if (v == null || v === '') return null;
  const s = String(v).trim().toLowerCase();
  if (s === '1' || s === 'true' || s === 'yes') return true;
  if (s === '0' || s === 'false' || s === 'no') return false;
  return null;
}

/**
 * One value out of a per-slot array, or the marker that the slots disagree.
 *
 * `nozzle_diameter` is `["0.4"]` on a single-extruder machine and
 * `["0.4","0.4","0.4","0.4"]` on the U1. Reporting the first blindly would say
 * 0.4 for a machine with a 0.4 and a 0.6 fitted, so a real disagreement is
 * reported as one.
 */
function oneOf(list) {
  if (!Array.isArray(list) || !list.length) return { value: null, varies: false };
  const seen = [];
  for (const v of list) {
    const s = v == null ? '' : String(v).trim();
    if (s && seen.indexOf(s) === -1) seen.push(s);
  }
  if (!seen.length) return { value: null, varies: false };
  return { value: seen[0], varies: seen.length > 1, all: seen };
}

/**
 * The `<metadata key= value=>` pairs inside each `<object>` of a
 * `model_settings.config`, as a list of plain maps — one per object.
 *
 * Regex rather than a parser because this module has no DOM and must not gain
 * one. The shape is a slicer's own output, not arbitrary XML: it is flat,
 * attribute-only, and the same three lines have held for every file in this
 * library. A file it cannot read yields an empty list and the project's own
 * settings answer instead, which is the pre-override behaviour and never worse.
 */
function objectSettings(modelSettings) {
  const text = String(modelSettings || '');
  if (!text) return [];
  const out = [];
  const objects = text.match(/<object\b[\s\S]*?<\/object>/g) || [];
  for (const block of objects) {
    // Only the object's OWN metadata, not a <part>'s: a part carries a name and
    // a transform, and reading its keys as the object's would double-count.
    const head = block.split(/<part\b/)[0];
    const map = {};
    const re = /<metadata\s+key="([^"]+)"\s+value="([^"]*)"/g;
    let m;
    while ((m = re.exec(head)) !== null) map[m[1]] = m[2];
    out.push(map);
  }
  return out;
}

/**
 * What the objects on the plate actually use for one setting.
 *
 * AN OBJECT'S OWN VALUE BEATS THE PROJECT'S, and 14 of this library's 43 files
 * set one. A king plate whose project says 15% infill has `100%` on the object;
 * showing 15% would be a straight lie about the file. An object that says
 * nothing uses the project value, so the effective value is computed per object
 * and only then compared — that is what makes a mixed plate report as mixed
 * rather than as whichever object happened to be first.
 */
function effective(objects, key, projectValue) {
  if (!Array.isArray(objects) || !objects.length) {
    return { value: projectValue, varies: false };
  }
  const seen = [];
  for (const o of objects) {
    const v = (o && o[key] != null && o[key] !== '') ? String(o[key]) : projectValue;
    const s = v == null ? null : String(v);
    if (s != null && seen.indexOf(s) === -1) seen.push(s);
  }
  if (!seen.length) return { value: projectValue, varies: false };
  return { value: seen[0], varies: seen.length > 1 };
}

/** `key = value` out of a PrusaSlicer config, or null. */
function ini(text, key) {
  const re = new RegExp('^[ \\t]*' + key + '[ \\t]*=[ \\t]*(.*)$', 'm');
  const m = re.exec(String(text || ''));
  return m ? m[1].trim() : null;
}

/**
 * The facts, from whichever dialect the file is written in.
 *
 * @param {{projectSettings?:string, modelSettings?:string, prusa?:string}} configs
 * @returns {{printer:?string, layerHeight:?number, nozzle:?number,
 *            nozzleVaries:boolean, materials:string[], infill:?string,
 *            infillVaries:boolean, support:?boolean, supportStyle:?string,
 *            objects:?number, source:?string}}
 */
function printFacts(configs) {
  const cfg = configs || {};
  const empty = {
    printer: null, layerHeight: null, nozzle: null, nozzleVaries: false,
    materials: [], infill: null, infillVaries: false,
    support: null, supportStyle: null, objects: null, source: null,
  };

  const objects = objectSettings(cfg.modelSettings);
  const objectCount = objects.length ? objects.length : null;

  // ── Orca / Bambu ────────────────────────────────────────────────────────
  let proj = null;
  const projText = String(cfg.projectSettings || '');
  if (projText) { try { proj = JSON.parse(projText); } catch (_) { proj = null; } }

  if (proj && typeof proj === 'object') {
    const nozzle = oneOf(proj.nozzle_diameter);
    const types = oneOf(proj.filament_type);
    const infill = effective(objects, 'sparse_infill_density',
                             proj.sparse_infill_density == null ? null
                               : String(proj.sparse_infill_density));
    const support = effective(objects, 'enable_support',
                              proj.enable_support == null ? null
                                : String(proj.enable_support));
    // The style is only true when support is actually on. Every one of these
    // files carries a `support_type`, including the ones with support switched
    // off — reporting "tree (auto)" for a model that prints without support is
    // the most misleading thing this module could say.
    const on = support.varies ? null : bool(support.value);
    return {
      printer: proj.printer_model ? String(proj.printer_model) : null,
      layerHeight: num(proj.layer_height),
      nozzle: num(nozzle.value),
      nozzleVaries: !!nozzle.varies,
      materials: (types.all || (types.value ? [types.value] : [])).slice(),
      infill: pct(infill.value),
      infillVaries: !!infill.varies,
      support: on,
      supportStyle: on === true && proj.support_type ? String(proj.support_type) : null,
      objects: objectCount,
      source: 'orca',
    };
  }

  // ── PrusaSlicer ─────────────────────────────────────────────────────────
  const pru = String(cfg.prusa || '');
  if (pru) {
    // A Prusa config is one value per key, not one per slot; a multi-material
    // one separates with `;`.
    const types = oneOf(String(ini(pru, 'filament_type') || '').split(/[;,]/));
    const nozzle = oneOf(String(ini(pru, 'nozzle_diameter') || '').split(/[;,]/));
    // `support_material` is the switch; `support_material_auto` only chooses
    // between automatic and painted-on, so it is not what "has support" means.
    const on = bool(ini(pru, 'support_material'));
    return {
      printer: ini(pru, 'printer_model'),
      layerHeight: num(ini(pru, 'layer_height')),
      nozzle: num(nozzle.value),
      nozzleVaries: !!nozzle.varies,
      materials: (types.all || (types.value ? [types.value] : [])).slice(),
      infill: pct(ini(pru, 'fill_density')),
      infillVaries: false,
      support: on,
      supportStyle: on === true ? ini(pru, 'support_material_style') : null,
      objects: objectCount,
      source: 'prusa',
    };
  }

  // A 3MF a CAD program wrote. It still has a name and a shape; it has no
  // opinion about how to print it, and saying so is the honest answer.
  return Object.assign({}, empty, { objects: objectCount });
}

const printFactsApi = { printFacts, objectSettings, effective, oneOf };
if (typeof module !== 'undefined' && module.exports) module.exports = printFactsApi;
global.KhaytPrintFacts = printFactsApi;

})(typeof globalThis !== 'undefined' ? globalThis : this);
