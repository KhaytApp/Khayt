'use strict';
/**
 * "These are the spools I have loaded — make the file fit them." (KhaytSpoolMatch)
 *
 * The converter's default runs the other way: it reads the model's colours and
 * keeps them, or proposes slot colours from them (`reduceColors`), so the slots
 * end up holding whatever the creator painted with. That is right when you are
 * about to go and load those colours. It is backwards when the printer is
 * already loaded and you want to print NOW with what is on it.
 *
 * Ported from bedready.io (src/lib/spool-match.ts `matchToSpools`, its #33, with
 * the usable-slot mask its #39 added). The matching is the reference's, line for
 * line: every model colour goes to the nearest loaded slot by ΔE76 — the same
 * distance bedready's my-filaments uses, NOT the CIEDE2000 in lib/color-mix.js,
 * so the two products agree about which spool is "closest" — slots may be shared
 * (five reds on a model with one red spool all print red), ties go to the lower
 * slot, and a slot not marked usable is never chosen.
 *
 * What Khayt adds around it, none of which changes a match:
 *   - loaded slots in the shape the machines screen and the printer poll use
 *     (`[{ slot, hex, material }]`, see lib/loaded-colours.js);
 *   - a material warning, by FAMILY (lib/loaded-colours `family`), when a PETG
 *     colour lands on a PLA spool — warned, never silently re-routed;
 *   - the converter request: the 0-based source → slot `slotMap` that
 *     lib/mf-convert.js already applies, or — when the file has more colours
 *     than the printer has slots — an explicit merge through its existing
 *     mergeToSlots path. Never a third way of moving paint;
 *   - the refusals that converter would make, worked out up front so the
 *     screen can show them instead of a file in which nothing moved.
 *
 * Pure; no DOM, no I/O. UMD so the renderer, the tests and (bundled) the Mac
 * can load the one file.
 */
