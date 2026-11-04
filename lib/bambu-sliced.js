'use strict';

(function (global) {
/**
 * What a Bambu job was SLICED to use, for the plate the printer was told to run.
 *
 * Bambu's MQTT report carries no cumulative extrusion — nothing like Moonraker's
 * `filament_used` — so the printer cannot say what a job weighed. What CAN be
 * known is what the file it ran was sliced to weigh, plate by plate: every
 * Bambu Studio / Orca print file carries `Metadata/slice_info.config`, one
 * `<plate>` block each, with
 *
 *     <metadata key="index"      value="2"/>
 *     <metadata key="prediction" value="5420"/>     seconds
 *     <metadata key="weight"     value="41.83"/>    grams
 *     <filament id="1" type="PLA" color="#FFFFFF" used_m="13.91" used_g="41.83"/>
 *
 * When Khayt sent the job itself it has that file in hand, so it can say what
 * THAT PLATE was sliced to use — which is more than a shop's quote figure (the
 * quote may be for another slice, another plate, or a guess) and less than a
 * measurement. It is labelled `sliced` wherever it travels, never `measured`:
 * the same discipline as R1, and the reason `printer-actuals` refuses
 * OctoPrint's `job.filament`. A sliced figure taken for a reading teaches the
 * estimator its own guess and reports a variance of zero.
 *
 * Read here rather than through `mf-convert.extractMeta`, deliberately: that
 * answers "what does this PROJECT cost" and so collapses a single-plate file
 * into totals (dropping the plate's index) and rounds the prediction to whole
 * minutes. This answers "what did plate N cost", which needs both. Grams are
 * summed from `used_g` first and the plate's `weight` second, the same
 * precedence `extractMeta` uses, so the two agree on the same file.
 *
 * Pure — text in, numbers out. No Buffer, no zip, no DOM: the Mac runs this in
 * JavaScriptCore.
 */

/** Same bounds `mf-convert` puts on the same fields of the same file. */
const MAX_PLATES = 512;
const MAX_PLATE_FILAMENTS = 64;
const MAX_GRAMS = 1e6;
const MAX_SECONDS = 1e8;
const MAX_TEXT = 4 * 1024 * 1024;

const finite = (v, max) => {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 && n <= max ? n : null;
};

/** One attribute of one tag, either quote style. */
function attr(tag, name) {
  const m = new RegExp('\\b' + name + '\\s*=\\s*"([^"]*)"', 'i').exec(tag)
    || new RegExp('\\b' + name + "\\s*=\\s*'([^']*)'", 'i').exec(tag);
  return m ? m[1] : null;
}

/** `<metadata key="k" value="v"/>`, attributes in either order. */
function metadata(block, key) {
  const re = /<metadata\b[^>]*>/gi;
  let m;
  while ((m = re.exec(block))) {
    if (String(attr(m[0], 'key') || '').toLowerCase() === key) return attr(m[0], 'value');
  }
  return null;
}

/**
 * Every plate a slice_info.config lists.
 *
 * @param {string} text  the member's text
 * @returns {Array<{index:number, grams:number|null, predictionS:number|null,
 *   filaments:Array<{id:string, type:string|null, color:string|null, usedG:number|null, usedM:number|null}>}>}
 *   in file order. A plate whose index is missing, not a whole number or a
 *   repeat is DROPPED rather than renumbered: the whole point here is matching
 *   the plate the printer ran, and a guessed index is a guess at that.
 */
function parseSliceInfo(text) {
  if (typeof text !== 'string' || !text) return [];
  const src = text.length > MAX_TEXT ? text.slice(0, MAX_TEXT) : text;
  const out = [];
  const seen = new Set();
  const re = /<plate\b[^>]*>([\s\S]*?)<\/plate>/gi;
  let m;
  while ((m = re.exec(src)) && out.length < MAX_PLATES) {
    const block = m[1];
    const rawIndex = metadata(block, 'index');
    const index = /^\s*\d{1,6}\s*$/.test(String(rawIndex || '')) ? parseInt(rawIndex, 10) : null;
    if (!(index >= 1) || seen.has(index)) continue;
    seen.add(index);

    const filaments = [];
    const fre = /<filament\b[^>]*>/gi;
    let f;
    let summed = 0, anyUsed = false;
    while ((f = fre.exec(block)) && filaments.length < MAX_PLATE_FILAMENTS) {
      const usedG = finite(attr(f[0], 'used_g'), MAX_GRAMS);
      const usedM = finite(attr(f[0], 'used_m'), MAX_GRAMS);
      if (usedG !== null) { summed += usedG; anyUsed = true; }
      filaments.push({
        id: String(attr(f[0], 'id') || String(filaments.length + 1)).slice(0, 16),
        type: (attr(f[0], 'type') || '').slice(0, 40) || null,
        color: (attr(f[0], 'colou?r') || '').slice(0, 16) || null,
        usedG,
        usedM,
      });
    }
    const weight = finite(metadata(block, 'weight'), MAX_GRAMS);
    const grams = anyUsed && summed > 0 ? summed : (weight !== null && weight > 0 ? weight : null);
    const pred = finite(metadata(block, 'prediction'), MAX_SECONDS);
    out.push({
      index,
      grams: grams === null ? null : Math.round(grams * 100) / 100,
      predictionS: pred !== null && pred > 0 ? pred : null,
      filaments,
    });
  }
  return out;
}

/**
 * The plate a print file will run when Khayt starts it.
 *
 * Bambu's `project_file` command names a G-code member — `Metadata/plate_N.gcode`
 * — and the printer runs that plate. Khayt asked for plate 1 unconditionally,
 * which fails outright on a file exported as "this plate only" from plate 3:
 * there is no plate_1.gcode in it. So: plate 1 when the file carries it, else
 * the lowest plate the file does carry, else 1 (a file with no embedded G-code
 * at all is the printer's to refuse).
 *
 * @param {string[]} memberNames  the archive's member names
 */
function plateToStart(memberNames) {
  const plates = [];
  for (const n of Array.isArray(memberNames) ? memberNames : []) {
    const m = /^\/?Metadata\/plate_(\d{1,6})\.gcode$/i.exec(String(n || ''));
    if (m) plates.push(parseInt(m[1], 10));
  }
  if (!plates.length || plates.includes(1)) return 1;
  return Math.min.apply(null, plates);
}

/**
 * The sliced figures for the plate that was printed — or nothing.
 *
 * With a plate named, that plate or nothing: a multi-plate project's other
 * plates are other prints. With none named, only a file of exactly one plate
 * answers, because then there is no choice to get wrong.
 *
 * @returns {{plate:number, grams:number|null, predictionS:number|null}|null}
 */
function slicedForPlate(plates, plateIndex) {
  const list = Array.isArray(plates) ? plates : [];
  let p = null;
  if (plateIndex !== undefined && plateIndex !== null && plateIndex !== '') {
    const want = Number(plateIndex);
    p = list.find((x) => x && x.index === want) || null;
  } else if (list.length === 1) {
    p = list[0];
  }
  if (!p || !(p.grams > 0 || p.predictionS > 0)) return null;
  return { plate: p.index, grams: p.grams > 0 ? p.grams : null, predictionS: p.predictionS > 0 ? p.predictionS : null };
}

/**
 * Does a printer's reported job name belong to the file Khayt sent?
 *
 * Khayt sets `subtask_name` to the remote file name when it starts a job, and
 * the report echoes it back. Compared case-blind and with the print-file
 * extension off, because firmware has been seen reporting the name with and
 * without `.3mf` (ha-bambulab keeps both spellings for the same reason).
 */
function sameJob(reported, sent) {
  const norm = (s) => String(s || '').trim().replace(/^.*[\\/]/, '').toLowerCase()
    .replace(/(\.gcode)?\.3mf$/i, '').replace(/\.gcode$/i, '');
  const a = norm(reported), b = norm(sent);
  return !!a && a === b;
}

/**
 * A Bambu status with the sliced figures of the job Khayt sent laid on, when
 * the printer is running that job. Otherwise the status unchanged.
 *
 * `record` is what the sender kept: `{ remoteName, plate, plates }`. The
 * figures go through `printer-actuals.extractActuals`, so the labels
 * (`gramsBasis: 'sliced'`, `timeBasis: 'sliced'`) are set in the one place that
 * decides what each protocol's numbers mean.
 *
 * @param {object} status   a parsed Bambu status (`parseBambuReport`)
 * @param {object} record   the sent job, or null
 * @param {function} extractActuals  `printer-actuals.extractActuals`
 */
function withSliced(status, record, extractActuals) {
  if (!status || typeof status !== 'object' || !record || typeof extractActuals !== 'function') return status;
  if (!sameJob(status.filename, record.remoteName)) return status;
  const sliced = slicedForPlate(record.plates, record.plate);
  if (!sliced) return status;
  const actuals = extractActuals('bambu', {}, { sliced });
  if (!actuals || !(actuals.filamentGrams > 0 || actuals.durationS > 0)) return status;
  return { ...status, actuals };
}

const api = { parseSliceInfo, plateToStart, slicedForPlate, sameJob, withSliced, MAX_PLATES };

if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytBambuSliced = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
