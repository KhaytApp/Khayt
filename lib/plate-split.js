'use strict';
/**
 * "Split into plates": every plate of a multi-plate project, each converted into
 * a file of its own with its own colours.
 *
 * The idea comes from Bambu2U1_MultiPlate (github.com/bradhoschar, MIT, Python):
 * a Bambu project of twelve colours over eleven plates does not fit a four-head
 * printer as one file, but each plate on its own usually does. Nothing of its
 * code is here — this is the two pipelines Khayt already had, put end to end:
 *
 *   lib/plates.js      extractPlateMembers — one plate as a standalone project,
 *                      seated on one bed, referencing only what it contains
 *   lib/mf-convert.js  convertMembers — the ordinary retarget, given the plate's
 *                      own filaments as `plateColours`, which it turns into a
 *                      merge plan (planMerge): those filaments take slots 1..k
 *                      and the config, the paint and every extruder move
 *                      together, or not at all
 *
 * So there is no second converter. What this module adds is the two questions
 * the pipeline could not ask on its own:
 *
 * WHICH FILAMENTS DOES THIS PLATE PRINT WITH — EXACTLY. lib/plates.js's listing
 * answers it cheaply and says when it is approximate (no mesh read, or a sampled
 * one); a colour map built on an approximation would print a rarely-used colour
 * in somebody else's slot. So this reads the extracted plate's own members: every
 * object's and part's `extruder`, every colour/tool change and layer range that
 * names one, and every leaf state of every paint code (decoded with the same
 * full-spectrum codec that later rewrites them). A plate whose mesh is not here
 * to read — a host passing it by name — is converted without a plate map, and
 * the report says so.
 *
 * WHERE ON THE TARGET BED. extractPlate seats the plate on the SOURCE bed. A
 * retarget re-tiles plates for a different bed size only when there are two or
 * more (retilePlatesForBed); a one-plate file is left at the source origin, which
 * on a 270 mm U1 is 7 mm off a 256 mm Bambu bed's centre. Here every item moves
 * by the difference between the two beds' centres, which is what the re-tile does
 * for each plate of a multi-plate file: the author's offset from the plate centre
 * is kept.
 *
 * A project whose colours already fit the target (n <= slots) keeps its own slot
 * numbers on every plate, so a shop that loads the spools once prints every plate
 * without reloading. Only past the slot count is a plate given its own map.
 *
 * Members in, members out, like convertMembers, so the Mac (Swift's zip) asks the
 * same question as the desktop (Node's). `splitPlates(buf)` is the Node end.
 */
