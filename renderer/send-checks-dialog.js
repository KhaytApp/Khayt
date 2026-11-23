'use strict';
/**
 * Send to printer, checked against the printer before it goes (C8). Built to
 * Figma desktop page 129 (7Iqw0GcrLLRW7CLDEhTa1P): S1 the checks, S1b a stop
 * (too big on the PLACED extents: Send stays off), S1c a moves-only
 * measurement (a warning, never a stop); AR the same, right to left.
 *
 * It replaces the plain "Send to …?" confirm in machines.js. The findings are
 * lib/send-checks.js's, run over what main read from the file
 * (hub:printer-send-facts), the machine record, what the printer says is
 * loaded and its poll entry (the bed rule is lib/auto-dispatch.js bedState,
 * the dispatcher's own). This file only says them and asks.
 *
 *   rows(findings, ctx)          the lines to draw, in order (pure; tested)
 *   sendChecksFor(machine, facts) the findings for this machine and file
 *   openSendChecks(opts)          the dialog; resolves true to send
 */
(function (global) {

const tr = (k, v) => (typeof t === 'function' ? t(k, v) : k);
const esc = (s) => (typeof escapeHtml === 'function'
  ? escapeHtml(String(s == null ? '' : s))
  : String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])));
const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
const n1 = (v) => { const n = Number(v); return Number.isFinite(n) ? String(Math.round(n * 10) / 10) : '?'; };

/**
 * A sentence whose {slots} are already-safe HTML: the sentence is escaped,
 * then each slot put in. Every machine- or file-supplied value goes in a
 * <bdi>, so a Latin name or a size keeps its own direction in Arabic.
 */
