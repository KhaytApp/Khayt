'use strict';
(function () {

/**
 * How a library file was measured, which engine measures it, and the one
 * rule about prices — pure, shared by every app.
 *
 * ── THREE ENGINES, THE SHOP PICKS ────────────────────────────────────────
 *
 * Settings ▸ Library ▸ "Calculate with" (docs: ~/Khayt-proposals/orca-cli-library-engine.md,
 * approved Nov 16):
 *   builtin             Khayt's own readers (estimates; everywhere)
 *   orca / bambu /      a slicer the shop installed, run on its command line
 *   snapmaker-orca /
 *   prusa
 *   khayt-orca-engine   the separate AGPL helper, when installed
 * Automatic tries orca → bambu → snapmaker-orca → khayt-orca-engine → builtin.
 * PrusaSlicer is NEVER automatic: it reads only Prusa's own project
 * settings, so it would slice a Bambu/Orca project with other settings than
 * the shop saved. Its results say so ("prusa-settings").
 *
 * ── THE STAMP ────────────────────────────────────────────────────────────
 *
 * Every measurement names its engine, version and the profiles it used. A
 * different engine, version or profile set makes it stale, and the file is
 * measured again in the background.
 *
 * ── PRICES ALREADY QUOTED NEVER MOVE ─────────────────────────────────────
 *
 * A measurement feeds NEW quotes and the library's defaults only. A job that
 * was sent as a quote, accepted, or invoiced keeps the price it has, whatever
 * any engine says later (`mayReprice`).
 *
 * ── TWO SLICER HABITS THE ADAPTERS ABSORB (Bambu Studio 02.08, Nov 16) ───
 *
 * 1. A slice can report 0 g for a filament it extruded metres of: the
 *    profile's density was inherited and not resolved. Grams are then worked
 *    out from length × the filament's cross-section × density, and marked
 *    `gramsDerived`, so nothing presents them as the slicer's own.
 * 2. Bambu's G-code says `total filament volume [cm^3]` and carries mm³. It
 *    is never read here: the Bambu adapter reads `result.json`.
 */

const ENGINES = ['builtin', 'orca', 'bambu', 'snapmaker-orca', 'prusa', 'khayt-orca-engine'];
const AUTOMATIC = ['orca', 'bambu', 'snapmaker-orca', 'khayt-orca-engine', 'builtin'];
const DEFAULT_DIAMETER = 1.75;

const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
const pos = (v) => { const n = num(v); return n !== null && n > 0 ? n : null; };
const round = (v, places) => { const f = 10 ** places; return Math.round(v * f) / f; };

/**
 * Which engine measures, given the shop's setting and what is installed.
 * `available`: [{ id, version }] (built-in is always there).
 * → `{ engine, version, auto, fallback }`; `fallback` names a chosen engine
 * that is not installed (the shop is told; built-in measures meanwhile).
 */
function choose(setting, available) {
  const have = new Map([['builtin', { id: 'builtin', version: null }]]);
  for (const a of Array.isArray(available) ? available : []) {
    if (isObj(a) && ENGINES.includes(a.id)) have.set(a.id, a);
  }
  const pick = (id, extra) => ({ engine: id, version: (have.get(id) || {}).version || null, ...extra });
  const wanted = typeof setting === 'string' && setting ? setting : 'auto';
  if (wanted === 'auto' || !ENGINES.includes(wanted)) {
    const id = AUTOMATIC.find((e) => have.has(e));
    return pick(id, { auto: true, fallback: null });
  }
  if (have.has(wanted)) return pick(wanted, { auto: false, fallback: null });
  return pick('builtin', { auto: false, fallback: wanted });
}

/** Grams from a length of filament: mm × π(d/2)² mm² → mm³ → cm³ × g/cm³. */
function gramsFromLength(mm, density, diameter) {
  const l = pos(mm), d = pos(density);
  if (l === null || d === null) return null;
  const r = (pos(diameter) || DEFAULT_DIAMETER) / 2;
  return round((l * Math.PI * r * r / 1000) * d, 2);
}

/**
 * One slot as kept: the slicer's grams, or — when it said 0 (or nothing) for
 * a length it extruded — grams from that length, marked derived.
 * `material`: { density, diameter } of the filament in that slot, when known.
 */
function slotFigures(slot, grams, mm, material) {
  const g = pos(grams), l = pos(mm);
  const out = { slot, grams: g, mm: l, gramsDerived: false };
  if (g === null && l !== null) {
    const m = isObj(material) ? material : {};
    const derived = gramsFromLength(l, m.density, m.diameter);
    if (derived !== null) { out.grams = derived; out.gramsDerived = true; }
  }
  return out;
}

/**
 * Bambu Studio's `result.json` (verified on 02.08.02.61) → plates.
 * `materials`: { [slot]: { density, diameter } } from the profiles used.
 * Bambu's result gives grams per filament but not their length; the length
 * comes from the G-code's own `total filament length [mm]`, passed in as
 * `lengths` ({ [plateIndex]: [mm per slot] }) — never its volume line.
 */
function fromBambuResult(result, opts) {
  const o = isObj(opts) ? opts : {};
  if (!isObj(result) || result.return_code !== 0 || !Array.isArray(result.sliced_plates)) {
    return { ok: false, reason: isObj(result) && typeof result.error_string === 'string' ? result.error_string : 'no-result' };
  }
  const plates = result.sliced_plates.filter(isObj).map((p) => {
    const index = Number.isInteger(p.id) ? p.id : null;
    const lengths = isObj(o.lengths) && Array.isArray(o.lengths[index]) ? o.lengths[index] : [];
    const slots = (Array.isArray(p.filaments) ? p.filaments : []).filter(isObj).map((f) => {
      const slot = Number.isInteger(f.id) ? f.id : null;
      return slotFigures(slot, f.total_used_g, lengths[slot - 1], isObj(o.materials) ? o.materials[slot] : null);
    }).filter((s) => s.slot !== null && (s.grams !== null || s.mm !== null));
    const warning = typeof p.warning_message === 'string' && p.warning_message.trim() ? [p.warning_message.trim()] : [];
    return {
      index,
      timeSec: pos(p.total_predication) !== null ? Math.round(p.total_predication) : null,
      changes: Number.isInteger(p.filament_change_times) ? p.filament_change_times : null,
      slots,
      warnings: warning,
    };
  });
  return { ok: true, plates };
}

/**
 * A G-code's own summary, as `lib/gcode-parse.js parseFilaments` read it
 * (Snapmaker Orca, PrusaSlicer) → one plate. The volume never enters: a
 * length and a density are what grams are derived from.
 */
function fromGcodeSummary(filaments, timeMins, changes, opts) {
  const o = isObj(opts) ? opts : {};
  const slots = (Array.isArray(filaments) ? filaments : []).filter(isObj).map((f) =>
    slotFigures(f.slot, f.grams, f.mm, isObj(o.materials) && o.materials[f.slot]
      ? o.materials[f.slot] : { density: f.density, diameter: null }))
    .filter((s) => Number.isInteger(s.slot) && (s.grams !== null || s.mm !== null));
  return {
    ok: true,
    plates: [{ index: 1, timeSec: pos(timeMins) !== null ? Math.round(timeMins * 60) : null,
      changes: Number.isInteger(changes) ? changes : null, slots, warnings: [] }],
  };
}

/**
 * The record kept on a library file. `profiles`: names only (machine,
 * process, filaments). `figures`: an adapter's `{ plates }`.
 */
function stamp(input) {
  const i = isObj(input) ? input : {};
  const engine = ENGINES.includes(i.engine) ? i.engine : 'builtin';
  const p = isObj(i.profiles) ? i.profiles : {};
  const text = (v) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, 120) : null);
  return {
    v: 1,
    engine,
    version: text(i.version),
    profiles: {
      machine: text(p.machine), process: text(p.process),
      filaments: Array.isArray(p.filaments) ? p.filaments.map(text) : [],
    },
    // PrusaSlicer slices with its own settings, not the project's: said, always.
    prusaSettings: engine === 'prusa',
    at: text(i.at),
    plates: isObj(i.figures) && Array.isArray(i.figures.plates) ? i.figures.plates : [],
  };
}

/** Measured again? Yes when the engine, its version or the profiles differ. */
function isStale(measurement, current) {
  if (!isObj(measurement)) return true;
  const c = stamp(current);
  return measurement.engine !== c.engine || measurement.version !== c.version
    || JSON.stringify(measurement.profiles || null) !== JSON.stringify(c.profiles);
}

/**
 * May a measurement set this job's price? Only a quote that has not been
 * sent, and never once invoiced. Everything else keeps its price.
 */
function mayReprice(order) {
  if (!isObj(order)) return false;
  if (order.invoiceNumber || order.invoiceNo || order.invoicedAt) return false;
  if (order.status !== 'quote') return false;
  return !order.quoteSentAt;
}

const api = {
  ENGINES, AUTOMATIC, choose, gramsFromLength, slotFigures, fromBambuResult, fromGcodeSummary,
  stamp, isStale, mayReprice,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytLibraryMeasure = api;
})();
