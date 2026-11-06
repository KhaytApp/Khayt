'use strict';

/**
 * Calibration → tuned OrcaSlicer filament profile (main-process, Bed Ready).
 *
 * OrcaSlicer's own calibration suite writes results back to NOTHING — every measured value (temp, flow
 * ratio, pressure advance, retraction, max volumetric speed) is eyeballed and hand-typed into filament
 * settings. This closes that loop: it takes one of the user's EXISTING filament presets as the base
 * (so the `inherits` chain and all other fields stay valid), applies the measured overrides, and writes
 * a new tuned preset straight into the slicer's user filament folder — the same place lib/orca-filament-
 * install.js installs into, reusing its slicer detection / version / filename machinery. Node-only.
 */
const fs = require('fs');
const path = require('path');
const orca = require('./orca-filament-install');
const P = require('./orca-presets');

// The rules (what a measurement becomes, what a preset lists as) are lib/orca-presets.js, shared
// with the native Mac app; this is the Node file-system half.
const { overridesFromValues } = P;

/** The user's own filament presets for a detected slicer — the bases you can tune from. */
function listUserFilaments(slicer) {
  let ents = [];
  try { ents = fs.readdirSync(slicer.filamentDir, { withFileTypes: true }); } catch { return []; }
  const out = [];
  for (const e of ents) {
    if (!e.isFile() || !e.name.endsWith('.json')) continue;
    let j = null;
    try { j = JSON.parse(fs.readFileSync(path.join(slicer.filamentDir, e.name), 'utf8')); } catch { j = null; }
    const f = P.userFilament(j, e.name);
    if (f) out.push(f);
  }
  return out.sort((a, b) => a.name.localeCompare(b.name));
}

/** Detected slicers we can save into, each with its printers + user filament presets. */
function calibrationTargets() {
  return orca.detectSlicers().map((s) => ({
    id: s.id, label: s.label,
    printers: orca.listPrinters(s),
    filaments: listUserFilaments(s),
  }));
}

/**
 * Write a tuned filament preset derived from a base user preset. `baseFile` is a bare filename from
 * listUserFilaments (path.basename confines it to the filament dir — no traversal). Throws with a
 * user-facing message on any problem.
 */
function saveCalibratedProfile({ slicerId, baseFile, printerLabel, name, values } = {}) {
  const slicers = orca.detectSlicers();
  const slicer = slicers.find((s) => s.id === slicerId) || slicers[0];
  if (!slicer) throw new Error('No supported slicer detected.');
  if (!baseFile) throw new Error('Pick a base filament to tune.');

  const basePath = path.join(slicer.filamentDir, path.basename(String(baseFile)));
  let preset;
  try { preset = JSON.parse(fs.readFileSync(basePath, 'utf8')); } catch { throw new Error('Could not read the base filament.'); }
  const printer = orca.listPrinters(slicer).find((p) => p.label === printerLabel);
  const tuned = P.tunedPreset(preset, values, name, printer, orca.resolveVersion(slicer));
  const newName = tuned.name;

  fs.mkdirSync(slicer.filamentDir, { recursive: true });
  const out = path.join(slicer.filamentDir, orca.safeFileBase(newName) + '.json');
  const tmp = out + '.tmp';
  fs.writeFileSync(tmp, P.presetText(preset), 'utf8');
  fs.renameSync(tmp, out);
  return { ok: true, path: out, slicer: slicer.label, name: newName, applied: tuned.applied };
}

module.exports = { calibrationTargets, saveCalibratedProfile, overridesFromValues, listUserFilaments };
