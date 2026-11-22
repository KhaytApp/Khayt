'use strict';
/**
 * Reads the filament preset database from an installed Snapmaker Orca / OrcaSlicer so the converter can
 * offer the maker the SAME filament list their slicer has — and write real preset names into a converted
 * U1 file (instead of the source's foreign "@BBL X1C" presets that Orca flags as customized).
 *
 * Orca stores system presets as JSON under <app>/resources/profiles/<Vendor>/filament/*.json, each with
 * an `inherits` chain. We only need the display name + filament_type, so a shallow inherit walk suffices.
 * Main-process only (filesystem). Returns empty when no slicer is found — callers fall back to "Generic".
 */
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');

// Candidate "profiles" roots for a Snapmaker-Orca-family slicer, most specific first.
function profileRoots() {
  const home = os.homedir();
  const roots = [];
  const add = (p) => { if (p) roots.push(p); };
  if (process.platform === 'darwin') {
    for (const base of ['/Applications', path.join(home, 'Applications')]) {
      for (const app of ['Snapmaker Orca.app', 'OrcaSlicer.app']) {
        add(path.join(base, app, 'Contents', 'Resources', 'profiles'));
      }
    }
  } else if (process.platform === 'win32') {
    const pf = process.env['ProgramFiles'] || 'C:\\Program Files';
    const lad = process.env['LOCALAPPDATA'] || path.join(home, 'AppData', 'Local');
    for (const root of [pf, lad, path.join(lad, 'Programs')]) {
      for (const app of ['Snapmaker Orca', 'OrcaSlicer']) add(path.join(root, app, 'resources', 'profiles'));
    }
  } else {
    for (const d of ['/usr/share', '/opt', path.join(home, '.local', 'share')]) {
      for (const app of ['SnapmakerOrca', 'OrcaSlicer', 'orca-slicer']) add(path.join(d, app, 'resources', 'profiles'));
    }
  }
  return roots.filter((p) => { try { return fs.statSync(p).isDirectory(); } catch (_) { return false; } });
}

let _cache = null; // memo for a session; cleared by refresh()

// All installed slicer profile roots (Snapmaker Orca + upstream OrcaSlicer). Unioning them gives the
// most comprehensive DB — OrcaSlicer ("the original") ships far more generic/vendor filaments, while
// Snapmaker Orca carries the authoritative U1 machine/process profile. Snapmaker Orca is ordered first
// so on a name clash its (vendor-correct) preset wins; OrcaSlicer still contributes everything unique.
function allRoots() {
  if (_cache) return _cache.roots;
  const roots = profileRoots();
  roots.sort((a, b) => (/Snapmaker/i.test(a) ? 0 : 1) - (/Snapmaker/i.test(b) ? 0 : 1));
  _cache = { roots, filaments: null, machines: null };
  return roots;
}
function activeRoot() { return allRoots()[0] || null; }

// A preset / inherits name must be a bare file stem — reject path separators and traversal so a
// crafted `inherits: "../../../../etc/whatever"` in an on-disk profile can't read outside the
// profiles tree. Also drop prototype-polluting keys when merging untrusted profile JSON.
function isSafePresetName(name) {
  const s = String(name || '');
  return !!s && !/[\\/]/.test(s) && !s.split(/[\\/]/).includes('..') && !/\.\./.test(s);
}
const PROTO_KEYS = new Set(['__proto__', 'constructor', 'prototype']);

/** Read a filament preset json + resolve its filament_type through the (shallow) inherits chain. */
function readFilamentType(dir, name, seen) {
  seen = seen || new Set();
  if (seen.has(name) || seen.size > 6 || !isSafePresetName(name)) return null;
  seen.add(name);
  let j;
  try { j = JSON.parse(fs.readFileSync(path.join(dir, name + '.json'), 'utf8')); } catch (_) { return null; }
  const ft = Array.isArray(j.filament_type) ? j.filament_type[0] : j.filament_type;
  if (ft) return String(ft);
  return j.inherits ? readFilamentType(dir, String(j.inherits), seen) : null;
}

/**
 * Every U1-compatible filament preset the installed slicer ships: [{ name, type }], de-duped, sorted.
 * "U1-compatible" = the preset name carries the "@U1" tag (how Orca scopes a preset to the U1) and isn't
 * an internal base template. Empty array when no slicer/profiles are found.
 */