(function (global) {
  const req = (typeof require === 'function') ? require : null;
  const plates = req ? req('./plates') : global.KhaytPlates;
  const mf = req ? req('./mf-convert') : global.KhaytMfConvert;
  const profiles = req ? req('./printer-profiles') : global.KhaytPrinterProfiles;
  const fullSpectrum = req ? req('./full-spectrum') : global.fullSpectrum;
  const zipWrite = req ? req('./zip-write') : null;

  const MODEL_SETTINGS = /(^|\/)Metadata\/model_settings\.config$/i;
  const PROJECT_SETTINGS = /(^|\/)Metadata\/project_settings\.config$/i;
  const CUSTOM_GCODE = /(^|\/)Metadata\/custom_gcode_per_layer\.xml$/i;
  const LAYER_RANGES = /(^|\/)Metadata\/layer_config_ranges\.xml$/i;
  const ROOT_MODEL = /(^|\/)3D\/3dmodel\.model$/i;

  const textOf = (m) => {
    const d = m ? m.data : null;
    if (d == null) return null;
    return typeof d === 'string' ? d : d.toString('utf8');
  };
  const tryJson = (s) => { try { return JSON.parse(s); } catch (_) { return null; } };
  const attr = (s, name) => (new RegExp(`\\b${name}="([^"]*)"`).exec(s) || [])[1];

  /** The target exactly as convertMembers resolves it. */
  function targetOf(opts) {
    const custom = opts.targetProfile && typeof opts.targetProfile === 'object' && opts.targetProfile.id
      ? profiles.customProfile(opts.targetProfile) : null;
    return custom || profiles.getProfile(opts.targetId) || profiles.GENERIC;
  }

  /**
   * The filaments one (extracted) plate prints with, 0-based and sorted, and whether that
   * is known exactly. `n` is the project's filament count; anything outside 1..n is not a
   * filament this project has and is left out.
   *
   * @returns {{ used:number[], exact:boolean }}
   */
  function plateFilaments(members, n) {
    const used = new Set();
    const add = (v) => { const k = parseInt(v, 10); if (k >= 1 && k <= n) used.add(k - 1); };
    let exact = true;

    // Objects and their parts. An object that names no filament prints in filament 1; a part
    // at 0 takes its object's, which is already counted.
    const ms = textOf(members.find((m) => MODEL_SETTINGS.test(m.name)));
    if (ms) {
      for (const ob of ms.matchAll(/<object\b[^>]*>([\s\S]*?)<\/object>/g)) {
        const own = ob[1].replace(/<part\b[\s\S]*?<\/part>/g, '');
        const e = /<metadata\b[^>]*\bkey="extruder"[^>]*\bvalue="(\d+)"/.exec(own);
        add(e ? e[1] : 1);
        for (const p of ob[1].matchAll(/<part\b[^>]*>([\s\S]*?)<\/part>/g)) {
          const pe = /<metadata\b[^>]*\bkey="extruder"[^>]*\bvalue="(\d+)"/.exec(p[1]);
          if (pe) add(pe[1]);
        }
      }
    } else exact = false;

    // Colour changes (type 0) and tool changes (type 3) name the filament they switch to; a
    // pause or a custom G-code only repeats the current one.
    const cg = textOf(members.find((m) => CUSTOM_GCODE.test(m.name)));
    if (cg) {
      for (const l of cg.matchAll(/<layer\b[^>]*>/g)) {
        const type = attr(l[0], 'type');
        if (type == null || type === '0' || type === '3') add(attr(l[0], 'extruder'));
      }
    }
    // A height range can print in a filament of its own.
    const lr = textOf(members.find((m) => LAYER_RANGES.test(m.name)));
    if (lr) for (const r of lr.matchAll(/opt_key="extruder"\s*>(\d+)</g)) add(r[1]);

    // Paint: every leaf state of every distinct code, through the codec that rewrites them.
    // State 0 is "the object's own filament", counted above.
    for (const m of members) {
      if (!/\.model$/i.test(m.name)) continue;
      const t = textOf(m);
      if (t == null) { exact = false; continue; }
      const codes = new Set();
      for (const c of t.matchAll(/(?:paint_color|mmu_segmentation)="([0-9A-Fa-f]+)"/g)) codes.add(c[1]);
      for (const code of codes) {
        try { fullSpectrum.remapPaintCode(code, (s) => { if (s >= 1) add(s); return s; }); } catch (_) { exact = false; }
      }
    }
    return { used: [...used].sort((a, b) => a - b), exact };
  }

  /** Centre of a printable_area polygon's bounding box, or null. */
  function centreOf(area) {
    if (!Array.isArray(area)) return null;
    const pts = area.map((p) => String(p).split('x').map(Number)).filter((p) => p.length === 2 && p.every(Number.isFinite));
    if (!pts.length) return null;
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    const w = Math.max(...xs) - Math.min(...xs), d = Math.max(...ys) - Math.min(...ys);
    return w > 0 && d > 0 ? { x: (Math.max(...xs) + Math.min(...xs)) / 2, y: (Math.max(...ys) + Math.min(...ys)) / 2 } : null;
  }

  /**
   * Move the plate's build items from the source bed's centre to the target's. Returns the
   * members (the root rewritten when it moved) and the shift, or null when there is nothing
   * to do — same bed, no bed, another slicer family, or a root model that is not here.
   */
  function recentre(members, target) {
    const ps = tryJson(textOf(members.find((m) => PROJECT_SETTINGS.test(m.name))) || '');
    const from = ps ? centreOf(ps.printable_area) : null;
    const to = target.printableArea ? centreOf(target.printableArea)
      : (target.bed && target.bed.x && target.bed.y ? { x: target.bed.x / 2, y: target.bed.y / 2 } : null);
    if (!from || !to) return null;
    const dx = to.x - from.x, dy = to.y - from.y;
    if (Math.abs(dx) <= 0.5 && Math.abs(dy) <= 0.5) return null;
    const at = members.findIndex((m) => ROOT_MODEL.test(m.name));
    const root = at >= 0 ? textOf(members[at]) : null;
    if (root == null) return null;
    const fmt = (v) => String(Number(v.toFixed(6)));
    const next = root.replace(/(<build\b[\s\S]*?<\/build>)/, (build) => build.replace(/<item\b[^>]*>/g, (it) =>
      it.replace(/\btransform="([^"]*)"/, (all, t) => {
        const tok = t.trim().split(/\s+/);
        if (tok.length !== 12 || !tok.every((x) => Number.isFinite(Number(x)))) return all;
        tok[9] = fmt(Number(tok[9]) + dx);
        tok[10] = fmt(Number(tok[10]) + dy);
        return `transform="${tok.join(' ')}"`;
      })));
    if (next === root) return null;
    const out = members.slice();
    out[at] = { name: members[at].name, data: next };
    return { members: out, shift: [dx, dy] };
  }

  /**
   * One plate of a project, extracted and converted.
   *
   * `opts` are convertMembers' (targetId / targetProfile, dropVariableLayerHeight, …). The
   * plate's own colour map is added here, and only when nothing else owns the colours: a
   * slot map, a spool match, Full Spectrum or band-swap is the caller's decision and runs as
   * it would on the whole file.
   *
   * @returns {{ok:true, members:Array, report:object, plate:object} | {ok:false, code?, error}}
   *   report.plate = { index, platerId, name, seat, recentred, filaments (1-based), exact }
   */
  function convertPlateMembers(members, plateIndex, opts = {}) {
    const ex = plates.extractPlateMembers(members, plateIndex);
    if (!ex.ok) return ex;
    let pm = ex.members;
    const target = targetOf(opts);
    const normalize = opts.mode === 'normalize' || target.id === profiles.GENERIC.id;
    const flavour = mf.detectFlavour(pm);
    const sameFamily = profiles.configFamily(flavour) !== 'generic' && profiles.configFamily(flavour) === profiles.configFamily(target.flavour);

    let recentred = null;
    if (!normalize && sameFamily) {
      const r = recentre(pm, target);
      if (r) { pm = r.members; recentred = r.shift; }
    }

    const o = Object.assign({}, opts);
    delete o.plateColours;
    const n = mf.extractFilaments(pm).length;
    const slots = target.maxColors;
    const otherPlan = o.fullSpectrum || o.bandSwap || o.spoolMerge || (Array.isArray(o.slotMap) && o.slotMap.some((t, i) => t !== i));
    let filaments = null;
    if (!normalize && slots >= 1 && n > slots && !otherPlan) {
      filaments = plateFilaments(pm, n);
      if (filaments.exact && filaments.used.length) o.plateColours = filaments.used;
    }

    const r = mf.convertMembers(pm, o);
    if (!r.ok) return r;
    if (filaments && !filaments.exact) {
      r.report.warnings.push('This plate\'s colours could not all be read, so it keeps the project\'s colour numbering. Map its colours in your slicer.');
    }
    r.report.plate = {
      index: ex.plate.index, platerId: ex.plate.platerId, name: ex.plate.name,
      seat: ex.report.seat, recentred,
      filaments: filaments ? filaments.used.map((i) => i + 1) : null, exact: filaments ? filaments.exact : null,
    };
    return { ok: true, members: r.members, report: r.report, plate: ex.plate };
  }

  /**
   * The plates a split would make: lib/plates.js's listing, without pictures or colours.
   * @returns {{ok:true, plates:Array<{index, platerId, name, splittable, problem}>} | {ok:false, code, error}}
   */
  function listPlatesMembers(members) {
    const r = plates.peekPlatesMembers(members, { colors: false, thumbnails: false });
    if (!r.ok) return r;
    return { ok: true, plates: r.plates.map((p) => ({ index: p.index, platerId: p.platerId, name: p.name, splittable: p.splittable, problem: p.problem })) };
  }

  /**
   * Every plate, each converted on its own. One plate that cannot be split out (an object
   * shared with another plate, say) fails alone; the rest still convert.
   *
   * @param {Array} members
   * @param {object} opts  convertMembers' options, plus `sourceName` for the file names
   * @returns {{ok:true, plates:Array<{index, name, fileName, ok, members?, report?, code?, error?}>}
   *   | {ok:false, code, error}}
   */
  function splitPlatesMembers(members, opts = {}) {
    const list = listPlatesMembers(members);
    if (!list.ok) return list;
    if (list.plates.length < 2) return { ok: false, code: 'single-plate', error: 'This project has only one plate — convert the whole file instead.' };
    const out = list.plates.map((p) => {
      const fileName = plates.plateFileName(opts.sourceName, p.index);
      if (!p.splittable) return { index: p.index, name: p.name, fileName, ok: false, code: p.problem && p.problem.code, error: p.problem ? p.problem.error : 'This plate cannot be split out.' };
      const r = convertPlateMembers(members, p.index, opts);
      return r.ok ? { index: p.index, name: p.name, fileName, ok: true, members: r.members, report: r.report }
        : { index: p.index, name: p.name, fileName, ok: false, code: r.code, error: r.error };
    });
    return { ok: true, plates: out };
  }

  /**
   * Node end: a 3MF buffer in, one converted 3MF buffer per plate out. Geometry a plate
   * keeps untouched is copied across still compressed. Each file is re-opened and checked,
   * as `convert` checks its own (`report.verified`).
   *
   * @returns {{ok:true, files:Array<{index, name, fileName, ok, buffer?, report?, code?, error?}>}
   *   | {ok:false, code, error}}
   */
  function splitPlates(buf, opts = {}) {
    const members = plates.readMembers(buf);
    if (!members.length) return { ok: false, code: 'not-3mf', error: 'Not a readable 3MF/ZIP file.' };
    const r = splitPlatesMembers(members, opts);
    if (!r.ok) return r;
    const target = targetOf(opts);
    const files = r.plates.map((p) => {
      if (!p.ok) return p;
      const raw = (m) => m.src || m.raw || null;
      const buffer = zipWrite.writeZip(p.members.map((m) => (raw(m) ? { name: m.name, raw: raw(m) } : { name: m.name, data: m.data })));
      if (!buffer) return { index: p.index, name: p.name, fileName: p.fileName, ok: false, code: 'error', error: 'Could not write the plate\'s 3MF.' };
      const report = p.report;
      try {
        const back = mf.analyze(buffer);
        const want = report.mode === 'normalize' ? null
          : report.colorsMerged ? report.colorsMerged.to
          : (report.fullSpectrum || report.bandSwap) ? target.maxColors
          : mf.extractFilaments(p.members).length;
        report.verified = !!(back && back.ok && back.hasGeometry && (want == null || back.colorCount === want));
      } catch (_) { report.verified = false; }
      if (!report.verified) report.warnings.push('The converted file could not be re-validated — open it in your slicer to check before printing.');
      return { index: p.index, name: p.name, fileName: p.fileName, ok: true, buffer, report };
    });
    return { ok: true, files };
  }

  const api = { splitPlates, splitPlatesMembers, convertPlateMembers, listPlatesMembers, plateFilaments };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytPlateSplit = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
