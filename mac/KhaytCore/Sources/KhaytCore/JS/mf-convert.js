'use strict';
/**
 * 3MF converter engine (3.1) — the BedReady-style multi-printer tooling.
 *
 * A 3MF is a ZIP. This engine reads every member, rewrites ONLY the slicer metadata /
 * `Metadata/*.config` members, and repackages — the mesh (`3D/*.model`), relationships
 * (`_rels`, `[Content_Types].xml`) and thumbnails pass through byte-identical, so a
 * conversion can never corrupt geometry. Worst case a metadata field is imperfect and the
 * maker tweaks it in their slicer; the file always opens.
 *
 * Three operations (the maker picked all): retarget to a printer (re-profile: printer
 * model + bed + nozzle) combined with an optional colour→slot **remap**, and **normalize**
 * (strip vendor-locked metadata → a clean standard 3MF any slicer opens).
 *
 * Pure Node (Buffer + the zip read/write libs). Main-process only, no DOM.
 */
(function (global) {
  const zipRead = (typeof require === 'function') ? require('./zip-read') : global.KhaytZip;
  const zipWrite = (typeof require === 'function') ? require('./zip-write') : global.KhaytZipWrite;
  const profiles = (typeof require === 'function') ? require('./printer-profiles') : global.KhaytPrinterProfiles;
  const mfMesh = (typeof require === 'function') ? require('./mf-mesh')
    // `KhaytMfMesh` is what `mf-mesh.js` actually publishes. The old name
    // here was `mfMesh`, which nothing has ever defined: never wrong in
    // practice because both readers are main-process and take the
    // `require` branch, and wrong the moment the Mac app loaded this
    // into JavaScriptCore. The old name is NOT kept as a second chance —
    // a fallback that can only ever be undefined reads like an option.
    : global.KhaytMfMesh;
  const fullSpectrum = (typeof require === 'function') ? require('./full-spectrum') : global.fullSpectrum;
  const colorBands = (typeof require === 'function') ? require('./color-bands') : global.KhaytColorBands;
  const swapPauses = (typeof require === 'function') ? require('./swap-pauses') : global.KhaytSwapPauses;
  const printFit = (typeof require === 'function') ? require('./print-fit') : global.KhaytPrintFit;
  let orcaDb = null; // installed Snapmaker Orca profile DB (main-process only; absent in the renderer/browser)
  try { if (typeof require === 'function') orcaDb = require('./orca-db'); } catch (_) { orcaDb = null; }

  const CFG_BAMBU = /Metadata\/(project_settings|model_settings|slice_info)\.config$/i;
  const CFG_PRUSA = /Metadata\/(Slic3r_PE|Prusa_?Slicer)\.config$/i;
  const GEOMETRY = /(^3D\/|^_rels\/|\.rels$|\[Content_Types\]\.xml$|\.model$)/i;

  function normHex(s) {
    const m = /#?([0-9a-fA-F]{6})/.exec(String(s || ''));
    return m ? ('#' + m[1].toUpperCase()) : null;
  }

  // Zip-bomb defence: zip-read caps each member's inflated size, but a 3MF can hold many members.
  // Bound the CUMULATIVE inflated bytes (and the member count) so a multi-entry bomb can't OOM the
  // main process when a downloaded file is opened.
  //
  // 1 GiB was "far above any real multicolour 3MF" until a real one arrived: a 229 MB
  // Spider-Man poster whose 19 meshes inflate to 1168 MB. It fitted under the budget by
  // every measure a maker can see and still lost an object — 240 MB of geometry — to a
  // limit that dropped them without a word. 2 GiB clears that file with room, and
  // `truncated` below means the next one over the line says so instead of quietly
  // converting to less than it was handed.
  const MEMBERS_TOTAL_BUDGET = 2 * 1024 * 1024 * 1024;
  const MEMBERS_MAX_COUNT = 4096;

  const MESH_MEMBER = /\.model$/i;

  // Component-graph nodes one mesh walk may visit — the same ceiling lib/mf-mesh.js puts on the
  // preview's walk, and for the same hostile file. Read from there so the two cannot drift.
  const MAX_WALK_VISITS = (mfMesh && mfMesh.MAX_WALK_VISITS) || 4000000;
  // Triangles one extraction may BUILD after component instancing — mf-mesh's HARD_CAP, the
  // count past which it will not even decode a model. See the count in _extractCore.
  const MAX_BUILT_TRIANGLES = (mfMesh && mfMesh.HARD_CAP) || 30000000;

  /**
   * Read every member of a 3MF into { name, data:Buffer }. Returns [] on a bad file.
   *
   * Meshes are read LAST, and that ordering is the whole point. A 3MF's identity
   * lives in a handful of KB — project_settings.config, model_settings.config,
   * slice_info.config — while its bulk is .model geometry. Reading in archive
   * order meant a real 229 MB Orca project spent all 1 GiB of budget on meshes
   * and stopped at member 111 of 117, never reaching the configs sitting at 113
   * and 114. detectFlavour then saw no config member, returned 'generic',
   * extractFilaments found nothing, and a fully-coloured file converted to
   * nothing at all — with no error, because every step had behaved correctly on
   * the members it was given.
   *
   * The zip-bomb defence is exactly as strong. All that moves is who has first
   * claim on the budget: the few kilobytes that say what the file IS, before the
   * megabytes that say what shape it is.
   *
   * Two things the members carry besides their name:
   *
   *   `src`  the member as stored, still compressed. A repackage that doesn't
   *          rewrite a member copies these bytes instead of deflating them again
   *          (see zip-write) — on that Spider-Man file the difference is 106
   *          seconds of frozen main process against about three.
   *   `size` the uncompressed length from the central directory, known without
   *          inflating anything.
   *
   * Mesh `data` is a getter, so geometry is inflated only if something reads it.
   * Normalizing a 3MF never does — it keeps every mesh byte-for-byte — so the
   * gigabyte stays on disk. Config members are read eagerly and unconditionally:
   * they are kilobytes, and whether they PARSE is what detectFlavour answers.
   *
   * The returned array carries a non-enumerable `truncated` when the budget or the
   * member cap dropped anything, so callers can refuse rather than quietly convert
   * a partial model.
   */
  function readMembers(buf) {
    let zip;
    try { zip = zipRead.openZip(buf); } catch (_) { return tagTruncation([], null); }
    if (!zip || !zip.entries) return tagTruncation([], null);
    const out = [];
    let total = 0;
    let dropped = 0, droppedBytes = 0;
    const take = (wantMesh) => {
      for (const e of zip.entries) {
        if (MESH_MEMBER.test(e.name) !== wantMesh) continue;
        if (out.length >= MEMBERS_MAX_COUNT) { dropped++; droppedBytes += e.size || 0; continue; }
        // Budgeted on the DECLARED size, which costs nothing to read and is what
        // zip-read already caps each member's actual inflation against. Checked
        // BEFORE counting, and `continue` rather than `return`: one oversized
        // member must not close the door on every smaller one behind it.
        const declared = e.size > 0 ? e.size : e.compSize;
        if (total + declared > MEMBERS_TOTAL_BUDGET) { dropped++; droppedBytes += declared; continue; }

        const src = zip.rawOf(e);
        // ── A MEMBER THAT DECLARES NOTHING ──────────────────────────────────
        // The declared size is only a fair charge when zip-read holds the inflate to it.
        // It does for a member that declares a size (size + 1 KB), but one declaring
        // `size: 0` may inflate to zip-read's full per-member ceiling (MAX_INFLATED, 400
        // MB) while being charged its compressed size here — a kilobyte. A few hundred
        // such members in a small archive were "within budget" and could inflate to
        // terabytes the moment anything read their lazy `data`. So a deflated member
        // that declares nothing is read now, like a config, its inflate held to what is
        // left of the budget, and charged what it really inflated to — or, when it would
        // not fit, the whole allowance it was given, so a run of them cannot each cost
        // the full ceiling in work while costing the budget nothing.
        const undeclared = e.size === 0 && e.method === 8;
        if (undeclared) {
          const allowance = Math.min(zipRead.MAX_INFLATED || MEMBERS_TOTAL_BUDGET, MEMBERS_TOTAL_BUDGET - total);
          // readEntry caps an inflate at `size + 1 KB`; this asks it for the allowance.
          const data = allowance > 1024 ? zipRead.readEntry(buf, Object.assign({}, e, { size: allowance - 1024 })) : null;
          if (!data) {
            total += Math.max(0, allowance);
            // Past the budget it is a part left out, and the convert must say so. A member
            // that fails within zip-read's own ceiling is corrupt, and is skipped as before.
            if (allowance < (zipRead.MAX_INFLATED || 0)) { dropped++; droppedBytes += Math.max(0, allowance); }
            continue;
          }
          total += data.length;
          out.push({ name: e.name, size: data.length, data, src });
          continue;
        }
        if (wantMesh) {
          const member = { name: e.name, size: e.size, src };
          let cached;
          Object.defineProperty(member, 'data', {
            enumerable: true,
            configurable: true,
            get() {
              if (cached === undefined) cached = zip.entryData(e) || Buffer.alloc(0);
              return cached;
            },
          });
          total += declared;
          out.push(member);
        } else {
          const data = zip.entryData(e);
          if (!data) continue;
          // Charged on what it REALLY inflated to, and checked again: the check above
          // used the declared size, which for an undeclared member is not a bound.
          if (total + data.length > MEMBERS_TOTAL_BUDGET) { dropped++; droppedBytes += data.length; continue; }
          total += data.length;
          out.push({ name: e.name, size: data.length, data, src });
        }
      }
    };
    take(false);   // configs, thumbnails, rels — what the file is
    take(true);    // geometry, with whatever budget remains
    return tagTruncation(out, dropped ? { members: dropped, bytes: droppedBytes } : null);
  }

  /**
   * A member's uncompressed length without inflating it. Falls back to the buffer for
   * members built in memory (mf-write's meshTo3mf, the tests) that carry no `size`.
   */
  function memberSize(m) {
    if (!m) return 0;
    if (Number.isFinite(m.size)) return m.size;
    return m.data ? m.data.length : 0;
  }

  /** Record what a read had to leave behind, without changing the array everyone consumes. */
  function tagTruncation(arr, info) {
    Object.defineProperty(arr, 'truncated', { value: info, enumerable: false, configurable: true });
    return arr;
  }

  /* ── BOUNDED, LINEAR READS OF THE SLICER'S XML ─────────────────────────────
   *
   * `/<plate\b[\s\S]*?<\/plate>/gi` is quadratic on a file that opens many
   * `<plate ` tags and never closes them: each start scans to the end of the
   * text looking for a close that is not there. 350 KB of unclosed `<plate `
   * took 4.9 s (alpha.59 review). A crafted 3MF is something a shop is SENT,
   * so this reads blocks with indexOf-style scans that stop as soon as no
   * closing tag remains, and caps how many it takes.
   *
   * The caps are far above anything a slicer writes — a Bambu/Orca project
   * tops out at a few dozen plates and 16-32 filament slots — and exist only
   * so a hostile file cannot turn one import into minutes of work or a book
   * full of junk rows. */
  const MAX_PLATES = 256;
  const MAX_PLATE_FILAMENTS = 64;
  const MAX_PLATE_NAME = 80;
  // Sane ceilings for the slicer's figures: a kilometre of filament, 100 kg,
  // a print a year long. Anything past them is not a print, it is a file built
  // to make every total downstream Infinity.
  const MAX_GRAMS = 100000;
  const MAX_METERS = 1000000;
  const MAX_SECONDS = 365 * 24 * 3600;
  const MAX_PLATE_INDEX = 999999;

  /** A finite number in [0, max], or NaN when the text is not one. */
  function bounded(v, max) {
    const n = typeof v === 'number' ? v : parseFloat(v);
    if (!Number.isFinite(n) || n < 0) return NaN;
    return Math.min(n, max);
  }

  /** `&amp;`, `&lt;`, `&#1575;`… → the characters they stand for. */
  function decodeXml(text) {
    return String(text == null ? '' : text).replace(/&(#x[0-9a-f]{1,6}|#\d{1,7}|amp|lt|gt|quot|apos);/gi, (whole, ent) => {
      const e = ent.toLowerCase();
      if (e === 'amp') return '&';
      if (e === 'lt') return '<';
      if (e === 'gt') return '>';
      if (e === 'quot') return '"';
      if (e === 'apos') return "'";
      const code = e[1] === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      try { return (code > 0 && code <= 0x10FFFF) ? String.fromCodePoint(code) : ''; } catch (_) { return ''; }
    });
  }

  /** An attribute value as a shop should see it: entities decoded, control
   *  characters out, trimmed and cut to `max` characters. */
  function cleanText(text, max) {
    // eslint-disable-next-line no-control-regex
    const s = decodeXml(text).replace(/[\u0000-\u001f\u007f]/g, ' ').trim();
    return Array.from(s).slice(0, max).join('');
  }

  /**
   * Every `<tag …>…</tag>` block in `text`, in order, at most `max` of them.
   * Linear: one pass for the opening tags, and the search for each close
   * starts where the last one ended — when no close is left, it stops.
   */
  function tagBlocks(text, tag, max) {
    const out = [];
    if (!text) return out;
    const open = new RegExp('<' + tag + '(?![\\w:-])', 'gi');
    const close = new RegExp('</' + tag + '\\s*>', 'gi');
    let m;
    while (out.length < max && (m = open.exec(text))) {
      close.lastIndex = m.index + 1;
      const c = close.exec(text);
      if (!c) break;
      out.push(text.slice(m.index, c.index + c[0].length));
      open.lastIndex = c.index + c[0].length;
    }
    return out;
  }

  /** The opening `<tag …>` tags in `text`, at most `max`. `[^<>]*` keeps each
   *  try to the tag's own length, so a run of unclosed `<filament ` is linear. */
  function openTags(text, tag, max) {
    const out = [];
    if (!text) return out;
    const re = new RegExp('<' + tag + '\\b[^<>]*>', 'gi');
    let m;
    while (out.length < max && (m = re.exec(text))) out.push(m[0]);
    return out;
  }

  /** One attribute of one tag, raw (entities still encoded). */
  function attr(tag, name) {
    const m = new RegExp('\\s' + name + '="([^"]*)"', 'i').exec(tag);
    return m ? m[1] : null;
  }

  function memberText(members, re) {
    const m = members.find((x) => re.test(x.name));
    // `data == null` is a member a host passed by NAME rather than by content
    // (see `retilePlatesForBed`). Not there and too big to hand over are the
    // same answer to "what does this file say": nothing we can read.
    return m && m.data != null ? m.data.toString('utf8') : null;
  }

  function detectFlavour(members) {
    const names = members.map((m) => m.name);
    if (names.some((n) => CFG_BAMBU.test(n))) {
      // Bambu vs Orca share the config family; slice_info's header hints at Orca.
      const si = memberText(members, /slice_info\.config$/i) || '';
      return /orca/i.test(si) ? 'orca' : 'bambu';
    }
    if (names.some((n) => CFG_PRUSA.test(n))) return 'prusa';
    return 'generic';
  }

  /** Lenient JSON parse of a *.config member (Bambu/Orca project settings). */
  function tryJson(text) {
    if (!text) return null;
    try { return JSON.parse(text); } catch (_) { return null; }
  }

  /**
   * One `key = value` out of a PrusaSlicer config, or null.
   *
   * ── THE `; ` IN FRONT OF EVERY LINE ──────────────────────────────────────
   *
   * PrusaSlicer writes `Metadata/Slic3r_PE.config` with its whole settings block
   * commented out — every line is `; printer_model = MK4S`, not
   * `printer_model = MK4S`. The readers and writers here were anchored at the
   * line start on the bare key, so on a real Prusa file they matched nothing at
   * all: the source printer, nozzle and bed came back empty, and a Prusa→Prusa
   * retarget rewrote nothing while still listing `printer_model` and `bed_shape`
   * under "fields changed". Found by bedready.io (src/lib/convert.ts iniValue),
   * which this is ported from.
   *
   * The rest of the pattern is that file's too, for the reasons it gives: `[ \t]`
   * rather than `\s` so nothing can cross a line break (an EMPTY value then
   * captured the next line), `(\S.*)` so an empty value is no match, and only a
   * `;` and spaces allowed before the key, so `physical_printer_settings_id` is
   * never read as `printer_settings_id`. The uncommented form still reads — a
   * hand-written or older config has no `;`.
   */
  function iniValue(ini, key) {
    const m = new RegExp('^[ \\t]*;?[ \\t]*' + key + '[ \\t]*=[ \\t]*(\\S[^\\r\\n]*)$', 'im').exec(String(ini || ''));
    return m ? m[1].trim() : null;
  }

  /**
   * Rewrite one key in a PrusaSlicer config, KEEPING whatever prefix the line had —
   * `; ` on a real file, nothing on a bare one — so the rewritten file is the same
   * dialect it came in as. `value` may be a function of the old value. Returns
   * `{ text, hit }`; `hit` is false when the key is not there, so a caller reports a
   * field as changed only when it was.
   */
  function iniSet(text, key, value) {
    let hit = false;
    const re = new RegExp('^([ \\t]*;?[ \\t]*' + key + '[ \\t]*=)[ \\t]*([^\\r\\n]*)$', 'im');
    const out = text.replace(re, (_all, pre, old) => {
      hit = true;
      return pre + ' ' + (typeof value === 'function' ? value(old.trim()) : value);
    });
    return { text: out, hit };
  }

  /** Ordered filament colours from whatever config the file carries. */
  function extractFilaments(members) {
    let list = [];
    // Bambu/Orca JSON project settings.
    const projText = memberText(members, /project_settings\.config$/i)
      || memberText(members, /model_settings\.config$/i);
    const proj = tryJson(projText);
    if (proj && Array.isArray(proj.filament_colour)) {
      list = proj.filament_colour.map((c, i) => ({ index: i, color: normHex(c) })).filter((f) => f.color);
    }
    if (!list.length) {
      // Bambu/Orca slice_info.config — <filament id="1" color="#hex" used_g="..">.
      const slice = memberText(members, /slice_info\.config$/i);
      if (slice) {
        const out = [];
        // One entry per filament SLOT. A multi-plate file lists slot 1 once
        // per plate; listing every tag made a two-plate, two-colour project
        // read as four filaments.
        const slots = new Set();
        for (const tag of openTags(slice, 'filament', MAX_PLATES * MAX_PLATE_FILAMENTS)) {
          const id = attr(tag, 'id');
          if (id != null && slots.has(id)) continue;
          if (id != null) slots.add(id);
          const color = normHex(attr(tag, 'colou?r'));
          if (color) out.push({ index: out.length, color });
          if (out.length >= MAX_PLATE_FILAMENTS) break;
        }
        if (out.length) list = out;
      }
    }
    if (!list.length) {
      // PrusaSlicer: filament_colour = #a;#b;#c
      const prusa = memberText(members, CFG_PRUSA);
      if (prusa) {
        const line = iniValue(prusa, 'filament_colou?r');
        if (line) {
          list = line.split(/[;,]/).map((s) => normHex(s)).filter(Boolean)
            .map((color, i) => ({ index: i, color }));
        }
      }
    }
    // PrusaSlicer "Full Spectrum" (ColorMix): the real palette is the physical bases PLUS the virtual
    // (mixed) colours in *_full_spectrum.json; filament_colour only carries the bases, so the mixed states
    // (5+) would otherwise be invisible to conversion + Full-Spectrum planning. Prefer the FS palette when
    // it's strictly longer — mirrors the preview reader (lib/mf-mesh.js).
    if (mfMesh && mfMesh.fullSpectrumFromMembers) {
      const fsPal = mfMesh.fullSpectrumFromMembers(members).palette;
      if (fsPal && fsPal.length > list.length) {
        list = fsPal.map((color, i) => ({ index: i, color: normHex(color) })).filter((f) => f.color);
      }
    }
    return list;
  }

  /**
   * Best-effort source metadata for the pre-convert summary: original printer, bed, nozzle,
   * layer height, per-filament grams, total grams and print time. Never throws — a field we
   * can't find is simply omitted.
   */
  function extractMeta(members) {
    const meta = { printerModel: null, nozzle: null, layerHeight: null, bed: null, grams: [], totalGrams: 0, printMinutes: null };
    const projText = memberText(members, /project_settings\.config$/i) || memberText(members, /model_settings\.config$/i);
    const proj = tryJson(projText);
    if (proj) {
      meta.printerModel = proj.printer_model || proj.printer_settings_id || null;
      const nz = proj.nozzle_diameter;
      meta.nozzle = Array.isArray(nz) ? Number(nz[0]) : (Number(nz) || null);
      meta.layerHeight = Number(proj.layer_height) || null;
      const pa = proj.printable_area; // ["0x0","256x0","256x256","0x256"]
      if (Array.isArray(pa) && pa.length >= 3) {
        let mx = 0, my = 0;
        for (const s of pa) { const c = /(-?[\d.]+)x(-?[\d.]+)/.exec(String(s)); if (c) { mx = Math.max(mx, +c[1]); my = Math.max(my, +c[2]); } }
        if (mx && my) meta.bed = { x: Math.round(mx), y: Math.round(my) };
      }
    }
    const slice = memberText(members, /slice_info\.config$/i);
    let plateGrams = null;
    if (slice) {
      for (const tag of openTags(slice, 'filament', MAX_PLATES * MAX_PLATE_FILAMENTS)) {
        const g = bounded(attr(tag, 'used_g'), MAX_GRAMS);
        if (!isNaN(g)) meta.grams.push(g);
      }
      if (!meta.printerModel) { const pm = /(?:printer_model_id|Printer Model)"?\s*(?:=|value=)?\s*"?([^"<>]+)"?/i.exec(slice); if (pm) meta.printerModel = pm[1].trim(); }
      // Bambu/Orca write this as <metadata key="prediction" value="7200"/>, so the
      // number is in a SEPARATE attribute from the name. Matching `prediction=`
      // never fired on a real file — grams came through and the time silently did
      // not. The bare-attribute form is kept as a fallback for older writers.
      //
      // EVERY PLATE, NOT THE FIRST. A multi-plate file writes one <plate> block
      // each, with its own prediction and its own filaments. The time used to be
      // the first plate's while the grams above were every plate's, so
      // model-intake priced a two-plate file at one plate's hours against two
      // plates' filament (found on a real Bambu/Orca file by the Mac session,
      // whose KhaytEngine.slicerFigures reads plates the same way).
      const predOf = (t) => {
        const pt = /key="prediction"\s+value="(\d+)"/i.exec(t) || /\bprediction="(\d+)"/i.exec(t);
        if (!pt) return null;
        const v = bounded(pt[1], MAX_SECONDS);
        return isNaN(v) ? null : v;
      };
      const plateBlocks = tagBlocks(slice, 'plate', MAX_PLATES);
      if (plateBlocks.length) {
        let secs = 0, timed = false, rawGrams = 0;
        const plates = [];
        // The shop's own plate names live in model_settings.config, keyed by
        // `plater_id` — the same number slice_info writes as the plate's
        // `index`. Absent (an exported plate, a non-Bambu writer) is no name.
        const names = plateNames(members);
        // Per filament SLOT across every plate: slot 1 on plate 2 is the same
        // spool as slot 1 on plate 1, so the project's own use of each spool is
        // the sum — what a shop needs to know it has enough of each colour.
        const bySlot = new Map();
        // A plate index is a small whole number the slicer counts from 1. One
        // that is not (1e20, a repeat) is replaced by the next free one, so a
        // crafted file cannot hand the apps a number no Int holds or two
        // plates the screen cannot tell apart.
        const usedIndex = new Set();
        plateBlocks.forEach((pb, i) => {
          const s = predOf(pb);
          if (s != null) { secs += s; timed = true; }
          let g = 0;
          const filaments = [];
          for (const tag of openTags(pb, 'filament', MAX_PLATE_FILAMENTS)) {
            const v = bounded(attr(tag, 'used_g'), MAX_GRAMS);
            if (!isNaN(v)) g += v;
            const m = bounded(attr(tag, 'used_m'), MAX_METERS);
            const id = cleanText(attr(tag, 'id'), 16) || String(filaments.length + 1);
            const f = {
              id,
              type: cleanText(attr(tag, 'type'), 40) || null,
              color: cleanText(attr(tag, 'colou?r'), 16) || null,
              grams: isNaN(v) ? 0 : Math.round(v * 100) / 100,
              meters: isNaN(m) ? 0 : Math.round(m * 100) / 100,
            };
            filaments.push(f);
            const had = bySlot.get(id);
            if (had) { had.grams += f.grams; had.meters += f.meters; }
            else if (bySlot.size < MAX_PLATE_FILAMENTS) bySlot.set(id, { ...f });
          }
          if (!g) {
            const w = /key="weight"\s+value="([\d.]+)"/i.exec(pb);
            const wv = w ? bounded(w[1], MAX_GRAMS) : NaN;
            if (!isNaN(wv)) g = wv;
          }
          g = Math.min(g, MAX_GRAMS);
          rawGrams += g;
          const idx = /key="index"\s+value="(\d{1,9})"/i.exec(pb);
          const ft = filaments.find((f) => f.type);
          let index = idx ? +idx[1] : i + 1;
          if (!(index >= 1 && index <= MAX_PLATE_INDEX) || usedIndex.has(index)) {
            index = i + 1;
            while (usedIndex.has(index)) index += 1;
          }
          usedIndex.add(index);
          plates.push({
            index,
            name: names.get(index) || null,
            printTimeMins: s != null ? Math.round(s / 60) : null,
            filamentGrams: Math.round(g * 10) / 10,
            filamentType: ft ? ft.type : null,
            filaments,
          });
        });
        if (timed) meta.printMinutes = Math.round(secs / 60);
        if (plates.length >= 2) meta.plates = plates;
        if (bySlot.size) {
          meta.filaments = [...bySlot.values()].map((f) => ({
            ...f, grams: Math.round(f.grams * 100) / 100, meters: Math.round(f.meters * 100) / 100,
          }));
        }
        // The grams, too, are the plates' own — including a plate that reports
        // only its weight — so the two figures always describe the same print.
        // Summed before rounding: 34.75 + 32.75 is 67.5, where the plates'
        // own 0.1 g figures (34.8 + 32.8) would have made it 67.6.
        plateGrams = rawGrams;
      } else {
        const s = predOf(slice);
        if (s != null) meta.printMinutes = Math.round(s / 60);
      }
    }
    const prusa = memberText(members, CFG_PRUSA);
    if (prusa) {
      // iniValue, not a bare `^key =`: a real PrusaSlicer file comments every line out
      // (`; printer_model = MK4S`), and the bare form found nothing in one.
      if (!meta.printerModel) { const p = iniValue(prusa, 'printer_model'); if (p) meta.printerModel = p; }
      if (!meta.nozzle) { const nz = /^[\d.]+/.exec(iniValue(prusa, 'nozzle_diameter') || ''); if (nz) meta.nozzle = +nz[0]; }
      if (!meta.layerHeight) { const lh = /^[\d.]+/.exec(iniValue(prusa, 'layer_height') || ''); if (lh) meta.layerHeight = +lh[0]; }
      if (!meta.bed) { const bs = iniValue(prusa, 'bed_shape'); if (bs) { const pts = bs.split(',').map((s) => s.split('x').map(Number)); const xs = pts.map((p) => p[0]).filter(Number.isFinite), ys = pts.map((p) => p[1]).filter(Number.isFinite); if (xs.length && ys.length) meta.bed = { x: Math.round(Math.max(...xs)), y: Math.round(Math.max(...ys)) }; } }
    }
    meta.totalGrams = Math.round((plateGrams != null && plateGrams > 0 ? plateGrams : meta.grams.reduce((a, b) => a + b, 0)) * 10) / 10;
    return meta;
  }

  const UNIT_MM = { micron: 0.001, micrometer: 0.001, millimeter: 1, centimeter: 10, meter: 1000, inch: 25.4, foot: 304.8 };
  const parseT = (s) => { const t = String(s || '').trim().split(/\s+/).map(Number); return (t.length === 12 && t.every(Number.isFinite)) ? t : null; };
  const cornersOf = (b) => { const o = []; for (const X of [b.mnx, b.mxx]) for (const Y of [b.mny, b.mxy]) for (const Z of [b.mnz, b.mxz]) o.push([X, Y, Z]); return o; };
  const applyT = (p, t) => t ? [p[0] * t[0] + p[1] * t[3] + p[2] * t[6] + t[9], p[0] * t[1] + p[1] * t[4] + p[2] * t[7] + t[10], p[0] * t[2] + p[1] * t[5] + p[2] * t[8] + t[11]] : p;
  const bboxOf = (pts) => { let x0 = Infinity, y0 = Infinity, z0 = Infinity, x1 = -Infinity, y1 = -Infinity, z1 = -Infinity; for (const p of pts) { if (p[0] < x0) x0 = p[0]; if (p[1] < y0) y0 = p[1]; if (p[2] < z0) z0 = p[2]; if (p[0] > x1) x1 = p[0]; if (p[1] > y1) y1 = p[1]; if (p[2] > z1) z1 = p[2]; } return { mnx: x0, mny: y0, mnz: z0, mxx: x1, mxy: y1, mxz: z1 }; };

  /**
   * Overall model footprint (mm) from the mesh — the union of every build item's transformed
   * object bounding box, honouring the file's declared unit and resolving <component>-composed
   * assemblies recursively. Best-effort and safe-by-default: returns null (→ no fit verdict shown)
   * whenever geometry can't be fully resolved, so the bed-fit check never reports a false "Fits".
   */
  function computeBounds(members) {
    const norm = (p) => String(p || '').replace(/^\/+/, '').toLowerCase();
    // Parse EVERY .model member: Bambu/Orca "split" 3MFs keep geometry in 3D/Objects/*.model
    // referenced by p:path from the root, so a single-member read resolved to null (→ no fit
    // verdict). Objects are keyed "<normpath>#<id>" so cross-file <component> refs resolve;
    // the root is the member carrying the <build> block. Mirrors _extractCore's keying.
    // `size` is the declared length, so an oversized mesh is skipped without being
    // inflated first — the filter used to read m.data and pay for every member it
    // then threw away.
    const modelMembers = members.filter((m) => /\.model$/i.test(m.name) && memberSize(m) <= 48 * 1024 * 1024);
    if (!modelMembers.length) return null;

    const objs = {};
    let rootKey = null, rootText = '', scale = 1, firstKey = null, firstScale = 1;
    for (const mm of modelMembers) {
      let text;
      try { text = mm.data.toString('utf8'); } catch (_) { continue; } // over V8's string limit — skip, don't fail all
      const fkey = norm(mm.name);
      const fscale = UNIT_MM[((/<model\b[^>]*\bunit="([^"]+)"/i.exec(text) || [])[1] || 'millimeter').toLowerCase()] || 1;
      if (!firstKey) { firstKey = fkey; firstScale = fscale; }
      if (!rootKey && /<build\b[^>]*>[\s\S]*?<item\b/i.test(text)) { rootKey = fkey; rootText = text; scale = fscale; }
      const objRe = /<object\b[^>]*\bid="([^"]+)"[^>]*>([\s\S]*?)<\/object>/g; let om;
      while ((om = objRe.exec(text))) {
        const block = om[2];
        const comps = [];
        const cRe = /<component\b([^>]*?)\/?>/g; let cm;
        while ((cm = cRe.exec(block))) {
          const ref = (/\bobjectid="([^"]+)"/i.exec(cm[1]) || [])[1];
          if (!ref) continue;
          const pp = (/\b(?:p:)?path="([^"]+)"/i.exec(cm[1]) || [])[1];
          comps.push({ ref, path: pp ? norm(pp) : fkey, t: parseT((/transform="([^"]+)"/i.exec(cm[1]) || [])[1]) });
        }
        const vRe = /<vertex\b([^>]*?)\/?>/g; let vm;
        let mnx = Infinity, mny = Infinity, mnz = Infinity, mxx = -Infinity, mxy = -Infinity, mxz = -Infinity, has = false;
        while ((vm = vRe.exec(block))) { const va = vm[1]; const x = parseFloat((/\bx=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]), y = parseFloat((/\by=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]), z = parseFloat((/\bz=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]); if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(z)) continue; has = true; if (x < mnx) mnx = x; if (y < mny) mny = y; if (z < mnz) mnz = z; if (x > mxx) mxx = x; if (y > mxy) mxy = y; if (z > mxz) mxz = z; }
        objs[fkey + '#' + om[1]] = { verts: has ? { mnx, mny, mnz, mxx, mxy, mxz } : null, comps };
      }
    }
    if (!Object.keys(objs).length) return null;
    if (!rootKey) { rootKey = firstKey; rootText = ''; scale = firstScale; } // no <build> → resolve every object

    // Resolve an object's bbox in its own local space (memoized, cycle-guarded). Returns null if
    // any referenced component can't be resolved — the caller then bails rather than under-count.
    const memo = {};
    function resolve(key, seen) {
      if (memo[key]) return memo[key];
      const o = objs[key];
      if (!o || (seen && seen.has(key))) return null;
      const pts = [];
      if (o.verts) pts.push(...cornersOf(o.verts));
      for (const c of o.comps) {
        const child = resolve(c.path + '#' + c.ref, new Set(seen || []).add(key));
        if (!child) return null;
        for (const p of cornersOf(child)) pts.push(applyT(p, c.t));
      }
      if (!pts.length) return null;
      return (memo[key] = bboxOf(pts));
    }

    const buildBlock = (/<build\b[^>]*>([\s\S]*?)<\/build>/i.exec(rootText || '') || [])[1];
    const items = [];
    if (buildBlock) { const itRe = /<item\b[^>]*>/g; let im; while ((im = itRe.exec(buildBlock))) items.push(im[0]); }
    // Per plate, for the reason measureMesh gives: a footprint drawn round
    // every plate at once is the layout, and `fitWarnings` was telling a shop
    // its 80 mm part would not go on a 256 mm bed because plate two sat 300 mm
    // to the right of plate one.
    const byPlate = new Map();
    const push = (k, p) => { let a = byPlate.get(k); if (!a) byPlate.set(k, (a = [])); a.push(p); };
    if (items.length) {
      const onPlate = plateOf(members);
      for (const it of items) {
        const oid = (/objectid="([^"]+)"/i.exec(it) || [])[1];
        const b = resolve(rootKey + '#' + oid, null);
        if (!b) return null; // an unresolvable item → don't trust the footprint
        const t = parseT((/transform="([^"]+)"/i.exec(it) || [])[1]);
        for (const p of cornersOf(b)) push(onPlate.get(String(oid)) || 1, applyT(p, t));
      }
    } else {
      for (const key in objs) { const b = resolve(key, null); if (b) for (const p of cornersOf(b)) push(1, p); }
    }
    if (!byPlate.size) return null;
    const boxes = new Map();
    for (const [k, pts] of byPlate) { const g = bboxOf(pts); boxes.set(k, { minX: g.mnx, minY: g.mny, minZ: g.mnz, maxX: g.mxx, maxY: g.mxy, maxZ: g.mxz }); }
    const g = largestPlate(boxes);
    return { x: Math.round((g.maxX - g.minX) * scale * 10) / 10, y: Math.round((g.maxY - g.minY) * scale * 10) / 10, z: Math.round((g.maxZ - g.minZ) * scale * 10) / 10 };
  }

  /**
   * Extract the model's triangle soup in global mm coordinates — vertices resolved through
   * each object's triangles, <component> assemblies (recursively) and the build items'
   * transforms, scaled by the file's declared unit. Used to write a 3MF back out to STL.
   * Returns null when geometry can't be fully resolved or the mesh is too large to scan.
   */
  // Core mesh reader. Parses EVERY .model member (Bambu/Orca "split" 3MFs keep geometry in
  // 3D/Objects/*.model referenced via p:path), keys objects "<normpath>#<id>", follows
  // components / build items. When wantPaint, also captures each triangle's per-facet paint
  // code (Bambu/Orca paint_color, Prusa mmu_segmentation) in emit order for true multicolour.
  function _extractCore(members, wantPaint, opts) {
    const norm = (p) => String(p || '').replace(/^\/+/, '').toLowerCase();
    // Cap per-member size only near V8's max string length (~512M chars) — a detailed model can
    // keep its whole mesh in one big 3D/Objects/*.model part, and dropping it left us with just
    // the component-reference root (no vertices) → an empty mesh. 480MB comfortably clears the
    // largest real files while staying under the toString() limit.
    const modelMembers = members.filter((m) => /\.model$/i.test(m.name) && memberSize(m) <= 480 * 1024 * 1024);
    if (!modelMembers.length) return null;
    // Preview thinning: a multi-million-triangle model only needs a representative slice on
    // screen. Rather than build every triangle as a nested array (gigabytes, seconds of stall,
    // and OOM in the main process) then decimate, count facets up front and keep only every
    // Nth during the parse. opts.maxTris caps the built mesh; without it we keep everything
    // (the STL-export path needs the full mesh). thinned flags that geometry was sampled.
    const maxTris = (opts && opts.maxTris > 0) ? opts.maxTris : 0;
    let stride = 1;
    if (maxTris) {
      let total = 0; const needle = Buffer.from('<triangle');
      for (const mm of modelMembers) { let i = 0; const b = mm.data; while ((i = b.indexOf(needle, i)) !== -1) { total++; i += needle.length; } }
      if (total > maxTris) stride = Math.ceil(total / maxTris);
    }
    const thinned = stride > 1;
    let gTri = 0; // running facet counter across all objects, for uniform stride sampling
    const paintRe = /\b(?:paint_color|(?:slic3r(?:pe)?:)?mmu_segmentation)="([^"]+)"/i;
    const objs = {};
    // Only the root file's text (the one with the <build> block) is needed after parsing; keeping
    // every file's text would double-hold a 200MB+ geometry part. Each non-root text is dropped as
    // its loop iteration ends so peak memory is ~one big file at a time.
    let rootKey = null, rootText = '', scale = 1, firstKey = null, firstScale = 1;
    for (const mm of modelMembers) {
      let text;
      try { text = mm.data.toString('utf8'); } catch (_) { continue; } // over V8's string limit — skip, don't fail all
      const fkey = norm(mm.name);
      const fscale = UNIT_MM[((/<model\b[^>]*\bunit="([^"]+)"/i.exec(text) || [])[1] || 'millimeter').toLowerCase()] || 1;
      if (!firstKey) { firstKey = fkey; firstScale = fscale; }
      if (!rootKey && /<build\b[^>]*>[\s\S]*?<item\b/i.test(text)) { rootKey = fkey; rootText = text; scale = fscale; }
      const objRe = /<object\b([^>]*)>([\s\S]*?)<\/object>/g; let om;
      while ((om = objRe.exec(text))) {
        const id = (/\bid="([^"]+)"/i.exec(om[1]) || [])[1];
        if (!id) continue;
        const block = om[2];
        const verts = [];
        // Robust float parse: accepts scientific notation incl. negative exponents (1.5e-3),
        // single OR double quotes, in any x/y/z order — a single unparsed vertex would corrupt
        // every triangle that indexes it and collapse the whole mesh, so this must be forgiving.
        const vRe = /<vertex\b([^>]*?)\/?>/g; let vm;
        while ((vm = vRe.exec(block))) {
          const va = vm[1];
          const x = parseFloat((/\bx=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]);
          const y = parseFloat((/\by=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]);
          const z = parseFloat((/\bz=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]);
          // null (not [0,0,0]) for an unparseable vertex: keeps index alignment while letting the
          // a&&b&&c guards drop any triangle that references it — otherwise it spikes to the origin.
          verts.push((Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(z)) ? [x, y, z] : null);
        }
        const tris = [];
        const paint = wantPaint ? [] : null;
        // `[^>]*?` (not `[^>/]*`) so an attribute value containing a "/" — some slicers put
        // one in paint/segmentation data — doesn't truncate the match and silently drop facets.
        const tRe = /<triangle\b([^>]*?)\/?>/g; let tm;
        while ((tm = tRe.exec(block))) {
          if (stride > 1 && (gTri++ % stride) !== 0) continue; // keep only every Nth facet
          const a = tm[1];
          const v1 = (/\bv1=["']?(\d+)/.exec(a) || [])[1], v2 = (/\bv2=["']?(\d+)/.exec(a) || [])[1], v3 = (/\bv3=["']?(\d+)/.exec(a) || [])[1];
          if (v1 == null || v2 == null || v3 == null) continue;
          tris.push([+v1, +v2, +v3]);
          if (wantPaint) { const pm = paintRe.exec(a); paint.push(pm ? pm[1] : null); }
        }
        const comps = [];
        const cRe = /<component\b([^>]*?)\/?>/g; let cm;
        while ((cm = cRe.exec(block))) {
          const ref = (/\bobjectid="([^"]+)"/i.exec(cm[1]) || [])[1];
          if (!ref) continue;
          const pp = (/\b(?:p:)?path="([^"]+)"/i.exec(cm[1]) || [])[1];
          comps.push({ ref, path: pp ? norm(pp) : fkey, t: parseT((/transform="([^"]+)"/i.exec(cm[1]) || [])[1]) });
        }
        objs[fkey + '#' + id] = { verts, tris, paint, comps };
      }
    }
    if (!Object.keys(objs).length) return null;
    if (!rootKey) { rootKey = firstKey; scale = firstScale; } // no <build> block → resolve every object

    const memo = {};
    function resolve(key, seen) {
      if (memo[key]) return memo[key];
      const o = objs[key];
      if (!o || (seen && seen.has(key))) return null;
      const geo = [], pnt = [];
      for (let i = 0; i < o.tris.length; i++) {
        const t = o.tris[i], a = o.verts[t[0]], b = o.verts[t[1]], c = o.verts[t[2]];
        if (a && b && c) { geo.push([a, b, c]); if (wantPaint) pnt.push(o.paint ? o.paint[i] : null); }
      }
      for (const cp of o.comps) {
        const child = resolve(cp.path + '#' + cp.ref, new Set(seen || []).add(key));
        if (child) for (let i = 0; i < child.geo.length; i++) { geo.push(child.geo[i].map((p) => applyT(p, cp.t))); if (wantPaint) pnt.push(child.pnt[i]); }
      }
      return (memo[key] = { geo, pnt });
    }

    const buildBlock = (/<build\b[^>]*>([\s\S]*?)<\/build>/i.exec(rootText || '') || [])[1];
    const items = [];
    if (buildBlock) { const itRe = /<item\b([^>]*?)\/?>/g; let im; while ((im = itRe.exec(buildBlock))) items.push(im[1]); }
    // COUNT BEFORE BUILDING. resolve() memoises each object, but its OUTPUT still multiplies:
    // an object referencing the next one twice, thirty levels deep over one triangle, is 2^30
    // triangles of nested arrays, and the process dies of memory long before it finishes. The
    // same count, memoised as numbers, costs one pass over the objects — so a model that would
    // come out past the ceiling mf-mesh already treats as impractical to even decode is refused
    // here, before anything is built. Below the ceiling nothing changes.
    const tally = {};
    const countOf = (key, depth) => {
      if (tally[key] != null) return tally[key];
      const o = objs[key];
      if (!o || depth > 64) return 0;
      tally[key] = 0; // a cycle counts as nothing, as resolve() drops it
      let n = o.tris.length;
      for (const cp of o.comps) n += countOf(cp.path + '#' + cp.ref, depth + 1);
      return (tally[key] = n);
    };
    let produced = 0;
    if (items.length) {
      for (const it of items) {
        const oid = (/\bobjectid="([^"]+)"/i.exec(it) || [])[1];
        const pp = (/\b(?:p:)?path="([^"]+)"/i.exec(it) || [])[1];
        if (oid) produced += countOf((pp ? norm(pp) : rootKey) + '#' + oid, 0);
      }
    } else {
      for (const k in objs) produced += countOf(k, 0);
    }
    if (produced > MAX_BUILT_TRIANGLES) return null;

    const soup = [], paintOut = [], objOut = [];
    // `oid` — the top-level (build-item) object id each facet belongs to, so the preview can
    // group triangles into build plates. Only tracked when wantPaint (the rich-preview path).
    const emit = (tri, code, t, oid) => { soup.push(tri.map((p) => { const q = applyT(p, t); return [q[0] * scale, q[1] * scale, q[2] * scale]; })); if (wantPaint) { paintOut.push(code); objOut.push(oid || null); } };
    if (items.length) {
      for (const it of items) {
        const oid = (/\bobjectid="([^"]+)"/i.exec(it) || [])[1];
        if (!oid) continue;
        const pp = (/\b(?:p:)?path="([^"]+)"/i.exec(it) || [])[1];
        const r = resolve((pp ? norm(pp) : rootKey) + '#' + oid, null);
        if (!r) continue; // skip an unresolved item rather than drop the whole mesh
        const t = parseT((/transform="([^"]+)"/i.exec(it) || [])[1]);
        for (let i = 0; i < r.geo.length; i++) emit(r.geo[i], wantPaint ? r.pnt[i] : null, t, oid);
      }
    } else {
      for (const k in objs) { const r = resolve(k, null); const oid = k.split('#')[1]; if (r) for (let i = 0; i < r.geo.length; i++) emit(r.geo[i], wantPaint ? r.pnt[i] : null, null, oid); }
    }
    // Last resort: the build/component graph resolved to nothing (unusual references, a broken
    // p:path, a build item pointing at a missing id…) but we DID parse real meshes. Render their
    // raw triangles untransformed rather than give up — a navigable model beats a flat image.
    if (!soup.length) {
      for (const k in objs) {
        const o = objs[k], oid = k.split('#')[1];
        for (let i = 0; i < o.tris.length; i++) {
          const t = o.tris[i], a = o.verts[t[0]], b = o.verts[t[1]], c = o.verts[t[2]];
          if (a && b && c) emit([a, b, c], wantPaint && o.paint ? o.paint[i] : null, null, oid);
        }
      }
    }
    if (!soup.length) return null;
    return wantPaint ? { triangles: soup, paint: paintOut, objIds: objOut, thinned } : soup;
  }

  /**
   * The shop's name for each plate, by `plater_id`, from a Bambu/Orca
   * Metadata/model_settings.config. Only names someone actually typed — an
   * empty `plater_name` is no name. Empty map when the file carries none.
   */
  function plateNames(members) {
    const out = new Map();
    const text = memberText(members, /model_settings\.config$/i);
    if (!text) return out;
    for (const block of tagBlocks(text, 'plate', MAX_PLATES)) {
      let id = null, name = '';
      for (const tag of openTags(block, 'metadata', 4096)) {
        const key = attr(tag, 'key');
        if (key === 'plater_id' && id == null) {
          const v = /^\d{1,9}$/.test(attr(tag, 'value') || '') ? +attr(tag, 'value') : NaN;
          if (v >= 1 && v <= MAX_PLATE_INDEX) id = v;
        } else if (key === 'plater_name' && !name) {
          name = cleanText(attr(tag, 'value'), MAX_PLATE_NAME);
        }
      }
      if (id != null && name) out.set(id, name);
    }
    return out;
  }

  // Build-plate assignments from a Bambu/Orca Metadata/model_settings.config: one entry per
  // <plate>, listing the object ids it holds (from its <model_instance> object_id metadata).
  // Lets the preview offer a per-plate view. Returns [] for single-plate / non-Bambu files.
  function extractPlates(members) {
    const text = memberText(members, /model_settings\.config$/i);
    if (!text) return [];
    const plates = [];
    for (const block of tagBlocks(text, 'plate', MAX_PLATES)) {
      let name = null;
      const ids = [];
      for (const tag of openTags(block, 'metadata', 65536)) {
        const key = attr(tag, 'key');
        if ((key === 'plater_name' || key === 'name') && name == null) name = cleanText(attr(tag, 'value'), MAX_PLATE_NAME) || null;
        else if (key === 'object_id') { const v = attr(tag, 'value'); if (v) ids.push(v); }
      }
      const objectIds = Array.from(new Set(ids));
      if (objectIds.length) plates.push({ name, objectIds });
    }
    return plates;
  }

  /**
   * Which plate each build-item object sits on, 1-based, in the order the
   * slicer wrote the `<plate>` blocks. Empty for a file with no plate
   * structure — a plain 3MF is one plate, and every object is on it.
   *
   * On top of extractPlates rather than beside it, and by BLOCK ORDER rather
   * than the `plater_id` value on purpose: the Mac app numbers plates the same
   * way, and the two apps write the same geometryKey into the same record.
   * Which plate is "plate 2" never matters; which objects share a plate does.
   */
  function plateOf(members) {
    const out = new Map();
    extractPlates(members).forEach((pl, i) => {
      for (const id of pl.objectIds) if (!out.has(String(id))) out.set(String(id), i + 1);
    });
    return out;
  }

  /**
   * The plate whose footprint is largest — the one that decides whether a
   * file can be printed at all. Ties go to the lowest plate number, so two
   * readers walking the same file pick the same plate.
   * @param {Map<number, {minX,minY,minZ,maxX,maxY,maxZ}>} boxes
   */
  function largestPlate(boxes) {
    let best = null, bestKey = Infinity, bestArea = -1;
    for (const [k, b] of boxes) {
      const area = (b.maxX - b.minX) * (b.maxY - b.minY);
      if (area > bestArea || (area === bestArea && k < bestKey)) { best = b; bestKey = k; bestArea = area; }
    }
    return best;
  }

  /**
   * Which filaments each PLATE actually uses.
   *
   * `filament_colour` in project_settings.config is file-wide, so a multi-plate project
   * reports one palette for everything in it — and the converter recommended the same four
   * spools for every plate. On a real 18-plate poster those plates are different designs:
   * some are white/amber/green, others red/blue/black, and no single plate uses more than
   * five. Loading one global set means loading spools a plate never touches.
   *
   * It also changes the verdict. File-wide that project reads as six colours and therefore
   * a Full-Spectrum job; per plate almost all of it fits four heads and prints outright.
   *
   * @returns {Array<{index, name, colorIndices:number[], colors:string[], sampled:boolean}>}
   *   empty when the file has no plate structure or the mesh cannot be read.
   */
  function platePalettes(members) {
    if (!mfMesh || !mfMesh.extractMeshFromMembers) return [];
    let mesh = null;
    try { mesh = mfMesh.extractMeshFromMembers(members); } catch (_) { return []; }
    if (!mesh || !mesh.faceState || !Array.isArray(mesh.parts) || !Array.isArray(mesh.plates)) return [];

    const pal = Array.isArray(mesh.palette) ? mesh.palette : [];
    const faces = mesh.faceState;
    // A thinned mesh can miss a colour that covers very few faces, so say so rather than
    // let a caller present a sampled answer as the whole truth.
    const sampled = !!mesh.sampled;

    return mesh.plates.map((plate, i) => {
      const used = new Set();
      for (const pi of (plate.partIndices || [])) {
        const part = mesh.parts[pi];
        if (!part) continue;
        for (let f = part.start; f < part.end && f < faces.length; f++) {
          const st = faces[f];
          // state 0 means the object's own filament, which is palette slot 0.
          used.add(st >= 1 ? Math.min(st - 1, Math.max(0, pal.length - 1)) : 0);
        }
      }
      const colorIndices = [...used].sort((a, b) => a - b);
      return {
        index: i,
        name: plate.name || null,
        colorIndices,
        colors: colorIndices.map((k) => pal[k]).filter(Boolean),
        sampled,
      };
    });
  }

  /**
   * How many facets a 3MF holds, WITHOUT building any of them.
   *
   * A byte scan for `<triangle`, which is what _extractCore already does to work
   * out its preview stride — lifted out because the cost of reading a 3MF's mesh
   * is per triangle, and a caller deciding whether it can afford one should be
   * able to ask before it commits. Measured on real files, a geometry-only 3MF
   * costs ~68x its own size in heap once the nested arrays exist: 27.8 MB in,
   * 1,886 MB out. Bytes are a poor proxy for that; facets are the actual unit.
   */
  function countTriangles(members) {
    const modelMembers = (members || []).filter((m) => /\.model$/i.test(m.name) && memberSize(m) <= 480 * 1024 * 1024);
    let total = 0;
    const needle = Buffer.from('<triangle');
    for (const mm of modelMembers) {
      let i = 0; const b = mm.data;
      if (!b) continue;
      while ((i = b.indexOf(needle, i)) !== -1) { total++; i += needle.length; }
    }
    return total;
  }

  /**
   * Volume, area, bounding box and facet count for a 3MF's mesh — WITHOUT ever
   * holding the mesh.
   *
   * _extractCore is the right shape for what it is for: the converter, the STL
   * export and the preview all need the triangles themselves. Measuring does
   * not, and going through that path to get four numbers is what made a real
   * model unreadable. It materialises twice — `resolve()` memoises each object's
   * geometry as nested `[[x,y,z],…]`, then `emit()` builds a second transformed
   * copy in `soup` — so a 229 MB / 13.2M-facet poster wants about 10 GB.
   *
   * This walks the same graph, in the same order, applying the same transforms
   * in the same sequence, and folds each triangle into a running total as it
   * goes. Per object it holds vertices in a Float64Array and triangle indices in
   * a Uint32Array: for that same poster, ~330 MB of typed arrays instead of ten
   * gigabytes of small objects.
   *
   * Float64, not Float32, on purpose. The vertices come out of parseFloat as
   * doubles and narrowing them would move the last digits of every volume — the
   * numbers here are asserted EQUAL to accumulateTriangles(extractTriangles(…)),
   * not merely close, and the order of the adds is preserved to keep them so.
   *
   * Returns null when there is no mesh to measure, exactly as _extractCore does,
   * so the caller's "no geometry" branch is unchanged.
   */
  function measureMesh(members) {
    const norm = (p) => String(p || '').replace(/^\/+/, '').toLowerCase();
    const modelMembers = (members || []).filter((m) => /\.model$/i.test(m.name) && memberSize(m) <= 480 * 1024 * 1024);
    if (!modelMembers.length) return null;

    // Counting first so each array is allocated once at its final size. A grown
    // array reallocates and copies, which for 13M facets is the cost this whole
    // function exists to avoid.
    const countOf = (str, needle) => {
      let n = 0, i = 0;
      while ((i = str.indexOf(needle, i)) !== -1) { n++; i += needle.length; }
      return n;
    };

    const objs = {};
    let rootKey = null, rootText = '', scale = 1, firstKey = null, firstScale = 1;
    for (const mm of modelMembers) {
      let text;
      try { text = mm.data.toString('utf8'); } catch (_) { continue; }
      const fkey = norm(mm.name);
      const fscale = UNIT_MM[((/<model\b[^>]*\bunit="([^"]+)"/i.exec(text) || [])[1] || 'millimeter').toLowerCase()] || 1;
      if (!firstKey) { firstKey = fkey; firstScale = fscale; }
      if (!rootKey && /<build\b[^>]*>[\s\S]*?<item\b/i.test(text)) { rootKey = fkey; rootText = text; scale = fscale; }
      const objRe = /<object\b([^>]*)>([\s\S]*?)<\/object>/g; let om;
      while ((om = objRe.exec(text))) {
        const id = (/\bid="([^"]+)"/i.exec(om[1]) || [])[1];
        if (!id) continue;
        const block = om[2];

        const nv = countOf(block, '<vertex');
        const verts = new Float64Array(nv * 3);
        // A vertex that will not parse is dropped rather than snapped to the
        // origin, which would spike every triangle indexing it. The mask keeps
        // index alignment while letting the guard below skip those facets —
        // same contract as the `null` _extractCore pushes.
        const vok = new Uint8Array(nv);
        /* One regex for the whole vertex where the attributes are in the usual
         * order, three only where they are not. Every writer in the wild emits
         * x, y, z in that order, and the general form costs three exec()s and
         * three match arrays per vertex — fourteen million of each on a real
         * poster, which was most of the time this function spent. The slow path
         * is kept because the order is not guaranteed and a mis-parsed vertex
         * corrupts every triangle indexing it. */
        const vFast = /<vertex\b[^>]*?\bx=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)["']?\s+y=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)["']?\s+z=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/g;
        const vRe = /<vertex\b([^>]*?)\/?>/g; let vm, vi = 0;
        while ((vm = vRe.exec(block)) && vi < nv) {
          vFast.lastIndex = vm.index;
          const fm = vFast.exec(block);
          let x, y, z;
          if (fm && fm.index === vm.index) {
            x = +fm[1]; y = +fm[2]; z = +fm[3];
          } else {
            const va = vm[1];
            x = parseFloat((/\bx=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]);
            y = parseFloat((/\by=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]);
            z = parseFloat((/\bz=["']?(-?[\d.]+(?:[eE][+-]?\d+)?)/.exec(va) || [])[1]);
          }
          if (Number.isFinite(x) && Number.isFinite(y) && Number.isFinite(z)) {
            verts[vi * 3] = x; verts[vi * 3 + 1] = y; verts[vi * 3 + 2] = z; vok[vi] = 1;
          }
          vi++;
        }

        const nt = countOf(block, '<triangle');
        const tris = new Uint32Array(nt * 3);
        const tFast = /<triangle\b[^>]*?\bv1=["']?(\d+)["']?\s+v2=["']?(\d+)["']?\s+v3=["']?(\d+)/g;
        const tRe = /<triangle\b([^>]*?)\/?>/g; let tm, ti = 0;
        while ((tm = tRe.exec(block)) && ti < nt) {
          tFast.lastIndex = tm.index;
          const fm = tFast.exec(block);
          let v1, v2, v3;
          if (fm && fm.index === tm.index) {
            v1 = fm[1]; v2 = fm[2]; v3 = fm[3];
          } else {
            const a = tm[1];
            v1 = (/\bv1=["']?(\d+)/.exec(a) || [])[1]; v2 = (/\bv2=["']?(\d+)/.exec(a) || [])[1]; v3 = (/\bv3=["']?(\d+)/.exec(a) || [])[1];
          }
          if (v1 == null || v2 == null || v3 == null) continue;
          tris[ti * 3] = +v1; tris[ti * 3 + 1] = +v2; tris[ti * 3 + 2] = +v3;
          ti++;
        }

        const comps = [];
        const cRe = /<component\b([^>]*?)\/?>/g; let cm;
        while ((cm = cRe.exec(block))) {
          const ref = (/\bobjectid="([^"]+)"/i.exec(cm[1]) || [])[1];
          if (!ref) continue;
          const pp = (/\b(?:p:)?path="([^"]+)"/i.exec(cm[1]) || [])[1];
          comps.push({ ref, path: pp ? norm(pp) : fkey, t: parseT((/transform="([^"]+)"/i.exec(cm[1]) || [])[1]) });
        }
        objs[fkey + '#' + id] = { verts, vok, nv: vi, tris, nt: ti, comps };
      }
    }
    if (!Object.keys(objs).length) return null;
    if (!rootKey) { rootKey = firstKey; scale = firstScale; }

    let vol6 = 0, area2 = 0, count = 0;

    /* A BOX PER PLATE, NOT ONE BOX ROUND THE LOT.
     *
     * Reported from the Mac app, and true of this reader too: "it is
     * calculating the print plate size as all the plates combined if there is
     * more than one". A slicer lays plates out side by side in one coordinate
     * space, and a box drawn round everything in <build> is the layout, not
     * the model. Measured on the shop's own two-plate file: plate 1 is
     * 77 x 170 x 9, plate 2 is 80 x 80 x 26, and the combined box was
     * 295 x 170 x 26 — the 295 being the distance between the plates, a figure
     * no part of the file has. Handed to print-fit, that says a model whose
     * widest plate is 80 mm will not go on a 256 mm bed.
     *
     * So the bbox is the LARGEST plate's. The count, the volume and the area
     * stay totals — every plate's material is printed — which is why those
     * three matched between the two apps all along and the box did not.
     *
     * The Mac app (Mesh.swift measure3MF) applies exactly this rule, and the
     * records the two write for one file are compared by test. */
    const plateBoxes = new Map();
    let plate = 1;
    const boxOf = (k) => {
      let b = plateBoxes.get(k);
      if (!b) { b = { minX: Infinity, minY: Infinity, minZ: Infinity, maxX: -Infinity, maxY: -Infinity, maxZ: -Infinity }; plateBoxes.set(k, b); }
      return b;
    };

    /* The same sums as lib/obj-parse.js accumulate() and lib/stl-parse.js, in
     * the same order — a 3MF's volume must not depend on which reader saw it. */
    const fold = (ax, ay, az, bx, by, bz, cx, cy, cz) => {
      count++;
      vol6 += ax * (by * cz - bz * cy)
            - ay * (bx * cz - bz * cx)
            + az * (bx * cy - by * cx);
      const ux = bx - ax, uy = by - ay, uz = bz - az;
      const vx = cx - ax, vy = cy - ay, vz = cz - az;
      const nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
      area2 += Math.sqrt(nx * nx + ny * ny + nz * nz);
      const b = boxOf(plate);
      if (ax < b.minX) b.minX = ax; if (ax > b.maxX) b.maxX = ax;
      if (ay < b.minY) b.minY = ay; if (ay > b.maxY) b.maxY = ay;
      if (az < b.minZ) b.minZ = az; if (az > b.maxZ) b.maxZ = az;
      if (bx < b.minX) b.minX = bx; if (bx > b.maxX) b.maxX = bx;
      if (by < b.minY) b.minY = by; if (by > b.maxY) b.maxY = by;
      if (bz < b.minZ) b.minZ = bz; if (bz > b.maxZ) b.maxZ = bz;
      if (cx < b.minX) b.minX = cx; if (cx > b.maxX) b.maxX = cx;
      if (cy < b.minY) b.minY = cy; if (cy > b.maxY) b.maxY = cy;
      if (cz < b.minZ) b.minZ = cz; if (cz > b.maxZ) b.maxZ = cz;
    };

    /* `chain` is the transforms to apply IN ORDER, innermost first, because
     * that is the order _extractCore applies them: resolve() transforms a
     * child's geometry by the component's matrix as the recursion unwinds, and
     * emit() applies the build item's matrix last. Composing them into one
     * matrix would be cheaper and would round differently, so it is not done. */
    // Written into a reused nine-slot buffer rather than returned as an array:
    // three points per facet times thirteen million facets is forty million
    // short-lived arrays, which is the allocation this function exists to avoid.
    const P = new Float64Array(9);
    const place = (i3, verts, chain, slot) => {
      let x = verts[i3], y = verts[i3 + 1], z = verts[i3 + 2];
      for (let k = 0; k < chain.length; k++) {
        const t = chain[k];
        if (!t) continue;
        const nx2 = x * t[0] + y * t[3] + z * t[6] + t[9];
        const ny2 = x * t[1] + y * t[4] + z * t[7] + t[10];
        const nz2 = x * t[2] + y * t[5] + z * t[8] + t[11];
        x = nx2; y = ny2; z = nz2;
      }
      P[slot] = x * scale; P[slot + 1] = y * scale; P[slot + 2] = z * scale;
    };

    // A total visit budget, for the reason lib/mf-mesh.js `walk` gives: `seen` stops a cycle
    // but not fan-out, and a component graph that doubles per level is 2^depth visits in a few
    // hundred bytes (24 levels took over five seconds here). Past the budget the measurement is
    // abandoned — null, "could not measure", the same answer as a model with no geometry.
    let visits = 0, overBudget = false;
    const walk = (key, chain, seen) => {
      if (overBudget) return false;
      if (++visits > MAX_WALK_VISITS) { overBudget = true; return false; }
      const o = objs[key];
      if (!o || (seen && seen.has(key))) return false;
      for (let i = 0; i < o.nt; i++) {
        const i0 = o.tris[i * 3], i1 = o.tris[i * 3 + 1], i2 = o.tris[i * 3 + 2];
        if (i0 >= o.nv || i1 >= o.nv || i2 >= o.nv) continue;
        if (!o.vok[i0] || !o.vok[i1] || !o.vok[i2]) continue;
        place(i0 * 3, o.verts, chain, 0);
        place(i1 * 3, o.verts, chain, 3);
        place(i2 * 3, o.verts, chain, 6);
        fold(P[0], P[1], P[2], P[3], P[4], P[5], P[6], P[7], P[8]);
      }
      // No geometry memo on purpose: a component used twice is walked twice.
      // That trades CPU for the memory this function exists to not spend.
      const next = new Set(seen || []); next.add(key);
      for (const cp of o.comps) walk(cp.path + '#' + cp.ref, [cp.t].concat(chain), next);
      return true;
    };

    const buildBlock = (/<build\b[^>]*>([\s\S]*?)<\/build>/i.exec(rootText || '') || [])[1];
    const items = [];
    if (buildBlock) { const itRe = /<item\b([^>]*?)\/?>/g; let im; while ((im = itRe.exec(buildBlock))) items.push(im[1]); }
    if (items.length) {
      const onPlate = plateOf(members);
      for (const it of items) {
        const oid = (/\bobjectid="([^"]+)"/i.exec(it) || [])[1];
        if (!oid) continue;
        const pp = (/\b(?:p:)?path="([^"]+)"/i.exec(it) || [])[1];
        // An item the slicer put on no plate is on plate one, which is also
        // where every item of a file with no plate structure lands.
        plate = onPlate.get(String(oid)) || 1;
        walk((pp ? norm(pp) : rootKey) + '#' + oid, [parseT((/transform="([^"]+)"/i.exec(it) || [])[1])], null);
      }
    } else {
      for (const k in objs) walk(k, [null], null);
    }
    // Same last resort as _extractCore: the build/component graph resolved to
    // nothing but real meshes were parsed. Measure them untransformed rather
    // than report a model with no size.
    if (!count) {
      for (const k in objs) {
        const o = objs[k];
        for (let i = 0; i < o.nt; i++) {
          const i0 = o.tris[i * 3], i1 = o.tris[i * 3 + 1], i2 = o.tris[i * 3 + 2];
          if (i0 >= o.nv || i1 >= o.nv || i2 >= o.nv) continue;
          if (!o.vok[i0] || !o.vok[i1] || !o.vok[i2]) continue;
          place(i0 * 3, o.verts, [], 0);
          place(i1 * 3, o.verts, [], 3);
          place(i2 * 3, o.verts, [], 6);
          fold(P[0], P[1], P[2], P[3], P[4], P[5], P[6], P[7], P[8]);
        }
      }
    }
    if (overBudget || !count) return null;
    const b = largestPlate(plateBoxes);
    return {
      triangleCount: count,
      volumeMm3: Math.abs(vol6) / 6,
      areaMm2: area2 / 2,
      bbox: {
        x: b.maxX - b.minX, y: b.maxY - b.minY, z: b.maxZ - b.minZ,
        min: [b.minX, b.minY, b.minZ], max: [b.maxX, b.maxY, b.maxZ],
      },
      plates: plateBoxes.size,
    };
  }

  function extractTriangles(members, opts) { return _extractCore(members, false, opts); }
  // Like extractTriangles but returns { triangles, paint, objIds, thinned } — paint[i]/objIds[i]
  // align to triangles[i]. Powers the true-multicolour, multi-plate preview. Pass opts.maxTris to
  // thin huge meshes for the preview; omit it for a faithful full-mesh extraction (STL export).
  function extractTrianglesWithPaint(members, opts) { return _extractCore(members, true, opts); }

  // Bed-fit warnings for a retarget (footprint / height vs the target build volume).
  // WHETHER it fits is `print-fit.js`; the sentences are this file's. The
  // decision moved out because the Mac app and the phone need it and cannot
  // load this module — it is 1500 lines on top of Node's zlib — while the
  // question "will this go on my bed" is arithmetic on six numbers. The wording
  // below is unchanged, and `printFitWordingTests` holds it to that.
  function fitWarnings(bounds, target) {
    const w = [];
    if (!bounds || !target || !target.bed) return w;
    const b = target.bed;
    const fit = printFit ? printFit.check(bounds, b) : null;
    if (!fit || !fit.known) return w;
    if (fit.footprint) w.push(`Model footprint ${bounds.x}×${bounds.y} mm is larger than ${target.name}'s bed ${b.x}×${b.y} mm — it may not fit. Rotate or rescale in your slicer.`);
    if (fit.height) w.push(`Model height ${bounds.z} mm exceeds ${target.name}'s ${b.z} mm max — it may not fit.`);
    return w;
  }

  /**
   * Analyze a 3MF: flavour, ordered filament colours (with grams where known), source printer
   * metadata and model footprint.
   * @returns {{ ok:boolean, flavour?:string, filaments?:Array, colorCount?:number, memberCount?:number, hasGeometry?:boolean, meta?:object, bounds?:object|null, error?:string }}
   */
  function analyze(buf) {
    const members = readMembers(buf);
    if (!members.length) return { ok: false, error: 'Not a readable 3MF/ZIP file.' };
    const hasGeometry = members.some((m) => /\.model$/i.test(m.name));
    const filaments = extractFilaments(members);
    const meta = extractMeta(members);
    // By filament SLOT where slice_info names them (`id` is the 1-based slot),
    // summed over every plate. `meta.grams` is every <filament> tag in file
    // order, so on a two-plate project its third entry is plate 2's slot 1 —
    // matched by position it gave slot 3 plate 2's grams and slots 1-2 plate
    // 1's alone.
    if (Array.isArray(meta.filaments) && meta.filaments.length) {
      // The project's palette is in slot order (position i is slot i+1);
      // without one the list came from slice_info in the same first-seen slot
      // order as meta.filaments, so position matches position.
      const fromProject = Array.isArray((tryJson(memberText(members, /project_settings\.config$/i)
        || memberText(members, /model_settings\.config$/i)) || {}).filament_colour);
      const slot = new Map(meta.filaments.map((x) => [String(x.id), x.grams]));
      filaments.forEach((f, i) => {
        const g = fromProject ? slot.get(String(i + 1)) : (meta.filaments[i] || {}).grams;
        if (g != null) f.grams = g;
      });
    } else if (meta.grams.length) filaments.forEach((f, i) => { if (meta.grams[i] != null) f.grams = meta.grams[i]; });
    return {
      ok: true,
      flavour: detectFlavour(members),
      filaments,
      colorCount: filaments.length,
      memberCount: members.length,
      hasGeometry,
      meta,
      // Non-null when the read had to leave parts behind, so the panel can say so up
      // front rather than letting the maker discover it from the convert that refuses.
      truncated: members.truncated || null,
      // Per-plate palettes: a multi-plate project's plates are often different designs
      // using different subsets, and one file-wide list cannot say that.
      platePalettes: hasGeometry ? platePalettes(members) : [],
      bounds: hasGeometry ? computeBounds(members) : null,
    };
  }

  // Reorder an array by a permutation: out[map[i]] = arr[i]. Holes keep the original.
  function permute(arr, map) {
    if (!Array.isArray(arr) || !Array.isArray(map)) return arr;
    const out = arr.slice();
    for (let i = 0; i < arr.length; i++) {
      const t = map[i];
      if (Number.isInteger(t) && t >= 0 && t < arr.length) out[t] = arr[i];
    }
    return out;
  }

  // ── MOVING A FILAMENT MEANS MOVING EVERYTHING THAT BELONGS TO IT ─────────────────────────────
  //
  // A slot map, a merge, Full Spectrum and band-swap all move filaments between positions. Each
  // position's colour, material, temperatures and fan settings belong together — and so do the
  // settings that NAME a filament by its number (support_filament = 2) and the purge matrix
  // indexed by filament pairs. Reindexing only `^filament_` keys left nozzle_temperature, the
  // plate temperatures and the fans in source order (after a 6→4 merge nozzle_temperature still
  // had six entries), so a slot printed one filament's colour at another's temperature.
  //
  // Which arrays are per-filament is decided by NAME, never by length alone: printable_area has
  // four corners and a four-filament file has four filaments, and a length test once turned the
  // bed into a bow-tie. On a toolchanger the per-EXTRUDER arrays (nozzle_diameter, retraction,
  // z-hop, extruder_offset) have the same length again; those stay with the physical head and
  // are deliberately absent here. Names from Orca / Bambu Studio's filament option set, as they
  // appear in a real U1 export (bedready.io's u1-profile.json).
  const PER_FILAMENT_JSON = new Set([
    'activate_air_filtration', 'activate_chamber_temp_control', 'adaptive_pressure_advance',
    'adaptive_pressure_advance_bridges', 'adaptive_pressure_advance_model', 'adaptive_pressure_advance_overhangs',
    'additional_cooling_fan_speed', 'chamber_temperature', 'chamber_temperatures', 'close_fan_the_first_x_layers',
    'complete_print_exhaust_fan_speed', 'cool_plate_temp', 'cool_plate_temp_initial_layer', 'default_filament_colour',
    'dont_slow_down_outer_wall', 'during_print_exhaust_fan_speed', 'enable_overhang_bridge_fan', 'enable_pressure_advance',
    'eng_plate_temp', 'eng_plate_temp_initial_layer', 'fan_cooling_layer_time', 'fan_max_speed', 'fan_min_speed',
    'full_fan_speed_layer', 'graphic_effect_plate_temp', 'graphic_effect_plate_temp_initial_layer', 'hot_plate_temp',
    'hot_plate_temp_initial_layer', 'idle_temperature', 'internal_bridge_fan_speed', 'ironing_fan_speed',
    'nozzle_temperature', 'nozzle_temperature_initial_layer', 'nozzle_temperature_range_high', 'nozzle_temperature_range_low',
    'overhang_fan_speed', 'overhang_fan_threshold', 'pellet_flow_coefficient', 'pressure_advance',
    'reduce_fan_stop_start_freq', 'required_nozzle_HRC', 'slow_down_for_layer_cooling', 'slow_down_layer_time',
    'slow_down_min_speed', 'supertack_plate_temp', 'supertack_plate_temp_initial_layer',
    'support_material_interface_fan_speed', 'temperature_vitrification', 'textured_cool_plate_temp',
    'textured_cool_plate_temp_initial_layer', 'textured_plate_temp', 'textured_plate_temp_initial_layer',
  ]);
  const isPerFilamentJson = (k) => /^filament_/i.test(k) || PER_FILAMENT_JSON.has(k);
  // Settings whose VALUE is a 1-based filament number; 0 means "the default" and stays 0.
  const FILAMENT_INDEX_JSON = ['support_filament', 'support_interface_filament', 'wipe_tower_filament',
    'wall_filament', 'sparse_infill_filament', 'solid_infill_filament'];
  const FILAMENT_INDEX_PRUSA = ['perimeter_extruder', 'infill_extruder', 'solid_infill_extruder',
    'support_material_extruder', 'support_material_interface_extruder', 'wipe_tower_extruder'];
  // The same, as per-object / per-part metadata in model_settings.config and Slic3r_PE_model.config.
  const FILAMENT_INDEX_META = new Set(['extruder'].concat(FILAMENT_INDEX_JSON, FILAMENT_INDEX_PRUSA));

  /**
   * Output position → source position for a slot map, with permute()'s semantics exactly: slot
   * map[i] takes source i, and a slot nobody maps to keeps its own. Everything that reindexes
   * under a slot map goes through this, so the colour and its settings cannot part company.
   */
  function srcOfSlotMap(map, n) {
    const src = [];
    for (let j = 0; j < n; j++) src.push(j);
    map.forEach((t, i) => { if (Number.isInteger(t) && t >= 0 && t < n) src[t] = i; });
    return src;
  }

  /** A 1-based filament number through a 0-based source→slot map. 0 and unknowns stay. */
  function remapIndexValue(v, map) {
    const k = parseInt(v, 10);
    if (!(k >= 1 && k <= map.length) || !Number.isInteger(map[k - 1])) return v;
    const nv = map[k - 1] + 1;
    return typeof v === 'number' ? nv : String(nv);
  }

  /** An n×n matrix (or e stacked ones), flattened, reindexed on both axes. Null if not that shape. */
  function reshapeSquare(arr, srcOf, n) {
    const blk = n * n;
    if (!arr.length || arr.length % blk) return null;
    const out = [];
    for (let b = 0; b < arr.length / blk; b++) {
      for (const i of srcOf) for (const j of srcOf) out.push(arr[b * blk + i * n + j]);
    }
    return out;
  }

  /** A per-filament list of PAIRS (Bambu's flush_volumes_vector: unload, load per filament). */
  function reshapePairs(arr, srcOf, n) {
    if (arr.length !== 2 * n) return null;
    const out = [];
    for (const i of srcOf) out.push(arr[2 * i], arr[2 * i + 1]);
    return out;
  }

  /**
   * Reindex a Bambu/Orca JSON config from `n` source filaments to `srcOf.length` output ones:
   * every named per-filament array of length n, the flush matrix and vector, the per-filament
   * entries of different_settings_to_system / inherits_group ([print, f1..fn, printer]), and —
   * when `idxMap` is given — every setting whose value is a filament number. Returns how many
   * keys moved.
   */
  function reindexFilamentJson(obj, srcOf, n, idxMap) {
    let changed = 0;
    for (const k of Object.keys(obj)) {
      const v = obj[k];
      if (!Array.isArray(v)) continue;
      let next = null;
      if (isPerFilamentJson(k) && v.length === n) next = srcOf.map((i) => (v[i] != null ? v[i] : v[0]));
      else if (k === 'flush_volumes_matrix') next = reshapeSquare(v, srcOf, n);
      else if (k === 'flush_volumes_vector') next = reshapePairs(v, srcOf, n);
      else if ((k === 'different_settings_to_system' || k === 'inherits_group') && v.length === n + 2) {
        next = [v[0]].concat(srcOf.map((i) => v[i + 1]), [v[n + 1]]);
      }
      if (next) { obj[k] = next; changed++; }
    }
    if (idxMap) {
      for (const k of FILAMENT_INDEX_JSON) {
        if (!(k in obj)) continue;
        const before = JSON.stringify(obj[k]);
        obj[k] = Array.isArray(obj[k]) ? obj[k].map((x) => remapIndexValue(x, idxMap)) : remapIndexValue(obj[k], idxMap);
        if (before !== JSON.stringify(obj[k])) changed++;
      }
    }
    return changed;
  }

  /**
   * A paint plan's source → slot map restricted to PHYSICAL filaments: Full Spectrum maps the
   * colours it mixes to virtual slots past the heads, which an object may print in but a
   * support or wall filament setting may not. Those go to the head with the largest share of
   * the mix; `clamped` lists the source indices that were moved that way. A band-swap plan is
   * all heads already, so it comes back unchanged.
   */
  function physicalIndexMap(plan) {
    const heads = plan.physical ? plan.physical.length : Infinity;
    const clamped = new Set();
    const map = plan.map.map((t, i) => {
      if (t < heads) return t;
      clamped.add(i);
      const e = (plan.extras || []).find((x) => x.src === i);
      if (!e || !e.recipe || !e.recipe.ids || !e.recipe.ids.length) return 0;
      let best = 0;
      e.recipe.weights.forEach((w, k) => { if (w > e.recipe.weights[best]) best = k; });
      return Math.min(heads - 1, Math.max(0, e.recipe.ids[best] - 1));
    });
    return { map, clamped };
  }

  /**
   * True when a per-filament setting holds k>1 values per filament — Bambu's H2D writes some
   * per nozzle variant, n × variants long. Their layout is not verified against a real project,
   * so rather than reindex filament_colour and leave those behind, a slot map or merge refuses.
   */
  function hasVariantArrays(obj, n) {
    if (!(n >= 2)) return false;
    return Object.keys(obj).some((k) => isPerFilamentJson(k) && Array.isArray(obj[k]) && obj[k].length > n && obj[k].length % n === 0);
  }

  /**
   * Remap every filament-number metadata (`extruder`, `support_filament`, Prusa's
   * `perimeter_extruder`…) in model_settings.config / Slic3r_PE_model.config XML, and the
   * `extruder` of colour changes and layer ranges, through a 0-based source→slot map.
   */
  function remapIndexText(text, map, extruderMap) {
    // `extruderMap`, when given, is for the objects' own `extruder` alone — under Full Spectrum
    // an object may print in a mixed (virtual) filament, while a support filament may not.
    return text
      .replace(/(key="([A-Za-z_]+)"\s+value=")(\d+)(")/g, (all, pre, key, num, post) =>
        (FILAMENT_INDEX_META.has(key) ? pre + remapIndexValue(num, key === 'extruder' && extruderMap ? extruderMap : map) + post : all))
      .replace(/(<(?:code|layer)\b[^>]*\bextruder=")(\d+)(")/g, (_a, pre, num, post) => pre + remapIndexValue(num, map) + post)
      .replace(/(opt_key="extruder"\s*>)(\d+)(<)/g, (_a, pre, num, post) => pre + remapIndexValue(num, map) + post);
  }

  // PrusaSlicer's per-filament options (its "filament" option set; one value per extruder in a
  // project) plus extruder_colour, which is what PrusaSlicer shows a painted region in. The
  // physical extruder's own options — nozzle_diameter, retract_*, extruder_offset, wipe — stay.
  const PER_FILAMENT_PRUSA = new Set([
    'temperature', 'first_layer_temperature', 'bed_temperature', 'first_layer_bed_temperature', 'idle_temperature',
    'chamber_temperature', 'chamber_minimal_temperature', 'fan_always_on', 'cooling', 'min_fan_speed', 'max_fan_speed',
    'bridge_fan_speed', 'disable_fan_first_layers', 'full_fan_speed_layer', 'fan_below_layer_time',
    'slowdown_below_layer_time', 'min_print_speed', 'start_filament_gcode', 'end_filament_gcode', 'extrusion_multiplier',
    'enable_dynamic_fan_speeds', 'overhang_fan_speed_0', 'overhang_fan_speed_1', 'overhang_fan_speed_2',
    'overhang_fan_speed_3', 'compatible_printers_condition_cummulative', 'compatible_prints_condition_cummulative',
    'inherits_cummulative', 'extruder_colour',
  ]);
  const isPerFilamentPrusa = (k) => /^filament_/i.test(k) || PER_FILAMENT_PRUSA.has(k);

  /**
   * Split a PrusaSlicer vector value into its raw tokens, or null when it cannot be done safely.
   *
   * A string vector is `;`-separated and PrusaSlicer quotes an entry only when it has to: an
   * empty entry is written bare, so `"Prusament PETG";;;;` is five entries and `"A";` is two.
   * Each entry is either a quoted string (backslash escapes, `;` allowed inside — G-code) or
   * bare text up to the next `;`; empty entries count, trailing ones included. Without quotes
   * or `;` it is a numeric/bool vector, `,`-separated. Tokens keep their exact text so a rejoin
   * changes nothing but the order.
   */
  function splitIniVector(raw) {
    const v = raw.trim();
    if (v.indexOf('"') < 0 && v.indexOf(';') < 0) return { parts: v.split(','), sep: ',' };
    const parts = [];
    let i = 0;
    for (;;) {
      let j = i;
      if (v[i] === '"') {
        j = i + 1;
        while (j < v.length && v[j] !== '"') j += v[j] === '\\' ? 2 : 1;
        if (j >= v.length) return null; // an unterminated quote
        j++;
        if (j < v.length && v[j] !== ';') return null; // text after a closing quote
      } else {
        while (j < v.length && v[j] !== ';') { if (v[j] === '"') return null; j++; }
      }
      parts.push(v.slice(i, j));
      if (j >= v.length) break;
      i = j + 1; // past the ';' — and an entry follows it, even an empty last one
    }
    return { parts, sep: ';' };
  }

  /**
   * Reindex a PrusaSlicer config the same way. `ok` is false — and the text must then be left
   * alone — when a per-filament value holds a number of entries other than 1 (one value for all)
   * or n, because then there is no way to move it with its colour. Wiping volumes are reshaped
   * like Bambu's flush matrix, and the *_extruder settings follow `idxMap`.
   */
  function reindexPrusaConfig(text, srcOf, n, idxMap) {
    let bad = null;
    const out = text.replace(/^([ \t]*;?[ \t]*)([A-Za-z0-9_]+)([ \t]*=[ \t]*)([^\r\n]*)$/gm, (all, pre, key, eq, val) => {
      if (bad) return all;
      if (key === 'wiping_volumes_matrix' || key === 'wiping_volumes_extruders') {
        const a = val.trim().split(',');
        const r = key === 'wiping_volumes_matrix' ? reshapeSquare(a, srcOf, n) : reshapePairs(a, srcOf, n);
        return r ? pre + key + eq + r.join(',') : all;
      }
      if (idxMap && FILAMENT_INDEX_PRUSA.includes(key)) return pre + key + eq + remapIndexValue(val.trim(), idxMap);
      if (!isPerFilamentPrusa(key) || !val.trim()) return all;
      const sp = splitIniVector(val);
      if (!sp) { bad = key; return all; }
      if (sp.parts.length === 1) return all; // one value applies to every filament — nothing to move
      if (sp.parts.length !== n) { bad = key; return all; }
      return pre + key + eq + srcOf.map((i) => sp.parts[i]).join(sp.sep);
    });
    return bad ? { ok: false, bad, text } : { ok: true, text: out };
  }

  /** Parse the max X/Y of a printable_area polygon (["0x0","256x0",…]) → { x, y } bed size, or null. */
  function bedFromPrintableArea(area) {
    if (!Array.isArray(area) || !area.length) return null;
    let x = 0, y = 0;
    for (const s of area) { const p = String(s).split('x').map(Number); if (p.length === 2 && isFinite(p[0]) && isFinite(p[1])) { x = Math.max(x, p[0]); y = Math.max(y, p[1]); } }
    return x && y ? { x, y } : null;
  }

  /**
   * Re-tile a multi-plate file's object layout for a different bed size.
   *
   * Bambu/Orca lay every plate out in one big world-coordinate grid — plate (col,row) sits at
   * (bed/2 + col·stride, bed/2 − row·stride), stride = bed + inter-plate gap. When the target bed differs
   * from the source's, that baked grid no longer matches, so each plate drifts (worse the further from the
   * origin) and objects end up near/over the plate edge. We recover each object's offset within its plate,
   * then re-place it on a grid built from the TARGET bed (same gap), so every plate is centred again.
   *
   * ── THE ONE MEMBER A HOST MAY NOT HAND OVER ──────────────────────────────
   *
   * Everything else here reads a config: a few kilobytes, always passed by
   * content. The root `.model` is the mesh, up to four hundred megabytes, and a
   * host that is not Node passes it by NAME — the native Mac app inlines a
   * member only up to four megabytes, so on that app `root.data` is undefined
   * and reading it threw, which failed the whole conversion before it had even
   * asked whether there was a second plate to re-tile. Every same-family
   * retarget to a differently-sized bed died that way, multi-plate or not.
   *
   * So the layout can arrive on its own: `root.build` is the `<build>…</build>`
   * block lifted out of the mesh by the host, which is the only part of that
   * file this rewrites. Given the whole text we return the whole text; given
   * the block we return the block, and the host splices it back where it found
   * it. Same arithmetic either way — see `test/mf-convert-members.js`.
   *
   * Returns `{ text }` or `{ buildBlock }`, or null when there is nothing to do
   * (single plate / same bed / no build block / no layout to read at all).
   */
  function retilePlatesForBed(members, target, srcBed, report) {
    if (!target.bed || !srcBed) return null;
    const root = members.find((m) => /3D\/3dmodel\.model$/i.test(m.name));
    const msc = members.find((m) => /model_settings\.config$/i.test(m.name));
    if (!root || !msc || msc.data == null) return null;
    // The whole file when we have it, the build block alone when that is all
    // the host could give us. `rootTxt` is what gets searched either way.
    const whole = root.data == null ? null : root.data.toString('utf8');
    const rootTxt = whole != null ? whole
      : (root.build == null ? null : String(root.build));
    if (rootTxt == null) {
      // Not a crash and not silence: the file converts, and the shop is told
      // the plates were left where the source slicer put them.
      if (report) report.warnings.push('Multi-plate layout was left as it was — this app could not read the file\'s object layout, so plates may sit off-centre on a different bed size. Open the converted file in your slicer and re-arrange the plates.');
      return null;
    }
    const buildMatch = rootTxt.match(/<build[\s\S]*?<\/build>/);
    if (!buildMatch) return null;
    const buildBlock = buildMatch[0];
    const plates = msc.data.toString('utf8').match(/<plate>[\s\S]*?<\/plate>/g) || [];
    if (plates.length < 2) return null; // single plate — nothing to re-tile
    const objPlate = {};
    plates.forEach((p, i) => { for (const m of p.matchAll(/object_id"\s+value="(\d+)"/g)) objPlate[m[1]] = i; });

    // Per-plate centroid of the item translations (transform indices 9,10 = tx,ty).
    const items = [];
    for (const it of buildBlock.match(/<item[^>]*>/g) || []) {
      const oid = (it.match(/objectid="(\d+)"/) || [])[1];
      const tr = (it.match(/transform="([^"]+)"/) || [])[1];
      if (!oid || !tr) continue;
      const n = tr.trim().split(/\s+/).map(Number);
      if (n.length >= 12) items.push({ oid, x: n[9], y: n[10] });
    }
    const byPlate = {};
    items.forEach((it) => { const pl = objPlate[it.oid]; if (pl == null) return; (byPlate[pl] = byPlate[pl] || []).push(it); });
    const centroid = {};
    Object.keys(byPlate).forEach((pl) => { const a = byPlate[pl]; centroid[pl] = { x: a.reduce((s, i) => s + i.x, 0) / a.length, y: a.reduce((s, i) => s + i.y, 0) / a.length }; });
    if (!Object.keys(centroid).length) return null;

    // Cluster centroids into grid columns (X) / rows (Y).
    const cluster = (vals, tol) => {
      const g = [];
      [...vals].sort((a, b) => a - b).forEach((v) => { const f = g.find((q) => Math.abs(q.c - v) < tol); if (f) { f.items.push(v); f.c = f.items.reduce((s, x) => s + x, 0) / f.items.length; } else g.push({ c: v, items: [v] }); });
      return g.map((q) => q.c);
    };
    const colCenters = cluster(Object.values(centroid).map((c) => c.x), 60).sort((a, b) => a - b);
    const rowCenters = cluster(Object.values(centroid).map((c) => c.y), 60).sort((a, b) => b - a); // row 0 = top
    const strideOf = (arr) => { if (arr.length < 2) return 0; let d = 0; for (let i = 1; i < arr.length; i++) d += Math.abs(arr[i] - arr[i - 1]); return d / (arr.length - 1); };
    const gapX = Math.max(0, (strideOf([...colCenters]) || srcBed.x) - srcBed.x);
    const gapY = Math.max(0, (strideOf(rowCenters) || srcBed.y) - srcBed.y);
    const tSX = target.bed.x + gapX, tSY = target.bed.y + gapY, tCX = target.bed.x / 2, tCY = target.bed.y / 2;
    const nearest = (centers, v) => { let bi = 0, bd = Infinity; centers.forEach((c, i) => { const d = Math.abs(c - v); if (d < bd) { bd = d; bi = i; } }); return bi; };

    let changed = 0;
    const newBuild = buildBlock.replace(/<item[^>]*>/g, (it) => {
      const oid = (it.match(/objectid="(\d+)"/) || [])[1];
      const pl = oid != null ? objPlate[oid] : null;
      const trM = it.match(/transform="([^"]+)"/);
      if (pl == null || !centroid[pl] || !trM) return it;
      const n = trM[1].trim().split(/\s+/).map(Number);
      if (n.length < 12) return it;
      const col = nearest(colCenters, centroid[pl].x), row = nearest(rowCenters, centroid[pl].y);
      n[9] = tCX + col * tSX + (n[9] - colCenters[col]);   // preserve offset from plate centre
      n[10] = tCY - row * tSY + (n[10] - rowCenters[row]);
      changed++;
      return it.replace(/transform="[^"]+"/, `transform="${n.join(' ')}"`);
    });
    if (!changed) return null;
    if (report) { report.platesRetiled = changed; report.fieldsChanged.push('plate_layout'); }
    return whole != null ? { text: whole.replace(buildBlock, newBuild) } : { buildBlock: newBuild };
  }

  /**
   * Tally per-filament (1-based paint state) usage across the model. Sources it from the shared mesh
   * reader (lib/mf-mesh.js), which resolves EVERY face's state — per-triangle paint_color, per-<part>
   * object colouring (idToExtr), and the base extruder — so an OBJECT-ENCODED multicolour file (coloured
   * per part, with zero paint_color in the mesh) tallies its colours correctly. A raw paint_color scan
   * (the previous implementation, kept as the fallback) reports zero usage for those files, which silently
   * breaks Full-Spectrum head selection. The mesh reader samples very large models to a preview budget,
   * but usage is a RELATIVE weight (most-used → physical head), so a representative sample is sufficient.
   */
  function tallyPaintUsage(members, n) {
    const usage = new Array(n).fill(0);
    if (mfMesh && mfMesh.extractMeshFromMembers) {
      try {
        const mesh = mfMesh.extractMeshFromMembers(members);
        const fs = mesh && mesh.faceState;
        if (fs && fs.length) {
          for (let i = 0; i < fs.length; i++) { const s = fs[i]; if (s >= 1 && s <= n) usage[s - 1] += 1; }
          // Only trust the mesh tally if it actually saw painted/assigned faces; otherwise fall through.
          if (usage.some((u) => u > 0)) return usage;
        }
      } catch (_) { /* fall back to the raw scan below */ }
    }
    // Fallback: raw paint_color scan (per-triangle codes only).
    if (mfMesh && mfMesh.dominantState) {
      for (const m of members) {
        if (!/\.model$/i.test(m.name) || m.data == null) continue;
        const text = m.data.toString('utf8');
        const re = /paint_color="([0-9A-Fa-f]+)"/g; let mm;
        while ((mm = re.exec(text))) { const s = mfMesh.dominantState(mm[1]); if (s >= 1 && s <= n) usage[s - 1] += 1; }
      }
    }
    return usage;
  }

  /**
   * Full Spectrum planning: keep 4 filaments physical, reproduce the rest as dithered mixes.
   * Only viable for a Snapmaker-Orca target (mixed_filament_definitions is Orca's feature) when the
   * source carries a palette and more colours than the target's 4 slots. Returns a plan or null.
   */
  function planFS(members, filaments, target, opts) {
    if (!opts || !opts.fullSpectrum) return null;
    if (!fullSpectrum || !fullSpectrum.planFullSpectrum) return null;
    // Mixed-filament dithering is a specific hardware feature (Snapmaker U1), NOT every Orca-flavour
    // printer — single-extruder Orca-family machines (Sovol/QIDI/Creality/…) cannot mix.
    if (!target.supportsMixedFilament) return null;
    if (!(target.maxColors >= 2) || filaments.length <= target.maxColors) return null;
    const colors = filaments.map((f) => f.color).filter(Boolean);
    if (colors.length !== filaments.length) return null;     // need every colour known to mix safely
    const usage = tallyPaintUsage(members, colors.length);
    const physical = Array.isArray(opts.fsPhysical) && opts.fsPhysical.length === target.maxColors ? opts.fsPhysical : undefined;
    const physicalHex = Array.isArray(opts.fsPhysicalHex) ? opts.fsPhysicalHex : undefined;
    return fullSpectrum.planFullSpectrum(colors, usage, { physical, physicalHex, maxPhysical: target.maxColors });
  }

  /** Rewrite paint_color / mmu_segmentation codes in a .model member through a colour plan (FS or band-swap). */
  function remapModelPaint(text, plan) {
    return text.replace(/(paint_color|mmu_segmentation)="([0-9A-Fa-f]+)"/g,
      (_m, attr, code) => `${attr}="${fullSpectrum.remapPaintCode(code, plan.stateMap)}"`);
  }

  /**
   * Band-swap planning (alternative to Full Spectrum): when a painted file is cleanly VERTICALLY
   * colour-banded, keep EVERY colour exactly by mapping each onto one of the target's physical heads and
   * inserting an M600 pause for each colour beyond the head count — no mixing, no dropped colours. Only for
   * a swap-capable target (Snapmaker U1) when `opts.bandSwap` is set and the model is banded with >1 band.
   * Mirrors the web reference (convert.ts band-swap branch). Returns a plan or null.
   */
  function planBandSwap(members, filaments, target, opts) {
    if (!opts || !opts.bandSwap) return null;
    if (!colorBands || !swapPauses || !mfMesh || !mfMesh.extractMeshFromMembers) return null;
    if (!target.supportsMixedFilament) return null; // swap-capable head layout (U1)
    const pal = filaments.map((f) => f.color).filter(Boolean);
    if (pal.length !== filaments.length) return null; // need every colour known to map safely
    let mesh;
    try { mesh = mfMesh.extractMeshFromMembers(members); } catch (_) { return null; }
    if (!mesh || !mesh.faceState || !mesh.faceState.length) return null;
    const baseState = mesh.baseState >= 1 ? mesh.baseState : 1;
    // Per plate, not per file: plates all stand at z=0, and slicing them together either hides a
    // real banding or — worse — returns one plate's swap heights for all of them, which this then
    // writes into the output as pauses. See lib/color-bands.js detectColorBandsForMesh.
    const bp = colorBands.detectColorBandsForMesh(mesh, baseState);
    if (!bp.banded || bp.bands.length <= 1) return null;
    const meta = extractMeta(members);
    const layerHeight = meta && meta.layerHeight ? meta.layerHeight : undefined;
    const pauseGcode = opts.pauseGcode || 'M600';
    const swap = swapPauses.buildBandSwapPlan(bp.bands, pal, pauseGcode, layerHeight, baseState);
    const headOf = swap.headOf; // Map(state → 0-based head)
    const heads = Math.min(target.maxColors && target.maxColors >= 1 ? target.maxColors : 4, 4);
    const baseHead = (headOf.has(baseState) ? headOf.get(baseState) : 0) + 1; // unpainted faces print here
    const stateMap = (s) => (s === 0 ? baseHead : (headOf.has(s) ? headOf.get(s) + 1 : 1));
    const firstOnHead = (h) => { for (const [st, hd] of headOf) if (hd === h) return st; return 1; };
    const headSrcIdx = [], headColors = [];
    for (let h = 0; h < heads; h++) { const st = firstOnHead(h); headSrcIdx.push(st - 1); headColors.push(normHex(pal[st - 1]) || '#FFFFFF'); }
    // config extruder refs (1-based source slot) → head (0-based); parallels fsPlan.map.
    const map = pal.map((_, i) => (headOf.has(i + 1) ? headOf.get(i + 1) : 0));
    return { stateMap, map, headColors, headSrcIdx, heads, baseHead, bands: bp.bands, instructions: swap.instructions, customGcodeXml: swap.customGcodeXml };
  }

  /**
   * Apply a band-swap plan to a project_settings.config object: reduce every per-filament array to the
   * physical heads (reindex to the head's loaded source slot) and stamp the head colours. No mixed-filament
   * keys (that's Full Spectrum) — the M600 custom_gcode member carries the swaps instead.
   */
  function applyBandSwapConfig(obj, plan, srcCount, report) {
    // Per-filament settings by NAME (see reindexFilamentJson): a length test alone once matched
    // printable_area's four corners on a four-filament model and turned the bed into a bow-tie.
    // Filament numbers (support_filament…) follow each colour to its head, like the paint.
    reindexFilamentJson(obj, plan.headSrcIdx, srcCount, plan.map);
    obj.filament_colour = plan.headColors.slice();
    if (report) {
      report.bandSwap = true;
      report.bandSwaps = plan.instructions.length;
      report.fieldsChanged.push('filament_colour', 'custom_gcode_per_layer');
    }
  }

  /**
   * The merge plan for "Merge to the nearest {n} slots", or null when it does not apply: not
   * asked for, another colour plan or a manual slot map already owns the colours, the file fits,
   * a colour is unknown, or the file is not the Bambu/Orca JSON dialect this can reindex.
   * Usage comes from the same mesh tally Full Spectrum uses, so the most-painted colours keep
   * their own slot; with no usage at all it falls back to merging the nearest pair.
   */
  function planMerge(members, filaments, target, opts, otherPlan, flavour) {
    if (!opts || !opts.mergeToSlots || otherPlan) return null;
    if (!fullSpectrum || !fullSpectrum.reduceColors) return null;
    if (profiles.configFamily(flavour) !== 'bbl' || profiles.configFamily(target.flavour) !== 'bbl') return null;
    const slots = target.maxColors;
    if (!(slots >= 1) || filaments.length <= slots) return null;
    const colors = filaments.map((f) => f.color);
    if (colors.some((c) => !c)) return null;
    // The palette must be the config's own: a palette read from slice_info or a full-spectrum
    // JSON is a different length from the arrays this would reindex, and merging it would leave
    // the config's colours, temperatures and paint describing different filaments.
    const proj = tryJson(memberText(members, /project_settings\.config$/i));
    if (!proj || !Array.isArray(proj.filament_colour) || proj.filament_colour.length !== colors.length) return null;
    const usage = tallyPaintUsage(members, colors.length);
    const r = fullSpectrum.reduceColors(colors, usage.some((u) => u > 0) ? usage : undefined, undefined, slots);
    // One group per slot; the clamp is belt and braces, as in the reference.
    const map = r.map.map((g) => Math.min(g, slots - 1));
    // Each slot keeps the colour of the source that survived into it — and so its temperatures,
    // fans and material too. (It used to take the lowest-numbered member's settings, which is not
    // the colour it kept whenever a higher-numbered colour survived.)
    const slotSrc = r.reps.slice();
    return { map, colors: slotSrc.map((i) => normHex(colors[i])), slotSrc };
  }

  /**
   * Apply a merge plan to project_settings.config: every per-filament array goes from the source
   * count to the slot count (each slot taking its first member's value), and the merged colours
   * are stamped. Per-filament arrays only, for the reason applyBandSwapConfig gives.
   */
  function applyMergeConfig(obj, plan, srcCount, report) {
    reindexFilamentJson(obj, plan.slotSrc, srcCount, plan.map);
    obj.filament_colour = plan.colors.slice();
    if (report) {
      report.colorsMerged = { from: srcCount, to: plan.colors.length };
      report.fieldsChanged.push('filament_colour');
    }
  }

  /**
   * Turn a source Bambu/Orca project_settings.config into a Full Spectrum U1 config: keep only the 4
   * physical filaments (reindex every per-filament array to them), stamp the loaded head colours, and
   * add the mixed_filament_definitions + dithering keys that realise the extra colours as mixes.
   */
  function applyFullSpectrumConfig(obj, plan, srcCount, report, opts) {
    opts = opts || {};
    const keep = plan.physical; // 0-based source indices, length = slots
    // Per-filament settings by name, as above, and filament numbers through the physical map:
    // a support or wall filament that Full Spectrum turned into a mix has no filament of its
    // own any more, so it goes to the head that carries most of that mix — and the maker is told.
    const phys = physicalIndexMap(plan);
    const mixedRefs = FILAMENT_INDEX_JSON.filter((k) => [].concat(obj[k]).some((v) => phys.clamped.has(parseInt(v, 10) - 1)));
    reindexFilamentJson(obj, keep, srcCount, phys.map);
    if (mixedRefs.length && report) {
      report.warnings.push(`Full Spectrum mixes a colour that ${mixedRefs.join(', ')} used, so ${mixedRefs.length === 1 ? 'it now uses' : 'they now use'} the head that carries most of that mix. Check those settings in your slicer.`);
    }
    obj.filament_colour = plan.physicalHex.slice();
    obj.mixed_filament_definitions = fullSpectrum.serializeMixedDefs(plan.mixDefs);
    for (const [k, val] of Object.entries(fullSpectrum.MIXED_DITHERING_DEFAULTS)) obj[k] = val;

    // The rest is bedready.io's withMixes (src/lib/convert.ts), learned from real mixed prints.
    //
    // "Subdivide Mix Layer" (dithering_local_z_mode): on by default — the U1 splits each layer
    // into thinner sub-layers inside mixed areas for smoother blends — and off on request, for
    // fewer tool changes and less purge.
    if (opts.fsSubdivide === false) { obj.dithering_local_z_mode = '0'; obj.dithering_local_z_infill = '0'; }
    // A fixed mixed-colour layer height re-slices the painted mixed zones at that height. It is
    // the fixed-step pipeline, which excludes the adaptive one, so Subdivide goes off with it.
    const mlh = Number(opts.fsMixedLayerHeight);
    if (mlh > 0) {
      obj.dithering_z_step_size = String(mlh);
      obj.dithering_step_painted_zones_only = '1';
      obj.dithering_local_z_mode = '0';
      obj.dithering_local_z_infill = '0';
    }
    // Mixed zones lay two filaments down in alternating thin layers, run hotter and fuse supports
    // more readily, so support interfaces get extra clearance. A floor only — a creator's larger
    // gap is kept. (0.35 because a real print still fused at 0.3.)
    if (!(parseFloat(obj.support_top_z_distance) >= 0.35)) obj.support_top_z_distance = '0.35';
    if (!(parseFloat(obj.support_bottom_z_distance) >= 0.25)) obj.support_bottom_z_distance = '0.25';
    // A mix swaps filament every dither step, which is a lot of purge. flush_into_* on dumped it
    // into the model and the supports right beside the painted features — the ooze seen on real
    // mixed prints. Off, the purge goes to the tower.
    obj.flush_into_objects = '0';
    obj.flush_into_infill = '0';
    obj.flush_into_support = '0';
    // ── AND MAKE ORCA KEEP ALL OF IT ──────────────────────────────────────────────────────
    // When print_settings_id names a system preset, Orca rebuilds that preset on import and
    // re-applies ONLY the keys listed in different_settings_to_system — everything else here,
    // the mix definitions included, silently reverted to stock. lib/hueforge-3mf.js already pins
    // its own keys for exactly this reason; this did not. Index 0 is the print-preset list (all of
    // these are print-scoped), the array is filament count + 2 long, and whatever the source had
    // declared there is kept. The per-filament entries are cleared, not carried: the filaments
    // were just reindexed to the physical heads, so the source's positions no longer line up.
    const pins = ['mixed_filament_definitions'].concat(Object.keys(fullSpectrum.MIXED_DITHERING_DEFAULTS),
      ['support_top_z_distance', 'support_bottom_z_distance', 'flush_into_objects', 'flush_into_infill', 'flush_into_support']);
    if (mlh > 0) pins.push('dithering_z_step_size');
    const prev = Array.isArray(obj.different_settings_to_system) ? obj.different_settings_to_system : [];
    const printDiffs = [...new Set(String(prev[0] || '').split(';').filter(Boolean).concat(pins))].sort();
    const dss = new Array(obj.filament_colour.length + 2).fill('');
    dss[0] = printDiffs.join(';');
    obj.different_settings_to_system = dss;
    if (report) {
      report.fullSpectrum = true;
      report.fullSpectrumMixes = plan.mixDefs.length;
      report.fieldsChanged.push('mixed_filament_definitions');
    }
  }

  // Bambu-flavour enum strings that Snapmaker Orca doesn't recognise (it silently "replaces" them and
  // warns on open). Normalise them to Orca's accepted values so the converted file loads clean. Mirrors
  // the web app's U1_VALUE_REMAP; keys hold string→string maps applied to scalars or per-object arrays.
  const ORCA_VALUE_REMAP = {
    ensure_vertical_shell_thickness: { disabled: 'none', enabled: 'ensure_all', partial: 'ensure_all' },
    support_style: { tree_organic: 'default' },
  };

  /**
   * Point each filament slot at a real Orca filament preset so the slicer stops flagging the source's
   * foreign preset (e.g. "Bambu PLA Basic @BBL X1C") as customized. Defaults every slot to the universal
   * "Generic <TYPE>" preset (what a clean U1 export uses); `opts.filaments[i]` (from the UI's per-slot
   * Orca-DB picker) overrides a slot with a specific preset name + type. Operates on the resolved
   * per-filament arrays already trimmed to the target's slots.
   */
  function applyOrcaFilaments(obj, opts, report) {
    const types = Array.isArray(obj.filament_type) ? obj.filament_type : null;
    const cols = Array.isArray(obj.filament_colour) ? obj.filament_colour : null;
    const count = (types && types.length) || (cols && cols.length) || 0;
    if (!count) return;
    const picks = Array.isArray(opts.filaments) ? opts.filaments : [];
    const ids = [], newTypes = [];
    for (let i = 0; i < count; i++) {
      const pick = picks[i] && picks[i].name ? picks[i] : null;
      const type = (pick && pick.type) || (types && types[i]) || 'PLA';
      ids.push(pick ? pick.name : `Generic ${type}`);
      newTypes.push(type);
    }
    obj.filament_settings_id = ids;
    obj.filament_type = newTypes;
    if (report) { report.fieldsChanged.push('filament_settings_id'); report.filamentPresets = ids.slice(); }
  }

  // Keys we set explicitly / manage elsewhere — never overwritten by the machine/process overlay.
  const U1_OVERLAY_SKIP = new Set(['printer_settings_id', 'print_settings_id', 'name', 'inherits',
    'printer_model', 'mixed_filament_definitions']);

  /**
   * Make the converted file's PRINTER + PROCESS settings genuinely native to the target printer by
   * overlaying the resolved machine profile (real start/end/tool-change G-code, flavour, build volume,
   * tool clearances) and a matching process preset (layer height, walls, speeds…) read from the maker's
   * INSTALLED Orca-family slicer. This is what stops the slicer's "please confirm this G-code is safe"
   * prompt — the embedded G-code is then the printer's own, not the source's. Works for any target that
   * names an `orcaMachine` (the built-in U1, or a printer picked from the slicer's catalogue). Filament
   * keys are left to applyOrcaFilaments; Full Spectrum keys are applied afterwards so they win. No-op
   * when the DB is absent or the machine isn't found (falls back to the plain reprofile).
   */
  function applyOrcaNative(obj, opts, target, report) {
    if (!orcaDb) return;
    const machineName = target.orcaMachine;
    if (!machineName) return;
    const machine = orcaDb.machineSettings(machineName);
    if (!machine || !Object.keys(machine).length) return; // slicer not installed → keep plain reprofile
    const procName = (opts && opts.process) || target.process || orcaDb.defaultProcessFor(machineName);
    const proc = procName ? orcaDb.resolvePreset('process', procName) : {};
    const overlay = (settings) => {
      for (const k of Object.keys(settings)) {
        if (k === '__proto__' || k === 'constructor' || k === 'prototype') continue;
        if (U1_OVERLAY_SKIP.has(k) || k.indexOf('filament_') === 0) continue;
        obj[k] = settings[k];
      }
    };
    overlay(machine);
    overlay(proc);
    obj.printer_settings_id = machineName;
    if (machine.printer_model) obj.printer_model = machine.printer_model;
    if (procName) { obj.print_settings_id = procName; if (report) report.processPreset = procName; }
    if (report) { report.fieldsChanged.push('printer_gcode', 'process_settings'); report.u1Native = true; }
    // What was overlaid, for the nozzle refit: a resolved PROCESS preset brings widths and layer
    // heights already made for the target nozzle; the machine alone brings only its limits. It
    // used to answer "yes" either way, so a machine without a process preset skipped the refit
    // and kept the source nozzle's widths.
    return proc && Object.keys(proc).length ? 'process' : 'machine';
  }

  // ── WHO WROTE THE FILE ───────────────────────────────────────────────────────────────────────
  // Snapmaker Orca, like mainline OrcaSlicer and Bambu Studio, imports a 3MF as a full project —
  // colours, painting, plates, object assignments — only when the root model's
  // <metadata name="Application"> starts with a producer it trusts. Anything else ("Creality_Print
  // V6…", Cura, …) loads as "geometry data only", every colour dropped, even when the configs this
  // converter just wrote are perfect. Rewriting the producer to an OrcaSlicer- string makes Orca
  // trust the project. Ported from bedready.io (forceOrcaGenerator, verified there against
  // OrcaSlicer/CrealityPrint Format/bbs_3mf.cpp).
  const ORCA_GENERATOR = 'OrcaSlicer-2.1.1';
  const TRUSTED_GENERATORS = /^(BambuStudio-|OrcaSlicer-|SnapmakerOrca-)/;
  const APPLICATION_RE = /(<metadata\s+name="Application"[^>]*>)([^<]*)(<\/metadata>)/;

  /**
   * The root model with an Orca-trusted producer, as `{ text, from }`, or null when it already
   * has one, has none, or never crossed into this process (a host passing the mesh by name). Only
   * the head of the file is searched — the producer sits in the opening metadata — so a large
   * mesh is not turned into one enormous string just to be told it is fine.
   */
  function forceOrcaGenerator(member) {
    if (!member || member.data == null) return null;
    const head = typeof member.data === 'string' ? member.data.slice(0, 65536)
      : member.data.subarray(0, 65536).toString('utf8');
    const m = APPLICATION_RE.exec(head);
    if (!m || TRUSTED_GENERATORS.test(m[2].trim())) return null;
    let text;
    try { text = member.data.toString('utf8'); } catch (_) { return null; } // past V8's string limit: leave it
    return { text: text.replace(APPLICATION_RE, (_a, open, _old, close) => open + ORCA_GENERATOR + close), from: m[2].trim() };
  }

  // ── VARIABLE LAYER HEIGHT ON THE U1 ─────────────────────────────────────────────────────────
  /** A Snapmaker-Orca target: the built-in U1, or a profile resolved from its machine catalogue. */
  function isSnapmakerOrca(target) {
    return target.flavour === 'orca' && (!!target.supportsMixedFilament || /snapmaker/i.test(String(target.orcaMachine || target.printerModel || '')));
  }

  /**
   * Pin print-preset keys in different_settings_to_system[0] so Orca KEEPS these overrides on
   * import instead of rebuilding the named system preset and reverting them, merged with whatever
   * the file already declared. Format: a (filament count + 2) array, index 0 the print-preset list.
   * Ported from bedready.io pinProcessKeys.
   */
  function pinProcessKeys(obj, keys) {
    if (!keys.length) return;
    const filCount = Array.isArray(obj.filament_colour) ? obj.filament_colour.length : 4;
    const prev = Array.isArray(obj.different_settings_to_system) ? obj.different_settings_to_system : [];
    const merged = [...new Set(String(prev[0] || '').split(';').filter(Boolean).concat(keys))].sort();
    const dss = new Array(Math.max(filCount + 2, prev.length)).fill('');
    for (let i = 1; i < prev.length; i++) dss[i] = prev[i] || '';
    dss[0] = merged.join(';');
    obj.different_settings_to_system = dss;
  }

  /**
   * Snapmaker Orca refuses to slice variable layer height with a prime tower or tree supports, so a
   * VLH file converted for it came out unsliceable. Tower off, tree → normal (keeping the
   * (auto)/(manual) suffix), both pinned or Orca puts the tower straight back on import. The VLH
   * profile itself is kept. `keepPrimeTowerVlh` skips this. Ported from bedready.io applyVlhGuard.
   */
  function applyVlhGuard(obj, report) {
    const pins = [];
    if (String(obj.enable_prime_tower) !== '0') { obj.enable_prime_tower = '0'; pins.push('enable_prime_tower'); }
    if (typeof obj.support_type === 'string' && obj.support_type.startsWith('tree')) {
      obj.support_type = obj.support_type.replace(/^tree/, 'normal');
      pins.push('support_type');
    }
    if (!pins.length) return;
    pinProcessKeys(obj, pins);
    if (report) {
      report.vlhGuard = true;
      report.fieldsChanged.push(...pins);
      report.warnings.push('This model uses variable layer height, which Snapmaker Orca cannot slice with a prime tower or tree supports — the prime tower was turned off and tree supports switched to normal.');
    }
  }

  // ── NOZZLE REFIT ─────────────────────────────────────────────────────────────────────────────
  // A retarget writes the target's nozzle_diameter, but line widths and layer heights are process
  // settings and arrive from the source untouched. So a 0.6-nozzle file converted for a 0.4 printer
  // claimed a 0.4 nozzle while asking for 0.63 mm extrusions — silently. Ported from bedready.io's
  // applyNozzleFit (src/lib/convert.ts): scale the nozzle-dependent values by target/source, and
  // hold layer height inside 20–80% of the new nozzle (the band its reference profile declares).
  // A matched nozzle changes nothing, a percentage is already nozzle-relative and is left alone,
  // and 0 (Prusa's "auto") stays auto. Not applied when the installed slicer's own process preset
  // was overlaid — that preset is already for the target nozzle.
  const NOZZLE_FIT_KEYS = ['line_width', 'initial_layer_line_width', 'inner_wall_line_width', 'outer_wall_line_width',
    'internal_solid_infill_line_width', 'sparse_infill_line_width', 'support_line_width',
    'top_surface_line_width', 'layer_height', 'initial_layer_print_height'];
  const NOZZLE_FIT_KEYS_PRUSA = ['extrusion_width', 'first_layer_extrusion_width', 'perimeter_extrusion_width',
    'external_perimeter_extrusion_width', 'infill_extrusion_width', 'solid_infill_extrusion_width',
    'top_infill_extrusion_width', 'support_material_extrusion_width', 'layer_height', 'first_layer_height'];
  // The per-extruder machine limits move with the nozzle by the same ratio, keeping the source's
  // own proportion (bedready reads them off its reference profile; this has none to read).
  const NOZZLE_LIMIT_KEYS = ['max_layer_height', 'min_layer_height'];
  const LAYER_KEYS = new Set(['layer_height', 'initial_layer_print_height', 'first_layer_height']);
  const LAYER_MIN_RATIO = 0.2, LAYER_MAX_RATIO = 0.8;

  /** The first nozzle a config declares — a list per extruder, uniform in practice — or NaN. */
  function nozzleNumber(v) {
    return parseFloat(String(Array.isArray(v) ? v[0] : v).split(/[,;]/)[0]);
  }

  /**
   * One refitted value, or null for "leave it". `s` is the value as written; the result keeps
   * the string-or-number form it came in.
   */
  function refitValue(key, s, from, to) {
    if (s == null || Array.isArray(s)) return null;
    const str = String(s);
    if (str.includes('%')) return null;
    const n = parseFloat(str);
    if (!Number.isFinite(n) || n <= 0) return null;
    let next = Math.round(n * (to / from) * 100) / 100;
    if (LAYER_KEYS.has(key)) next = Math.min(+(to * LAYER_MAX_RATIO).toFixed(2), Math.max(+(to * LAYER_MIN_RATIO).toFixed(2), next));
    return next === n ? null : next;
  }

  /** Refit a Bambu/Orca JSON config in place from nozzle `from` to `to`. */
  function applyNozzleFit(obj, from, to, report, fitOpts) {
    if (!(from > 0) || !(to > 0) || Math.abs(from - to) < 0.001) return;
    const limits = !fitOpts || fitOpts.limits !== false;
    const note = (k, a, b) => { if (report) { (report.nozzleFit = report.nozzleFit || []).push({ key: k, from: String(a), to: String(b) }); report.fieldsChanged.push(k); } };
    for (const k of NOZZLE_FIT_KEYS) {
      const next = refitValue(k, obj[k], from, to);
      if (next == null) continue;
      note(k, obj[k], next);
      obj[k] = typeof obj[k] === 'string' ? String(next) : next;
    }
    for (const k of limits ? NOZZLE_LIMIT_KEYS : []) {
      if (!(k in obj)) continue;
      const fit = (v) => { const n = parseFloat(v); return Number.isFinite(n) && n > 0 ? (typeof v === 'string' ? String(Math.round(n * (to / from) * 100) / 100) : Math.round(n * (to / from) * 100) / 100) : v; };
      const before = JSON.stringify(obj[k]);
      obj[k] = Array.isArray(obj[k]) ? obj[k].map(fit) : fit(obj[k]);
      if (before !== JSON.stringify(obj[k])) note(k, before, JSON.stringify(obj[k]));
    }
  }

  /** The same refit on a PrusaSlicer config's text, keeping each line's prefix. */
  function applyNozzleFitIni(text, from, to, report) {
    if (!(from > 0) || !(to > 0) || Math.abs(from - to) < 0.001) return text;
    for (const k of NOZZLE_FIT_KEYS_PRUSA) {
      const r = iniSet(text, k, (old) => {
        const next = refitValue(k, old, from, to);
        if (next == null) return old;
        if (report) { (report.nozzleFit = report.nozzleFit || []).push({ key: k, from: old, to: String(next) }); report.fieldsChanged.push(k); }
        return String(next);
      });
      text = r.text;
    }
    // The per-extruder limits too, entry by entry and by the same ratio — a 0.6 profile's 0.45 mm
    // ceiling is not a 0.4 nozzle's. `0` (no limit) stays.
    for (const k of NOZZLE_LIMIT_KEYS) {
      text = iniSet(text, k, (old) => {
        const next = old.split(',').map((v) => { const x = parseFloat(v); return Number.isFinite(x) && x > 0 ? String(Math.round(x * (to / from) * 100) / 100) : v.trim(); }).join(',');
        if (next !== old && report) { (report.nozzleFit = report.nozzleFit || []).push({ key: k, from: old, to: next }); report.fieldsChanged.push(k); }
        return next;
      }).text;
    }
    return text;
  }

  /** Rewrite known Bambu→Orca-incompatible enum values in a project_settings.config object in place. */
  function applyOrcaValueSafety(obj, report) {
    let changed = 0;
    for (const k of Object.keys(ORCA_VALUE_REMAP)) {
      if (!(k in obj)) continue;
      const map = ORCA_VALUE_REMAP[k];
      const fix = (v) => (typeof v === 'string' && v in map ? map[v] : v);
      const before = JSON.stringify(obj[k]);
      obj[k] = Array.isArray(obj[k]) ? obj[k].map(fix) : fix(obj[k]);
      if (report && before !== JSON.stringify(obj[k])) { report.fieldsChanged.push(k); changed++; }
    }
    return changed;
  }

  /**
   * Convert a 3MF for a target printer.
   * @param {Buffer} buf source 3MF
   * @param {{ targetId:string, mode?:('retarget'|'normalize'), slotMap?:number[], targetProfile?:object }} opts
   *        targetProfile — an explicit profile (e.g. a user-defined printer) used instead of
   *        the built-in registry lookup, so custom printers convert without server-side state.
   * @returns {{ ok:boolean, buffer?:Buffer, report?:object, error?:string }}
   */
  /**
   * The conversion itself: members in, members out.
   *
   * ── WHY THIS IS SEPARATE FROM `convert` ───────────────────────────────────
   *
   * Everything above and below it is ZIP work, and zip work is where this
   * module stops being portable: `zip-read` and `zip-write` are built on Node's
   * `zlib`, which does not exist in JavaScriptCore. So the native Mac app — the
   * one place a shop might convert a file without Electron running — could not
   * load this file at all, and the DECISIONS in it are not the part that needs
   * Node. They are string and JSON work on a handful of small config members.
   *
   * So the reading and the writing stay in `convert`, which is what a Node
   * caller wants, and this half takes the members already read and answers with
   * the members to write. A host that has its own zip — Swift's, in the Mac
   * app's case — can do the two ends itself and ask this the question in the
   * middle. Nothing here has changed; it has only been given a door.
   *
   * @param {Array} members from `readMembers`
   * @returns {{ok: true, members: Array, report: object} | {ok: false, error: string}}
   */
  function convertMembers(members, opts = {}) {
    if (!members.length) return { ok: false, error: 'Not a readable 3MF/ZIP file.' };
    // Refuse rather than write a file that is quietly less than the one handed over.
    // A convert that drops one of nineteen meshes still opens, still slices and still
    // prints — as something other than the model the maker chose.
    //
    // Checked before the no-geometry test on purpose: when the dropped members ARE the
    // geometry, "too large" is the true diagnosis and "has no model geometry" is a
    // description of the damage rather than its cause.
    if (members.truncated) {
      const mb = Math.round(members.truncated.bytes / (1024 * 1024));
      return {
        ok: false,
        error: `This 3MF is too large to convert in one piece — ${members.truncated.members} part(s)`
          + (mb >= 1 ? `, about ${mb} MB,` : '') + ' would be left out. '
          + 'Split it into fewer objects per file, or convert one plate at a time.',
      };
    }
    if (!members.some((m) => /\.model$/i.test(m.name))) {
      return { ok: false, error: 'This 3MF has no model geometry to convert.' };
    }
    const flavour = detectFlavour(members);
    const custom = opts.targetProfile && typeof opts.targetProfile === 'object' && opts.targetProfile.id
      ? profiles.customProfile(opts.targetProfile) : null;
    const target = custom || profiles.getProfile(opts.targetId) || profiles.GENERIC;
    const mode = opts.mode === 'normalize' || target.id === profiles.GENERIC.id ? 'normalize' : 'retarget';
    const filaments = extractFilaments(members);
    const report = { flavour, target: target.id, targetName: target.name, mode, fieldsChanged: [], colorsRemapped: 0, warnings: [] };

    // The members themselves, not copies of their bytes: an entry that survives to the
    // end untouched still carries its `src`, and gets copied across still compressed.
    // Rewrites below replace the element with a plain { name, data }, which loses `src`
    // exactly when it should — the bytes no longer match what the source held.
    let out = members.slice();

    if (mode === 'normalize') {
      // Drop vendor-locked slicer configs; keep geometry, rels, content-types, thumbnails.
      const before = out.length;
      out = out.filter((m) => GEOMETRY.test(m.name) || /thumbnail.*\.png$/i.test(m.name) || /\.png$/i.test(m.name));
      report.fieldsChanged.push(`stripped ${before - out.length} slicer config member(s)`);
      if (target.id !== profiles.GENERIC.id) report.warnings.push('Normalized to a generic 3MF (target-specific settings not written).');
    } else {
      // Retarget: rewrite the JSON/text settings for the target printer + optional remap.
      const n = filaments.length;
      let slotMap = Array.isArray(opts.slotMap) && opts.slotMap.length === n ? opts.slotMap : null;
      // A slot past the file's own filaments has no colour, material or temperature to give it —
      // the picker offers the printer's slots, which can outnumber the file's colours. Moving paint
      // there wrote states and extruders past the end of filament_colour; growing every
      // per-filament array to fit would mean inventing a filament. Nothing is moved instead, and
      // the maker is told to place it in the slicer.
      if (slotMap && slotMap.some((t) => !Number.isInteger(t) || t < 0 || t >= n)) {
        const far = Math.max(...slotMap.filter(Number.isInteger)) + 1;
        report.warnings.push(`The colour assignment uses slot ${far}, but this file has only ${n} filament${n === 1 ? '' : 's'}, so colours were left in their original slots. Reassign them in your slicer.`);
        slotMap = null;
      }
      // PrusaSlicer's config can only move as a whole: every per-filament value has to split into
      // exactly one entry per filament. Worked out before anything is rewritten, so a config that
      // cannot move leaves the paint where it is too.
      let prusaReindexed = null;
      if (slotMap && flavour === 'prusa') {
        const r = reindexPrusaConfig(memberText(members, CFG_PRUSA) || '', srcOfSlotMap(slotMap, n), n, slotMap);
        if (r.ok) prusaReindexed = r.text;
        else {
          report.warnings.push(`Colours were left in their original slots: this PrusaSlicer project's "${r.bad}" setting could not be matched to its ${n} filaments. Reassign the colours in PrusaSlicer.`);
          slotMap = null;
        }
      }

      // Band-swap: a cleanly vertically-banded painted model keeps ALL colours exactly by mapping each to a
      // physical head + M600 pauses (opt-in, U1 only). When active it supersedes Full Spectrum — the two are
      // mutually-exclusive colour strategies. Computed first so we skip the (expensive) FS mesh tally when
      // band-swap wins.
      const bandPlan = planBandSwap(members, filaments, target, opts);
      // Full Spectrum: >4 colours → 4 physical heads + dithered mixes (Snapmaker Orca). When active it
      // fully owns the colour mapping (paint codes + config), so it supersedes the plain slotMap remap.
      const fsPlan = bandPlan ? null : planFS(members, filaments, target, opts);
      // The active paint plan (band-swap or Full Spectrum) — both expose stateMap + map with the same shape.
      const paintPlan = bandPlan || fsPlan;

      // "Merge to the nearest {n} slots" (opts.mergeToSlots): more colours than the target has
      // slots, and no mixing or swapping asked for. Folds the least-used colours into their
      // nearest-looking neighbour until they fit (fullSpectrum.reduceColors, ported from
      // bedready.io). Only for a same-family Bambu/Orca file — the JSON config is the one this
      // can reindex — and never under a manual slot map, which is the maker's own decision.
      let mergePlan = planMerge(members, filaments, target, opts, paintPlan || slotMap, flavour);

      // ── THE PLAIN COLOUR → SLOT MAP REACHES THE PAINT TOO ─────────────────────────────
      // A slot map used to reorder the filament_* arrays and nothing else. On a PAINTED model
      // the colours live in the mesh — each triangle's paint code names a filament by number —
      // and on an object-coloured one in each object's `extruder`. Neither was touched, so the
      // palette moved and the paint still pointed at the old numbers: every colour landed on
      // somebody else's slot. bedready.io's retargetThreeMF remaps all three with one map
      // (remapPaintCode / remapExtruders / stateMap, its #39); so does this now. 0 is "the
      // object's own filament" and stays 0 — the object's extruder is remapped instead.
      let plainMap = paintPlan ? null : (mergePlan ? mergePlan.map : slotMap);
      // Variable layer height travels as one of these two members; see applyVlhGuard.
      const hasVLH = members.some((mm) => /(^|\/)(layer_config_ranges\.xml|layer_heights_profile\.txt)$/i.test(mm.name));

      // ── ALL OF THE PAINT MOVES, OR NONE OF IT ─────────────────────────────────────────
      // The mesh's paint, each object's extruder and the colour changes are rewritten together
      // or not at all, and decided BEFORE anything is written: a file whose model_settings moved
      // while its mesh could not (a host passing the mesh by name, a paint code that would not
      // re-encode, a palette that is not the config's) says two different things about the same
      // object.
      //
      // And when they cannot move, NOTHING moves — the config included. Reindexing the palette
      // and its temperatures while an object stays on extruder 1 prints that object in another
      // filament's colour at another filament's temperature (red PLA at 220 became green PETG at
      // 250), which is worse than not reassigning at all. The one safe exception is a file shown
      // to have no paint: then the config and the objects' extruders move together. A mesh that
      // never crossed into this process cannot be shown to have none, so that is refused too.
      let paintRewrites = null, paintBlocked = null;
      if (plainMap && plainMap.some((t, i) => t !== i)) {
        const proj = tryJson(memberText(members, /project_settings\.config$/i));
        const projCount = proj && Array.isArray(proj.filament_colour) ? proj.filament_colour.length : null;
        if (flavour !== 'prusa' && projCount !== n) paintBlocked = 'palette';
        else if (proj && hasVariantArrays(proj, n)) paintBlocked = 'variants';
        else if (members.some((mm) => /\.model$/i.test(mm.name) && mm.data == null)) paintBlocked = 'mesh';
        else {
          const stateMap = (st) => (st >= 1 && st <= n ? plainMap[st - 1] + 1 : st);
          paintRewrites = new Map();
          try {
            for (const mm of members) {
              if (!/\.model$/i.test(mm.name)) continue;
              const text = mm.data.toString('utf8');
              // Unpainted geometry is left as it was, still compressed — byte-identical.
              if (/(paint_color|mmu_segmentation)="/.test(text)) paintRewrites.set(mm.name, remapModelPaint(text, { stateMap }));
            }
          } catch (_) { paintBlocked = 'encode'; paintRewrites = null; } // a slot past the paint encoding, or text past V8's limit
        }
      }
      // A merge cannot leave the paint behind: states past the new slot count would point at
      // nothing. So a merge whose paint cannot move does not happen at all.
      let mergeDropped = false, slotMapDropped = false;
      if (paintBlocked && mergePlan) { mergePlan = null; plainMap = null; mergeDropped = true; }
      if (paintBlocked && slotMap) { slotMap = null; prusaReindexed = null; plainMap = null; slotMapDropped = true; }
      const plainMoves = !!paintRewrites;

      // Re-profiling only makes sense within one config family (Bambu/Orca share a JSON
      // dialect; Prusa is separate). Across families we can't produce a coherent file by
      // rewriting metadata, so we keep the colour remap but DON'T write a foreign printer
      // model into the source's config — and tell the maker to use Generic instead.
      const srcFamily = profiles.configFamily(flavour);
      const tgtFamily = profiles.configFamily(target.flavour);
      const reprofile = srcFamily !== 'generic' && srcFamily === tgtFamily;
      report.reprofile = reprofile;
      if (!reprofile && srcFamily !== 'generic') {
        report.crossFamily = true;
        report.warnings.push(`${target.name} uses a different slicer format than this file (${flavour} → ${target.flavour}). Colours were remapped, but printer settings weren't rewritten — convert to "Generic 3MF" and pick ${target.name} in your slicer instead.`);
      }

      out = out.map((m) => {
        // Band-swap / Full Spectrum: rewrite the paint codec in the mesh so each colour points at its
        // physical head (band-swap) or mixed/virtual slot (FS), and remap the XML part→extruder refs the same way.
        if (paintPlan && /\.model$/i.test(m.name)) {
          return { name: m.name, data: remapModelPaint(m.data.toString('utf8'), paintPlan) };
        }
        if (paintPlan && /model_settings\.config$/i.test(m.name) && !tryJson(m.data.toString('utf8'))) {
          // Bambu model_settings.config is XML: <metadata key="extruder" value="N"/> (1-based).
          // Each object's extruder through the plan (a mixed filament is a valid object colour);
          // its support / wall filament numbers through the plan's PHYSICAL map.
          const text = remapIndexText(m.data.toString('utf8'), physicalIndexMap(paintPlan).map, paintPlan.map);
          return { name: m.name, data: text };
        }
        if (plainMoves && paintRewrites.has(m.name)) return { name: m.name, data: paintRewrites.get(m.name) };
        if (plainMoves && m.data != null && (/custom_gcode_per_(layer|print_z)\.xml$/i.test(m.name) || /layer_config_ranges\.xml$/i.test(m.name)
          || (/(model_settings|Slic3r_PE_model)\.config$/i.test(m.name) && !tryJson(m.data.toString('utf8'))))) {
          // Bambu model_settings.config / Prusa Slic3r_PE_model.config are XML: each object's and
          // part's extruder and filament settings (1-based) follow the same map, and so do the
          // colour changes and layer ranges that name an extruder.
          const before = m.data.toString('utf8'), after = remapIndexText(before, plainMap);
          return after === before ? m : { name: m.name, data: after };
        }
        if (/project_settings\.config$/i.test(m.name) || /model_settings\.config$/i.test(m.name)) {
          const text = m.data.toString('utf8');
          const obj = tryJson(text);
          if (obj) {
            // The source's own nozzle, read before the re-profile below overwrites it.
            const srcNozzle = nozzleNumber(obj.nozzle_diameter);
            // Re-profile fields (same-family only).
            if (reprofile) {
              if (target.printerModel) { obj.printer_model = target.printerModel; report.fieldsChanged.push('printer_model'); }
              // Use the printer's EXACT library preset name (e.g. "Snapmaker U1 (0.4 nozzle)") so the
              // slicer matches it to an installed printer instead of flagging a "customized" preset.
              if (target.printerSettingsId || target.printerModel) obj.printer_settings_id = target.printerSettingsId || target.printerModel;
              if (target.nozzle) obj.nozzle_diameter = Array.isArray(obj.nozzle_diameter) ? obj.nozzle_diameter.map(() => String(target.nozzle)) : String(target.nozzle);
              // Prefer the printer's exact build-plate polygon when the profile carries it (keeps the
              // plate layout correct); otherwise derive a rectangle from the bed size.
              if (target.printableArea) {
                obj.printable_area = target.printableArea.slice();
                report.fieldsChanged.push('printable_area');
                if (target.printableHeight) { obj.printable_height = String(target.printableHeight); report.fieldsChanged.push('printable_height'); }
              } else if (target.bed) {
                const { x, y, z } = target.bed;
                obj.printable_area = [`0x0`, `${x}x0`, `${x}x${y}`, `0x${y}`];
                report.fieldsChanged.push('printable_area');
                if (z) { obj.printable_height = String(z); report.fieldsChanged.push('printable_height'); }
              }
            }
            // Overlay the real machine + process settings (from the installed slicer) so the printer
            // G-code and print settings are native — runs before Full Spectrum so mix keys win.
            const native = /project_settings\.config$/i.test(m.name) && target.flavour === 'orca' && applyOrcaNative(obj, opts, target, report);
            // Widths and layer heights follow a changed nozzle — unless the installed slicer's
            // process preset was just overlaid, which is already the target nozzle's own.
            if (reprofile && native !== 'process' && target.nozzle && /project_settings\.config$/i.test(m.name)) {
              // With the machine overlaid, max/min_layer_height are already the target machine's own.
              applyNozzleFit(obj, srcNozzle, Number(target.nozzle), report, { limits: native !== 'machine' });
            }
            // Band-swap / Full Spectrum own the colour mapping (only meaningful on project_settings, which
            // holds the filament palette + mixed-filament keys); otherwise apply the plain colour→slot remap.
            if (bandPlan && /project_settings\.config$/i.test(m.name)) {
              applyBandSwapConfig(obj, bandPlan, n, report);
            } else if (fsPlan && /project_settings\.config$/i.test(m.name)) {
              applyFullSpectrumConfig(obj, fsPlan, n, report, opts);
            } else if (mergePlan && /project_settings\.config$/i.test(m.name)) {
              applyMergeConfig(obj, mergePlan, n, report);
            } else if (slotMap && !paintPlan) {
              // Every per-filament setting and every filament number moves with its colour.
              report.colorsRemapped += reindexFilamentJson(obj, srcOfSlotMap(slotMap, n), n, slotMap);
            }
            // Snapmaker Orca rejects a few Bambu enum spellings — normalise them so it opens clean.
            if (/project_settings\.config$/i.test(m.name) && target.flavour === 'orca') {
              applyOrcaValueSafety(obj, report);
              applyOrcaFilaments(obj, opts, report); // real Orca filament presets (+ per-slot picks)
              if (hasVLH && isSnapmakerOrca(target) && !opts.keepPrimeTowerVlh) applyVlhGuard(obj, report);
            }
            return { name: m.name, data: JSON.stringify(obj, null, 4) };
          }
          return m;
        }
        if (/slice_info\.config$/i.test(m.name) && slotMap) {
          // Renumber/reorder <filament id=".." color=".."> by the slot map (text-level).
          const text = m.data.toString('utf8');
          const tags = [];
          const re = /<filament\b[^>]*>/g; let mm;
          while ((mm = re.exec(text))) tags.push(mm[0]);
          if (tags.length === n) {
            const reordered = permute(tags, slotMap).map((tag, i) =>
              tag.replace(/id="\d+"/i, `id="${i + 1}"`));
            let k = 0;
            const next = text.replace(/<filament\b[^>]*>/g, () => reordered[k++] || '');
            report.colorsRemapped += 1;
            return { name: m.name, data: next };
          }
          return m;
        }
        if (CFG_PRUSA.test(m.name)) {
          let text = m.data.toString('utf8');
          // iniSet keeps each line's own prefix: PrusaSlicer writes `; key = value`, and a
          // writer anchored on the bare key changed nothing in a real file while every one
          // of these fields was still reported as rewritten. A field is reported only when
          // the line was really there to rewrite.
          const set = (key, value, field) => {
            const r = iniSet(text, key, value);
            text = r.text;
            if (r.hit && field) report.fieldsChanged.push(field);
            return r.hit;
          };
          if (reprofile) {
            if (target.printerModel) set('printer_model', target.printerModel, 'printer_model');
            // The exact preset name and its variant, when the profile carries them — for the
            // reason the Bambu branch writes printer_settings_id: PrusaSlicer matches a project to
            // an installed printer by name, and a stale "Original Prusa MK3S" keeps the old one.
            if (target.printerSettingsId) set('printer_settings_id', target.printerSettingsId, 'printer_settings_id');
            if (target.printerVariant) set('printer_variant', target.printerVariant, 'printer_variant');
            // One value PER EXTRUDER, as many as the line already had: PrusaSlicer counts a
            // project's extruders from this list, so writing a single `0.4` over an MMU's
            // `0.4,0.4,0.4,0.4,0.4` would quietly turn a five-colour project into one.
            if (target.nozzle) {
              const srcNozzle = nozzleNumber(iniValue(text, 'nozzle_diameter'));
              set('nozzle_diameter', (old) => (old ? old.split(',').map(() => target.nozzle).join(',') : String(target.nozzle)), 'nozzle_diameter');
              text = applyNozzleFitIni(text, srcNozzle, Number(target.nozzle), report);
            }
            if (target.bed) {
              const { x, y, z } = target.bed;
              set('bed_shape', `0x0,${x}x0,${x}x${y},0x${y}`, 'bed_shape');
              if (z) set('max_print_height', String(z), 'max_print_height');
            }
          }
          if (slotMap && prusaReindexed != null) {
            // Every per-filament option, extruder_colour, the wiping volumes and the *_extruder
            // settings, together (reindexPrusaConfig). Checked on the source up front; the
            // re-profile above touched only printer and process keys, so it still holds here.
            const r = reindexPrusaConfig(text, srcOfSlotMap(slotMap, n), n, slotMap);
            if (r.ok && r.text !== text) { text = r.text; report.colorsRemapped += 1; }
          }
          return { name: m.name, data: text };
        }
        return m;
      });

      // A foreign producer string makes Orca load geometry only — see forceOrcaGenerator.
      if (reprofile && target.flavour === 'orca') {
        const ri = out.findIndex((mm) => /(^|\/)3D\/3dmodel\.model$/i.test(mm.name));
        const fixed = ri >= 0 ? forceOrcaGenerator(out[ri]) : null;
        if (fixed) {
          out[ri] = { name: out[ri].name, data: fixed.text };
          report.producerRewritten = fixed.from;
          report.fieldsChanged.push('Application');
        }
      }

      // Re-tile the multi-plate object layout when the target bed size differs from the source's, so
      // plates stay centred instead of drifting to the edge. Operates on the already-rewritten output.
      if (reprofile && target.bed) {
        const srcCfgMember = members.find((mm) => /project_settings\.config$/i.test(mm.name));
        const srcCfg = srcCfgMember && srcCfgMember.data != null ? tryJson(srcCfgMember.data.toString('utf8')) : null;
        const srcBed = srcCfg ? bedFromPrintableArea(srcCfg.printable_area) : null;
        if (srcBed && (Math.abs(srcBed.x - target.bed.x) > 0.5 || Math.abs(srcBed.y - target.bed.y) > 0.5)) {
          const retiled = retilePlatesForBed(out, target, srcBed, report);
          const ri = retiled ? out.findIndex((mm) => /3D\/3dmodel\.model$/i.test(mm.name)) : -1;
          // The whole member when we rewrote the whole text; the block alone when
          // the mesh never crossed into this process — the host puts that back.
          if (ri >= 0) {
            out[ri] = retiled.text != null
              ? { name: out[ri].name, data: retiled.text }
              : { name: out[ri].name, buildBlock: retiled.buildBlock };
          }
        }
      }

      // Band-swap: painted files have no custom_gcode_per_layer.xml, so add the synthesized one carrying the
      // M600 pauses at each manual-swap height (replacing any existing one).
      if (bandPlan) {
        out = out.filter((m) => !/Metadata\/custom_gcode_per_layer\.xml$/i.test(m.name));
        out.push({ name: 'Metadata/custom_gcode_per_layer.xml', data: bandPlan.customGcodeXml });
      }

      if (flavour === 'generic') report.warnings.push('Source slicer not recognized — geometry preserved, but no colour/printer settings were found to rewrite.');
      if (bandPlan) {
        const sw = bandPlan.instructions.length;
        report.warnings.push(`Colour-banded model: kept all ${n} colours exactly by mapping them onto ${bandPlan.heads} heads` +
          (sw ? ` with ${sw} manual filament swap(s) — M600 pauses were added at the swap heights. Load the head colours shown and swap the spool when ${target.name} pauses.` : ' — no manual swaps needed (fits the heads).'));
      } else if (fsPlan) {
        report.warnings.push(`Full Spectrum: kept ${target.maxColors} filaments physical and reproduced ${n - target.maxColors} extra colour(s) as ${fsPlan.mixDefs.length} dithered mix(es). Load the ${target.maxColors} head colours shown; ${target.name} prints the rest by mixing.`);
      } else if (mergePlan) {
        report.warnings.push(`Merged ${n} colours into the nearest ${mergePlan.colors.length} for ${target.name}: the least-used colours now print in the closest-looking slot. Check the colours in your slicer before printing.`);
      } else if (target.maxColors && n > target.maxColors) {
        report.warnings.push(`Source uses ${n} colours but ${target.name} supports ${target.maxColors}. Extra colours will need manual mapping in your slicer.`);
      }
      if (paintBlocked) {
        // Why, in words that fit a file whether it is painted or coloured per object.
        const why = {
          mesh: 'this app could not read the model to move its colours with them',
          palette: 'the file\'s colour list does not match its filament settings',
          variants: 'this file keeps several values per filament (one per nozzle type), which this converter does not reorder yet',
          encode: 'the model\'s colour data could not be rewritten for the new slots',
        }[paintBlocked];
        if (mergeDropped) report.warnings.push(`Colours were not merged: ${why}. ${target.name} supports ${target.maxColors} colours — map the extra ones in your slicer.`);
        if (slotMapDropped) report.warnings.push(`Colours were left in their original slots: ${why}. Reassign them in your slicer${paintBlocked === 'mesh' ? ', or convert the file in Khayt' : ''}.`);
      }
      const bounds = computeBounds(members);
      if (bounds) { report.bounds = bounds; for (const w of fitWarnings(bounds, target)) report.warnings.push(w); }
      report.fieldsChanged = [...new Set(report.fieldsChanged)];
    }

    return { ok: true, members: out, report };
  }

  function convert(buf, opts = {}) {
    const members = readMembers(buf);
    const planned = convertMembers(members, opts);
    if (!planned.ok) return planned;
    const { members: out, report } = planned;
    // The self-check below needs the target and the source's colours. The
    // target is worked out the SAME WAY the conversion did, not looked up by
    // the id in the report: a caller can hand in a whole custom profile, and
    // `getProfile` does not know about one — it would fall back to GENERIC and
    // check the colour count against the wrong `maxColors`. Nothing in the
    // suite covers that combination, which is exactly why it is written out.
    const custom = opts.targetProfile && typeof opts.targetProfile === 'object' && opts.targetProfile.id
      ? profiles.customProfile(opts.targetProfile) : null;
    const target = custom || profiles.getProfile(opts.targetId) || profiles.GENERIC;
    const filaments = extractFilaments(members);
    const mode = report.mode;

    const zipped = zipWrite.writeZip(out.map((m) => (m.src ? { name: m.name, raw: m.src } : { name: m.name, data: m.data })));
    if (!zipped) return { ok: false, error: 'Failed to repackage the 3MF.' };

    // Output self-check: re-open the file we just wrote and confirm it still parses with its
    // geometry (and, on a retarget, its colours) intact — cheap insurance behind the "it
    // always opens" guarantee. A failure is surfaced as a warning, not a hard error.
    try {
      const back = analyze(zipped);
      // Full Spectrum / band-swap reduce the palette to the physical heads (FS mixes are virtual; band-swap
      // folds colours onto heads), so the round-trip colour count is the target's slot count, not the source's.
      const expectColours = (report.fullSpectrum || report.bandSwap) ? (target.maxColors || filaments.length)
        : report.colorsMerged ? report.colorsMerged.to : filaments.length;
      const coloursOk = mode === 'normalize' ? true : back.colorCount === expectColours;
      report.verified = !!(back && back.ok && back.hasGeometry && coloursOk);
    } catch (_) { report.verified = false; }
    if (report.verified === false) report.warnings.push('The converted file could not be re-validated — open it in your slicer to check before printing.');

    return { ok: true, buffer: zipped, report };
  }

  /**
   * Preview a Full Spectrum plan for the UI: which filaments load physically and how each extra colour
   * is reproduced as a mix. Returns { available:false } when FS doesn't apply (≤ slots, no palette,
   * non-Orca target). Pure read — no file is written.
   */
  function fsPreview(buf, opts = {}) {
    const members = readMembers(buf);
    if (!members.length) return { available: false };
    const custom = opts.targetProfile && typeof opts.targetProfile === 'object' && opts.targetProfile.id
      ? profiles.customProfile(opts.targetProfile) : null;
    const target = custom || profiles.getProfile(opts.targetId) || profiles.GENERIC;
    const filaments = extractFilaments(members);
    if (!target.supportsMixedFilament || !(target.maxColors >= 2) || filaments.length <= target.maxColors) {
      return { available: false, colours: filaments.length, slots: target.maxColors || null };
    }
    const plan = planFS(members, filaments, target, { fullSpectrum: true, fsPhysical: opts.fsPhysical, fsPhysicalHex: opts.fsPhysicalHex });
    if (!plan) return { available: false, colours: filaments.length, slots: target.maxColors };
    const heads = plan.physical.map((srcI, k) => ({ slot: k + 1, srcIndex: srcI, hex: plan.physicalHex[k] }));
    const mixes = plan.extras.map((e) => ({
      srcHex: e.srcHex, resultHex: e.resultHex, deltaE: Math.round(e.deltaE * 10) / 10,
      ids: e.recipe.ids, weights: e.recipe.weights, kind: e.recipe.kind,
    }));
    return { available: true, slots: target.maxColors, colours: filaments.length, targetName: target.name, heads, mixes };
  }

  /**
   * Read-only analysis: is this a cleanly VERTICALLY colour-banded model that a swap-capable printer
   * (e.g. the Snapmaker U1) can print with EXACT colours via manual filament-swap pauses — instead of
   * Full-Spectrum mixing? Extracts the painted mesh through the shared reader (object/part colouring +
   * paint codes resolved), runs the band detector, and — when banded with more colours than heads —
   * builds the swap plan (pause heights + a ready custom_gcode_per_layer.xml). Pure; writes nothing.
   * @param {Buffer} buf source 3MF
   * @param {{ heads?:number, pauseGcode?:string }} [opts] heads = physical toolheads (default 4)
   * @returns {{ available:boolean, banded?:boolean, reason?:string, colorCount?:number, bands?:object[],
   *            manualSwaps?:number, changeHeights?:number[], instructions?:object[], customGcodeXml?:string,
   *            purity?:number, palette?:string[] }}
   */
  function analyzeColorBands(buf, opts = {}) {
    if (!colorBands || !mfMesh || !mfMesh.extractMeshFromMembers) return { available: false };
    const members = readMembers(buf);
    if (!members.length) return { available: false };
    let mesh;
    try { mesh = mfMesh.extractMeshFromMembers(members); } catch (_) { return { available: false }; }
    if (!mesh || !mesh.faceState || !mesh.faceState.length) return { available: false };
    const baseState = mesh.baseState >= 1 ? mesh.baseState : 1;
    const plan = colorBands.detectColorBandsForMesh(mesh, baseState); // per plate — see planBandSwap
    const palette = Array.isArray(mesh.palette) ? mesh.palette.slice() : [];
    const base = {
      available: true,
      banded: plan.banded,
      reason: plan.reason,
      colorCount: plan.colorCount,
      bands: plan.bands,
      manualSwaps: plan.manualSwaps,
      changeHeights: plan.changeHeights,
      purity: Math.round(plan.purity * 1000) / 1000,
      sampled: !!mesh.sampled,
      palette,
    };
    if (!plan.banded || !swapPauses || !swapPauses.buildBandSwapPlan) return base;
    // Layer height (mm) for pause placement — from the source project settings when available.
    const meta = extractMeta(members);
    const layerHeight = meta && meta.layerHeight ? meta.layerHeight : undefined;
    const pauseGcode = opts.pauseGcode || 'M600';
    // heads = physical toolheads (default 4 = U1). heads:1 → a single-extruder M600 plan: a swap at every
    // colour change, so any pause-capable printer can print a vertically-banded multicolour file.
    const heads = opts.heads && opts.heads > 0 ? opts.heads : undefined;
    const swap = swapPauses.buildBandSwapPlan(plan.bands, palette, pauseGcode, layerHeight, baseState, heads);
    return Object.assign(base, {
      heads: heads || swapPauses.N_PHYSICAL,
      swaps: swap.instructions.length,
      instructions: swap.instructions,
      customGcodeXml: swap.customGcodeXml,
      headOf: [...swap.headOf.entries()].map(([state, head]) => ({ state, head })),
    });
  }

  const api = { analyze, convert, convertMembers, fsPreview, analyzeColorBands, readMembers, detectFlavour, extractFilaments, extractMeta, computeBounds, countTriangles, measureMesh, extractTriangles, extractTrianglesWithPaint, extractPlates, plateOf, platePalettes, fitWarnings };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytMfConvert = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