function say(key, html) {
  const marks = {};
  for (const k of Object.keys(html || {})) marks[k] = `\u0000${k}\u0000`;
  let s = esc(tr(key, marks));
  for (const k of Object.keys(html || {})) s = s.split(`\u0000${k}\u0000`).join(html[k]);
  return s;
}
const bdi = (v) => `<bdi>${esc(v)}</bdi>`;
const mm = (v) => bdi(tr('sc.mm', { n: n1(v) }));
const area = (b) => bdi(tr('sc.mm_area', { x: n1(b.x), y: n1(b.y) }));
const hex = (v) => { const m = /^#?([0-9a-f]{6})/i.exec(String(v || '')); return m ? '#' + m[1].toUpperCase() : null; };

/** "PLA ■" — the material, and the colour as a swatch with its hex for a screen reader. */
function filament(material, colour) {
  const h = hex(colour);
  const bits = [];
  if (material) bits.push(bdi(String(material).toUpperCase()));
  if (h) bits.push(`<span class="sc-swatch" style="background:${h}" role="img" aria-label="${esc(h)}" title="${esc(h)}"></span>`);
  return bits.join(' ') || bdi('?');
}

/**
 * The lines to draw. `ctx`: { printer (name), bed {x,y,z}, bounds (the file's,
 * with source), time(ms) → string }. A "Fits the bed" line leads when the file
 * was measured, the machine's bed is known and no bed finding was made.
 * Each line: { kind: 'ok'|'block'|'warn'|'info', code, title, hint } (HTML).
 */
function rows(findings, ctx) {
  const c = isObj(ctx) ? ctx : {};
  const list = Array.isArray(findings) ? findings : [];
  const printer = bdi(c.printer || '');
  const bed = isObj(c.bed) && +c.bed.x > 0 && +c.bed.y > 0 ? c.bed : null;
  const b = isObj(c.bounds) && +c.bounds.x > 0 && +c.bounds.y > 0 ? c.bounds : null;
  const out = [];
  const bedCodes = ['bed-footprint', 'bed-height', 'bed-rotate'];
  if (b && bed && !list.some((f) => f && bedCodes.includes(f.code))) {
    out.push({ kind: 'ok', code: 'fits', title: say('sc.fits', { model: area(b), bed: area(bed) }), hint: null });
  }
  for (const f of list) {
    if (!f || !f.code) continue;
    const kind = f.severity === 'block' ? 'block' : f.severity === 'warn' ? 'warn' : 'info';
    const hard = kind === 'block';
    const tool = bdi(String(f.slot || '?'));
    const want = isObj(f.want) ? filament(f.want.type, f.want.colour) : bdi('?');
    const have = isObj(f.have) ? filament(f.have.material, f.have.colour) : null;
    let title = null, hint = null;
    switch (f.code) {
      case 'type-unsupported':
        title = f.reason === 'not_sliced' ? say('sc.not_sliced')
          : say('sc.wrong_type', { printer, kind: bdi('.' + (f.kind || '?')) });
        hint = say('sc.slice_for', { printer });
        break;
      case 'bed-footprint': {
        const sizes = { model: b ? area(b) : bdi('?'), bed: bed ? area(bed) : bdi('?') };
        title = say(hard ? 'sc.too_big' : 'sc.may_not_fit', sizes);
        hint = hard ? say('sc.too_big_hint', { printer })
          : say(b && b.source === 'toolpath' ? 'sc.moves_hint' : 'sc.may_not_fit_hint');
        break;
      }
      case 'bed-height': {
        const sizes = { model: b && b.z ? mm(b.z) : bdi('?'), bed: bed && bed.z ? mm(bed.z) : bdi('?') };
        title = say(hard ? 'sc.too_tall' : 'sc.may_too_tall', sizes);
        hint = hard ? say('sc.too_big_hint', { printer }) : say('sc.may_not_fit_hint');
        break;
      }
      case 'bed-rotate':
        title = say('sc.rotate', { model: b ? area(b) : bdi('?'), bed: bed ? area(bed) : bdi('?') });
        hint = say('sc.rotate_hint');
        break;
      case 'sliced-for-other':
        title = f.model ? say('sc.sliced_other', { model: bdi(f.model) })
          : say('sc.sliced_bigger', { bed: isObj(f.bed) ? area(f.bed) : bdi('?') });
        hint = say('sc.sliced_other_hint', { printer });
        break;
      case 'material-mismatch':
        if (have) {
          title = say('sc.mismatch', { n: tool, have, want });
          hint = say('sc.mismatch_hint', { n: tool, want });
        } else {
          title = say('sc.no_tool', { n: tool });
          hint = say('sc.slice_for', { printer });
        }
        break;
      case 'colour-far':
        title = say('sc.mismatch', { n: tool, have: have || bdi('?'), want });
        hint = say('sc.colour_far_hint', { n: tool, want });
        break;
      case 'head-not-reported':
        title = say('sc.unreported', { n: tool });
        hint = say('sc.not_checked');
        break;
      case 'bed-not-cleared': {
        const at = Number(f.since);
        title = Number.isFinite(at) && at > 0 && typeof c.time === 'function'
          ? say('sc.bed_not_clear', { time: bdi(c.time(at)) })
          : say('sc.bed_not_clear_any');
        hint = say('sc.bed_not_clear_hint', { button: esc(tr('queue.bed_cleared')) });
        break;
      }
      case 'bed-unknown':
        title = say('sc.bed_unknown');
        hint = say('sc.bed_unknown_hint');
        break;
      default: continue;
    }
    out.push({ kind, code: f.code, title, hint });
  }
  return out;
}

/** "1 h 12 min · 38 g", or '' when the file says neither. */
function metaLine(facts) {
  const bits = [];
  const mins = Number(facts && facts.printTimeMins);
  if (Number.isFinite(mins) && mins > 0) {
    const h = Math.floor(mins / 60), m = Math.round(mins % 60);
    bits.push(h ? tr('sc.hm', { h: String(h), m: String(m) }) : tr('sc.m', { m: String(m) }));
  }
  const g = Number(facts && facts.filamentGrams);
  if (Number.isFinite(g) && g > 0) bits.push(tr('sc.g', { g: String(Math.round(g)) }));
  return bits.join(' · ');
}

/** 14:02 today, else the day and the time, in the app's language. */
function timeOf(ms) {
  const d = new Date(ms);
  const tag = typeof localeTag === 'function' ? localeTag() : undefined;
  const sameDay = new Date().toDateString() === d.toDateString();
  return sameDay
    ? d.toLocaleTimeString(tag, { hour: '2-digit', minute: '2-digit' })
    : d.toLocaleString(tag, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

/** When each machine last finished a job, from the book (auto-dispatch's lastFinishedByMachine). */
function lastFinishedByMachine() {
  const out = {};
  const log = (typeof printLog !== 'undefined' && Array.isArray(printLog)) ? printLog : [];
  for (const o of log) {
    if (!o || !o.machineId) continue;
    const at = Date.parse(o.completedAt || '');
    if (Number.isFinite(at) && !(out[o.machineId] >= at)) out[o.machineId] = at;
  }
  return out;
}

/** The findings for this machine and file, with what the printer says now. */
function sendChecksFor(machine, facts) {
  const SC = global.KhaytSendChecks;
  if (!SC || !machine) return [];
  const f = isObj(facts) ? facts : {};
  const cache = (typeof machineStatusCache !== 'undefined' && machineStatusCache) || {};
  const live = isObj(cache[machine.id]) ? cache[machine.id] : {};
  const loaded = Array.isArray(live.loaded) && live.loaded.length ? live.loaded
    : (Array.isArray(machine.loaded) ? machine.loaded : []);
  // A model that is about to be sliced (an .stl, .3mf, .step…) is not what
  // reaches the printer, so its NAME is not checked against what the printer
  // takes: the G-code the slicer writes is (review: "Slice & send" was blocked
  // as type-unsupported for every model). Only the bed and live checks run.
  const file = f.sliced ? { name: f.name || '' } : {};
  if (f.sliced) {
    file.filaments = f.filaments || [];
    file.header = f.header || null;
    if (f.bounds) file.bounds = f.bounds;
  }
  return SC.sendChecks(file, machine, loaded, live, { lastFinishedByMachine: lastFinishedByMachine() });
}

/** The dialog body (frames S1, S1b, S1c). */
function dialogHtml(opts) {
  const { machine, facts, findings, model } = opts;
  const lines = rows(findings, { printer: machine.name, bed: machine.bed, bounds: facts && facts.bounds, time: timeOf });
  const stop = global.KhaytSendChecks ? global.KhaytSendChecks.blocks(findings) : false;
  const warned = lines.some((r) => r.kind === 'warn' || r.kind === 'block');
  const label = stop ? tr('sc.send') : warned ? tr('sc.send_anyway') : model ? tr('sc.slice_send') : tr('sc.send');
  const icon = { ok: '✓', warn: '!', block: '✕', info: '?' };
  const meta = metaLine(facts);
  const list = lines.map((r) => `<div class="sc-row is-${r.kind}" data-sc-code="${esc(r.code)}">
      <span class="sc-icon" aria-hidden="true">${icon[r.kind]}</span>
      <div class="sc-text"><div class="sc-title">${r.title}</div>${r.hint ? `<div class="sc-hint">${r.hint}</div>` : ''}</div>
    </div>`).join('');
  return `<div class="modal sc-dialog" role="dialog" aria-modal="true" aria-labelledby="scTitle">
      <h3 id="scTitle" class="sc-head">${say('sc.title', { printer: bdi(machine.name || '') })}</h3>
      <div class="sc-file">${bdi((facts && facts.name) || '')}</div>
      ${meta ? `<div class="sc-meta">${esc(meta)}</div>` : ''}
      ${lines.length ? `<div class="sc-eyebrow">${esc(tr('sc.eyebrow'))}</div><div class="sc-list">${list}</div>` : ''}
      <div class="btn-row sc-actions">
        <button type="button" class="btn ghost" data-act="cancel">${esc(tr('common.cancel'))}</button>
        <button type="button" class="btn primary" data-act="send"${stop ? ' disabled aria-disabled="true"' : ''}>${esc(label)}</button>
      </div>
    </div>`;
}

/**
 * Ask before a file goes. Resolves true to send, false to stop.
 * opts: { machine, facts (hub:printer-send-facts), model (true: sliced first) }
 */
function openSendChecks(opts) {
  return new Promise((resolve) => {
    const findings = sendChecksFor(opts.machine, opts.facts);
    // The shell's stacked modal: it traps Tab inside and gives focus back on close.
    const overlay = appendStackedModal(dialogHtml({ ...opts, findings }));
    overlay.classList.add('sc-overlay');
    const stack = Array.isArray(global._escHandlerStack) ? global._escHandlerStack : null;
    const done = (v) => {
      document.removeEventListener('keydown', onKey);
      if (stack) { const i = stack.indexOf(onKey); if (i !== -1) stack.splice(i, 1); }
      overlay.remove();
      resolve(v);
    };
    const onKey = (e) => {
      if (e.key !== 'Escape') return;
      if (stack && stack[stack.length - 1] !== onKey) return;
      done(false);
    };
    if (stack) stack.push(onKey);
    document.addEventListener('keydown', onKey);
    overlay.querySelector('[data-act="cancel"]').addEventListener('click', () => done(false));
    const send = overlay.querySelector('[data-act="send"]');
    send.addEventListener('click', () => { if (!send.disabled) done(true); });
    overlay.addEventListener('click', (e) => { if (e.target === overlay) done(false); });
    (send.disabled ? overlay.querySelector('[data-act="cancel"]') : send).focus();
  });
}

const api = { rows, metaLine, sendChecksFor, openSendChecks };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytSendChecksView = api;
global.openSendChecks = openSendChecks;

})(typeof globalThis !== 'undefined' ? globalThis : this);