function listU1Filaments() {
  if (!allRoots().length) return [];
  if (_cache.filaments) return _cache.filaments;
  const out = [];
  const seenNames = new Set();
  for (const root of allRoots()) {
    let vendors = [];
    try { vendors = fs.readdirSync(root); } catch (_) { continue; }
    for (const vendor of vendors) {
      const dir = path.join(root, vendor, 'filament');
      let files = [];
      try { files = fs.readdirSync(dir); } catch (_) { continue; }
      for (const f of files) {
        if (!/\.json$/i.test(f)) continue;
        const name = f.replace(/\.json$/i, '');
        if (!/@U1\b/i.test(name)) continue;          // scoped to the U1
        if (/\bbase\d*\b/i.test(name)) continue;      // internal base/base2 template, not user-selectable
        if (/\b0\.[0-9]+\s*nozzle/i.test(name) && !/\b0\.4\s*nozzle/i.test(name)) continue; // keep 0.4 (default) only
        if (seenNames.has(name)) continue;
        const type = readFilamentType(dir, name) || 'PLA';
        seenNames.add(name);
        out.push({ name, type });
      }
    }
  }
  out.sort((a, b) => a.name.localeCompare(b.name));
  _cache.filaments = out;
  return out;
}

// Meta keys that describe the preset itself (not print settings) — dropped from a resolved merge.
const META_KEYS = new Set(['type', 'name', 'from', 'instantiation', 'inherits', 'setting_id',
  'filament_id', 'version', 'is_custom_defined', 'filament_settings_id']);

/** Locate a preset json across every root + vendor dir for a given kind (machine/process/filament). */
function findPresetFile(kind, name) {
  if (!isSafePresetName(name)) return null;
  for (const root of allRoots()) {
    let vendors = [];
    try { vendors = fs.readdirSync(root); } catch (_) { continue; }
    for (const v of vendors) {
      const p = path.join(root, v, kind, name + '.json');
      try { if (fs.statSync(p).isFile()) return p; } catch (_) { /* keep looking */ }
    }
  }
  return null;
}

/** Resolve a preset's full settings by merging its `inherits` chain (root-first, child wins). */
function resolvePreset(kind, name, seen) {
  seen = seen || new Set();
  if (seen.has(name) || seen.size > 12) return {};
  seen.add(name);
  const file = findPresetFile(kind, name);
  if (!file) return {};
  let j;
  try { j = JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return {}; }
  const parent = j.inherits ? resolvePreset(kind, String(j.inherits), seen) : {};
  const out = Object.assign({}, parent);
  for (const k of Object.keys(j)) { if (!META_KEYS.has(k) && !PROTO_KEYS.has(k)) out[k] = j[k]; }
  return out;
}

/** Resolved settings for a named machine preset, or {} if not found. */
function machineSettings(name) { return name ? resolvePreset('machine', name) : {}; }

/** Bed size {x,y,z} from a resolved printable_area/height, or null. */
function bedFromArea(area, height) {
  if (!Array.isArray(area) || !area.length) return null;
  let x = 0, y = 0;
  for (const s of area) { const p = String(s).split('x').map(Number); if (p.length === 2 && isFinite(p[0]) && isFinite(p[1])) { x = Math.max(x, p[0]); y = Math.max(y, p[1]); } }
  return x && y ? { x: Math.round(x), y: Math.round(y), z: Math.round(Number(height) || Math.max(x, y)) } : null;
}

/**
 * Every selectable machine preset across the installed slicers: [{ name, vendor }] — just names, so it's
 * instant (2000+ printers). Resolve one with machineInfo() when the maker actually picks it.
 */
function listMachines() {
  if (!allRoots().length) return [];
  if (_cache.machines) return _cache.machines;
  const out = [];
  const seen = new Set();
  for (const root of allRoots()) {
    let vendors = [];
    try { vendors = fs.readdirSync(root); } catch (_) { continue; }
    for (const vendor of vendors) {
      const dir = path.join(root, vendor, 'machine');
      let files = [];
      try { files = fs.readdirSync(dir); } catch (_) { continue; }
      for (const f of files) {
        if (!/\.json$/i.test(f) || /^fdm_/i.test(f)) continue; // skip base templates
        const name = f.replace(/\.json$/i, '');
        if (seen.has(name)) continue;
        seen.add(name);
        out.push({ name, vendor });
      }
    }
  }
  out.sort((a, b) => a.vendor.localeCompare(b.vendor) || a.name.localeCompare(b.name));
  _cache.machines = out;
  return out;
}

