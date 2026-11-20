'use strict';
(function (global) {

/**
 * What a Snapmaker U1 (Moonraker) says is WRONG, as a closed list
 * (U1 idea 5, toward batch 2's C3 problem catalogue; ideas only from
 * bloodf/u1control's docs, no code). lib/bambu-faults.js is the Bambu row of
 * the same catalogue, and these findings have its shape, so C3 can fold both.
 *
 * Read from two status objects the U1 already answers (checked with read-only
 * queries on the shop's U1, Nov 19):
 *
 *   exception_manager.exceptions[]  { id, index, code, level, message }
 *                                   e.g. id 523, level 2, "e1_filament runout"
 *   power_loss_check.power_loss_flag  true after the power went mid-print
 *
 * Each finding: { kind, code, severity, head?, id?, message? }
 *
 *   code 'filament-runout'    id 523: a head ran out. `head` is 0-based (the
 *                             U1 says e0..e3); the apps say "Filament ran
 *                             out on head N" in their own words.
 *   code 'printer-exception'  any other id: the printer's own message, shown
 *                             as it came, with the level as the severity.
 *   code 'power-lost'         "Power was lost during a print. Resume or
 *                             discard it on the printer." INFORMATION ONLY:
 *                             Khayt never sends resume or discard.
 *
 * Levels are the printer's, read as: 3 and up fatal, 2 serious, 1 common,
 * anything else info. That reading is inferred from what the U1 shows, not
 * documented by Snapmaker; a level it does not know is info, never dropped.
 * Worst first. Pure: no sockets, no DOM.
 */

const CODES = ['filament-runout', 'printer-exception', 'power-lost'];
const SEVERITIES = ['fatal', 'serious', 'common', 'info'];
const RANK = { fatal: 0, serious: 1, common: 2, info: 3 };
/** The exception ids Khayt has words for. */
const KNOWN = { 523: 'filament-runout' };

const int = (v) => { if (typeof v !== 'number' && (typeof v !== 'string' || !v.trim())) return null; const n = Number(v); return Number.isInteger(n) ? n : null; };
const text = (v) => (v == null ? '' : String(v)).replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, 200);

function severityOf(level) {
  const l = int(level);
  if (l === null) return 'info';
  if (l >= 3) return 'fatal';
  if (l === 2) return 'serious';
  if (l === 1) return 'common';
  return 'info';
}

/**
 * The head an exception names, from the "eN_" its message starts with (the
 * U1's own e0..e3, as in power_loss_check e0..e3). Not `index`: nothing says
 * that is a head rather than the exception's own position, so it is not
 * guessed at; no "eN_" is no head.
 */
function headOf(ex) {
  const m = /^e(\d{1,2})_/i.exec(text(ex.message));
  return m ? Number(m[1]) : null;
}

/**
 * @param {object} status  the Moonraker objects-query `status` ({ exception_manager, power_loss_check, … })
 * @returns {Array<{kind: string, code: string, severity: string, head?: number|null, id?: number, message?: string}>}
 */
function problems(status) {
  const s = status && typeof status === 'object' ? status : {};
  const out = [];
  const em = s.exception_manager && typeof s.exception_manager === 'object' ? s.exception_manager : null;
  const list = em && Array.isArray(em.exceptions) ? em.exceptions.slice(0, 32) : [];
  const seen = new Set();
  for (const ex of list) {
    if (!ex || typeof ex !== 'object') continue;
    const id = int(ex.id);
    if (id === null) continue;
    const head = headOf(ex);
    const key = id + ':' + head;
    if (seen.has(key)) continue;
    seen.add(key);
    const code = KNOWN[id] || 'printer-exception';
    const f = { kind: 'exception', code, severity: severityOf(ex.level), head, id };
    if (code === 'printer-exception') f.message = text(ex.message) || null;
    out.push(f);
  }
  const plc = s.power_loss_check && typeof s.power_loss_check === 'object' ? s.power_loss_check : null;
  if (plc && plc.power_loss_flag === true) out.push({ kind: 'power-loss', code: 'power-lost', severity: 'info' });
  return out.sort((a, b) => (RANK[a.severity] - RANK[b.severity])
    || ((a.head ?? 99) - (b.head ?? 99)) || ((a.id ?? 0) - (b.id ?? 0)));
}

const api = { CODES, SEVERITIES, KNOWN, problems, severityOf };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytMoonrakerProblems = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
