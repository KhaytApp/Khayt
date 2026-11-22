'use strict';
/**
 * Bambu / Orca painted 3MF → a PrusaSlicer project for a multi-tool Prusa (the MK4/MK4S + MMU3 and
 * the CORE One INDX), with ColorMix blends on a printer that has them.
 *
 * Ported from bedready.io's src/lib/prusa-project.ts (its #35, #36 and #37), which was checked
 * against PrusaSlicer 2.9.6 by slicing, not only by tests. Until this existed, the converter met a
 * Bambu file aimed at a Prusa with "different slicer format — convert to Generic 3MF". PrusaSlicer
 * does read Bambu's `paint_color` and its `p:path` components, so the painting survived that; three
 * things did not:
 *
 *   1. WHICH TOOLHEAD. Paint states point at filament 1…n of whatever printer is active, so a model
 *      painted for a Bambu AMS lands on Prusa tools in creator order. Every state is remapped here
 *      through the converter's slot assignment (or the merge that fits the colours onto the tools).
 *   2. THE UNPAINTED FACES. Bambu keeps a part's own filament in Metadata/model_settings.config, which
 *      PrusaSlicer never reads, so a part assigned filament 3 printed with tool 1. Every face is painted
 *      EXPLICITLY here, so nothing depends on a "base extruder" either slicer could read differently.
 *   3. THE PRINTER. A minimal Metadata/Slic3r_PE.config names the target's exact preset and carries
 *      the tool colours. Identity and colour ONLY, as bedready.io writes it: PrusaSlicer fills every
 *      other key from its own system preset of that name, and Prusa's profiles are AGPL.
 *
 * Build items move from the source bed's centre to the target's.
 *
 * What is deliberately NOT written: Metadata/Slic3r_PE_model.config. PrusaSlicer's importer, given an
 * object entry there, builds that object from the <volume firstid/lastid> ranges listed and from
 * nothing else — an entry with a wrong or missing range loads as an object with no volumes. Bambu
 * projects keep their meshes in p:path component files whose object ids collide with the root's, so
 * those ranges cannot be written without guessing how PrusaSlicer flattens components. Without the
 * file PrusaSlicer takes each object's whole geometry as one volume, which is what bedready.io
 * verified by slicing. A guessed file would be worse than none.
 *
 * Paint states after remapping are ≤ 16, the encoding PrusaSlicer's `mmu_segmentation` and Bambu's
 * `paint_color` share (they only diverge above that), so the codes are the same bits renamed.
 *
 * Members in, members out — the shape lib/mf-convert.js's convertMembers works in, so the Mac app,
 * which does its own zip, runs this too. Pure: no fs, no zlib.
 */
