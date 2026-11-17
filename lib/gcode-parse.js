'use strict';

(function (global) {

/**
 * Pure slicer-metadata parser for gcode / 3MF text — extracts estimated print
 * time and filament weight. See docs/KHAYT-3.0-PRINTFILES-SPEC.md.
 *
 * IMPORTANT: PrusaSlicer / SuperSlicer / OrcaSlicer write their summary in the
 * FOOTER config block (end of file); Cura writes near the head; Bambu in header
 * comments. So callers must pass the file HEAD **and** TAIL (or the whole file
 * for small ones) — a head-only read misses most modern slicers. This module is
 * fs/IPC-free so it can be unit-tested directly.
 */

function toMinutes(days, hours, mins, secs) {
  const totalSec = (days * 86400) + (hours * 3600) + (mins * 60) + secs;
  return Math.round(totalSec / 60);
}

/** The days/hours/minutes/seconds after an "=" or ":", read from a short slice. */
const DHMS = /^\s*(?:(\d+)\s*d)?\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?/i;
const DHMS_WINDOW = 512;

/**
 * The value of the first "estimated printing time … = 2h 3m 4s" (Prusa,
 * SuperSlicer, Orca), as the old pattern found it, in ONE pass.
 *
 * The old `/estimated printing time[^=\n\r]*=…/i` rescanned to the end of
 * the line from every occurrence of the phrase, so a single long line of it
 * with no "=" was quadratic: 800 KB took 13 s, 32 MB hours. A stranger can
 * send such a file to the Mac's intake quote (beta.40 security review, Nov
 * 17). Here each occurrence is scanned forward only to its "=" or its line
 * end, and a line with no "=" is skipped whole, so every character is looked
 * at a fixed number of times. The match found is the one the regex found:
 * the earliest occurrence with an "=" before the line ends, its first "=".
 */
function estimatedPrintingTime(text) {
  const lower = text.toLowerCase();
  const key = 'estimated printing time';
  let from = 0;
  for (;;) {
    const i = lower.indexOf(key, from);
    if (i < 0) return null;
    let j = i + key.length;
    while (j < lower.length) {
      const c = lower.charCodeAt(j);
      if (c === 61 /* = */ || c === 10 || c === 13) break;
      j++;
    }
    if (j < lower.length && lower.charCodeAt(j) === 61) {
      // From `lower`, where j was found: a lowercase can be LONGER than its
      // capital ('İ' is two characters), so an index into `lower` is not one
      // into `text`. Digits and d/h/m/s read the same either way.
      return DHMS.exec(lower.slice(j + 1, j + 1 + DHMS_WINDOW));
    }
    // No "=" before the line ends: no occurrence before here can match either.
    from = j + 1;
  }
}

/** Estimated print time in minutes, or null if not found. */
function parsePrintTimeMins(text) {
  // PrusaSlicer / SuperSlicer / OrcaSlicer: "estimated printing time (normal mode) = 2h 3m 4s" (+ optional Nd)
  let m = estimatedPrintingTime(text);
  if (m && (m[1] || m[2] || m[3] || m[4])) {
    return toMinutes(+(m[1] || 0), +(m[2] || 0), +(m[3] || 0), +(m[4] || 0));
  }
  // Bambu Studio: "; total estimated time: 1h 4m 5s" (colon separator)
  m = text.match(/total estimated time\s*[:=]\s*(?:(\d+)\s*d)?\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?/i);
  if (m && (m[1] || m[2] || m[3] || m[4])) {
    return toMinutes(+(m[1] || 0), +(m[2] || 0), +(m[3] || 0), +(m[4] || 0));
  }
  // Cura: ";TIME:12345" (seconds)
  m = text.match(/^;\s*TIME:\s*(\d+)/im);
  if (m) return Math.round(parseInt(m[1], 10) / 60);
  return null;
}

/** Sum a "1.2, 3.4" style multi-extruder value list into a single number. */
function sumValueList(s) {
  const nums = String(s).match(/[\d.]+/g);
  if (!nums) return null;
  const total = nums.reduce((a, n) => a + (parseFloat(n) || 0), 0);
  return total > 0 ? total : null;
}

/** Total filament weight in grams, or null if not found. */
function parseFilamentGrams(text) {
  // Prefer an explicit total when present (single authoritative value).
  let m = text.match(/total filament used \[g\]\s*[:=]\s*([\d.,\s]+)/i);
  if (m) { const v = sumValueList(m[1]); if (v != null) return v; }
  // Bambu: "total filament weight [g] : 12.34"
  m = text.match(/total filament weight \[g\]\s*[:=]\s*([\d.,\s]+)/i);
  if (m) { const v = sumValueList(m[1]); if (v != null) return v; }
  // PrusaSlicer / Orca per-extruder: "filament used [g] = 1.2, 3.4" (sum them)
  m = text.match(/(?<!total )filament used \[g\]\s*[:=]\s*([\d.,\s]+)/i);
  if (m) { const v = sumValueList(m[1]); if (v != null) return v; }
  // Cura plugin: "FILAMENT_WEIGHT = 12.34"
  m = text.match(/FILAMENT_WEIGHT\s*[:=]\s*([\d.]+)/i);
  if (m) { const v = parseFloat(m[1]); if (v > 0) return v; }
  return null;
}

/**
 * Total filament VOLUME in cm3, or null.
 *
 * Worth having on its own because a slice with no printer profile loaded reports
 * "total filament used [g] = 0.00" — the slicer has no filament density, so it
 * cannot weigh what it just measured. It still reports the volume exactly, from
 * the real toolpaths rather than from geometry, and grams is one multiplication
 * away from a density the SHOP knows.
 */
function parseFilamentCm3(text) {
  // PrusaSlicer / SuperSlicer / Orca: "filament used [cm3] = 3.59" (per-extruder list on MMU)
  let m = text.match(/filament used \[cm3\]\s*[:=]\s*([\d.,\s]+)/i);
  if (m) { const v = sumValueList(m[1]); if (v != null) return v; }
  // Some builds write mm3.
  m = text.match(/filament used \[mm3\]\s*[:=]\s*([\d.,\s]+)/i);
  if (m) { const v = sumValueList(m[1]); if (v != null) return v / 1000; }
  return null;
}

/**
 * Grams from the slicer's own volume and a density the caller supplies.
 *
 * Kept separate from parseFilamentGrams so the two can never be confused: one is
 * what the slicer weighed, this is what the shop's density implies about a volume
 * the slicer measured. Callers that report it should say which they have.
 */
function gramsFromCm3(cm3, densityGPerCm3) {
  const v = Number(cm3);
  const d = Number(densityGPerCm3);
  if (!(v > 0) || !(d > 0)) return null;
  return Math.round(v * d * 100) / 100;
}

/** Total filament cost from the slicer (in the slicer's currency), or null. */
function parseFilamentCost(text) {
  // PrusaSlicer / Orca / SuperSlicer: "total filament cost = 1.87" (or per-extruder list)
  let m = text.match(/total filament cost\s*[:=]\s*([\d.,\s]+)/i);
  if (m) { const v = sumValueList(m[1]); if (v != null) return v; }
  m = text.match(/(?<!total )filament cost\s*[:=]\s*([\d.,\s]+)/i);
  if (m) { const v = sumValueList(m[1]); if (v != null) return v; }
  return null;
}

/** Filament material type (e.g. "PLA"), or null. First extruder for multi-material. */
function parseFilamentType(text) {
  // PrusaSlicer / SuperSlicer / OrcaSlicer / Bambu: "filament_type = PLA" (or ":")
  const m = text.match(/filament_type\s*[:=]\s*([A-Za-z0-9 +._-]+)/i);
  if (m) {
    const first = String(m[1]).split(/[,;]/)[0].trim();
    return first ? first.toUpperCase() : null;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Per-slot figures (a slot is a filament position: slot 1 is the slicer's
// first filament, tool T0 on a toolchanger).
//
// PrusaSlicer / SuperSlicer / OrcaSlicer write one comma list per figure, by
// filament index and zero-filled, plus the filament presets in the config
// block. The totals above sum those lists, which is right for a price and
// loses which spool used what. docs/connector.vectors.json holds the cases;
// the OrcaSlicer plugin's Python reader has to pass the same file.
// ---------------------------------------------------------------------------

/** The value of the first comment line "; <key> = value" (or ":"), or null. */
function commentValue(text, keyPattern) {
  const re = new RegExp('^[ \\t]*;[ \\t]*' + keyPattern + '[ \\t]*[:=][ \\t]*(.*)$', 'im');
  const m = text.match(re);
  return m ? m[1].replace(/\r$/, '').trim() : null;
}

/** "1.2, 0.00, 3" -> [1.2, 0, 3]; an entry that is not a number is null. */
function numberList(value) {
  if (value == null || value === '') return [];
  return String(value).split(/[,;]/).map((part) => {
    const t = part.trim();
    if (!/^\d+(\.\d+)?$|^\.\d+$/.test(t)) return null;
    return parseFloat(t);
  });
}

/**
 * A slicer string list: `"Generic PLA @U1";"PETG; black"` or `PLA;PETG`.
 * Entries are separated by ";" and may be double-quoted, in which case they
 * may hold a ";" or a "," themselves, and \" and \\ are escapes.
 */
function stringList(value) {
  if (value == null || value === '') return [];
  const s = String(value);
  const out = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (quoted) {
      if (c === '\\' && i + 1 < s.length) { cur += s[++i]; continue; }
      if (c === '"') { quoted = false; continue; }
      cur += c;
    } else if (c === '"') {
      quoted = true;
    } else if (c === ';') {
      out.push(cur.trim());
      cur = '';
    } else {
      cur += c;
    }
  }
  out.push(cur.trim());
  return out;
}

function colourOrNull(v) {
  const t = String(v || '').trim();
  return /^#([0-9a-f]{6}|[0-9a-f]{8})$/i.test(t) ? t.toUpperCase() : null;
}

function at(list, i) {
  const v = list[i];
  return v == null || v === '' ? null : v;
}

/**
 * What each filament slot used, for the slots that used any.
 *
 * `slot` is 1-based and keeps its position: a print on filaments 1 and 3 gives
 * slots 1 and 3, never 1 and 2. A slot with no length, volume or weight is
 * left out. `grams` is null when the slicer wrote 0 for a slot that has a
 * volume: it had no density to weigh with (see parseFilamentCm3), and 0 g
 * would read as a fact. `costPerKg` and `cost` are in the slicer's currency.
 *
 * Returns [] when the file has no per-filament lists (Cura, a hand-written
 * file), so a caller can tell "one filament" from "not said".
 */
function parseFilaments(text) {
  const s = String(text || '');
  let grams = numberList(commentValue(s, 'filament used \\[g\\]'));
  let mm = numberList(commentValue(s, 'filament used \\[mm\\]'));
  let cm3 = numberList(commentValue(s, 'filament used \\[cm3\\]'));
  if (!cm3.length) {
    cm3 = numberList(commentValue(s, 'filament used \\[mm3\\]')).map((v) => (v == null ? null : v / 1000));
  }
  // Bambu Studio's header block names its per-filament lists differently. Its
  // volume line is left alone: it is labelled cm^3 and has carried mm^3.
  if (!grams.length) grams = numberList(commentValue(s, 'total filament weight \\[g\\]'));
  if (!mm.length) mm = numberList(commentValue(s, 'total filament length \\[mm\\]'));
  const count = Math.max(grams.length, mm.length, cm3.length);
  if (!count) return [];

  const cost = numberList(commentValue(s, 'filament cost'));
  const types = stringList(commentValue(s, 'filament_type'));
  const colours = stringList(commentValue(s, 'filament_colour'));
  const presets = stringList(commentValue(s, 'filament_settings_id'));
  const density = numberList(commentValue(s, 'filament_density'));
  const perKg = numberList(commentValue(s, 'filament_cost'));

  const out = [];
  for (let i = 0; i < count; i++) {
    const g = at(grams, i);
    const l = at(mm, i);
    const v = at(cm3, i);
    if (!(g > 0) && !(l > 0) && !(v > 0)) continue;
    const type = at(types, i);
    out.push({
      slot: i + 1,
      grams: g > 0 ? g : null,
      cm3: v > 0 ? v : null,
      mm: l > 0 ? l : null,
      cost: at(cost, i),
      type: type ? String(type).toUpperCase() : null,
      colour: colourOrNull(at(colours, i)),
      preset: at(presets, i),
      density: at(density, i) > 0 ? at(density, i) : null,
      costPerKg: at(perKg, i) > 0 ? at(perKg, i) : null,
    });
  }
  return out;
}

/** Best-effort slicer name, for display/debugging. */
function detectSlicer(text) {
  if (/PrusaSlicer/i.test(text)) return 'PrusaSlicer';
  if (/OrcaSlicer/i.test(text)) return 'OrcaSlicer';
  if (/SuperSlicer/i.test(text)) return 'SuperSlicer';
  if (/BambuStudio|Bambu Studio/i.test(text)) return 'BambuStudio';
  if (/Cura/i.test(text)) return 'Cura';
  return null;
}

/**
 * Parse slicer metadata from gcode/3mf text (pass head+tail for large files).
 * @returns {{ printTimeMins: number|null, filamentGrams: number|null, slicer: string|null }}
 * `filaments` is the per-slot breakdown (parseFilaments); `filamentGrams` stays
 * the total, so a caller that only prices the print reads what it always did.
 */
/**
 * Slicer metadata sits in a file's head (Cura, Bambu) or its footer (Prusa,
 * Orca), never in the moves between. A large file is read as its first and
 * last half megabyte, so no pattern here ever runs over 32 MB of moves a
 * stranger chose (beta.40 security review, Nov 17).
 */
const EDGE_BYTES = 512 * 1024;
function edges(s) {
  return s.length <= EDGE_BYTES * 2 ? s : s.slice(0, EDGE_BYTES) + '\n' + s.slice(s.length - EDGE_BYTES);
}

function parseGcodeText(text, opts = {}) {
  const s = edges(String(text || ''));
  const cm3 = parseFilamentCm3(s);
  const weighed = parseFilamentGrams(s);
  // Only when the slicer could not weigh it itself, and only when the caller
  // supplied a density to weigh it with. `filamentGramsDerived` says which of
  // the two the number is, so nothing downstream presents a derived figure as
  // one the slicer stood behind.
  const derived = weighed == null ? gramsFromCm3(cm3, opts.densityGPerCm3) : null;
  return {
    printTimeMins: parsePrintTimeMins(s),
    filamentGrams: weighed != null ? weighed : derived,
    filamentGramsDerived: weighed == null && derived != null,
    filamentCm3: cm3,
    filamentType: parseFilamentType(s),
    filamentCost: parseFilamentCost(s),
    filaments: parseFilaments(s),
    slicer: detectSlicer(s),
  };
}

const api = {
  parseGcodeText,
  parsePrintTimeMins,
  parseFilamentGrams,
  parseFilamentCm3,
  gramsFromCm3,
  parseFilamentType,
  parseFilamentCost,
  parseFilaments,
  detectSlicer,
  EDGE_BYTES,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytGcodeParse = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
