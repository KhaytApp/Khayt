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
 *          cannot take, or a model whose PLACED extents (file.bounds.source
 *          'placed-extents') do not fit the bed even turned a quarter turn
 *          (Mac frame 182:253: a red row, Send off). Bounds from anywhere
 *          else (mesh dimensions, raw toolpath extents) only warn.
 *   warn   worth a look before sending: fits only rotated, sliced for
 *          another printer, a material or colour that is not what is loaded
 *          a printer whose last print ended (finished, stopped, cancelled)
 *          with nobody saying the bed was cleared since ('bed-not-cleared')
 *   info   a head the printer does not report (a U1 head with
 *          filament_exist:false or type NONE): never a mismatch; a bed
 *          nobody has said is clear, on a printer with no activity to go by
 *          ('bed-unknown')
 *
 * Every input is optional; a check whose inputs are missing says nothing (an
 * unmeasured model is not a model that does not fit). Pure; no DOM, no I/O.
 *
 *   file     { name, type?, filaments: gcode-parse.parseFilaments(),
 *              header: gcode-parse.parsePrinterHeader(),
 *              bounds: {x, y, z, source?: 'placed-extents' | 'mesh' | 'toolpath'} }
 *   machine  { model, printerModel?, toolheads?, bed: {x,y,z}, printerApi: {type} }
 *   loaded   [{ slot (0-based head), hex, material }], loaded-colours shape
 *            (normalizeLoaded, or fromPrintTaskConfig for a U1)
 *   live     the printer's poll entry ({ state, lastActivityAt, lastFinishedAt },
 *            printer-poll-cache); `opts.lastFinishedByMachine` as plan() gives
 *            it. Leave `live` out and the bed says nothing. The bed rule is
 *            lib/auto-dispatch.js bedState, the dispatcher's own: a file sent
 *            by hand and one sent by dispatch are judged the same way.
 */

const CODES = ['type-unsupported', 'bed-footprint', 'bed-height', 'bed-rotate', 'bed-not-cleared', 'sliced-for-other',
  'material-mismatch', 'colour-far', 'head-not-reported', 'bed-unknown'];
const SEVERITIES = ['block', 'warn', 'info'];
const RANK = { block: 0, warn: 1, info: 2 };

function lib(name, file) {
  if (global && global[name]) return global[name];
  if (typeof require === 'function') { try { return require(file); } catch (_) { return null; } }
  return null;
}

const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
/** A printer name's whole words: "Snapmaker_U1" and "Snapmaker U1" are [snapmaker, u1]. */
const tokens = (v) => String(v == null ? '' : v).toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
/** The same printer when either name's words all appear in the other ("U1" in "Snapmaker U1"). */
function sameModel(a, b) {
  const ta = tokens(a), tb = tokens(b);
  if (!ta.length || !tb.length) return true;
  const sa = new Set(ta), sb = new Set(tb);
  return ta.every((t) => sb.has(t)) || tb.every((t) => sa.has(t));
}
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
  // BLOCK only on the object's PLACED extents inside the printable area (purge
  // and prime lines excluded), said by the caller as source 'placed-extents'.
  // print-fit turns a model a quarter turn only: mesh dimensions would hold a
  // 300 x 10 rod a 250 bed takes on the diagonal, and raw toolpath extents a
  // print whose purge line starts at y -4 (#2591 review, MED). Any other or
  // no source can at most warn.
  const hard = file.bounds.source === 'placed-extents' ? 'block' : 'warn';
  if (r.footprint && !r.rotated) out.push({ code: 'bed-footprint', severity: hard, over });
  if (r.height) out.push({ code: 'bed-height', severity: hard, over });
  if (r.footprint && r.rotated && !r.height) out.push({ code: 'bed-rotate', severity: 'warn', over });
}

function slicedForChecks(file, machine, out) {
  const h = isObj(file.header) ? file.header : null;
  if (!h) return;
  const PF = lib('KhaytPrintFit', './print-fit.js');
  const slack = PF && PF.SLACK != null ? PF.SLACK : 1;
  // The machine's slicer printer model when it records one, else its model.
  const haveModel = machine.printerModel || machine.model;
  const otherModel = !!(h.printerModel && haveModel && !sameModel(h.printerModel, haveModel));
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

function bedClearChecks(machine, live, opts, out) {
  if (live === undefined) return;
  const AD = lib('KhaytAutoDispatch', './auto-dispatch.js');
  const PA = lib('KhaytPrinterActivity', './printer-activity.js');
  if (!AD || typeof AD.bedState !== 'function') return;
  const l = isObj(live) ? live : {};
  const why = AD.bedState(machine, l, isObj(opts) ? opts : {});
  if (!why) return;
  const st = PA && l.state ? PA.machineStatus({ printerApi: machine.printerApi || {} }, { state: l.state }) : null;
  const ended = !!(st && st.cls === 'finished');
  // WARN on a print that ended with no "bed is clear" after it, or one the
  // book says finished after the last "clear". INFO when there is nothing to
  // go by: the printer reports no state, or it is idle and nobody ever said.
  if (ended || why === 'ad.bed_not_clear') {
    const at = Number(l.lastActivityAt);
    out.push({ code: 'bed-not-cleared', severity: 'warn', since: Number.isFinite(at) ? at : null, clearedAt: machine.bedClearedAt || null });
  } else {
    out.push({ code: 'bed-unknown', severity: 'info' });
  }
}

/**
 * @returns {Array<{code: string, severity: 'block'|'warn'|'info', slot?: number}>}
 */
function sendChecks(file, machine, loaded, live, opts) {
  const f = isObj(file) ? file : {};
  const m = isObj(machine) ? machine : {};
  const out = [];
  fileChecks(f, m, out);
  bedChecks(f, m, out);
  slicedForChecks(f, m, out);
  filamentChecks(f, m, loaded, out);
  bedClearChecks(m, live, opts, out);
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
