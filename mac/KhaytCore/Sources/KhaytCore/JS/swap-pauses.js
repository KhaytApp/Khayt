'use strict';
/*
 * M600 swap-pause planning — a Node port of the bedready.io web reference (src/lib/swap-pauses.ts).
 *
 * When a file has more colours than physical toolheads, several source slots must share one head. Instead
 * of MERGING colours (losing them), we keep them all and insert M600 pause commands into the project's
 * `custom_gcode_per_layer.xml` so the user swaps the physical spool at the right height. Pauses are keyed
 * to absolute `top_z` (mm), which survives re-slicing in Snapmaker Orca.
 *
 * Algorithm mirrors the approach proven by thadius83/bambu-to-snapmaker-u1:
 *   1. ext→phys map (source slot 1-based → physical head 0-based).
 *   2. Walk colour-change layers in Z order, tracking the slot loaded on each head; a requested slot ≠
 *      loaded slot is a swap event.
 *   3. Greedily batch swaps that don't overlap in Z into one pause.
 *   4. Insert a pause layer one layer-height before each batch's first needed colour.
 */
(function (global) {
  const N_PHYSICAL = 4;

  /** Parse `<layer .../>` self-closing tags (attributes only) in document order. */
  function parseLayers(xml) {
    const out = [];
    for (const m of xml.matchAll(/<layer\b([^>]*?)\/?>/g)) {
      const attrs = {};
      for (const a of m[1].matchAll(/(\w+)\s*=\s*"([^"]*)"/g)) attrs[a[1]] = a[2];
      out.push({ attrs, raw: m[0] });
    }
    return out;
  }

  function layerXml(attrs) {
    const order = ['top_z', 'type', 'extruder', 'color', 'extra', 'gcode'];
    const keys = order.filter((k) => k in attrs).concat(Object.keys(attrs).filter((k) => order.indexOf(k) < 0));
    return `<layer ${keys.map((k) => `${k}="${attrs[k]}"`).join(' ')}/>`;
  }

  /** physical head → [source slots] for heads that hold more than one source slot. */
  function detectConflicts(remap) {
    const groups = new Map();
    for (const [src, phys] of remap) {
      if (phys < 0) continue;
      const arr = groups.get(phys) || [];
      arr.push(src);
      groups.set(phys, arr);
    }
    const conflicts = new Map();
    for (const [p, srcs] of groups) if (srcs.length > 1) conflicts.set(p, srcs.sort((a, b) => a - b));
    return conflicts;
  }

  /**
   * Insert batched M600 pauses into a custom_gcode_per_layer.xml string.
   * @param {string} xml source custom_gcode_per_layer.xml
   * @param {Map<number,number>} remap source slot (1-based) → physical head (0-based)
   * @param {string[]} colours source slot colours (0-based; colour of slot s is colours[s-1])
   * @param {string} pauseGcode the pause command to emit (e.g. "M600")
   * @param {number} [layerHeight] real print layer height (mm) — places each pause one layer below the
   *   colour it serves. Omit to fall back to inferring it from colour-change spacing (less accurate).
   * @returns {{ xml:string, instructions:object[] }}
   */
  function insertSwapPauses(xml, remap, colours, pauseGcode, layerHeight, nHeads) {
    if (detectConflicts(remap).size === 0) return { xml, instructions: [] };
    const H = nHeads && nHeads > 0 ? nHeads : N_PHYSICAL; // 1 = single-extruder (swap at every change)

    const extToPhys = new Map();
    for (const [src, phys] of remap) if (phys >= 0) extToPhys.set(src, phys % H);

    const layers = parseLayers(xml);
    if (layers.length === 0) return { xml, instructions: [] };

    // Initial spool on each head = the first slot that head actually PRINTS, walking layers
    // in Z order. Seeding from the lowest-numbered source slot instead meant that whenever
    // the numerically-smallest slot was not the first one used, the walker saw a mismatch on
    // the very first band and emitted a wasted M600 at layer 1 — halting the print to ask
    // the operator to load filament that was already on the head. With bands ordered 3,2,1
    // up Z on a single extruder, that was "T1: #ff0000 → #0000ff @ 0.2mm" for a colour not
    // printed until the top.
    const loadedInit = new Map();
    for (const layer of layers) {
      if (layer.attrs.type !== '2') continue;
      const ext = parseInt(layer.attrs.extruder != null ? layer.attrs.extruder : '0', 10);
      const phys = extToPhys.get(ext);
      if (phys === undefined) continue;
      if (!loadedInit.has(phys)) loadedInit.set(phys, ext);
    }
    // Any head that never prints keeps its lowest-numbered slot, as before.
    for (const src of [...remap.keys()].sort((a, b) => a - b)) {
      const phys = remap.get(src);
      if (phys < 0) continue;
      const h = phys % H;
      if (!loadedInit.has(h)) loadedInit.set(h, src);
    }

    const zs = [...new Set(layers.map((l) => parseFloat(l.attrs.top_z)).filter((z) => !isNaN(z)))].sort((a, b) => a - b);
    // Prefer the real layer height; the colour-change spacing only bounds it from above (those layers are
    // sparse), so inferring from gaps overestimates and can shove a pause's top_z back below the preceding
    // layer — breaking the monotonic Z order Snapmaker Orca expects.
    let layerH = layerHeight && layerHeight > 0 ? layerHeight : 0.2;
    if (!(layerHeight && layerHeight > 0)) {
      for (let i = 1; i < zs.length; i++) if (zs[i] - zs[i - 1] > 0) { layerH = zs[i] - zs[i - 1]; break; }
    }

    const details = [];
    const loaded = new Map(loadedInit);
    const headLast = new Map();

    layers.forEach((layer, i) => {
      if (layer.attrs.type !== '2') return; // only colour-change layers
      const ext = parseInt(layer.attrs.extruder != null ? layer.attrs.extruder : '0', 10);
      const phys = extToPhys.get(ext);
      if (phys === undefined) return;
      const cur = loaded.get(phys);
      if (cur !== ext) {
        details.push({
          firstNeeded: i,
          lastUse: headLast.get(phys) != null ? headLast.get(phys) : -1,
          phys,
          fromSlot: cur != null ? cur : ext,
          toSlot: ext,
          fromColour: cur && cur <= colours.length ? colours[cur - 1] : '',
          toColour: layer.attrs.color != null ? layer.attrs.color : '',
        });
        loaded.set(phys, ext);
      }
      headLast.set(phys, i);
    });

    if (details.length === 0) return { xml, instructions: [] };

    // Greedy batch: merge while max(lastUse) < min(firstNeeded) across the batch.
    const batches = [];
    let cur = [];
    for (const d of details) {
      if (cur.length === 0) { cur = [d]; continue; }
      const mx = Math.max(...cur.concat(d).map((s) => s.lastUse));
      const mn = Math.min(...cur.concat(d).map((s) => s.firstNeeded));
      if (mx < mn) cur.push(d);
      else { batches.push(cur); cur = [d]; }
    }
    batches.push(cur);

    const instructions = [];
    const inserts = [];
    for (const batch of batches) {
      const minFirst = Math.min(...batch.map((s) => s.firstNeeded));
      const firstZ = parseFloat(layers[minFirst].attrs.top_z != null ? layers[minFirst].attrs.top_z : '0') || 0;
      const pauseZ = `${Math.max(layerH, firstZ - layerH)}`;
      inserts.push({
        afterRaw: layers[minFirst].raw,
        pause: layerXml({ top_z: pauseZ, type: '1', extruder: '1', color: '', extra: '', gcode: pauseGcode }),
      });
      for (const s of batch) {
        instructions.push({
          z: parseFloat(pauseZ),
          toolhead: s.phys + 1,
          fromSlot: s.fromSlot,
          toSlot: s.toSlot,
          fromColour: s.fromColour,
          toColour: s.toColour,
          label: `T${s.phys + 1}: ${s.fromColour || '?'} → ${s.toColour || '?'} @ ${pauseZ}mm`,
        });
      }
    }

    // Insert each pause immediately BEFORE its target layer tag in the XML.
    let outXml = xml;
    for (const ins of inserts) outXml = outXml.replace(ins.afterRaw, ins.pause + ins.afterRaw);
    return { xml: outXml, instructions };
  }

  /**
   * Plan manual filament swaps for a vertically colour-BANDED painted model (from detectColorBands).
   * A painted file has no `type="2"` colour-change layers, so we synthesise one per band boundary and
   * reuse insertSwapPauses' proven head-tracking + batching. Each distinct band colour is assigned a
   * physical head in order of first appearance (Z); the 5th+ colour reuses a head, which insertSwapPauses
   * turns into a manual swap at the right height.
   * @returns {{ instructions:object[], headOf:Map<number,number>, customGcodeXml:string }}
   */
  function buildBandSwapPlan(bands, colours, pauseGcode, layerHeight, baseState, nHeads) {
    const H = nHeads && nHeads > 0 ? nHeads : N_PHYSICAL; // 4 = U1 heads; 1 = single-extruder M600
    // Distinct band colours in order of first appearance up the Z axis. Seed the base colour first so it
    // lands on head 0 (slot 1) — unpainted faces have no paint_color and print on the base extruder, so the
    // base colour must be the one loaded on head 0 or those faces come out wrong.
    const order = [];
    if (baseState != null) order.push(baseState);
    for (const b of bands) if (order.indexOf(b.state) < 0) order.push(b.state);
    // First H colours get their own head; the (H+1)th+ reuses a head (round-robin) → a manual swap. With
    // H=1 (single extruder) EVERY colour change is a swap. Not globally optimal when a reused head's colour
    // returns higher up, but correct, and fine in the small-swap-count sweet spot this feature targets.
    const remap = new Map();
    order.forEach((s, i) => remap.set(s, i % H));

    const tags = bands
      .map((b) => `<layer top_z="${b.z0}" type="2" extruder="${b.state}" color="${colours[b.state - 1] != null ? colours[b.state - 1] : ''}"/>`)
      .join('');
    const xml = `<custom_gcodes_per_layer><plate>${tags}</plate></custom_gcodes_per_layer>`;
    const { instructions } = insertSwapPauses(xml, remap, colours, pauseGcode, layerHeight, H);

    // A painted band model already maps each colour to its head via the paint remap, so the only thing the
    // output needs from the custom-gcode file is a PAUSE at each manual-swap height (one per distinct Z,
    // even if two heads swap at once). Emit a standalone Orca custom_gcode_per_layer.xml with just those.
    const pauseZs = [...new Set(instructions.map((s) => s.z))].sort((a, b) => a - b);
    const pauseTags = pauseZs
      .map((z) => layerXml({ top_z: `${z}`, type: '1', extruder: '1', color: '', extra: '', gcode: pauseGcode }))
      .join('\n    ');
    const customGcodeXml =
      `<?xml version="1.0" encoding="utf-8"?>\n<custom_gcodes_per_layer>\n  <plate>\n    <plate_info id="1"/>\n    ${pauseTags}\n  </plate>\n</custom_gcodes_per_layer>\n`;

    return { instructions, headOf: remap, customGcodeXml };
  }

  const api = { detectConflicts, insertSwapPauses, buildBandSwapPlan, N_PHYSICAL };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytSwapPauses = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
