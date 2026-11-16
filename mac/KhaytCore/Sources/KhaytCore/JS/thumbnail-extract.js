'use strict';
/**
 * Extract a preview thumbnail (and, for 3MF, multicolour info) from a print file —
 * WITHOUT re-rendering anything. Slicers already embed a real preview:
 *
 *   - gcode/gco : Prusa/Orca/Bambu/Cura write one or more base64 PNG blocks in the
 *                 comments (`; thumbnail begin WxH len … ; thumbnail end`). We take
 *                 the largest.
 *   - 3mf       : a ZIP whose `Metadata/thumbnail*.png` (or `Metadata/plate_*.png`)
 *                 is the slicer's own coloured render. The `*.config` members carry
 *                 filament colours + usage, from which we derive colours[] + a
 *                 best-effort swap count.
 *
 * Pure-ish (Buffer + KhaytZip); no DOM. Main-process only. Never throws — returns
 * nulls/empties so a weird file can't crash the parse. STL has no embedded preview;
 * it is rendered separately by lib/stl-thumbnail.js.
 */
(function (global) {

// Wrapped like every other module the Mac app bundles. They share ONE
// JavaScriptCore context, so a top-level `function` or `let` here is a binding
// in that shared scope — `normHex` and `extract3mf` are exactly the names a
// second module would plausibly want. test/bundled-modules-are-wrapped.test.js
// refuses an unwrapped one, and refused this one.
let KhaytZip = null;
try { KhaytZip = (typeof global !== 'undefined' && global.KhaytZip) || require('./zip-read'); } catch (_) { KhaytZip = null; }

/** Pull the largest embedded PNG thumbnail out of gcode text. */
function extractGcodeThumbnail(text) {
  if (!text) return { pngBase64: null, width: 0, height: 0 };
  const re = /;\s*thumbnail begin\s+(\d+)\s*[xX]\s*(\d+)\s+\d+([\s\S]*?);\s*thumbnail end/g;
  let m, best = null;
  while ((m = re.exec(text)) !== null) {
    const width = parseInt(m[1], 10), height = parseInt(m[2], 10);
    const b64 = m[3].replace(/;/g, '').replace(/\s+/g, '');
    /* A THUMBNAIL IS BASE64 OR IT IS NOT A THUMBNAIL.
     *
     * Stripping `;` and whitespace left `"`, `<`, `>`, `/` and `=` in place, and
     * this string is concatenated onto `data:image/png;base64,` and written into
     * an `src="…"`. HTML takes `/` as an attribute separator and CSS needs
     * neither a semicolon nor a space, so the stripping was not a defence.
     * Rejected here as well as at the sink, because a value that is not base64
     * is not a picture and should never reach a record. */
    if (!b64 || !/^[A-Za-z0-9+/]*={0,2}$/.test(b64)) continue;
    const area = width * height;
    if (!best || area > best.area) best = { pngBase64: b64, width, height, area };
  }
  return best ? { pngBase64: best.pngBase64, width: best.width, height: best.height }
              : { pngBase64: null, width: 0, height: 0 };
}

function normHex(h) {
  if (!h) return null;
  let s = String(h).trim();
  if (s[0] !== '#') s = '#' + s;
  // Accept #RGB, #RRGGBB, #RRGGBBAA — normalise to #RRGGBB.
  const m = /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.exec(s);
  if (!m) return null;
  let hex = m[1];
  if (hex.length === 3) hex = hex.split('').map((c) => c + c).join('');
  if (hex.length === 8) hex = hex.slice(0, 6);
  return '#' + hex.toUpperCase();
}

/**
 * Which reader wrote a record's colours. A record below it, or with none, was
 * written by the rule that took the printer's LOADED spools for the print's
 * colours, and is read again where its file is in reach (`coloursStale`).
 * Reader 2: only the slots the print uses (Nov 16 2026).
 */
const COLOURS_READER = 2;
function coloursStale(rec) {
  const r = Number(rec && rec.coloursReader);
  return !(Number.isFinite(r) && r >= COLOURS_READER);
}

/**
 * The filament slots (1-based) an UNSLICED Orca/Bambu project prints with.
 *
 * `filament_colour` in project_settings.config is the printer's LOADED slots,
 * four on a U1 whatever the model needs, so it cannot answer this. What does:
 *   - model_settings.config: each part's `extruder`, else its object's. It is
 *     ONE-based (slot 4 is filament_colour[3]) and value="0" means "inherit",
 *     never slot zero: an object saying 0 whose parts say 1 and 2 uses 1 and 2;
 *   - layer_config_ranges.xml: a height range's `extruder` (a relief that
 *     changes colour with height has one part and every colour here);
 *   - the paint: the slots painted faces use, read by the host from the mesh
 *     (lib/mf-mesh.js `slotsUsed`), because this rule takes text only.
 *
 * @param {{modelSettings?:string, layerRanges?:string, paintSlots?:number[]}} input
 * @returns {number[]} sorted, distinct
 */
function usedSlots(input) {
  const i = input || {};
  const out = new Set();
  const ex = (text) => +((/<metadata\b[^>]*key="extruder"[^>]*value="(\d+)"/.exec(text) || [])[1] || 0);
  const objects = String(i.modelSettings || '').split(/<object\b/).slice(1);
  for (const o of objects) {
    const [head, ...parts] = o.split(/<part\b/);
    const own = ex(head);
    if (!parts.length) out.add(own || 1);
    for (const p of parts) out.add(ex(p) || own || 1);
  }
  // No model_settings naming an object: every object prints with slot 1, the
  // slicer's default (lib/mf-mesh.js starts from the same baseState).
  if (!objects.length) out.add(1);
  for (const m of String(i.layerRanges || '').matchAll(/opt_key="extruder"\s*>\s*(\d+)/g)) if (+m[1] > 0) out.add(+m[1]);
  for (const n of (Array.isArray(i.paintSlots) ? i.paintSlots : [])) if (+n > 0) out.add(+n);
  return [...out].sort((a, b) => a - b);
}

/** Parse colours + usage + a swap estimate from the 3MF *.config members. */
/**
 * The colours a 3MF's slicer configs describe, from the config TEXT.
 *
 * Split out of `parse3mfColors` so a host that reads a zip some other way can
 * still use this rule. `lib/zip-read.js` is Node-only — Buffer and zlib — and
 * the Mac app has to open a 3MF with its own reader; without this split it
 * would have had to re-implement the three slicer formats below, which is
 * exactly how two apps come to disagree about what a model is printed in.
 *
 * Everything the rule does is here. `parse3mfColors` is now the adapter that
 * reads four named members and hands the text over, and its behaviour is
 * unchanged — proven against the original over this shop's real 3MF files and
 * generated inputs in test/thumbnail-extract.test.js.
 *
 * Unsliced Orca/Bambu: only the slots `usedSlots` finds, each with its own
 * slot's label. That needs `paint` from the host:
 *   {slots:number[]}  the mesh was read: these slots are painted (may be []);
 *   {unread:true}     the file is painted and its mesh could not be read: the
 *                     answer is NO colours with slotsKnown:false — never the
 *                     loaded spools, which is the bug this replaced.
 * A host that passes no `paint` at all predates this and gets the old answer
 * (`legacy: true`) until it is moved over; the Mac app is one (Nov 2026).
 * No slice, no swap figure: swapCount is 0, not colours − 1, and swapsKnown is
 * false — so a card can tell "not known yet" from a sliced one-colour 0.
 *
 * @param {{sliceInfo?:string, projectSettings?:string, modelSettings?:string, prusa?:string,
 *          layerRanges?:string, paint?:{slots?:number[], unread?:boolean}}} configs
 * @returns {{colors:Array, swapCount:number, usedFilaments:number, slotsKnown:boolean,
 *            colourCount:?number, reader:number, legacy?:boolean}}
 */
function colorsFromConfigs(configs) {
  const cfg = configs || {};
  const colors = [];
  const seen = new Set();
  const push = (hex, grams, label) => {
    const h = normHex(hex);
    if (!h) return;
    if (seen.has(h)) {
      // ADDED, not first-wins. A multi-plate slice_info lists the same spool
      // once per plate, and keeping the first plate's grams showed a two-plate
      // project as using one plate's worth of each colour (tester, Oct 2026).
      if (grams != null) {
        const e = colors.find((c) => c.hex === h);
        if (e) e.grams = e.grams == null ? grams : Math.round((e.grams + grams) * 100) / 100;
      }
      return;
    }
    seen.add(h);
    colors.push({ hex: h, grams: (grams != null ? grams : null), label: label || ('Filament ' + (colors.length + 1)) });
  };

  // Bambu/Orca: slice_info.config — <filament id=.. color="#hex" used_g=".." />
  const slice = String(cfg.sliceInfo || '');
  let usedFilaments = 0;
  if (slice) {
    const fre = /<filament\b[^>]*>/g; let fm;
    while ((fm = fre.exec(slice)) !== null) {
      const tag = fm[0];
      const color = /\bcolou?r\s*=\s*"([^"]+)"/i.exec(tag);
      const usedG = /\bused_g\s*=\s*"([\d.]+)"/i.exec(tag);
      // A slice lists every filament it was set up with; one it printed 0 g of
      // is not in the print. One with no used_g at all is kept: some writers
      // leave it off a filament they did use.
      if (usedG && !(parseFloat(usedG[1]) > 0)) continue;
      if (color) { push(color[1], usedG ? parseFloat(usedG[1]) : null, null); usedFilaments++; }
    }
  }

  const sliced = colors.length > 0;
  let slotsKnown = true;
  let legacy = false;
  // Bambu/Orca, unsliced: the slots the print uses, coloured from filament_colour.
  if (!colors.length && cfg.paint && typeof cfg.paint === 'object') {
    let loaded = null;
    try { loaded = JSON.parse(String(cfg.projectSettings || '')).filament_colour; } catch (_) { loaded = null; }
    if (Array.isArray(loaded) && loaded.length) {
      if (cfg.paint.unread) slotsKnown = false;
      else {
        const slots = usedSlots({ modelSettings: cfg.modelSettings, layerRanges: cfg.layerRanges, paintSlots: cfg.paint.slots });
        // A slot past the loaded list is a mixed (Full Spectrum) filament: its
        // colour is not one hex here, so say "not known" rather than guess.
        if (!slots.length || slots.some((n) => n > loaded.length)) slotsKnown = false;
        else for (const n of slots) push(loaded[n - 1], null, 'Filament ' + n);
      }
      // A painted file whose mesh was not read, or a mixed filament, gives
      // nothing rather than the loaded spools.
      if (!slotsKnown) colors.length = 0;
      return { colors, swapCount: 0, swapsKnown: false, usedFilaments, slotsKnown, colourCount: slotsKnown ? colors.length : null, reader: COLOURS_READER };
    }
  }

  // Bambu/Orca: project_settings.config (JSON) — "filament_colour": ["#hex", ...]
  // The LOADED spools: kept only for a host that passes no `paint` (above).
  if (!colors.length) {
    const proj = String(cfg.projectSettings || '') || String(cfg.modelSettings || '');
    const arr = /"filament_colou?r"\s*:\s*\[([^\]]*)\]/i.exec(proj);
    if (arr) {
      const hexes = arr[1].match(/#?[0-9a-fA-F]{6,8}/g) || [];
      hexes.forEach((h) => push(h));
      legacy = hexes.length > 0;
    }
  }

  // PrusaSlicer MMU: config text — filament_colour = #hex;#hex;...
  if (!colors.length) {
    const prusa = String(cfg.prusa || '');
    const line = /filament_colou?r\s*=\s*([#0-9a-fA-F;,\s]+)/i.exec(prusa);
    if (line) (line[1].match(/#?[0-9a-fA-F]{6,8}/g) || []).forEach((h) => push(h));
  }

  // Swap estimate: prefer an explicit filament-change count if present, else the
  // single-extruder floor (one swap between each distinct colour used).
  let swapCount = 0;
  const chg = /(?:filament[_\s]*changes?|total[_\s]*filament[_\s]*change)\D*(\d+)/i.exec(slice || '');
  if (chg) swapCount = parseInt(chg[1], 10);
  else if (colors.length > 1) swapCount = colors.length - 1;

  // Only a slice knows how often the printer changes filament; anything else
  // is a guess (colours − 1), and a card must not show it as a count.
  const out = { colors, swapCount, swapsKnown: sliced, usedFilaments, slotsKnown, colourCount: colors.length, reader: COLOURS_READER };
  if (legacy && !sliced) { out.legacy = true; out.reader = 1; }
  return out;
}

/**
 * The same rule, reading its four config members out of an open zip.
 *
 * The names, and only the names, live here. `Slic3r_PE.config` OR
 * `Prusa_Slicer.config` — either is what a PrusaSlicer 3MF carries depending on
 * its age — and `project_settings.config` before `model_settings.config`, which
 * is the order the rule wants and not alphabetical.
 */
function parse3mfColors(zip, paint) {
  const text = (name) => { const b = zip.file(name); return b ? b.toString('utf8') : ''; };
  return colorsFromConfigs({
    sliceInfo: text('Metadata/slice_info.config'),
    projectSettings: text('Metadata/project_settings.config'),
    modelSettings: text('Metadata/model_settings.config'),
    prusa: text('Metadata/Slic3r_PE.config') || text('Metadata/Prusa_Slicer.config'),
    layerRanges: text('Metadata/layer_config_ranges.xml'),
    paint,
  });
}

let MfMesh = null;
try { MfMesh = (typeof global !== 'undefined' && global.KhaytMfMesh) || require('./mf-mesh'); } catch (_) { MfMesh = null; }

/**
 * The painted slots of a 3MF, for `colorsFromConfigs`. {slots:[]} when nothing
 * is painted (the cheap case: no model member mentions paint), {slots} from the
 * mesh when it is, {unread:true} when it is painted and cannot be read.
 */
function paintOf(zip, buf) {
  const models = zip.entries.filter((e) => /\.model$/i.test(e.name));
  let painted = false;
  for (const e of models) {
    const b = KhaytZip.readEntry(buf, e);
    if (!b) return { unread: true };
    if (/paint_color=|mmu_segmentation=/.test(b.toString('latin1'))) { painted = true; break; }
  }
  if (!painted) return { slots: [] };
  if (!MfMesh || !MfMesh.extractMeshFromBuffer) return { unread: true };
  let mesh = null;
  // One preview face: only `slotsUsed` is wanted, and it is counted over every triangle.
  try { mesh = MfMesh.extractMeshFromBuffer(buf, 1); } catch (_) { mesh = null; }
  if (!mesh || mesh.skipped || !Array.isArray(mesh.slotsUsed)) return { unread: true };
  return { slots: mesh.slotsUsed };
}

/** A 3MF's colours only, with its paint read: what a library record stores. */
function colours3mf(buf) {
  const none = { colors: [], swapCount: 0, swapsKnown: false, slotsKnown: false, colourCount: null, reader: COLOURS_READER, unreadable: true };
  if (!KhaytZip || !buf) return none;
  let zip;
  try { zip = KhaytZip.openZip(buf); } catch (_) { return none; }
  if (!zip || !zip.entries.length) return none;
  return parse3mfColors(zip, paintOf(zip, buf));
}

/** Extract preview + colours from a 3MF buffer. `opts.colours === false` reads the picture only. */
function extract3mf(buf, opts) {
  const out = { pngBase64: null, colors: [], swapCount: 0 };
  if (!KhaytZip || !buf) return out;
  let zip;
  try { zip = KhaytZip.openZip(buf); } catch (_) { return out; }
  if (!zip || !zip.entries.length) return out;
  // Prefer a plate render (coloured) then the generic thumbnail; take the biggest file.
  const pngs = zip.entries.filter((e) => /^metadata\/.*\.png$/i.test(e.name.replace(/^\.?\//, '')));
  if (pngs.length) {
    pngs.sort((a, b) => b.size - a.size);
    for (const e of pngs) {
      const png = KhaytZip.readEntry(buf, e);
      if (png && png.length) { out.pngBase64 = png.toString('base64'); break; }
    }
  }
  if (opts && opts.colours === false) return out;
  const c = parse3mfColors(zip, paintOf(zip, buf));
  out.colors = c.colors;
  out.swapCount = c.swapCount;
  out.slotsKnown = c.slotsKnown;
  out.swapsKnown = c.swapsKnown;
  out.coloursReader = c.reader;
  return out;
}

/**
 * Dispatch by extension.
 * @param {{ext:string, buf?:Buffer, text?:string}} input
 * @returns {{pngBase64:string|null, colors:Array, swapCount:number, source:string}}
 */
function extract(input) {
  const ext = String((input && input.ext) || '').toLowerCase().replace(/^\./, '');
  if (ext === 'gcode' || ext === 'gco' || ext === 'g') {
    const text = input.text != null ? input.text : (input.buf ? input.buf.toString('latin1') : '');
    const t = extractGcodeThumbnail(text);
    return { pngBase64: t.pngBase64, colors: [], swapCount: 0, source: t.pngBase64 ? 'embedded' : null };
  }
  if (ext === '3mf') {
    const r = extract3mf(input.buf, { colours: input.colours });
    return { pngBase64: r.pngBase64, colors: r.colors, swapCount: r.swapCount, slotsKnown: r.slotsKnown, swapsKnown: r.swapsKnown, coloursReader: r.coloursReader, source: r.pngBase64 ? 'embedded' : null };
  }
  return { pngBase64: null, colors: [], swapCount: 0, source: null };
}

/**
 * Put a colour read on a library record: the one rule both apps re-read with
 * (lifted from renderer/printfiles.js on Nov 16 2026, for the Mac's re-read).
 *
 * MUTATES `rec`. Returns `{ changed }`: whether its colours, swap count, reader
 * or swapsKnown moved. Rules:
 *   - the read's `reader` is stamped as `coloursReader`, whatever it found;
 *   - a read that cannot name the slots (`slotsKnown: false`) or found none
 *     leaves the colours and swap count as they were: a re-read never empties
 *     what was there;
 *   - otherwise the colours are the read's, keeping the grams an earlier slice
 *     gave for a colour that is still there and that this read has none for;
 *   - `swapsKnown`, when the read says, is copied;
 *   - `updatedAt` is never touched: what a file is printed in is not an edit.
 */
function applyColours(rec, read) {
  if (!rec || typeof rec !== 'object' || !read || typeof read !== 'object') return { changed: false };
  const snap = () => JSON.stringify([rec.colors || [], rec.swapCount || 0, rec.coloursReader || 0,
    rec.swapsKnown === undefined ? null : rec.swapsKnown]);
  const was = snap();
  if (read.reader) rec.coloursReader = read.reader;
  const list = Array.isArray(read.colors) ? read.colors : [];
  if (read.slotsKnown !== false && list.length) {
    const old = Array.isArray(rec.colors) ? rec.colors : [];
    rec.colors = list.map((c) => {
      const o = old.find((x) => x && c && x.hex === c.hex);
      return o && c.grams == null && o.grams != null ? Object.assign({}, c, { grams: o.grams }) : c;
    });
    rec.swapCount = read.swapCount || 0;
    if (typeof read.swapsKnown === 'boolean') rec.swapsKnown = read.swapsKnown;
  }
  return { changed: was !== snap() };
}

const api = { extract, extractGcodeThumbnail, extract3mf, parse3mfColors, colorsFromConfigs, colours3mf, usedSlots, coloursStale, applyColours, COLOURS_READER, normHex };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
global.KhaytThumb = api;

})(typeof globalThis !== 'undefined' ? globalThis : this);
