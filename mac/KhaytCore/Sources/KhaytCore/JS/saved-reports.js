'use strict';
(function () {
/**
 * A report a shop named and wants back.
 *
 * The report builder lets a shop pick columns, stages and a date range; a shop
 * that runs the same question every month should not have to rebuild it every
 * month. The answer is a short list on `settings.savedReports`, and this module
 * owns its shape so the two apps cannot disagree about it.
 *
 * ── WHY THIS IS A MODULE AND NOT FIVE LINES IN A CLICK HANDLER ──────────────
 *
 * It WAS five lines in a click handler, and they had two faults that only show
 * up after a shop has used the feature for a while:
 *
 *   1. Saving twice under one name appended twice. A shop tweaking a report and
 *      re-saving it ends up with six entries called "Monthly VAT", all but one
 *      stale, and no way to tell them apart.
 *   2. There was no way to remove one. The list only ever grew.
 *
 * Both are fixed here rather than in either app, because a saved report written
 * by one and read by the other has to mean the same thing.
 *
 * Pure: no DOM, no fs, no Electron. Every function returns a NEW list.
 */

function text(v) { return String(v == null ? '' : v).trim(); }

/** One stored report, or null if it is not one. */
function clean(row) {
  if (!row || typeof row !== 'object') return null;
  const id = text(row.id);
  const name = text(row.name);
  if (!id || !name) return null;
  return {
    id,
    name,
    fields: Array.isArray(row.fields) ? row.fields.map(text).filter(Boolean) : [],
    statusIn: Array.isArray(row.statusIn) ? row.statusIn.map(text).filter(Boolean) : [],
    from: text(row.from).slice(0, 10),
    to: text(row.to).slice(0, 10),
  };
}

/**
 * What is really on the settings, with the junk dropped.
 *
 * A store edited by hand, or written by an older build, can hold anything. A
 * screen that renders `settings.savedReports` straight would draw a button with
 * no name on it and load a report with no columns.
 */
function savedReports(settings) {
  const list = settings && Array.isArray(settings.savedReports) ? settings.savedReports : [];
  const out = [];
  const seen = new Set();
  for (const row of list) {
    const r = clean(row);
    if (!r || seen.has(r.id)) continue;
    seen.add(r.id);
    out.push(r);
  }
  return out;
}

/**
 * Keep a report under a name.
 *
 * Saving under a name the shop already used REPLACES it, in place, keeping its
 * id and its position. That is what "save" means to the person doing it — they
 * are correcting the report they just ran, not filing a second one — and it is
 * the difference between a list a shop prunes and a list a shop abandons.
 *
 * @param {object[]} list  the current list (from `savedReports`)
 * @param {object} spec    { name, fields, statusIn, from, to }
 * @param {string} id      the id to use IF this is a new one; callers own uniqueness
 */
function addReport(list, spec, id) {
  const current = Array.isArray(list) ? list.map(clean).filter(Boolean) : [];
  const name = text(spec && spec.name);
  if (!name) return current;
  const at = current.findIndex((r) => r.name.toLowerCase() === name.toLowerCase());
  const row = clean({ id: at === -1 ? text(id) : current[at].id, name, ...spec });
  if (!row) return current;
  if (at === -1) return [...current, row];
  const next = current.slice();
  next[at] = row;
  return next;
}

/** Drop one. Unknown ids are not an error — two windows can remove the same one. */
function removeReport(list, id) {
  const wanted = text(id);
  return (Array.isArray(list) ? list.map(clean).filter(Boolean) : [])
    .filter((r) => r.id !== wanted);
}

/** Find one to load back into the builder. */
function findReport(list, id) {
  const wanted = text(id);
  return (Array.isArray(list) ? list.map(clean).filter(Boolean) : [])
    .find((r) => r.id === wanted) || null;
}

const api = { savedReports, addReport, removeReport, findReport };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (typeof globalThis !== 'undefined') globalThis.KhaytSavedReports = api;
})();
