'use strict';
/**
 * Dropping ONE object from a print that is already running.
 *
 * A plate of twelve parts where one has come loose is a plate that will finish
 * with eleven good parts and one ball of spaghetti — and, on a machine that
 * keeps moving through the wreckage, sometimes eleven ruined ones. Klipper's
 * `exclude_object` skips the rest of a named object's moves and carries on with
 * everything else. Khayt could watch a print fail and could cancel the whole
 * plate; it could not save the other eleven.
 *
 * This matters most on a toolchanger, which is what is on the bench: a U1 plate
 * is commonly one model per head, so one failure was costing four parts and a
 * full reprint of all of them.
 *
 * ── EXCLUDING IS NOT UNDOABLE, AND THAT IS THE WHOLE UI PROBLEM ───────────
 *
 * Klipper has no "put it back". `EXCLUDE_OBJECT RESET` clears the whole list,
 * it does not reprint the layers that were skipped while an object was
 * excluded — so an object dropped by mistake is scrap, and the shop finds out
 * at the end. Anything that calls this must ask first, by name, and say that it
 * cannot be taken back. `reversible` is exported as `false` so that sentence
 * has something to hang on rather than being a comment nobody reads.
 *
 * ── WHY ONLY A NAME THE PRINTER JUST REPORTED CAN BE EXCLUDED ─────────────
 *
 * The command is sent as a G-CODE SCRIPT: `EXCLUDE_OBJECT NAME=<name>` posted
 * to `/printer/gcode/script`. The name comes from the sliced file, and a file a
 * shop downloaded is a stranger's file — a name carrying a newline would end
 * that command and start another, which is arbitrary G-code on a hot machine.
 *
 * Escaping it would be one more thing to get right. Instead `excludeRequest`
 * refuses any name that is not EXACTLY one the printer itself just listed. A
 * caller cannot construct a name at all, only choose one, so there is nothing
 * to escape.
 *
 * Pure: no sockets. Builds requests and reads replies.
 */
(function (global) {

  /** Klipper skips what is left of an object. It cannot unskip it. */
  const reversible = false;

  /** Added to a status query when the machine is asked what is on its plate. */
  const QUERY = 'exclude_object';

  /**
   * What is on the plate, out of a `/printer/objects/query?exclude_object` reply.
   *
   * ── "NOT SUPPORTED" IS NOT "NOTHING ON THE PLATE" ─────────────────────────
   *
   * `exclude_object` is a Klipper module a printer may not have configured, and
   * a slicer must also have written the object markers into the file. Both
   * absences look the same from here — an empty or missing key — and the
   * difference is what a screen has to say: "this printer cannot do that" is a
   * setting to change, "nothing is printing" is not. So `supported` answers
   * whether the KEY was there at all, separately from how many objects it held.
   *
   * @param {object} data  the query reply
   * @returns {{supported: boolean, objects: string[], excluded: string[], current: string|null}}
   */
  function plate(data) {
    const status = (data && data.result && data.result.status) || {};
    const held = status[QUERY];
    if (!held || typeof held !== 'object') {
      return { supported: false, objects: [], excluded: [], current: null };
    }
    const names = Array.isArray(held.objects)
      ? held.objects.map((o) => (o && typeof o.name === 'string' ? o.name : '')).filter(Boolean)
      : [];
    const excluded = Array.isArray(held.excluded_objects)
      ? held.excluded_objects.map((n) => String(n || '')).filter(Boolean)
      : [];
    const current = typeof held.current_object === 'string' && held.current_object
      ? held.current_object : null;
    return { supported: true, objects: names, excluded, current };
  }

  /**
   * The objects still printing — what a shop may actually choose from.
   *
   * An object already excluded is not offered again: the command would succeed,
   * change nothing, and read as though it had done something.
   */
  function remaining(data) {
    const p = plate(data);
    const gone = new Set(p.excluded);
    return p.objects.filter((name) => !gone.has(name));
  }

  /**
   * The request that drops one object, or a refusal.
   *
   * @param {string} name  the object to drop — must be one the printer listed
   * @param {object} data  the reply `remaining` was read from, so the name can
   *                       be checked against what the machine actually has
   * @returns {{method: string, path: string}|{refused: string}}
   */
  function excludeRequest(name, data) {
    const p = plate(data);
    if (!p.supported) {
      return { refused: 'This printer does not report the objects on its plate.' };
    }
    const wanted = String(name == null ? '' : name);
    if (!p.objects.includes(wanted)) {
      // Includes the empty name and anything invented, which is the guard that
      // makes escaping unnecessary — see the note at the top.
      return { refused: 'That object is not on the plate.' };
    }
    if (p.excluded.includes(wanted)) {
      return { refused: 'That object has already been dropped.' };
    }
    if (p.objects.length - p.excluded.length <= 1) {
      // Dropping the last one leaves a print that moves, heats and produces
      // nothing. Cancelling is the honest way to do that, and it is a different
      // button with a different confirmation.
      return { refused: 'That is the only object left — cancel the print instead.' };
    }
    return {
      method: 'POST',
      path: '/printer/gcode/script?script=' + encodeURIComponent('EXCLUDE_OBJECT NAME=' + wanted),
    };
  }

  const api = { QUERY, reversible, plate, remaining, excludeRequest };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytExcludeObject = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
