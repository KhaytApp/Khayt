'use strict';
// IIFE-wrapped like every other lib/ module the renderer <script>-loads: plain
// script tags share one global scope, so the top-level `const api` below used to
// occupy that name globally. The next module to declare it failed to parse
// entirely with "Identifier 'api' has already been declared", taking its exports
// with it — which is exactly what happened when lib/pricing.js was added.
// Nothing here was renamed; the wrapper is the whole change.
(function () {
/**
 * Target-printer registry for the 3MF converter — the "add more printers" surface.
 * Pure data + lookups, no DOM, so it's shared by the engine (lib/mf-convert.js), the
 * main-process IPC and the renderer UI, and is trivially extended: add an entry here and
 * it appears everywhere.
 *
 * Each profile describes what a converted 3MF needs to target that printer's multicolour
 * system. Values are best-effort defaults the maker can rely on for slot remapping and
 * re-profiling; the converter only rewrites metadata/config members and never touches the
 * mesh, so an imperfect field degrades gracefully (the file still opens; the maker tweaks
 * in their slicer) rather than corrupting geometry.
 *
 *   id           stable key
 *   name         display name
 *   vendor       brand
 *   flavour      the slicer 3MF dialect this printer uses: 'bambu'|'orca'|'prusa'|'generic'
 *   maxColors    physical multicolour slots (AMS / CFS / MMU / toolhead)
 *   bed          build volume {x,y,z} mm
 *   nozzle       default nozzle diameter mm
 *   printerModel vendor printer_model identifier written into project settings
 *   gcodeFlavour target g-code flavour hint
 *   system       name of the multicolour system (for UI copy)
 */
const PROFILES = [
  {
    id: 'snapmaker-u1', name: 'Snapmaker U1', vendor: 'Snapmaker', flavour: 'orca',
    maxColors: 4, bed: { x: 270, y: 270, z: 270 }, nozzle: 0.4,
    // Exact Snapmaker U1 (0.4 nozzle) build volume from Orca's machine profile — a 0.5mm inset origin.
    // Writing this verbatim keeps the plate layout positioned correctly (a 220mm bed misplaced them).
    printableArea: ['0.5x1', '270.5x1', '270.5x271', '0.5x271'], printableHeight: '270.05',
    printerModel: 'Snapmaker U1', printerSettingsId: 'Snapmaker U1 (0.4 nozzle)',
    orcaMachine: 'Snapmaker U1 (0.4 nozzle)', // resolves the native machine+process from the installed slicer
    gcodeFlavour: 'marlin', system: 'U1 4-colour',
    // Mixed-filament ("Full Spectrum") dithering is a Snapmaker U1 hardware feature — keep N physical
    // heads and reproduce extra colours by mixing. Gate the whole feature on this flag, NOT on
    // flavour === 'orca' (single-extruder Orca-family printers like Sovol/QIDI/Creality can't mix).
    supportsMixedFilament: true,
  },
  {
    id: 'bambu-x1c', name: 'Bambu Lab X1 Carbon', vendor: 'Bambu Lab', flavour: 'bambu',
    maxColors: 4, bed: { x: 256, y: 256, z: 256 }, nozzle: 0.4,
    printerModel: 'Bambu Lab X1 Carbon', gcodeFlavour: 'marlin', system: 'AMS',
  },
  {
    id: 'bambu-p1s', name: 'Bambu Lab P1S', vendor: 'Bambu Lab', flavour: 'bambu',
    maxColors: 4, bed: { x: 256, y: 256, z: 256 }, nozzle: 0.4,
    printerModel: 'Bambu Lab P1S', gcodeFlavour: 'marlin', system: 'AMS',
  },
  {
    id: 'bambu-a1', name: 'Bambu Lab A1', vendor: 'Bambu Lab', flavour: 'bambu',
    maxColors: 4, bed: { x: 256, y: 256, z: 256 }, nozzle: 0.4,
    printerModel: 'Bambu Lab A1', gcodeFlavour: 'marlin', system: 'AMS lite',
  },
  {
    id: 'prusa-mk4-mmu3', name: 'Prusa MK4 + MMU3', vendor: 'Prusa Research', flavour: 'prusa',
    maxColors: 5, bed: { x: 250, y: 210, z: 220 }, nozzle: 0.4,
    printerModel: 'MK4IS', gcodeFlavour: 'marlin', system: 'MMU3 5-colour',
  },
  {
    id: 'prusa-xl-5t', name: 'Prusa XL (5 toolheads)', vendor: 'Prusa Research', flavour: 'prusa',
    maxColors: 5, bed: { x: 360, y: 360, z: 360 }, nozzle: 0.4,
    printerModel: 'XL5T', gcodeFlavour: 'marlin', system: '5 toolheads',
  },
  {
    id: 'creality-k2', name: 'Creality K2 Plus', vendor: 'Creality', flavour: 'orca',
    maxColors: 4, bed: { x: 350, y: 350, z: 350 }, nozzle: 0.4,
    printerModel: 'Creality K2 Plus', gcodeFlavour: 'marlin', system: 'CFS',
  },
  {
    id: 'anycubic-kobra-s1', name: 'Anycubic Kobra S1', vendor: 'Anycubic', flavour: 'orca',
    maxColors: 4, bed: { x: 250, y: 250, z: 250 }, nozzle: 0.4,
    printerModel: 'Anycubic Kobra S1', gcodeFlavour: 'marlin', system: 'ACE Pro',
  },
  {
    id: 'anycubic-kobra-3', name: 'Anycubic Kobra 3', vendor: 'Anycubic', flavour: 'orca',
    maxColors: 4, bed: { x: 250, y: 220, z: 260 }, nozzle: 0.4,
    printerModel: 'Anycubic Kobra 3', gcodeFlavour: 'marlin', system: 'ACE',
  },
  {
    id: 'bambu-h2d', name: 'Bambu Lab H2D', vendor: 'Bambu Lab', flavour: 'bambu',
    maxColors: 4, bed: { x: 350, y: 320, z: 325 }, nozzle: 0.4,
    printerModel: 'Bambu Lab H2D', gcodeFlavour: 'marlin', system: 'AMS 2 Pro',
  },
  {
    id: 'bambu-x1e', name: 'Bambu Lab X1E', vendor: 'Bambu Lab', flavour: 'bambu',
    maxColors: 4, bed: { x: 256, y: 256, z: 256 }, nozzle: 0.4,
    printerModel: 'Bambu Lab X1E', gcodeFlavour: 'marlin', system: 'AMS',
  },
  {
    id: 'bambu-a1-mini', name: 'Bambu Lab A1 mini', vendor: 'Bambu Lab', flavour: 'bambu',
    maxColors: 4, bed: { x: 180, y: 180, z: 180 }, nozzle: 0.4,
    printerModel: 'Bambu Lab A1 mini', gcodeFlavour: 'marlin', system: 'AMS lite',
  },
  {
    id: 'prusa-mk4s', name: 'Prusa MK4S', vendor: 'Prusa Research', flavour: 'prusa',
    maxColors: 1, bed: { x: 250, y: 210, z: 220 }, nozzle: 0.4,
    printerModel: 'MK4S', gcodeFlavour: 'marlin', system: 'single',
  },
  {
    id: 'prusa-core-one', name: 'Prusa Core One', vendor: 'Prusa Research', flavour: 'prusa',
    maxColors: 1, bed: { x: 250, y: 220, z: 270 }, nozzle: 0.4,
    printerModel: 'COREONE', gcodeFlavour: 'marlin', system: 'single',
  },
  {
    id: 'prusa-mk3s-mmu2s', name: 'Prusa MK3S+ & MMU2S', vendor: 'Prusa Research', flavour: 'prusa',
    maxColors: 5, bed: { x: 250, y: 210, z: 210 }, nozzle: 0.4,
    printerModel: 'MK3S', gcodeFlavour: 'marlin', system: 'MMU2S 5-colour',
  },
  {
    id: 'creality-k1c', name: 'Creality K1C', vendor: 'Creality', flavour: 'orca',
    maxColors: 1, bed: { x: 220, y: 220, z: 250 }, nozzle: 0.4,
    printerModel: 'Creality K1C', gcodeFlavour: 'marlin', system: 'single',
  },
  {
    id: 'creality-k1-max', name: 'Creality K1 Max', vendor: 'Creality', flavour: 'orca',
    maxColors: 1, bed: { x: 300, y: 300, z: 300 }, nozzle: 0.4,
    printerModel: 'Creality K1 Max', gcodeFlavour: 'marlin', system: 'single',
  },
  {
    id: 'qidi-plus4', name: 'Qidi Plus4', vendor: 'Qidi Tech', flavour: 'orca',
    maxColors: 1, bed: { x: 305, y: 305, z: 280 }, nozzle: 0.4,
    printerModel: 'Qidi Plus4', gcodeFlavour: 'marlin', system: 'single',
  },
  {
    id: 'qidi-xmax3', name: 'Qidi X-Max 3', vendor: 'Qidi Tech', flavour: 'orca',
    maxColors: 1, bed: { x: 325, y: 325, z: 315 }, nozzle: 0.4,
    printerModel: 'Qidi X-Max 3', gcodeFlavour: 'marlin', system: 'single',
  },
  {
    id: 'sovol-sv08', name: 'Sovol SV08', vendor: 'Sovol', flavour: 'orca',
    maxColors: 1, bed: { x: 350, y: 350, z: 345 }, nozzle: 0.4,
    printerModel: 'Sovol SV08', gcodeFlavour: 'marlin', system: 'single',
  },
  {
    id: 'flashforge-ad5m-pro', name: 'FlashForge Adventurer 5M Pro', vendor: 'FlashForge', flavour: 'orca',
    maxColors: 1, bed: { x: 220, y: 220, z: 220 }, nozzle: 0.4,
    printerModel: 'FlashForge Adventurer 5M Pro', gcodeFlavour: 'marlin', system: 'single',
  },
  {
    id: 'elegoo-centauri-carbon', name: 'Elegoo Centauri Carbon', vendor: 'Elegoo', flavour: 'orca',
    maxColors: 1, bed: { x: 256, y: 256, z: 256 }, nozzle: 0.4,
    printerModel: 'Elegoo Centauri Carbon', gcodeFlavour: 'marlin', system: 'single',
  },
];

// A synthetic "target" for the format-normalize mode (strip vendor lock → generic 3MF).
const GENERIC = {
  id: 'generic-3mf', name: 'Generic / any slicer', vendor: '', flavour: 'generic',
  maxColors: 16, bed: null, nozzle: 0.4, printerModel: '', gcodeFlavour: 'marlin', system: 'standard 3MF',
};

function listProfiles() {
  return PROFILES.map((p) => ({ ...p }));
}

function getProfile(id) {
  if (id === GENERIC.id) return { ...GENERIC };
  const p = PROFILES.find((x) => x.id === id);
  return p ? { ...p } : null;
}

const FLAVOURS = ['bambu', 'orca', 'prusa', 'generic'];

// The 3MF config family a flavour uses. Bambu Studio and OrcaSlicer share the same
// project_settings.config JSON dialect, so retargeting between them is coherent;
// PrusaSlicer uses a different text .config. A retarget only makes sense within one
// family — the converter can't turn a Bambu project into a working Prusa one by
// rewriting metadata (the slicer settings differ fundamentally).
function configFamily(flavour) {
  if (flavour === 'bambu' || flavour === 'orca') return 'bbl';
  if (flavour === 'prusa') return 'prusa';
  return 'generic';
}

/**
 * Validate + normalize a user-defined printer into a full profile the engine can use.
 * Returns null if there isn't at least a name. Best-effort: every field is clamped to a
 * safe range so a malformed custom printer degrades gracefully (never corrupts geometry).
 * The `id` is supplied by the caller (renderer uid) so it stays stable across sessions.
 */
function customProfile(spec) {
  if (!spec || typeof spec !== 'object') return null;
  const name = String(spec.name || '').trim().slice(0, 48);
  if (!name) return null;
  const numPos = (v, d) => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : d; };
  const bedIn = spec.bed || {};
  const bx = numPos(bedIn.x, 0), by = numPos(bedIn.y, 0);
  const bed = (bx && by) ? { x: bx, y: by, z: numPos(bedIn.z, Math.max(bx, by)) } : null;
  return {
    id: String(spec.id || '').trim() || ('custom-' + name.toLowerCase().replace(/[^a-z0-9]+/g, '-')).slice(0, 40),
    name,
    vendor: String(spec.vendor || '').trim().slice(0, 32),
    flavour: FLAVOURS.includes(spec.flavour) ? spec.flavour : 'generic',
    maxColors: Math.min(16, Math.max(1, Math.round(numPos(spec.maxColors, 1)))),
    bed,
    nozzle: numPos(spec.nozzle, 0.4),
    printerModel: String(spec.printerModel || spec.name || '').trim().slice(0, 64),
    gcodeFlavour: 'marlin',
    system: String(spec.system || 'custom').trim().slice(0, 32),
    custom: true,
    // Opt-in mixed-filament (Full Spectrum) support, mirroring the built-in U1 profile — without
    // this a user's custom mixing-capable printer could never get Full Spectrum (planFS gates on it).
    ...(spec.supportsMixedFilament ? { supportsMixedFilament: true } : {}),
    // Orca-catalogue printers carry these so the converter can build a native config for them.
    ...(spec.orcaMachine ? { orcaMachine: String(spec.orcaMachine).slice(0, 96) } : {}),
    ...(spec.process ? { process: String(spec.process).slice(0, 96) } : {}),
    ...(spec.printerSettingsId ? { printerSettingsId: String(spec.printerSettingsId).slice(0, 96) } : {}),
    ...(Array.isArray(spec.printableArea) ? { printableArea: spec.printableArea.slice(0, 8).map((s) => String(s).slice(0, 24)) } : {}),
    ...(spec.printableHeight ? { printableHeight: String(spec.printableHeight).slice(0, 12) } : {}),
    ...(spec.fromOrca ? { fromOrca: true } : {}),
  };
}

const api = { PROFILES, GENERIC, FLAVOURS, listProfiles, getProfile, customProfile, configFamily };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytPrinterProfiles = api;

})();
