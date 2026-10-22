'use strict';
(function (global) {
/**
 * What a Bambu printer says is WRONG, in words a shop can act on.
 *
 * A report carries two kinds of fault, and Khayt read neither: a card said
 * "Paused" or "Failed" and nothing about why.
 *
 *   print_error   one integer, the reason the current job stopped or paused.
 *                 Written as 8 hex digits in two groups: 50348044 = 0x0300400C
 *                 → "0300_400C", "The task was canceled."
 *   hms[]         Health Management System notices, `{ attr, code }` pairs.
 *                 Written as 16 hex digits in four groups: attr 50331904 =
 *                 0x03000100, code 65543 = 0x00010007 → "0300_0100_0001_0007".
 *
 * ── SOURCES ───────────────────────────────────────────────────────────────
 *
 * The formatting, severity and module rules are ha-bambulab's
 * (`custom_components/bambu_lab/pybambu/models.py` `HMSNotification.hms_code`
 * and `PrintError.print_update`; `utils.py` `get_HMS_severity` = code >> 16,
 * `get_HMS_module` = (attr >> 24) & 0xFF; `const.py` `HMS_SEVERITY_LEVELS`
 * and `HMS_MODULES`). OpenBambuAPI `mqtt.md` documents the same `hms` and
 * `print_error` fields in the push_status report.
 *
 * The sentences below are copied verbatim from ha-bambulab's
 * `pybambu/hms_error_text/hms_en.json.gz` (MIT, Copyright (c) 2023 ha-bambulab
 * contributors), which in turn carries Bambu's own HMS texts. That table holds
 * 946 print errors and 4,998 HMS codes, most of them per-slot and per-model
 * variants of one another — far too big to bundle into both apps for a status
 * line. So this is the common ones: cancellations, runouts, door/cover, first
 * layer and spaghetti detection, clogs, temperature faults, storage. Anything
 * else is shown by its code, which is what Bambu Studio and the printer's own
 * screen show, and which Bambu's HMS wiki is searchable by.
 *
 * ── WHAT IS LEFT OUT, AND WHY ─────────────────────────────────────────────
 *
 * ha-bambulab suppresses a print_error it has no text for, because such codes
 * "get fired when there are no errors". With the full table that is a safe
 * rule; with this short one it would hide most real faults. So an UNKNOWN code
 * is shown only when the job has actually stopped or paused (`FAILED`,
 * `PAUSE`), and suppressed while it is running, where it would be noise.
 * HMS notices of severity "info" (4) are left out of the headline — "Inspecting
 * the first layer: please wait a moment" is not a fault.
 *
 * Pure: no sockets, no DOM. Both apps load it.
 */

  const SEVERITY = { 1: 'fatal', 2: 'serious', 3: 'common', 4: 'info' };
  const MODULE = { 0x03: 'mc', 0x05: 'mainboard', 0x07: 'ams', 0x08: 'toolhead', 0x0C: 'xcam' };

  /** print_error codes, keyed without the underscore (ha-bambulab's own key). */
  const PRINT_ERRORS = {
    '0300400C': 'The task was canceled.',
    '0500400E': 'Printing was cancelled.',
    '03008001': "Printing was paused by the user. You can select 'Resume' to continue printing.",
    '03008004': 'Filament ran out. Please load new filament.',
    '07008011': 'AMS filament ran out. Please insert a new filament into the same AMS slot.',
    '07018011': 'AMS filament ran out. Please insert a new filament into the same AMS slot.',
    '07028011': 'AMS filament ran out. Please insert a new filament into the same AMS slot.',
    '07038011': 'AMS filament ran out. Please insert a new filament into the same AMS slot.',
    '07FF8011': 'External filament has run out; please load a new filament.',
    '07008006': 'Unable to feed filament into the extruder. The AMS may be mismatched with the extruder. You can rerun the AMS Setup. This could also be due to an entangled filament or a stuck spool. If not, please check if the AMS PTFE tube is connected.',
    '07FF8012': "Failed to get AMS mapping table; please select 'Resume' to retry.",
    '0C008001': "First layer defects were detected. If the defects are acceptable, select 'Resume' to resume the print job.",
    '03008002': 'First layer defects were detected by the Micro Lidar. Please check the quality of the printed model before continuing your print.',
    '03008003': 'Spaghetti defects were detected by the AI Print Monitoring. Please check the quality of the printed model before continuing your print. Cleaning the build plate or drying the filament can effectively reduce the risk of spaghetti failure.',
    '0300800A': 'A Filament pile-up was detected by AI Print Monitoring. Please clean filament from the waste chute.',
    '0300800B': 'The cutter is stuck. Please make sure the cutter handle is out and check the filament sensor cable connection.',
    '03008005': 'Toolhead front cover fell off. Please remount the front cover and check to make sure your print is going okay.',
    '0300800F': 'The door seems to be open, so printing was paused.',
    '0300404B': 'Task aborted because the front door or top cover is open.',
    '03004006': 'The nozzle is clogged.',
    '03008016': "The nozzle is clogged with filament. Please cancel this print and clean the nozzle or select 'Resume' to resume the print job.",
    '03008008': 'Nozzle temperature malfunction. Check the Assistant page and resolve the issue before retrying heating.',
    '03008009': 'Heatbed temperature malfunction',
    '03008010': 'The hotend cooling fan speed is abnormal.',
    '03004000': 'Z axis homing failed; the task has been stopped.',
    '03004001': 'The printer timed out waiting for the nozzle to cool down before homing.',
    '0300400D': 'Resume failed after power loss.',
    '0300800E': 'The print file is not available. Please check to see if the storage media has been removed.',
    '0500400C': 'Please insert a MicroSD card and restart the print job.',
    '05004004': 'Device is busy and cannot start new task. Please wait for current task to complete before sending new task.',
    '05008036': 'Your sliced file is not consistent with the current printer model. Continue?',
  };

  /** HMS codes, keyed without underscores. */
  const HMS = {
    '0300010000010001': 'The heatbed temperature is abnormal; the heater may have a short circuit.',
    '0300010000010002': 'The heatbed temperature is abnormal; the heater may have an open circuit, or the thermal switch may be open.',
    '0300010000010003': 'The heatbed temperature is abnormal; the heater is over temperature.',
    '0300010000010007': 'The heatbed temperature is abnormal; the sensor may have an open circuit.',
    '0300020000010001': 'The nozzle temperature is abnormal; the heater may have a short circuit.',
    '0300020000010002': 'The nozzle temperature is abnormal; the heater may have an open circuit.',
    '0300020000010003': 'The nozzle temperature is abnormal; the heater is over temperature.',
    '0300030000010001': 'The hotend cooling fan speed is too slow or stopped. It may be stuck or the connector may not be plugged in properly.',
    '0300040000020001': 'The speed of the part cooling fan is too slow or stopped. It may be stuck, or the connector may not be plugged in properly.',
    '0300090000020001': 'The extrusion motor is overloaded. The extruder may be clogged or the filament may be stuck in the tool head.',
    '0300120000020001': 'The front cover of the toolhead fell off.',
    '03000D0000010003': 'The build plate is not placed properly. Please adjust it.',
    '0700200000020001': 'AMS A Slot 1 filament has run out. Please insert a new filament.',
    '0700700000020001': 'Failed to pull out the AMS A Slot 1 filament from the extruder. Possible cause: clogged extruder or broken filament inside the extruder.',
    '0C00030000030008': 'A possible spaghetti failure has been detected. Please check the print quality and decide whether to stop the job. Cleaning the build plate or drying the filament can effectively reduce the risk of spaghetti failure.',
    '0500040000010001': 'Failed to download print job; please check your network connection.',
  };

  const hex = (n, width) => (n >>> 0).toString(16).toUpperCase().padStart(width, '0');

  /** A whole, non-negative 32-bit number, or null. The wire is a peer's claim. */
  function u32(v) {
    const n = typeof v === 'string' && /^\d+$/.test(v) ? Number(v) : v;
    if (typeof n !== 'number' || !Number.isInteger(n) || n < 0 || n > 0xFFFFFFFF) return null;
    return n;
  }

  /** `print_error` as Bambu writes it, "0300_400C". Null for none (0) or junk. */
  function printErrorCode(value) {
    const n = u32(value);
    if (!n) return null;
    const h = hex(n, 8);
    return `${h.slice(0, 4)}_${h.slice(4, 8)}`;
  }

  /** An HMS pair as Bambu writes it, "0300_0100_0001_0007". Null unless both > 0. */
  function hmsCode(attr, code) {
    const a = u32(attr), c = u32(code);
    if (!a || !c) return null;
    const ha = hex(a, 8), hc = hex(c, 8);
    return `${ha.slice(0, 4)}_${ha.slice(4)}_${hc.slice(0, 4)}_${hc.slice(4)}`;
  }

  function hmsSeverity(code) {
    const c = u32(code);
    return (c && SEVERITY[c >>> 16]) || 'unknown';
  }

  function hmsModule(attr) {
    const a = u32(attr);
    return (a && MODULE[(a >>> 24) & 0xFF]) || 'unknown';
  }

  const RANK = { fatal: 0, serious: 1, common: 2, unknown: 3, info: 4 };

  /**
   * Every fault in one report's `print` object, most severe first.
   *
   * Each is `{ kind: 'print_error' | 'hms', code, text, severity, module }`;
   * `text` is null when the code is not in the short table above.
   */
  function faults(print) {
    const p = print && typeof print === 'object' && !Array.isArray(print) ? print : {};
    const state = String(p.gcode_state || '').toUpperCase();
    const out = [];

    const pe = printErrorCode(p.print_error);
    if (pe) {
      const text = PRINT_ERRORS[pe.replace('_', '')] || null;
      // See the header: an unknown code on a running job is not a fault.
      if (text || state === 'FAILED' || state === 'PAUSE') {
        out.push({ kind: 'print_error', code: pe, text, severity: 'serious', module: null });
      }
    }

    if (Array.isArray(p.hms)) {
      const seen = new Set();
      for (const h of p.hms.slice(0, 32)) {
        if (!h || typeof h !== 'object') continue;
        const code = hmsCode(h.attr, h.code);
        if (!code || seen.has(code)) continue;
        seen.add(code);
        const severity = hmsSeverity(h.code);
        if (severity === 'info') continue;
        out.push({ kind: 'hms', code, text: HMS[code.replace(/_/g, '')] || null,
                   severity, module: hmsModule(h.attr) });
      }
    }

    return out.sort((a, b) => RANK[a.severity] - RANK[b.severity]);
  }

  /** One fault as a line: its sentence, then the code to look it up by. */
  function describe(f) {
    const code = f.kind === 'hms' ? `HMS_${f.code}` : f.code;
    return f.text ? `${f.text} (${code})` : `Printer reported ${code}`;
  }

  /**
   * The line a status shows, or null when nothing is wrong.
   *
   * The most severe fault, plus "(+N more)" when there are others — a status
   * line that lists four HMS notices is a paragraph nobody reads.
   */
  function faultText(print) {
    const all = faults(print);
    if (!all.length) return null;
    const more = all.length > 1 ? ` (+${all.length - 1} more)` : '';
    return describe(all[0]) + more;
  }

  const api = { printErrorCode, hmsCode, hmsSeverity, hmsModule, faults, describe, faultText,
                PRINT_ERRORS, HMS };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytBambuFaults = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
