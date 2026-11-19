'use strict';
(function (global) {

/**
 * What to tell a shop before a file goes to a printer (C8, Prusa batch 1;
 * design approved by Dev Hub, Nov 19: ~/Khayt-proposals/prusa-batch1-lib-design.md).
 *
 * `sendChecks(file, machine, loaded)` returns a CLOSED list of findings,
 * worst first. Each app says them in its own words (i18n `send.check.<code>`);
 * the screen decides from `severity`:
 *
 *   block  the send would fail or waste the plate: the file type the printer
 *          cannot take, or a model that does not fit the bed even turned a
 *          quarter turn (Mac frame 182:253: a red row, Send off)
 *   warn   worth a look before sending: fits only rotated, sliced for
 *          another printer, a material or colour that is not what is loaded
 *   info   a head the printer does not report (a U1 head with
 *          filament_exist:false or type NONE): never a mismatch
 *
 * Every input is optional; a check whose inputs are missing says nothing (an
 * unmeasured model is not a model that does not fit). Pure; no DOM, no I/O.
 *
 *   file     { name, type?, filaments: gcode-parse.parseFilaments(),
 *              header: gcode-parse.parsePrinterHeader(), bounds: {x,y,z}? }
 *   machine  { model, toolheads?, bed: {x,y,z}, printerApi: {type} }
 *   loaded   [{ slot (0-based head), hex, material }], loaded-colours shape
 *            (normalizeLoaded, or fromPrintTaskConfig for a U1)
 */

const CODES = ['type-unsupported', 'bed-footprint', 'bed-height', 'bed-rotate', 'sliced-for-other',
  'material-mismatch', 'colour-far', 'head-not-reported'];
const SEVERITIES = ['block', 'warn', 'info'];
const RANK = { block: 0, warn: 1, info: 2 };

function lib(name, file) {
  if (global && global[name]) return global[name];
  if (typeof require === 'function') { try { return require(file); } catch (_) { return null; } }
  return null;
}

const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const norm = (v) => String(v == null ? '' : v).toLowerCase().replace(/[\s_-]+/g, '');
const round1 = (n) => Math.round(n * 10) / 10;

/** The printer does not say what is in this head (absent, or a U1 reporting NONE). */
function unreported(entry) {
  if (!entry || !entry.hex) return true;
  const m = String(entry.material || '').trim().toUpperCase();
  return m === 'NONE' || /^NONE\b/.test(m);
}

function fileChecks(file, machine, out) {
  const PU = lib('KhaytPrinterUpload', './printer-upload.js');
  const type = machine && machine.printerApi && machine.printerApi.type;
  if (PU && type && file.name && typeof PU.check === 'function') {
    const r = PU.check(type, file.name);
    // Only the FILE's refusals (not sliced, or a kind this printer cannot
    // run). A protocol Khayt cannot send to at all ('unsupported') has no
    // send to check.
    if (r && r.ok === false && r.code !== 'unsupported') {
      out.push({ code: 'type-unsupported', severity: 'block', reason: r.code, kind: r.kind || (PU.kindOf ? PU.kindOf(file.name) : null) || null });
    }
  }
}

function bedChecks(file, machine, out) {
  const PF = lib('KhaytPrintFit', './print-fit.js');
  if (!PF || !isObj(file.bounds) || !isObj(machine.bed)) return;
  const r = PF.check(file.bounds, machine.bed);
  if (!r.known || r.ok) return;
  const over = { x: round1(r.over.x), y: round1(r.over.y), z: round1(r.over.z) };
  if (r.footprint && !r.rotated) out.push({ code: 'bed-footprint', severity: 'block', over });
  if (r.height) out.push({ code: 'bed-height', severity: 'block', over });
  if (r.footprint && r.rotated && !r.height) out.push({ code: 'bed-rotate', severity: 'warn', over });
}

function slicedForChecks(file, machine, out) {
  const h = isObj(file.header) ? file.header : null;
  if (!h) return;
  const PF = lib('KhaytPrintFit', './print-fit.js');
  const slack = PF && PF.SLACK != null ? PF.SLACK : 1;
  const wantModel = norm(h.printerModel), haveModel = norm(machine.model);
  const otherModel = !!(wantModel && haveModel && wantModel !== haveModel);
  const hb = isObj(h.bed) ? h.bed : null, mb = isObj(machine.bed) ? machine.bed : null;
  const biggerBed = !!(hb && mb && +mb.x > 0 && +mb.y > 0
    && ((+hb.x > +mb.x + slack || +hb.y > +mb.y + slack) && (+hb.x > +mb.y + slack || +hb.y > +mb.x + slack)));
  if (otherModel || biggerBed) {
    out.push({ code: 'sliced-for-other', severity: 'warn', model: h.printerModel || null, bed: hb ? { x: hb.x, y: hb.y, z: hb.z } : null });
  }
}

function filamentChecks(file, machine, loaded, out) {
  const LC = lib('KhaytLoadedColours', './loaded-colours.js');
  const KC = lib('KhaytColor', './color-mix.js');
  const used = (Array.isArray(file.filaments) ? file.filaments : []).filter((f) => f && Number.isInteger(f.slot) && f.slot >= 1);
  const raw = Array.isArray(loaded) ? loaded : [];
  // A printer that reports nothing (and nothing set by hand) gives no filament
  // findings at all: a row per slot saying "not reported" would be noise.
  if (!used.length || !raw.length || !LC) return;
  const slots = LC.normalizeLoaded(raw);
  const byHead = new Map();
  for (const s of raw) if (s && Number.isInteger(s.slot)) byHead.set(s.slot, slots.find((x) => x.slot === s.slot) || { slot: s.slot, hex: null, material: s.material });
  const heads = Number.isInteger(machine.toolheads) && machine.toolheads > 0 ? machine.toolheads : null;
  for (const f of used) {
    const head = f.slot - 1;
    const want = { type: f.type || null, colour: f.colour || null };
    if (heads !== null && head >= heads) {
      out.push({ code: 'material-mismatch', severity: 'warn', slot: f.slot, want, have: null });
      continue;
    }
    const have = byHead.get(head);
    if (unreported(have)) { out.push({ code: 'head-not-reported', severity: 'info', slot: f.slot }); continue; }
    const wf = LC.family(f.type), hf = LC.family(have.material);
    if (wf && hf && wf !== hf) {
      out.push({ code: 'material-mismatch', severity: 'warn', slot: f.slot, want, have: { material: have.material, colour: have.hex } });
      continue;
    }
    if (f.colour && KC && typeof KC.deltaE === 'function') {
      const d = KC.deltaE(f.colour, have.hex);
      if (Number.isFinite(d) && d > LC.DEFAULT_TOLERANCE) {
        out.push({ code: 'colour-far', severity: 'warn', slot: f.slot, want, have: { material: have.material, colour: have.hex }, deltaE: round1(d) });
      }
    }
  }
}

/**
 * @returns {Array<{code: string, severity: 'block'|'warn'|'info', slot?: number}>}
 */
function sendChecks(file, machine, loaded) {
  const f = isObj(file) ? file : {};
  const m = isObj(machine) ? machine : {};
  const out = [];
  fileChecks(f, m, out);
  bedChecks(f, m, out);
  slicedForChecks(f, m, out);
  filamentChecks(f, m, loaded, out);
  return out.sort((a, b) => (RANK[a.severity] - RANK[b.severity])
    || ((a.slot || 0) - (b.slot || 0)) || (CODES.indexOf(a.code) - CODES.indexOf(b.code)));
}

/** Whether the screen must hold the send (a `block` finding). */
function blocks(findings) {
  return (Array.isArray(findings) ? findings : []).some((x) => x && x.severity === 'block');
}

const api = { CODES, SEVERITIES, sendChecks, blocks };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
if (global) global.KhaytSendChecks = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
