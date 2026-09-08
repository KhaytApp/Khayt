'use strict';
(function (global) {

/**
 * What kind of machine this is, and what follows from that.
 *
 * Khayt was written for filament printers and says so everywhere: a machine has
 * a nozzle diameter, an extruder type and a number of colours; its consumable
 * is measured in grams; the thing that wears out is a nozzle. A shop that also
 * runs a resin printer, a UV flatbed or a laser cutter had to pretend all three
 * were FDM printers, and the app told it the laser's nozzle was 0.4 mm.
 *
 * This module is the vocabulary — one place that answers "what does a machine
 * of this kind consume, what wears out on it, and can Khayt ask it anything".
 * It decides nothing about money or stock; it says what each kind IS, so the
 * screens and the rules stop assuming.
 *
 * ── ABSENT IS FDM, AND THAT IS NOT A DEFAULT ──────────────────────────────
 *
 * Every machine in every book that exists today is a filament printer, because
 * until now nothing else could be recorded. So a machine with no `kind` is not
 * "unknown, assume the common case" — it is genuinely an FDM printer, and
 * reading it as one is correct rather than convenient. A book written from here
 * on says which it is.
 *
 * ── WHAT IS DELIBERATELY NOT HERE ─────────────────────────────────────────
 *
 * Units. A resin printer consumes millilitres and a laser consumes sheets, and
 * Khayt's inventory, deduction, waste and reorder rules are all written in
 * grams — `partGramsConsumed`, `gramsPerDay`, `committedByItem`. Teaching those
 * a second unit is a change to how a shop's stock and costs are counted, and it
 * does not belong in the module that names the machines. The unit each kind
 * measures in is recorded here so that work has something to read; nothing
 * consumes it yet, and this module claims nothing about what a job costs.
 */

/** The kinds, in the order a picker should offer them. */
const KINDS = ['fdm', 'resin', 'uv', 'laser', 'cnc'];

const SPEC = {
  fdm: {
    consumable: 'filament', unit: 'g',
    // Grams through it, which is what abrasive filament actually wears.
    wear: [{ part: 'nozzle', unit: 'g' }],
    layered: true,
    // Every protocol in this repo — Klipper, OctoPrint, PrusaLink, Bambu,
    // Duet, Repetier, Snapmaker — talks to a filament printer.
    polled: true,
    // The specs the machine screen may show. A laser has no extruder.
    specs: ['bed', 'nozzleDiameter', 'extruderType', 'maxColors', 'powerDraw'],
  },
  resin: {
    consumable: 'resin', unit: 'ml',
    // Two, and they run on different clocks: the film is counted in prints and
    // the screen in hours lit. A shop that tracks only one gets a ruined print
    // from whichever it was not watching.
    wear: [{ part: 'fep', unit: 'prints' }, { part: 'lcd', unit: 'h' }],
    layered: true,
    // Chitubox-family and Anycubic have APIs; none is implemented here yet, so
    // the honest answer today is no. Saying `true` would make every resin
    // printer look like a broken FDM one.
    polled: false,
    specs: ['bed', 'powerDraw'],
  },
  uv: {
    consumable: 'ink', unit: 'ml',
    wear: [{ part: 'printhead', unit: 'h' }],
    // A flatbed lays one pass over an area; there are no layers to count, so
    // nothing that reads a layer number should be drawn for one.
    layered: false,
    polled: false,
    specs: ['bed', 'powerDraw'],
  },
  laser: {
    consumable: 'sheet', unit: 'sheet',
    wear: [{ part: 'tube', unit: 'h' }, { part: 'lens', unit: 'h' }],
    layered: false,
    polled: false,
    specs: ['bed', 'powerDraw'],
  },
  cnc: {
    consumable: 'stock', unit: 'sheet',
    wear: [{ part: 'bit', unit: 'h' }],
    layered: false,
    polled: false,
    specs: ['bed', 'powerDraw'],
  },
};

/**
 * This machine's kind.
 *
 * Absent, blank, or a word this app does not know all read as `fdm` — see the
 * header. An unknown word is the interesting case: it means a newer Khayt wrote
 * a kind this one has not learned, and drawing that machine as a filament
 * printer is wrong but survivable, while refusing to draw it is not.
 */
function kindOf(machine) {
  const said = String((machine && machine.kind) || '').trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(SPEC, said) ? said : 'fdm';
}

/** Everything known about a kind. Always an object; never null. */
function spec(kind) {
  const k = Object.prototype.hasOwnProperty.call(SPEC, String(kind)) ? String(kind) : 'fdm';
  return SPEC[k];
}

/** What a machine of this kind eats, and in what unit. */
function consumable(kind) {
  const s = spec(kind);
  return { name: s.consumable, unit: s.unit };
}

/** What wears out on it, and what each is measured in. */
function wearParts(kind) { return spec(kind).wear.slice(); }

/**
 * Can Khayt ask a machine of this kind what it is doing?
 *
 * False is not a gap to be apologised for on every screen — it is why a laser
 * cutter must not be drawn as a printer that is failing to answer. The two look
 * identical to a status panel and mean completely different things.
 */
function isPolled(kind) { return !!spec(kind).polled; }

/** Does work on this machine happen in layers? */
function isLayered(kind) { return !!spec(kind).layered; }

/** Whether a given spec row is worth showing for this kind. */
function showsSpec(kind, field) { return spec(kind).specs.indexOf(String(field)) !== -1; }

/**
 * The locale keys a screen needs for a kind, so nothing assembles key names by
 * hand and a missing translation is a test failure rather than a screen reading
 * `mach.kind_laser`.
 */
function keysFor(kind) {
  const k = kindOf({ kind });
  const s = spec(k);
  return {
    name: 'mach.kind_' + k,
    consumable: 'mach.consumes_' + s.consumable,
    unit: 'unit.' + s.unit,
    wear: s.wear.map(w => ({ part: w.part, label: 'mach.wear_' + w.part, unit: 'unit.' + w.unit })),
  };
}

const api = { KINDS, kindOf, spec, consumable, wearParts, isPolled, isLayered, showsSpec, keysFor };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytMachineKinds = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