/** Resolved summary for one machine: bed, nozzle, colour slots, default process, gcode flavour. */
function machineInfo(name) {
  const m = machineSettings(name);
  if (!Object.keys(m).length) return null;
  const nozzles = Array.isArray(m.nozzle_diameter) ? m.nozzle_diameter : (m.nozzle_diameter ? [m.nozzle_diameter] : ['0.4']);
  return {
    name,
    printerModel: m.printer_model || name,
    bed: bedFromArea(m.printable_area, m.printable_height),
    printableArea: Array.isArray(m.printable_area) ? m.printable_area.slice() : null,
    printableHeight: m.printable_height != null ? String(m.printable_height) : null,
    nozzle: Number(nozzles[0]) || 0.4,
    colors: Math.max(1, nozzles.length),
    gcodeFlavor: m.gcode_flavor || null,
    defaultProcess: m.default_print_profile || null,
  };
}

/** Print/process presets scoped to a machine: [{ name, layer }], sorted. Presets share the machine's
 *  "@<tag>" suffix — derived from its default_print_profile (vendors use short tags like "@BBL X1C"). */
function listProcessesFor(machineName) {
  if (!allRoots().length || !machineName) return [];
  const info = machineInfo(machineName);
  const dp = info && info.defaultProcess;
  const at = dp ? dp.indexOf('@') : -1;
  const tag = at >= 0 ? dp.slice(at) : '@' + machineName;
  const out = [];
  const seen = new Set();
  for (const root of allRoots()) {
    let vendors = [];
    try { vendors = fs.readdirSync(root); } catch (_) { continue; }
    for (const vendor of vendors) {
      const dir = path.join(root, vendor, 'process');
      let files = [];
      try { files = fs.readdirSync(dir); } catch (_) { continue; }
      for (const f of files) {
        if (!/\.json$/i.test(f)) continue;
        const name = f.replace(/\.json$/i, '');
        if (name.indexOf(tag) < 0) continue;              // scoped to this machine
        if (/_old\b/i.test(name) || /^fdm_/i.test(name)) continue;
        if (seen.has(name)) continue;
        seen.add(name);
        out.push({ name, layer: String(resolvePreset('process', name).layer_height || '') });
      }
    }
  }
  out.sort((a, b) => (parseFloat(a.layer) || 9) - (parseFloat(b.layer) || 9) || a.name.localeCompare(b.name));
  return out;
}

/** Default process for a machine — its declared default_print_profile, else 0.20 Standard, else first. */
function defaultProcessFor(machineName) {
  const info = machineInfo(machineName);
  if (info && info.defaultProcess) return info.defaultProcess;
  const list = listProcessesFor(machineName);
  return ((list.find((p) => /0\.20 Standard/i.test(p.name)) || list[0] || {}).name) || null;
}

// ---- U1 back-compat wrappers (the converter's Full Spectrum + filament picker are U1-focused) ----
function u1MachineSettings() { return machineSettings('Snapmaker U1 (0.4 nozzle)'); }
function listU1Processes() { return listProcessesFor('Snapmaker U1 (0.4 nozzle)'); }
function defaultU1Process() { return defaultProcessFor('Snapmaker U1 (0.4 nozzle)'); }
function u1ProcessSettings(name) { return name ? resolvePreset('process', name) : {}; }

/** True when a Snapmaker-Orca-family filament DB was found on this machine. */
function available() { return !!activeRoot(); }

/** Drop the memo (e.g. after the user installs/updates their slicer). */
function refresh() { _cache = null; }

module.exports = {
  listU1Filaments, available, refresh, profileRoots,
  u1MachineSettings, listU1Processes, defaultU1Process, u1ProcessSettings, resolvePreset,
  listMachines, machineInfo, machineSettings, listProcessesFor, defaultProcessFor,
};