(function (global) {
  const LC = () => {
    if (typeof require === 'function') { try { return require('./loaded-colours'); } catch (_) { /* renderer */ } }
    return global.KhaytLoadedColours || null;
  };

  /**
   * Past this ΔE76 a colour has no spool that resembles it. ~2.3 is
   * just-noticeable and ~10 is "clearly a different shade"; 25 is where a print
   * stops looking like the picture (a red rendered in orange). It flags, never
   * blocks: the mapping still happens. (bedready.io FAR_MATCH.)
   */
  const FAR_MATCH = 25;
  /** Below this ΔE76 a match reads as the same colour; between it and FAR_MATCH, a near shade. */
  const GOOD_MATCH = 10;

  function normHex(hex) {
    const s = String(hex || '').trim().replace(/^#/, '');
    if (/^[0-9a-f]{8}$/i.test(s)) return '#' + s.slice(0, 6).toUpperCase();
    if (/^[0-9a-f]{6}$/i.test(s)) return '#' + s.toUpperCase();
    if (/^[0-9a-f]{3}$/i.test(s)) return '#' + s.split('').map((c) => c + c).join('').toUpperCase();
    return null;
  }

  function hexToRgb(hex) {
    const h = normHex(hex) || '#000000';
    return [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
  }

  // sRGB (0–255) → CIE-Lab (D65), exactly as bedready's my-filaments.ts.
  function rgbToLab(rgb) {
    const lin = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
    const R = lin(rgb[0]), G = lin(rgb[1]), B = lin(rgb[2]);
    let x = (R * 0.4124 + G * 0.3576 + B * 0.1805) / 0.95047;
    let y = R * 0.2126 + G * 0.7152 + B * 0.0722;
    let z = (R * 0.0193 + G * 0.1192 + B * 0.9505) / 1.08883;
    const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
    x = f(x); y = f(y); z = f(z);
    return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
  }

  /** Perceptual distance (ΔE76) between two hex colours. 0 = identical; ~2.3 = just-noticeable. */
  function colorDistance(a, b) {
    const p = rgbToLab(hexToRgb(a));
    const q = rgbToLab(hexToRgb(b));
    return Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2]);
  }

  /**
   * Map every model colour to the nearest loaded slot. Slots MAY be shared. Ties
   * go to the lower slot, so the result is deterministic. `usable` marks the
   * slots that really hold a spool; unmarked placeholder slots are never matched.
   * Omitted, or nothing marked, every slot counts. (bedready.io, verbatim.)
   *
   * @param {string[]} palette  the file's colours, in filament order
   * @param {string[]} slots    the printer's slot colours, in slot order
   * @param {boolean[]} [usable]
   * @returns {{ map:number[], distance:number[], far:number[] }} map: palette index → 0-based slot
   */
  function matchToSpools(palette, slots, usable) {
    palette = Array.isArray(palette) ? palette : [];
    slots = Array.isArray(slots) ? slots : [];
    const anyUsable = Array.isArray(usable) && slots.some((_, j) => usable[j]);
    if (!slots.length) return { map: palette.map(() => 0), distance: palette.map(() => Infinity), far: palette.map((_, i) => i) };
    const map = [], distance = [], far = [];
    palette.forEach((hex, i) => {
      let best = 0, bestD = Infinity;
      slots.forEach((s, j) => {
        if (anyUsable && !usable[j]) return;
        const d = colorDistance(hex, s);
        if (d < bestD) { bestD = d; best = j; }
      });
      map.push(best);
      distance.push(bestD);
      if (bestD >= FAR_MATCH) far.push(i);
    });
    return { map, distance, far };
  }

  /** 'good' | 'fair' | 'poor' for a ΔE76, for the screen's quality dot. */
  function quality(d) {
    if (!(d < FAR_MATCH)) return 'poor';
    return d < GOOD_MATCH ? 'good' : 'fair';
  }

  function family(material) {
    const lc = LC();
    if (lc && lc.family) return lc.family(material);
    const s = String(material || '').toUpperCase();
    const m = /(PETG|PCTG|PLA|ABS|ASA|TPU|PET|PVA|HIPS|PC|PA|PP)/.exec(s);
    return m ? m[1] : '';
  }

  /**
   * Loaded slots (`[{ slot, hex, material }]`, 0-based `slot`, empty slots
   * absent — the shape lib/loaded-colours.normalizeLoaded and the machine record
   * use) as the parallel arrays matchToSpools reads. A slot with no spool is a
   * white placeholder marked unusable, the way bedready pads unused slots.
   * Slots at or past `slotCount` are dropped: the target cannot print from them.
   */
  function slotsFromLoaded(loaded, slotCount) {
    const rows = (Array.isArray(loaded) ? loaded : []).map((s, i) => ({
      slot: s && Number.isInteger(s.slot) ? s.slot : i,
      hex: normHex(s && (s.hex || s.color || s.colour)),
      material: String((s && s.material) || '').trim(),
      label: String((s && s.label) || '').trim(),
    })).filter((s) => s.hex && s.slot >= 0);
    const count = Number.isInteger(slotCount) && slotCount > 0
      ? slotCount
      : rows.reduce((m, s) => Math.max(m, s.slot + 1), 0);
    const hexes = [], usable = [], materials = [], labels = [];
    for (let j = 0; j < count; j++) { hexes.push('#FFFFFF'); usable.push(false); materials.push(''); labels.push(''); }
    const beyond = [];
    for (const s of rows) {
      if (s.slot >= count) { beyond.push(s.slot); continue; }
      hexes[s.slot] = s.hex; usable[s.slot] = true; materials[s.slot] = s.material; labels[s.slot] = s.label;
    }
    return { hexes, usable, materials, labels, beyond };
  }

  /**
   * The converter request for a source → slot map — or the refusal the
   * converter would make, so the screen can say it first.
   *
   * mf-convert's rules, which this must not bypass:
   *   - a slot map's slots are the FILE's filaments: a slot at or past their
   *     count has no colour, material or temperature to give it, and the
   *     converter moves nothing (lib/mf-convert.js "A slot past the file's own
   *     filaments"). Here the spool in that slot IS known, so the request asks
   *     the converter to grow the file to it (`growToSlots`, `slotSpools`);
   *     a file it cannot grow (generic) is still refused with that reason.
   *   - more colours than the printer has slots is a MERGE: every per-filament
   *     array shrinks to the slot count. That is mergeToSlots, which only a
   *     Bambu/Orca file can take; the match is handed to it explicitly
   *     (`spoolMerge`) instead of letting reduceColors choose the groups.
   *     A PrusaSlicer file keeps every filament and maps the paint onto the
   *     loaded slots with a plain slot map — still the file's own filaments.
   *
   * @param {number[]} map       palette index → 0-based slot
   * @param {{ n?:number, slotCount:number, flavour?:string, palette?:string[], slotHexes?:string[] }} ctx
   * @returns {{ kind:'none'|'slotMap'|'grow'|'merge'|'refused', slotMap?:number[]|null, mergeToSlots?:boolean,
   *             growToSlots?:number, slotSpools?:Array<{colour:string, material:string}|null>,
   *             spoolMerge?:{map:number[], reps:number[]}, refusal?:{code:string, slot?:number, n?:number} }}
   */
  function toRequest(map, ctx) {
    ctx = ctx || {};
    const n = Number.isInteger(ctx.n) ? ctx.n : (Array.isArray(map) ? map.length : 0);
    const slotCount = Number.isInteger(ctx.slotCount) && ctx.slotCount > 0 ? ctx.slotCount : n;
    if (!Array.isArray(map) || map.length !== n || !n) return { kind: 'none', slotMap: null };
    if (map.some((t) => !Number.isInteger(t) || t < 0)) return { kind: 'refused', refusal: { code: 'bad-map' } };
    const top = Math.max.apply(null, map);
    if (top >= slotCount) return { kind: 'refused', refusal: { code: 'slot-past-printer', slot: top + 1, n: slotCount } };
    // What is loaded in each slot, for a converter that writes the tool colours itself (a
    // Bambu/Orca → PrusaSlicer project) and for the slots a grown file gains.
    const spoolsUpTo = (last) => {
      const out = [];
      for (let j = 0; j <= last; j++) {
        out.push(ctx.slotHexes && ctx.slotHexes[j] && (!ctx.usable || ctx.usable[j])
          ? { colour: ctx.slotHexes[j], material: (ctx.slotMaterials && ctx.slotMaterials[j]) || '' } : null);
      }
      return out;
    };
    const slotSpools = ctx.slotHexes ? spoolsUpTo(slotCount - 1) : null;
    const bbl = ctx.flavour === 'bambu' || ctx.flavour === 'orca';
    if (n > slotCount && bbl) {
      // Explicit merge: slots 0..top, each keeping the settings of the colour it
      // matched most closely. A slot no colour matched (an empty slot between
      // two loaded ones) still needs an entry so the slot numbers stay physical;
      // it takes a filament's settings and holds no paint.
      const reps = [];
      for (let s = 0; s <= top; s++) {
        let rep = -1, best = Infinity;
        map.forEach((t, i) => {
          if (t !== s) return;
          const d = (ctx.palette && ctx.slotHexes) ? colorDistance(ctx.palette[i], ctx.slotHexes[s]) : i;
          if (d < best) { best = d; rep = i; }
        });
        reps.push(rep >= 0 ? rep : Math.min(s, n - 1));
      }
      return { kind: 'merge', mergeToSlots: true, spoolMerge: { map: map.slice(), reps }, slotMap: null, slotSpools };
    }
    // A spool in a slot past the file's own filaments: the converter would refuse a plain slot
    // map, but this caller knows what is loaded there, so it asks for the file to GROW to that
    // slot (mf-convert growForSpools: each new slot a full copy of a source filament, in the
    // spool's colour). Only a file whose config the converter can grow — Bambu/Orca or Prusa.
    if (top >= n) {
      if (!(bbl || ctx.flavour === 'prusa')) return { kind: 'refused', refusal: { code: 'slot-past-end', slot: top + 1, n } };
      return { kind: 'grow', slotMap: map.slice(), growToSlots: slotCount, slotSpools: spoolsUpTo(top) };
    }
    if (map.every((t, i) => t === i)) return { kind: 'none', slotMap: null, slotSpools };
    return { kind: 'slotMap', slotMap: map.slice(), slotSpools };
  }

  /**
   * Everything the "Match to loaded spools" table needs, in one call.
   *
   * @param {Array<string|{color?:string, hex?:string, type?:string, material?:string}>} fileColours
   * @param {Array<{slot?:number, hex:string, material?:string, label?:string}>} loaded
   * @param {{ slotCount?:number, flavour?:string, map?:number[] }} [opts]
   *        `map` — the maker's own edits to the table; rows it names keep their slot.
   * @returns {{ ok:boolean, rows:Array, map:number[], distance:number[], far:number[],
   *             slots:object, request:object, warnings:Array<{code:string}> }}
   */
  function planSpoolMatch(fileColours, loaded, opts) {
    opts = opts || {};
    const cols = (Array.isArray(fileColours) ? fileColours : []).map((c) => (typeof c === 'string'
      ? { hex: normHex(c), material: '' }
      : { hex: normHex(c && (c.hex || c.color)), material: String((c && (c.material || c.type)) || '') }));
    const palette = cols.map((c) => c.hex || '#000000');
    const slots = slotsFromLoaded(loaded, opts.slotCount);
    const warnings = [];
    if (slots.beyond.length) warnings.push({ code: 'beyond-target', slots: slots.beyond.map((s) => s + 1), n: slots.hexes.length });
    if (!slots.usable.some(Boolean)) {
      return { ok: false, rows: [], map: [], distance: [], far: [], slots, request: { kind: 'none', slotMap: null }, warnings: warnings.concat([{ code: 'no-spools' }]) };
    }
    const auto = matchToSpools(palette, slots.hexes, slots.usable);
    const map = auto.map.slice();
    // The maker's edits win, as long as they name a slot that holds a spool.
    if (Array.isArray(opts.map)) {
      opts.map.forEach((t, i) => { if (i < map.length && Number.isInteger(t) && slots.usable[t]) map[i] = t; });
    }
    const distance = map.map((t, i) => colorDistance(palette[i], slots.hexes[t]));
    const far = [];
    const rows = cols.map((c, i) => {
      const t = map[i];
      const d = distance[i];
      if (d >= FAR_MATCH) { far.push(i); warnings.push({ code: 'far', index: i, deltaE: round1(d) }); }
      const ff = family(c.material), sf = family(slots.materials[t]);
      const materialMismatch = !!(ff && sf && ff !== sf);
      if (materialMismatch) warnings.push({ code: 'material', index: i, file: ff, spool: sf, slot: t + 1 });
      return {
        index: i, hex: palette[i], material: c.material,
        slot: t, spoolHex: slots.hexes[t], spoolMaterial: slots.materials[t], spoolLabel: slots.labels[t],
        deltaE: round1(d), quality: quality(d), materialMismatch, edited: map[i] !== auto.map[i],
      };
    });
    const request = toRequest(map, { n: palette.length, slotCount: slots.hexes.length, flavour: opts.flavour, palette,
      slotHexes: slots.hexes, usable: slots.usable, slotMaterials: slots.materials });
    return { ok: true, rows, map, distance, far, slots, request, warnings };
  }

  function round1(n) { return Number.isFinite(n) ? Math.round(n * 10) / 10 : n; }

  const api = { FAR_MATCH, GOOD_MATCH, colorDistance, matchToSpools, quality, slotsFromLoaded, toRequest, planSpoolMatch };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytSpoolMatch = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
