'use strict';
(function (global) {

/**
 * What each printer needs from a person, for the LAN's /api/machines/live and
 * anything else that hands it on (gap 5 of ~/Khayt-proposals/desktop-parity-
 * nov22.md): its problems (C3, lib/printer-problems.js) and why it waits at
 * the machine (C4, lib/waiting-at-machine.js). The SAME composition the Mac
 * runs inline in KhaytEngine+PrinterNeeds.swift `printerNeeds` (#2621), in one
 * shared file, so the desktop and the Mac cannot hand a phone two shapes.
 *
 *   printerNeeds({ machines, cache, polled, completions, orders })
 *     → { [machineId]: { problems: [...], waiting: [...] } }
 *
 *   machines     the book's machines; only those with a printer API
 *   cache        the poll cache: each entry's state, message, error
 *   polled       problems a poll already worked out, by machine (a Bambu's
 *                faults, a Moonraker's exception objects). A machine not in
 *                it is read from its state word; a Bambu without them has none
 *   completions  the persisted poll completions (book.printerCompletions)
 *   orders       the book's jobs, for the last one finished on each machine
 *
 * A printer that is not answering has no live problems: only what is stored
 * can still say it waits. problems: { code, severity, action, source, head?,
 * message?, ref? }, worst first; waiting: { reason, since, head? }, most
 * urgent first. Pure; loads in JavaScriptCore beside its two rules.
 */

function rules() {
  const PP = (global && global.KhaytPrinterProblems) || (typeof require === 'function' ? require('./printer-problems.js') : null);
  const W = (global && global.KhaytWaitingAtMachine) || (typeof require === 'function' ? require('./waiting-at-machine.js') : null);
  return { PP, W };
}

function printerNeeds(input) {
  const i = input || {};
  const { PP, W } = rules();
  const out = {};
  if (!PP || !W) return out;
  const cache = i.cache && typeof i.cache === 'object' ? i.cache : {};
  const polled = i.polled && typeof i.polled === 'object' ? i.polled : {};
  const saved = i.completions && typeof i.completions === 'object' ? i.completions : {};
  const lastDone = {};
  for (const o of Array.isArray(i.orders) ? i.orders : []) {
    // A deleted or voided job is not a print on the bed (review of the page-136 UI).
    if (!o || !o.machineId || !o.completedAt || o.deleted || o.voidedAt) continue;
    const at = Date.parse(String(o.completedAt));
    if (isFinite(at) && !(lastDone[o.machineId] >= at)) lastDone[o.machineId] = at;
  }
  for (const m of Array.isArray(i.machines) ? i.machines : []) {
    if (!m || !m.id) continue;
    const type = m.printerApi && m.printerApi.type;
    if (!type || type === 'none') continue;
    const entry = cache[m.id];
    const answering = !!(entry && !entry.error);
    let problems = [];
    if (answering) {
      if (Array.isArray(polled[m.id])) problems = polled[m.id];
      else if (String(type).toLowerCase() !== 'bambu') problems = PP.problemsFor(type, { state: entry.state, message: entry.message });
    }
    const kept = saved[m.id];
    const list = Array.isArray(kept) ? kept : (kept && Array.isArray(kept.completions) ? kept.completions : []);
    const waiting = W.waiting(m, { completions: list, lastFinishedAt: lastDone[m.id], live: answering ? entry : undefined, problems });
    out[m.id] = { problems, waiting };
  }
  return out;
}

/** The `polled` map from a desktop poll cache: what each poll worked out itself (`entry.problems`). */
function polledFrom(cache) {
  const out = {};
  for (const [id, e] of Object.entries(cache && typeof cache === 'object' ? cache : {})) if (e && Array.isArray(e.problems)) out[id] = e.problems;
  return out;
}

const api = { printerNeeds, polledFrom };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytPrinterNeeds = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
