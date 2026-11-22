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

/** Estimated print time in minutes, or null if not found. */
function parsePrintTimeMins(text) {
  // PrusaSlicer / SuperSlicer / OrcaSlicer: "estimated printing time (normal mode) = 2h 3m 4s" (+ optional Nd)
  let m = text.match(/estimated printing time[^=\n\r]*=\s*(?:(\d+)\s*d)?\s*(?:(\d+)\s*h)?\s*(?:(\d+)\s*m)?\s*(?:(\d+)\s*s)?/i);
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
 */
function parseGcodeText(text, opts = {}) {
  const s = String(text || '');
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
  detectSlicer,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytGcodeParse = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