(function (global) {
  const req = typeof require === 'function';
  const mfMesh = req ? require('./mf-mesh') : global.KhaytMfMesh;
  const fullSpectrum = req ? require('./full-spectrum') : global.fullSpectrum;
  const mixer = req ? require('./filament-mixer') : global.filamentMixer;
  const profiles = req ? require('./printer-profiles') : global.KhaytPrinterProfiles;
  // Looked up when used, not at load: the Mac app bundles `color-mix` after the converter.
  const colour = () => (req ? require('./color-mix') : global.KhaytColor);

  const SLIC3RPE_NS = 'http://schemas.slic3r.org/3mf/2017/06';
  const CONFIG_FILE = 'Metadata/Slic3r_PE.config';

  // ── COLORMIX: PRUSASLICER FULLSPECTRUM VIRTUAL EXTRUDERS ─────────────────────────────────────
  //
  // PrusaSlicer 2.9.6 prints a "virtual extruder" as a repeating cycle of physical tools, one per
  // layer, in proportion to its component ratios (libslic3r/Feature/FullSpectrum, Format/3mf.cpp).
  //   · Definitions live in Metadata/Prusa_Slicer_full_spectrum.json, version 1. `color` is left out
  //     of the virtual entries so PrusaSlicer predicts the blend with its own calibrated mixer.
  //   · Virtual ids sit above the physical tools (9+ on the 8T); every tool is listed as physical.
  //   · 2 or 3 components, at the ratios PrusaSlicer's own dialog offers: 1:1, 1:3, 3:1, 1:1:1.
  //   · Paint states stay ≤ 16, so the 8T gets at most 8 blends and the 4T 12, capped at 8.
  const FULL_SPECTRUM_FILE = 'Metadata/Prusa_Slicer_full_spectrum.json';
  const MAX_PAINT_STATE = 16;
  const MAX_BLENDS = 8;
  /** A spool this close needs no blend: a toolchange every layer is not worth a near-invisible shift. */
  const KEEP_SPOOL_DE = 6;
  /** A blend has to beat the nearest spool by this much (CIEDE2000) to be worth its tool changes. */
  const BLEND_MARGIN_DE = 2;

  const normalizeHex = (h) => mfMesh.normalizeHex(String(h || ''));
  const rgb3 = (hex) => {
    const c = colour().hexToRgb(hex) || { r: 255, g: 255, b: 255 };
    return [c.r, c.g, c.b];
  };
  const hex3 = (c) => colour().rgbToHex(c[0], c[1], c[2]).toUpperCase();
  const textOf = (m) => (m.data == null ? null : (typeof m.data === 'string' ? m.data : m.data.toString('utf8')));
  const typeKey = (t) => String(t || '').trim().toUpperCase();

  /**
   * Every blend PrusaSlicer's dialog can express from these slots: pairs at 1:1, 1:3, 3:1, triples
   * at 1:1:1. `loaded(i)` excludes placeholder slots; `same(i, j)` excludes a pair of different
   * materials (a PLA/PETG layer cycle is not a colour, it is a delamination).
   */
  function candidateBlends(slots, loaded, same) {
    const c = slots.map(rgb3);
    const out = [];
    const ok = (...ix) => ix.every(loaded) && ix.every((i) => same(ix[0], i));
    const mixRgb = mixer.mixRgb;
    for (let i = 0; i < c.length; i++) {
      for (let j = i + 1; j < c.length; j++) {
        if (!ok(i, j)) continue;
        for (const t of [0.5, 0.25, 0.75]) {
          out.push({ components: [{ tool: i + 1, ratio: 1 - t }, { tool: j + 1, ratio: t }], hex: hex3(mixRgb(c[i], c[j], t)) });
        }
      }
    }
    for (let i = 0; i < c.length; i++) {
      for (let j = i + 1; j < c.length; j++) {
        for (let k = j + 1; k < c.length; k++) {
          if (!ok(i, j, k)) continue;
          out.push({
            components: [{ tool: i + 1, ratio: 1 / 3 }, { tool: j + 1, ratio: 1 / 3 }, { tool: k + 1, ratio: 1 / 3 }],
            hex: hex3(mixRgb(mixRgb(c[i], c[j], 0.5), c[k], 1 / 3)),
          });
        }
      }
    }
    return out;
  }

  const blendKey = (b) => b.components.map((x) => `${x.tool}:${x.ratio.toFixed(4)}`).join('|');

  /**
   * For each palette colour: the nearest loaded spool, or a blend of them when no spool is close and
   * a blend is clearly closer. Identical blends are shared. If more blends are wanted than ids exist,
   * the ones that improve their colour least go back to their spool.
   *
   * `usable` marks the slots that really hold a spool (a placeholder slot is neither matched nor
   * blended); omitted or all-false, every slot counts — as bedready.io has it. `types`, Khayt's
   * addition, keeps a blend to one material; omitted, any slots may blend.
   *
   * @returns {{ map:number[], blends:{components:{tool:number,ratio:number}[], hex:string}[], predicted:string[] }}
   *   map: per palette colour, 0-based target; < tools is a physical slot, tools + k is blend k.
   */
  function planColorMix(palette, slots, tools, usable, types) {
    const n = Math.min(Math.max(1, tools), slots.length || tools);
    const loaded = slots.slice(0, n).map(normalizeHex);
    const anyUsable = Array.isArray(usable) && loaded.some((_, i) => usable[i]);
    const isLoaded = (i) => !anyUsable || !!usable[i];
    const same = Array.isArray(types) ? (i, j) => typeKey(types[i]) === typeKey(types[j]) : () => true;
    const cands = candidateBlends(loaded, isLoaded, same);
    const deltaE = colour().deltaE;
    const picks = palette.map((hex) => {
      let spool = 0;
      let spoolDE = Infinity;
      loaded.forEach((s, i) => {
        if (!isLoaded(i)) return;
        const d = deltaE(hex, s);
        if (d < spoolDE) { spoolDE = d; spool = i; }
      });
      if (spoolDE < KEEP_SPOOL_DE) return { spool, spoolDE, blend: null, blendDE: Infinity };
      let blend = null;
      let blendDE = Infinity;
      for (const b of cands) {
        const d = deltaE(hex, b.hex);
        if (d < blendDE) { blendDE = d; blend = b; }
      }
      return blendDE < spoolDE - BLEND_MARGIN_DE ? { spool, spoolDE, blend, blendDE } : { spool, spoolDE, blend: null, blendDE };
    });
    // Distinct blends, best improvement first, capped by the ids the paint encoding can address.
    const room = Math.max(0, Math.min(MAX_BLENDS, MAX_PAINT_STATE - n));
    const gain = new Map();
    for (const p of picks) if (p.blend) gain.set(blendKey(p.blend), Math.max(gain.get(blendKey(p.blend)) || 0, p.spoolDE - p.blendDE));
    const kept = [...gain.entries()].sort((a, b) => b[1] - a[1]).slice(0, room).map(([k]) => k);
    const blends = [];
    const idOf = new Map();
    for (const p of picks) {
      if (!p.blend) continue;
      const k = blendKey(p.blend);
      if (!kept.includes(k) || idOf.has(k)) continue;
      idOf.set(k, blends.length);
      blends.push(p.blend);
    }
    const hasBlend = (p) => p.blend && idOf.has(blendKey(p.blend));
    return {
      map: picks.map((p) => (hasBlend(p) ? n + idOf.get(blendKey(p.blend)) : p.spool)),
      blends,
      predicted: picks.map((p, i) => (hasBlend(p) ? p.blend.hex : loaded[p.spool] || palette[i])),
    };
  }

  /** The FullSpectrum JSON, in the shape PrusaSlicer 2.9.6 writes it (minus the optional colour). */
  function fullSpectrumJson(target, colours, blends) {
    const n = Math.max(1, target.maxColors || 1);
    return JSON.stringify({
      version: 1,
      physical_extruders: Array.from({ length: n }, (_, i) => ({ id: i + 1, color: normalizeHex(colours[i] || '#FFFFFF') })),
      virtual_extruders: blends.map((b, k) => ({
        id: n + 1 + k,
        kind: 'fullspectrum',
        components: b.components.map((c) => ({ extruder: c.tool, ratio: +c.ratio.toFixed(6) })),
      })),
    }, null, 4);
  }

  /**
   * The minimal project config: the preset to resolve against, and one colour and material per tool.
   * Every per-extruder key carries exactly one value per tool, so PrusaSlicer counts the same number
   * of extruders from each of them.
   */
  function prusaProjectConfig(target, colours, types) {
    const n = Math.max(1, target.maxColors || 1);
    const pad = (a, fill) => Array.from({ length: n }, (_, i) => (a[i] != null && a[i] !== '' ? a[i] : fill));
    const cols = pad(colours.map(normalizeHex), '#FFFFFF');
    const tys = pad(types, 'PLA');
    const { x, y, z } = target.bed;
    const lines = [
      `; generated for ${target.name}: identity and colours only; the preset supplies the rest`,
      `; printer_settings_id = ${target.printerSettingsId || target.name}`,
      ...(target.printerModel ? [`; printer_model = ${target.printerModel}`] : []),
      ...(target.printerVariant ? [`; printer_variant = ${target.printerVariant}`] : []),
      `; bed_shape = 0x0,${x}x0,${x}x${y},0x${y}`,
      `; max_print_height = ${z}`,
      `; nozzle_diameter = ${pad([], target.nozzle || 0.4).join(',')}`,
      `; extruder_colour = ${cols.join(';')}`,
      `; filament_colour = ${cols.join(';')}`,
      `; filament_type = ${tys.join(';')}`,
    ];
    return lines.join('\n') + '\n';
  }

  /** Bambu/Orca model_settings.config: object id → its extruder, and object id/part id → the part's. */
  function readExtruders(members) {
    const object = new Map();
    const part = new Map();
    const m = members.find((mm) => /model_settings\.config$/i.test(mm.name));
    const xml = m ? textOf(m) : null;
    if (!xml) return { object, part };
    for (const om of xml.matchAll(/<object id="(\d+)"[^>]*>([\s\S]*?)<\/object>/g)) {
      const oid = om[1], body = om[2];
      const own = body.replace(/<part\b[\s\S]*?<\/part>/g, '').match(/key="extruder" value="(\d+)"/);
      if (own) object.set(oid, parseInt(own[1], 10));
      for (const pm of body.matchAll(/<part id="(\d+)"[^>]*>([\s\S]*?)<\/part>/g)) {
        const e = pm[2].match(/key="extruder" value="(\d+)"/);
        if (e) part.set(`${oid}/${pm[1]}`, parseInt(e[1], 10));
      }
    }
    return { object, part };
  }

  /**
   * Which source filament an unpainted face of `objectId` in `path` prints with. A component file's
   * object is a PART of the root object that references it, so its extruder is looked up as a part
   * first, then as that root object; a root-level mesh is its own object.
   */
  function baseFilaments(members, ex) {
    const owner = new Map(); // "path#objectid" → root object id
    const rootM = members.find((m) => /^\/?3D\/3dmodel\.model$/i.test(m.name));
    const root = rootM ? textOf(rootM) : null;
    if (root) {
      for (const om of root.matchAll(/<object id="(\d+)"[^>]*>([\s\S]*?)<\/object>/g)) {
        for (const cm of om[2].matchAll(/<component\b([^>]*)\/>/g)) {
          const p = (/p:path="\/?([^"]+)"/.exec(cm[1]) || [])[1];
          const oid = (/objectid="(\d+)"/.exec(cm[1]) || [])[1];
          if (p && oid) owner.set(`${p}#${oid}`, om[1]);
        }
      }
    }
    return (path, objectId) => {
      const rootId = owner.get(`${path}#${objectId}`);
      if (rootId) {
        if (ex.part.has(`${rootId}/${objectId}`)) return ex.part.get(`${rootId}/${objectId}`);
        return ex.object.has(rootId) ? ex.object.get(rootId) : 1;
      }
      return ex.object.has(objectId) ? ex.object.get(objectId) : 1;
    };
  }

  /** Centre of a Bambu/Orca `printable_area` polygon, or null. */
  function areaCentre(area) {
    if (!Array.isArray(area) || !area.length) return null;
    const pts = area.map((p) => String(p).split('x').map(Number)).filter((p) => p.length === 2 && p.every(Number.isFinite));
    if (!pts.length) return null;
    const xs = pts.map((p) => p[0]);
    const ys = pts.map((p) => p[1]);
    return [(Math.min(...xs) + Math.max(...xs)) / 2, (Math.min(...ys) + Math.max(...ys)) / 2];
  }

  function tryJson(text) {
    if (!text) return null;
    try { return JSON.parse(text); } catch (_) { return null; }
  }

  /**
   * The project's members. Geometry is rewritten (explicit, remapped, Prusa-named paint), Bambu/Orca
   * metadata is dropped, Metadata/Slic3r_PE.config (and the FullSpectrum JSON, with blends) is added.
   * Everything else passes through as the member it was — still compressed, where it came that way.
   *
   * `input.map`: source filament (0-based) → target (0-based), null = identity; a target at or past
   * the tool count is blend (target − tools). States are clamped onto what exists, as bedready.io
   * does — the caller (convertMembers below) refuses a map that would need clamping.
   *
   * Returns `maxFilament`, the highest SOURCE filament number the paint or a part's extruder used, so
   * the caller can refuse a file that paints with a filament its colour list does not have.
   */
  function toPrusaProject(members, target, input) {
    const slots = Math.max(1, target.maxColors || 1);
    const blends = (input.blends || []).slice(0, Math.max(0, MAX_PAINT_STATE - slots));
    let maxFilament = 0;
    const toSlot = (filament) => {
      if (filament > maxFilament) maxFilament = filament;
      // 1-based source filament → 1-based target tool or virtual extruder, clamped onto what exists.
      const s = input.map ? (input.map[filament - 1] != null ? input.map[filament - 1] : 0) + 1 : filament;
      return Math.min(Math.max(1, s), slots + blends.length);
    };
    const baseOf = baseFilaments(members, readExtruders(members));

    // Source bed centre, from project_settings.config, so items land on the target bed's centre.
    let shift = [0, 0];
    const ps = members.find((m) => /project_settings\.config$/i.test(m.name));
    const psObj = ps ? tryJson(textOf(ps)) : null;
    const c = psObj ? areaCentre(psObj.printable_area) : null;
    if (c) shift = [target.bed.x / 2 - c[0], target.bed.y / 2 - c[1]];

    const out = [];
    const removed = [];
    let painted = false;
    for (const m of members) {
      const lower = m.name.toLowerCase();
      if (/^\/?metadata\//.test(lower) && /\.(config|json|xml|gcode|md5)$/.test(lower)) {
        removed.push(m.name); // Bambu/Orca settings, slice info, plate JSON: meaningless to PrusaSlicer
        continue;
      }
      if (!lower.endsWith('.model')) { out.push(m); continue; }
      const before = textOf(m);
      let xml = before;
      const filePath = m.name.replace(/^\//, '');
      xml = xml.replace(/<object id="(\d+)"([^>]*)>([\s\S]*?)<\/object>/g, (block, oid) => {
        if (!block.includes('<triangle')) return block; // a component wrapper: nothing to paint
        const base = toSlot(baseOf(filePath, oid));
        const stateMap = (s) => (s === 0 ? base : toSlot(s));
        // Linear on purpose (bedready.io's 2026-10-02 review): no lazy attribute group that can
        // backtrack quadratically against a run of spaces with no "/>".
        return block.replace(/<triangle\b([^>]*)\/>/g, (_t, rawAttrs) => {
          const attrs = rawAttrs.trimEnd();
          painted = true;
          const pm = /\s(?:paint_color|slic3rpe:mmu_segmentation)="([0-9A-Fa-f]+)"/.exec(attrs);
          const rest = attrs.replace(/\s(?:paint_color|slic3rpe:mmu_segmentation)="[0-9A-Fa-f]*"/g, '');
          const code = pm ? fullSpectrum.remapPaintCode(pm[1], stateMap) : mfMesh.encodeSolidPaint(base);
          return `<triangle${rest} slic3rpe:mmu_segmentation="${code}"/>`;
        });
      });
      if (painted && !/xmlns:slic3rpe=/.test(xml)) xml = xml.replace(/<model\b/, `<model xmlns:slic3rpe="${SLIC3RPE_NS}"`);
      if (/^\/?3d\/3dmodel\.model$/.test(lower) && (shift[0] || shift[1])) {
        xml = xml.replace(/<item\b([^>]*?)\btransform="([^"]+)"/g, (_m, pre, tr) => {
          const v = tr.trim().split(/\s+/).map(Number);
          if (v.length !== 12 || !v.every(Number.isFinite)) return `<item${pre}transform="${tr}"`;
          v[9] += shift[0];
          v[10] += shift[1];
          return `<item${pre}transform="${v.map((x) => +x.toFixed(6)).join(' ')}"`;
        });
      }
      out.push(xml === before ? m : { name: m.name, data: xml });
    }
    out.push({ name: CONFIG_FILE, data: prusaProjectConfig(target, input.colours, input.types) });
    if (blends.length) out.push({ name: FULL_SPECTRUM_FILE, data: fullSpectrumJson(target, input.colours, blends) });
    return { members: out, removed, painted, maxFilament };
  }

  // ── WHEN THIS PATH APPLIES, AND THE PLAN ─────────────────────────────────────────────────────

  /**
   * A Bambu/Orca source aimed at a Prusa whose exact PrusaSlicer preset name is known — the project
   * names that preset, and a guessed name resolves to nothing. Everything else keeps the converter's
   * old cross-family behaviour.
   */
  function applies(flavour, target, members) {
    if (!(profiles && profiles.prusaProjectReady === true)) return false; // HELD — see printer-profiles.js
    if (!(target && profiles && profiles.configFamily(flavour) === 'bbl' && profiles.configFamily(target.flavour) === 'prusa'
      && target.printerSettingsId && target.bed && target.bed.x && target.bed.y && (target.maxColors || 0) >= 1)) return false;
    // A mesh this process never saw (the Mac app passes a model over 4 MB by name) cannot be
    // repainted for the tools, so such a file keeps the converter's previous cross-family path
    // — the file it always wrote, with its warning — rather than being refused outright.
    if (Array.isArray(members) && members.some((m) => /\.model$/i.test(m.name) && m.data == null)) return false;
    return true;
  }

  /**
   * Bambu/Orca part types that are not printed geometry: modifiers, negative volumes, support
   * blockers/enforcers. They live only in model_settings.config, which this project drops, so
   * PrusaSlicer would load each as a solid part and print it. Returns the subtypes found.
   */
  function nonPrintingParts(members) {
    const m = members.find((mm) => /model_settings\.config$/i.test(mm.name));
    const xml = m ? textOf(m) : null;
    if (!xml) return [];
    const kinds = new Set();
    for (const pm of xml.matchAll(/<part\b[^>]*\bsubtype="([^"]+)"/g)) if (pm[1] !== 'normal_part') kinds.add(pm[1]);
    return [...kinds];
  }

  // ── SPOOL MATCH (lib/spool-match.js) ─────────────────────────────────────────────────────────
  // "Match to loaded spools" decides the tool of every colour itself: a merge (spoolMerge: map +
  // the colour whose material each tool keeps) or a plain slot map, plus what is loaded in each
  // slot (slotSpools). Checked, never second-guessed by reduceColors; an invalid one refuses.
  function spoolMergeFor(sm, n, tools) {
    const map = sm && sm.map, reps = sm && sm.reps;
    if (!Array.isArray(map) || map.length !== n || !Array.isArray(reps)) return null;
    if (map.some((t) => !Number.isInteger(t) || t < 0 || t >= tools)) return null;
    const k = Math.max(...map) + 1;
    if (reps.length !== k) return null;
    for (let s = 0; s < k; s++) {
      const r = reps[s];
      if (!Number.isInteger(r) || r < 0 || r >= n) return null;
      if (map.includes(s) && map[r] !== s) return null;
    }
    return { map: map.slice(), reps: reps.slice() };
  }
  const FAMILIES = ['PETG', 'PCTG', 'PLA', 'ABS', 'ASA', 'TPU', 'PET', 'PVA', 'HIPS', 'PC', 'PA', 'PP'];
  const familyOf = (x) => {
    const u = String(x || '').toUpperCase();
    return FAMILIES.find((k) => new RegExp('(^|[^A-Z])' + k + '($|[^A-Z])').test(u)) || '';
  };
  const spoolHex = (sp) => {
    const m = /^#?([0-9a-fA-F]{6})/.exec(String((sp && (sp.colour || sp.color || sp.hex)) || '').trim());
    return m ? '#' + m[1].toUpperCase() : null;
  };
  // ── end SPOOL MATCH ──

  const refuse = (error) => ({ ok: false, error });

  /**
   * Decide where every source colour goes, without writing anything — the preview and the convert
   * run the same plan. `ctx.tallyUsage(n)` gives per-filament usage for the merge (mf-convert's
   * tallyPaintUsage); `ctx.plateCount` the number of plates.
   *
   * Refuses rather than guesses: a palette that does not match its materials, a slot past the tools,
   * a model this process never saw.
   */
  function plan(members, target, opts, ctx) {
    opts = opts || {};
    ctx = ctx || {};
    const tools = Math.max(1, target.maxColors || 1);
    const name = target.name;
    if (members.some((m) => /\.model$/i.test(m.name) && m.data == null)) {
      return refuse(`This app could not read the model to move its colours onto ${name}'s tools. Convert the file in the desktop app, or pick Generic 3MF.`);
    }
    const odd = nonPrintingParts(members);
    if (odd.length) {
      return refuse(`This file has ${odd.join(', ')} parts. A PrusaSlicer project made from it would print them as solid geometry, so nothing was converted. Pick Generic 3MF and set those parts up again in PrusaSlicer.`);
    }
    const ps = members.find((m) => /project_settings\.config$/i.test(m.name));
    const proj = ps ? tryJson(textOf(ps)) : null;
    if (!proj || !Array.isArray(proj.filament_colour) || !proj.filament_colour.length) {
      return refuse(`This file's colour list could not be read, so its colours cannot be placed on ${name}'s tools. Pick Generic 3MF to keep the model as it is.`);
    }
    const n = proj.filament_colour.length;
    const srcColours = proj.filament_colour.map((h) => {
      const m = /^#?([0-9a-fA-F]{6})/.exec(String(h || '').trim());
      return m ? '#' + m[1].toUpperCase() : null;
    });
    const badColour = srcColours.findIndex((h) => !h);
    if (badColour >= 0) return refuse(`Filament ${badColour + 1}'s colour ("${proj.filament_colour[badColour]}") is not a colour this converter can read, so nothing was converted.`);
    const warnings = [];
    let srcTypes;
    if (Array.isArray(proj.filament_type)) {
      if (proj.filament_type.length !== n) {
        return refuse(`This file lists ${n} colours but ${proj.filament_type.length} materials, so which material each tool should carry is unclear. Nothing was converted.`);
      }
      srcTypes = proj.filament_type.map((t) => String(t || '').trim() || 'PLA');
    } else {
      srcTypes = srcColours.map(() => 'PLA');
      warnings.push('This file does not say which material each colour is; every tool is set to PLA. Check the filaments in PrusaSlicer.');
    }

    // Colour → tool. A manual assignment wins; otherwise merge only when there are more colours than
    // tools. ≤ tools and no reorder: the colours stay exactly where they were (map null).
    let map = null;
    let merged = false;
    let reps = null;
    const manual = Array.isArray(opts.slotMap) && opts.slotMap.length ? opts.slotMap : null;
    const spooled = !!(opts.spoolMerge || opts.spoolStrict); // SPOOL MATCH
    if (opts.spoolMerge) {
      const sm = spoolMergeFor(opts.spoolMerge, n, tools);
      if (!sm) return refuse(`The spool match does not fit this file's ${n} colours and ${name}'s ${tools} tools, so nothing was converted.`);
      map = sm.map;
      reps = sm.reps;
      merged = true;
    } else if (manual) {
      if (manual.length !== n) return refuse(`The colour assignment covers ${manual.length} colours, but this file has ${n}. Nothing was converted.`);
      const far = manual.find((t) => !Number.isInteger(t) || t < 0 || t >= tools);
      if (far !== undefined) return refuse(`The colour assignment uses slot ${Number.isInteger(far) ? far + 1 : '?'}, but ${name} has ${tools} tool${tools === 1 ? '' : 's'}. Choose a slot from 1 to ${tools}.`);
      if (!manual.every((t, i) => t === i)) map = manual.slice();
    } else if (n > tools && spooled) {
      return refuse(`This file has ${n} colours for ${name}'s ${tools} tools, and the spool match did not say how to merge them. Nothing was converted.`);
    } else if (n > tools) {
      const usage = ctx.tallyUsage ? ctx.tallyUsage(n) : [];
      const r = fullSpectrum.reduceColors(srcColours, usage && usage.some((u) => u > 0) ? usage : undefined, undefined, tools);
      map = r.map.map((g) => Math.min(g, tools - 1));
      reps = Array.isArray(r.reps) ? r.reps : null;
      merged = true;
    }
    // Each tool's colour and material are those of ONE source filament: the one that survived the
    // merge (reduceColors' reps), or the first one the maker assigned there. Unused tools are white
    // PLA placeholders, marked unusable so ColorMix neither matches nor blends them.
    const repOf = new Array(tools).fill(-1);
    if (map) map.forEach((s, i) => { if (repOf[s] < 0) repOf[s] = i; });
    else for (let i = 0; i < Math.min(n, tools); i++) repOf[i] = i;
    if (reps) reps.forEach((src, g) => { if (g < tools && map[src] === g) repOf[g] = src; });
    const colours = repOf.map((i) => (i >= 0 ? srcColours[i] : '#FFFFFF'));
    const types = repOf.map((i) => (i >= 0 ? srcTypes[i] : 'PLA'));
    const usable = repOf.map((i) => i >= 0);
    // SPOOL MATCH: each tool carries the colour of the spool loaded in it. A used tool keeps the
    // material of the colour it prints (and says so when the spool's family differs); an unused
    // tool with a spool in it is described as that spool.
    if (spooled && Array.isArray(opts.slotSpools)) {
      const off = [];
      for (let s = 0; s < tools; s++) {
        const sp = opts.slotSpools[s];
        const hex = spoolHex(sp);
        if (!hex) continue;
        colours[s] = hex;
        const sf = familyOf(sp.material);
        if (repOf[s] < 0) { if (sf) types[s] = sf; continue; }
        const cf = familyOf(types[s]);
        if (sf && cf && sf !== cf) off.push(`tool ${s + 1} holds ${sf} but prints colour ${repOf[s] + 1} in ${types[s]} settings`);
      }
      if (off.length) warnings.push(`Check the material: ${off.join('; ')}.`);
    }

    // A tool carrying two materials prints one of them in the other's settings — say which.
    const mixedTools = [];
    if (map) {
      for (let s = 0; s < tools; s++) {
        const on = map.map((t, i) => (t === s ? i : -1)).filter((i) => i >= 0);
        const kinds = [...new Set(on.map((i) => typeKey(srcTypes[i])))];
        if (kinds.length > 1) mixedTools.push(`tool ${s + 1} (${on.map((i) => srcTypes[i]).join(' + ')})`);
      }
    }
    if (mixedTools.length) {
      warnings.push(`Different materials now share a tool: ${mixedTools.join(', ')}. Each prints with that tool's material settings; check the filaments in PrusaSlicer.`);
    }
    if (merged && spooled) {
      warnings.push(`Matched ${n} colours to the spools loaded in ${name}'s tools.`);
    } else if (merged) {
      warnings.push(`Merged ${n} colours into ${tools} for ${name}: the least-used colours now print with the closest-looking tool.`);
    }

    // ColorMix: colours the planner blends point at virtual extruders; every other colour keeps the
    // tool the maker (or the merge) gave it. The planner sees all `tools` slots with the placeholder
    // mask — bedready.io passed only the used colours on an identity map, which numbered the blends
    // from the colour count and so pointed them at placeholder tools.
    let projectMap = map;
    let blends = [];
    let predicted = null;
    let colorMix = false;
    // A spool match has already chosen a tool for every colour; blending some of them as well would
    // print colours on tools the match did not pick, so ColorMix steps aside (SPOOL MATCH).
    if (opts.colorMix && spooled) {
      warnings.push('ColorMix was not used: the spool match already placed every colour on a loaded tool.');
    } else if (opts.colorMix && target.prusaColorMix) {
      colorMix = true;
      const cm = planColorMix(srcColours, colours, tools, usable, types);
      predicted = cm.predicted;
      if (cm.blends.length) {
        blends = cm.blends;
        projectMap = srcColours.map((_, i) => (cm.map[i] >= tools ? cm.map[i] : map ? map[i] : Math.min(i, tools - 1)));
      }
    } else if (opts.colorMix) {
      warnings.push(`${name} does not mix colours, so ColorMix was not used.`);
    }

    const finalMap = projectMap || srcColours.map((_, i) => i);
    const plates = ctx.plateCount || 0;
    if (plates > 1) {
      warnings.push(`This project has ${plates} plates. PrusaSlicer has one bed, so the other plates' objects sit beside it; arrange or delete them in PrusaSlicer.`);
    }
    return {
      ok: true,
      tools,
      colours,
      types,
      usable,
      srcColours,
      srcTypes,
      map: finalMap,
      projectMap,
      blends: blends.map((b, k) => ({ id: tools + 1 + k, hex: b.hex, components: b.components.map((c) => ({ tool: c.tool, ratio: c.ratio })) })),
      rawBlends: blends,
      predicted,
      merged,
      manual: !!map && !!manual,
      spool: spooled,
      colorMix,
      toolsUsed: [...new Set(finalMap.filter((t) => t < tools))].sort((a, b) => a - b).map((t) => t + 1),
      warnings,
    };
  }

  /**
   * The whole conversion: plan, rewrite, check. `{ ok, members, report }` or `{ ok:false, error }`.
   * `report` holds what the UI and the Mac app show: `prusaProject` (tools, colours, blends) and
   * `warnings`.
   */
  function convertMembers(members, target, opts, ctx) {
    const p = plan(members, target, opts, ctx);
    if (!p.ok) return p;
    let res;
    try {
      res = toPrusaProject(members, target, { map: p.projectMap, blends: p.rawBlends, colours: p.colours, types: p.types });
    } catch (e) {
      // A paint code past the encoding, or a model past the longest string this engine can hold.
      return refuse(`The model's colour data could not be rewritten for ${target.name}'s tools, so nothing was converted.`);
    }
    if (res.maxFilament > p.srcColours.length) {
      return refuse(`The model is painted with filament ${res.maxFilament}, but this file lists only ${p.srcColours.length} colour${p.srcColours.length === 1 ? '' : 's'}, so where it should print is unknown. Nothing was converted.`);
    }
    const report = {
      prusaProject: {
        tools: p.tools,
        colours: p.colours,
        types: p.types,
        map: p.map,
        blends: p.blends,
        toolsUsed: p.toolsUsed,
        merged: p.merged,
        colorMix: p.colorMix,
        painted: res.painted,
      },
      removed: res.removed,
      fieldsChanged: ['printer_settings_id', 'printer_model', 'bed_shape', 'nozzle_diameter', 'extruder_colour', 'filament_colour', 'filament_type', 'mmu_segmentation'],
      colorsRemapped: p.projectMap ? 1 : 0,
      warnings: p.warnings,
    };
    return { ok: true, members: res.members, report };
  }

  const api = {
    FULL_SPECTRUM_FILE, CONFIG_FILE, MAX_BLENDS,
    planColorMix, fullSpectrumJson, prusaProjectConfig, toPrusaProject, applies, plan, convertMembers, nonPrintingParts,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytPrusaProject = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
