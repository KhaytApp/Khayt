'use strict';
/**
 * The rules behind installing and tuning Orca-family filament presets, with no file system.
 *
 * lib/orca-filament-install.js (install a library profile) and lib/calibration-profile.js (save a
 * tuned one) both walk a slicer's config folder with `fs` and then decide things about what they
 * found: which printers it has, which preset version to stamp, what a preset's file is called,
 * what a measured value becomes. Those decisions are here, so the native Mac app — which walks the
 * folder in Swift, because JavaScriptCore has no `fs` — reaches the same answers from the same code.
 *
 * Pure: no require, no Buffer, no process. Loaded by Node and by JavaScriptCore.
 */
(function (global) {
  /**
   * Known Orca/Bambu-family slicers, by their config-dir name(s) under the per-OS config base. All share
   * the same JSON preset format + a user/ + system/ layout. `version` is a fallback stamp for a fork that
   * REQUIRES a specific config version on user presets (Snapmaker Orca drops unversioned ones); most
   * slicers use no filament version, so we normally read it from the target's own presets and this is unset.
   */
  const SLICERS = [
    { id: 'orcaslicer', label: 'OrcaSlicer', dirs: ['OrcaSlicer'] },
    { id: 'snapmaker', label: 'Snapmaker Orca', dirs: ['Snapmaker_Orca', 'SnapmakerOrca', 'Snapmaker Orca'], version: '02.03.01.10' },
    { id: 'bambustudio', label: 'Bambu Studio', dirs: ['BambuStudio', 'Bambu Studio'] },
    { id: 'crealityprint', label: 'Creality Print', dirs: ['Creality Print', 'CrealityPrint'] },
    { id: 'elegooslicer', label: 'Elegoo Slicer', dirs: ['ElegooSlicer', 'ELEGOO Slicer'] },
    { id: 'qidistudio', label: 'QIDI Studio', dirs: ['QIDIStudio'] },
    { id: 'sovolslicer', label: 'Sovol Slicer', dirs: ['SovolSlicer', 'Sovol Slicer'] },
    { id: 'anycubicnext', label: 'Anycubic Slicer Next', dirs: ['AnycubicSlicerNext', 'Anycubic Slicer Next'] },
  ];

  /** Which user profile folder holds the presets: "default" when it exists, else the first non-backup. */
  function userProfileName(subdirs, hasDefault) {
    if (hasDefault) return 'default';
    const subs = Array.isArray(subdirs) ? subdirs : [];
    return subs.find((n) => !/backup/i.test(n)) || subs[0] || 'default';
  }

  // Fold nozzle-size variants together: handles both "Printer 0.4 nozzle" and "Printer (0.4 nozzle)".
  const stripNozzle = (n) => n.replace(/\s*\(?\s*0\.\d+\s*nozzle\s*\)?\s*$/i, '').trim();

  /**
   * Machine preset names (file basenames without .json, in walk order) → the printers a slicer
   * supports, grouped by base name with nozzle variants folded together. [{ label, machines }] sorted.
   */
  function groupPrinters(machineNames) {
    const groups = new Map();
    for (const name of machineNames || []) {
      if (/^fdm_/i.test(name) || /^My[A-Z]/.test(name)) continue; // internal bases + generic templates (MyKlipper, MyMarlin…), not real printers
      const label = stripNozzle(name);
      if (!label) continue;
      if (!groups.has(label)) groups.set(label, []);
      groups.get(label).push(name);
    }
    return [...groups.entries()]
      .map(([label, machines]) => ({ label, machines: machines.sort() }))
      .sort((a, b) => a.label.localeCompare(b.label));
  }

  /** The printer an install goes to when none was chosen: the U1, else the first. */
  function defaultPrinter(printers) {
    const list = printers || [];
    return list.find((p) => /snapmaker u1/i.test(p.label)) || list[0] || null;
  }

  /** The config version to stamp: the most common among the slicer's own user presets → fallback → none. */
  function pickVersion(versions, fallback) {
    const counts = new Map();
    for (const v of versions || []) if (typeof v === 'string' && v) counts.set(v, (counts.get(v) || 0) + 1);
    if (counts.size) return [...counts.entries()].sort((a, b) => b[1] - a[1])[0][0];
    return fallback || null;
  }

  /** Turn a preset name into a safe, single-segment filename base. */
  function safeFileBase(name) {
    return String(name || 'filament').replace(/[\\/:*?"<>|]+/g, '-').replace(/\s+/g, ' ').replace(/^[.\s]+|[.\s]+$/g, '').slice(0, 120) || 'filament';
  }

  /** A library item's file reference is one of the served profiles, nothing else. */
  function validProfileRef(file) {
    return /^profiles\/[A-Za-z0-9._-]+\.json$/.test(String(file || ''));
  }

  /** Retarget a fetched preset: this printer's machine names + this slicer's preset version. */
  function retarget(preset, printer, version) {
    preset.compatible_printers = printer.machines.slice();
    if (version) preset.version = version; else delete preset.version;
    return preset;
  }

  /** Map measured calibration inputs → OrcaSlicer filament keys (each a one-element string array). */
  function overridesFromValues(values) {
    const v = values || {};
    const out = {};
    const num = (x) => (x != null && x !== '' && isFinite(Number(x)) ? String(Number(x)) : null);
    const temp = num(v.nozzleTemp);
    if (temp != null) { out.nozzle_temperature = [temp]; out.nozzle_temperature_initial_layer = [temp]; }
    const flow = num(v.flowRatio);
    if (flow != null) out.filament_flow_ratio = [flow];
    const pa = num(v.pressureAdvance);
    if (pa != null) { out.pressure_advance = [pa]; out.enable_pressure_advance = ['1']; }
    const ret = num(v.retractionLength);
    if (ret != null) out.filament_retraction_length = [ret];
    const mvs = num(v.maxVolSpeed);
    if (mvs != null) out.filament_max_volumetric_speed = [mvs];
    const bed = num(v.bedTemp);
    if (bed != null) { out.hot_plate_temp = [bed]; out.hot_plate_temp_initial_layer = [bed]; }
    return out;
  }

  /** First array element (Orca stores most filament values as one-element arrays), else the raw value. */
  function readVal(j, key) {
    const v = j[key];
    if (Array.isArray(v)) return v.length ? String(v[0]) : '';
    return v != null ? String(v) : '';
  }

  /** One user filament preset as the calibration form lists it; null when it is not a filament. */
  function userFilament(j, fileName) {
    if (!j || j.type !== 'filament') return null;
    return {
      name: j.name || String(fileName).replace(/\.json$/, ''),
      file: fileName,
      type: Array.isArray(j.filament_type) ? j.filament_type[0] : (j.filament_type || ''),
      // Current values so the UI can prefill (empty when the value is inherited, not stored in the diff).
      current: {
        nozzleTemp: readVal(j, 'nozzle_temperature'),
        flowRatio: readVal(j, 'filament_flow_ratio'),
        pressureAdvance: readVal(j, 'pressure_advance'),
        retractionLength: readVal(j, 'filament_retraction_length'),
        maxVolSpeed: readVal(j, 'filament_max_volumetric_speed'),
      },
    };
  }

  /**
   * A tuned preset from a base one: the measured overrides applied, renamed, and made a user preset
   * of its own. `printer` (from groupPrinters) and `version` are optional. Throws a user-facing
   * message when there is nothing to save. Mutates and returns `preset`.
   */
  function tunedPreset(preset, values, name, printer, version) {
    if (!preset || preset.type !== 'filament') throw new Error('That base isn’t a filament preset.');
    const overrides = overridesFromValues(values);
    if (!Object.keys(overrides).length) throw new Error('Enter at least one measured value to save.');
    const newName = String(name || '').trim() || (preset.name ? preset.name + ' (tuned)' : 'Tuned filament');
    Object.assign(preset, overrides);
    preset.name = newName;
    preset.from = 'User';
    delete preset.setting_id; // a new preset, not the base's cloud/library id
    if (printer) preset.compatible_printers = printer.machines.slice();
    if (version) preset.version = version; else delete preset.version;
    return { preset, name: newName, applied: Object.keys(overrides) };
  }

  /** The text written to disk for a preset — both apps write it the same way. */
  function presetText(preset) { return JSON.stringify(preset, null, 2); }

  const api = {
    SLICERS, userProfileName, stripNozzle, groupPrinters, defaultPrinter, pickVersion, safeFileBase,
    validProfileRef, retarget, overridesFromValues, readVal, userFilament, tunedPreset, presetText,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (global) global.KhaytOrcaPresets = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
