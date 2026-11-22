'use strict';
/**
 * What can be printed with the filament already loaded (KhaytLoadedColours).
 *
 * A shop with a four-head toolchanger, or an AMS, or just one spool on one
 * printer, asks the same question before every job it picks from the library:
 * "which of these can I start NOW, without swapping anything?" The library
 * knows each model's colours (`printFile.colors[].hex`, read out of the 3MF)
 * and its material; a printer that reports what it has loaded knows the other
 * half. This puts them together.
 *
 * Where "loaded" comes from is the caller's business, and deliberately not
 * one printer's: a Snapmaker U1 reports it (`print_task_config`, parsed by
 * `fromPrintTaskConfig` below), and any machine can have it set by hand. A
 * loaded slot is just `{ hex, material }`.
 *
 * Colours are compared perceptually (CIEDE2000, lib/color-mix), because two
 * spools called "white" differ by a few hex digits and a slicer's swatch is
 * never the spool's exact colour. Materials by FAMILY: "PLA+ 2.0" and "PLA
 * Silk" both go in a PLA slot; PETG does not.
 *
 * Pure; no DOM, no I/O. Shared by the desktop and, bundled, the Mac.
 */
(function (global) {
  const KC = () => (typeof require === 'function' ? require('./color-mix') : global.KhaytColor);

  /** How far apart two colours can be and still be "the same filament". */
  const DEFAULT_TOLERANCE = 15;

  const FAMILIES = ['PETG', 'PLA', 'ABS', 'ASA', 'TPU', 'PCTG', 'PC', 'PA', 'PET', 'PVA', 'HIPS', 'PP'];

  /** The material family a name belongs to, or '' when it names none. */
  function family(material) {
    const s = String(material || '').toUpperCase();
    if (!s.trim()) return '';
    // Longest first, so PETG is not read as PET and PCTG not as PC.
    const byLength = FAMILIES.slice().sort((a, b) => b.length - a.length);
    for (const f of byLength) {
      if (new RegExp('(^|[^A-Z])' + f + '($|[^A-Z])').test(s)) return f;
    }
    return '';
  }

  function hex(value) {
    const s = String(value || '').trim().replace(/^#/, '');
    if (/^[0-9a-f]{8}$/i.test(s)) return '#' + s.slice(0, 6).toUpperCase(); // RRGGBBAA
    if (/^[0-9a-f]{6}$/i.test(s)) return '#' + s.toUpperCase();
    return null;
  }

  /** Loaded slots in the one shape this module reads. Empty slots are dropped. */
  function normalizeLoaded(list) {
    return (Array.isArray(list) ? list : [])
      .map((slot, index) => ({
        slot: Number.isInteger(slot && slot.slot) ? slot.slot : index,
        hex: hex(slot && (slot.hex || slot.color || slot.colour)),
        material: String((slot && slot.material) || '').trim(),
      }))
      .filter((s) => s.hex);
  }

  /**
   * A Snapmaker U1's `print_task_config` status object, as Moonraker returns
   * it, into loaded slots. The U1 reports all four heads whether or not a
   * spool is in them; `filament_exist` (when present) says which are real.
   */
  function fromPrintTaskConfig(config) {
    if (!config || typeof config !== 'object') return [];
    const colours = config.filament_color_rgba || [];
    const types = config.filament_type || [];
    const subs = config.filament_sub_type || [];
    const exist = config.filament_exist;
    const out = [];
    for (let i = 0; i < colours.length; i++) {
      if (Array.isArray(exist) && exist[i] === false) continue;
      const material = [types[i], subs[i]].filter((x) => x && String(x).trim()).join(' ');
      out.push({ slot: i, hex: hex(colours[i]), material });
    }
    return normalizeLoaded(out);
  }

  /** The distinct colours a model needs: near-identical swatches count once. */
  function needed(model, tolerance) {
    const out = [];
    for (const c of (model && Array.isArray(model.colors) ? model.colors : [])) {
      const h = hex(c && (c.hex || c.color));
      if (!h) continue;
      if (out.some((o) => KC().deltaE(o, h) <= tolerance / 3)) continue;
      out.push(h);
    }
    return out;
  }

  /**
   * Can this model be printed with what is loaded?
   *
   * @returns {{ known: boolean, fits: boolean, swaps: number,
   *             matched: {hex, slot, deltaE}[], missing: {hex, nearest, deltaE}[] }}
   *   `known` is false when the model lists no colours: the library cannot
   *   say, and it is not counted as fitting. `swaps` is how many spools would
   *   have to change; 0 means it can start now.
   */
  function fit(model, loaded, opts) {
    const tolerance = (opts && isFinite(opts.tolerance)) ? Number(opts.tolerance) : DEFAULT_TOLERANCE;
    const slots = normalizeLoaded(loaded);
    const want = needed(model, tolerance);
    const fam = family(model && model.material);
    if (!want.length) return { known: false, fits: false, swaps: 0, matched: [], missing: [] };

    const usable = slots.filter((s) => !fam || !family(s.material) || family(s.material) === fam);
    const matched = [];
    const missing = [];
    for (const h of want) {
      let best = null;
      for (const s of usable) {
        const d = KC().deltaE(h, s.hex);
        if (!best || d < best.deltaE) best = { slot: s.slot, deltaE: d };
      }
      if (best && best.deltaE <= tolerance) matched.push({ hex: h, slot: best.slot, deltaE: round1(best.deltaE) });
      else missing.push({ hex: h, nearest: best ? best.slot : null, deltaE: best ? round1(best.deltaE) : null });
    }
    // More colours than heads can never start without a swap, even if each
    // colour on its own is close to something loaded.
    const heads = Math.max(slots.length, 1);
    const overflow = Math.max(0, want.length - heads);
    const swaps = Math.max(missing.length, overflow);
    return { known: true, fits: swaps === 0, swaps, matched, missing };
  }

  /**
   * Every model, with its fit, best first: what can start now, then what is
   * one swap away, and so on. Models the library cannot judge go last.
   */
  function rank(models, loaded, opts) {
    return (Array.isArray(models) ? models : [])
      .map((model) => ({ model, fit: fit(model, loaded, opts) }))
      .sort((a, b) => {
        if (a.fit.known !== b.fit.known) return a.fit.known ? -1 : 1;
        if (a.fit.swaps !== b.fit.swaps) return a.fit.swaps - b.fit.swaps;
        return total(a.fit) - total(b.fit);
      });
  }

  function total(f) { return f.matched.reduce((n, m) => n + m.deltaE, 0); }
  function round1(n) { return Math.round(n * 10) / 10; }

  const api = { DEFAULT_TOLERANCE, family, normalizeLoaded, fromPrintTaskConfig, needed, fit, rank };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  global.KhaytLoadedColours = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
