'use strict';

(function (global) {
/**
 * Repetier-Server — the job is on a different API call than the machine state,
 * and Khayt was asking only one of them.
 *
 * THE SHAPE OF THE MISTAKE, WHICH THIS FILE EXISTS TO STOP REPEATING
 *
 * `?a=stateList` answers, for every printer the server knows, the state of the
 * MACHINE: temperatures, the active extruder, the current layer, where the head
 * is, whether the fans are on. `?a=listPrinter` answers, for every printer, the
 * state of the JOB: how far through it is, what it is called, whether it is
 * paused, how many lines have been sent.
 *
 * Khayt read `done` (progress) and `job` (filename) off `stateList`, where
 * neither field exists. Reading an absent field is `undefined`, `undefined`
 * normalises to 0, and an empty filename made the adapter call the machine Idle
 * — so every Repetier printer reported **Idle, 0%, no job**, whatever it was
 * actually doing, and never threw.
 *
 * That is the same sentence the 2026-08-25 audit wrote about this adapter, and
 * that audit's fix was real but addressed a DIFFERENT cause of it: `stateList`
 * was being indexed as an array (`data.data[0]`) when it is an object keyed by
 * printer slug, so the state object was always `{}`. Fixing that recovered the
 * temperatures — which really are on `stateList` — and left progress and the
 * filename reading 0 and "", because they were never on that call to begin
 * with. A symptom with two causes, one fixed, and the fix looked complete
 * because the symptom had a name and the name had been crossed off.
 *
 * WHERE EACH FIELD LIVES, WITH THE SOURCE
 *
 *   stateList    activeExtruder, extruder[], heatedBeds[], heatedChambers[],
 *                layer, x/y/z, fans, speedMultiply, flowMultiply, firmware,
 *                sdcardMounted, powerOn, doorOpen
 *   listPrinter  done, job, jobid, jobstate, paused, pauseState, online,
 *                printStart, printTime, printedTimeComp, start, totalLines,
 *                linesSend, ofLayer, analysed, slug, name, active
 *
 * Repetier's own API reference lists the `stateList` fields and they contain no
 * `done` and no `job`; RepetierSharp — a typed C# client for this server, whose
 * `PrinterState` model matches that list field for field — puts `done` and
 * `job` on its `Printer` model, which is what `listPrinter` returns. Home
 * Assistant's `repetier` component reads progress from its own "current job"
 * group and publishes it as a PERCENTAGE rounded to two decimals, which is what
 * settles `done` as 0-100 rather than a 0-1 fraction.
 *
 * TWO ATTESTED SHAPES FOR `job`, AND NO SERVER HERE TO PICK ONE
 *
 * Repetier documents the printer listing's `job` as a STATE — one of
 * `none | paused | printing | waitstart` — while RepetierSharp types it as a
 * string alongside a separate `jobstate`, i.e. as the job's NAME. Both are
 * attested and there is no Repetier-Server on this bench to settle which
 * version answers which, so this treats the four state words as a state and
 * anything else as a filename. Betting on one shape would put the literal word
 * "printing" in a shop's queue as though it were a file.
 *
 * DELIBERATELY NOT REPORTED: time remaining, and actuals
 *
 * `printTime` and `printedTimeComp` are right there and are not used, because
 * what they MEAN is not documented anywhere this audit could find — RepetierSharp
 * annotates `printedTimeComp` with a literal question mark. Total-versus-elapsed
 * and compensated-versus-wall-clock are exactly the distinctions that made
 * OctoPrint's `job.filament` an estimate wearing a measurement's clothes. A
 * missing ETA is honest; a guessed one is not. See docs/PRINTER-PROTOCOL-AUDIT.md.
 *
 * Pure — takes two payloads a poller already has and returns the common status
 * shape. No fetch, no clock.
 */

/** The words Repetier documents in `job` that are a state, not a filename. */
const JOB_STATE_WORDS = new Set(['none', 'paused', 'printing', 'waitstart']);

/**
 * A number, or null — and null is NOT zero.
 *
 * `Number(null)` is 0 and `Number('')` is 0, both finite, so the obvious
 * one-liner turns "this machine has no heated bed" and "the server sent no
 * temperatures" into a bed sitting at 0 °C. That is a reading a shop can act on,
 * about a heater that does not exist. Absent has to stay absent.
 */
const num = (v) => {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
};

/**
 * Find one printer's entry in a `listPrinter` payload.
 *
 * `stateList` is an object keyed by slug; the printer listing is documented as
 * an ARRAY of printer objects. Both are handled rather than assumed, because
 * assuming the wrong one of exactly these two shapes is what this whole file is
 * about — and a server that answers the other way would silently return to
 * reporting 0%.
 */
function printerEntry(listData, slug) {
  const data = listData && typeof listData === 'object' ? (listData.data ?? listData) : null;
  if (!data || typeof data !== 'object') return {};
  const entries = Array.isArray(data)
    ? data
    : (Array.isArray(data.printers) ? data.printers : Object.values(data));
  const wanted = String(slug || '');
  const bySlug = entries.find((p) => p && typeof p === 'object' && String(p.slug || '') === wanted);
  // Falling back to the only entry matters: `printerSlug` is optional in the
  // machine dialog and defaults to "default", which is a slug most servers do
  // not use. One printer and one entry is not ambiguous.
  if (bySlug) return bySlug;
  const usable = entries.filter((p) => p && typeof p === 'object');
  return usable.length === 1 ? usable[0] : {};
}

/** The machine state, from a `stateList` payload keyed by slug. */
function machineState(stateData, slug) {
  const data = stateData && typeof stateData === 'object' ? (stateData.data ?? stateData) : null;
  const byName = data && typeof data === 'object' && !Array.isArray(data) ? data : {};
  const wanted = String(slug || '');
  if (byName[wanted]) return byName[wanted];
  const values = Object.values(byName).filter((v) => v && typeof v === 'object');
  return values.length === 1 ? values[0] : (values[0] || {});
}

/**
 * The bed, across the spellings this server has used.
 *
 * `heatedBeds` (a list) is the one RepetierSharp models and the one Home
 * Assistant's client reads; `heatedBed` (a single object) is what the vendor's
 * own API example shows. Khayt used to read `heated_bed`, which is neither.
 */
function repetierBed(state) {
  return state.heatedBed
    || (Array.isArray(state.heatedBeds) ? state.heatedBeds[0] : null)
    || (Array.isArray(state.heatedbeds) ? state.heatedbeds[0] : null)
    || state.heated_bed
    || null;
}

/**
 * Build the common status shape from both calls.
 *
 * @param {object}   args.stateData  the `?a=stateList` payload
 * @param {object}   args.listData   the `?a=listPrinter` payload (may be null —
 *                                   see the caller: losing the job must not cost
 *                                   the temperatures)
 * @param {string}   args.slug       the configured printer slug
 * @param {function} args.normalizeProgress  shared 0-100 clamp
 */
function repetierStatus({ stateData, listData, slug, normalizeProgress }) {
  const state = machineState(stateData, slug) || {};
  const entry = printerEntry(listData, slug) || {};

  // `job` is a filename only when it is not one of the documented state words.
  const rawJob = typeof entry.job === 'string' ? entry.job : '';
  const jobWord = rawJob.toLowerCase();
  const isStateWord = JOB_STATE_WORDS.has(jobWord);
  const filename = rawJob && !isStateWord ? rawJob : '';

  // A job exists if it has a name, or if the state word says one is running.
  const paused = entry.paused === true || jobWord === 'paused' || num(entry.pauseState) > 0;
  const running = !!filename || jobWord === 'printing' || jobWord === 'waitstart';

  let label;
  if (Number(entry.online) === 0) label = 'Offline';
  else if (paused) label = 'Paused';
  else if (jobWord === 'waitstart') label = 'Preparing';
  else if (running) label = 'Printing';
  else label = 'Idle';

  const nozzles = Array.isArray(state.extruder) ? state.extruder : [];
  const activeIdx = Number.isInteger(state.activeExtruder) ? state.activeExtruder : 0;
  const nozzle = nozzles[activeIdx] || nozzles[0] || null;
  const bed = repetierBed(state);

  return {
    state: label,
    progress: normalizeProgress(entry.done),
    filename,
    // Not derived from printTime/printedTimeComp — see the header.
    timeRemaining: null,
    tempNozzle: num(nozzle && nozzle.tempRead),
    tempBed: num(bed && bed.tempRead),
    type: 'repetier',
  };
}

const api = { repetierStatus, printerEntry, machineState, repetierBed, JOB_STATE_WORDS };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytRepetier = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
