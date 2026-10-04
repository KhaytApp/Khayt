'use strict';
/**
 * HueForge → Snapmaker U1 3MF assembler (main-process, Node). Packs a relief mesh + a
 * per-height filament plan into a Snapmaker-Orca 3MF that opens ready-to-slice: the colour
 * swaps are encoded as `Metadata/layer_config_ranges.xml` height-range modifiers (each Z
 * band → an `extruder` = one of the U1's 4 SnapSwap heads), exactly as a real
 * Snapmaker-Orca HueForge export does — so Orca changes tool automatically at each band, no
 * manual setup, no baked M600.
 *
 * The envelope + full U1 process/machine settings (native start/tool-change G-code, bed,
 * flavour — 572 keys) come from `hueforge-u1-template.json`, a genericised project_settings
 * captured from a real U1 export; we mutate only filament_colour + layer height. Structure
 * (object ids, model_settings, content-types) mirrors that known-good file.
 *
 * Only the ≤4-colour automatic case is emitted here (the U1's sweet spot); >4 colours fall
 * back to STL + the mm swap guide in the UI.
 */
(function (global) {
  const zipWrite = (typeof require === 'function') ? require('./zip-write') : global.KhaytZipWrite;
  let TEMPLATE = null;
  function template() {
    if (!TEMPLATE && typeof require === 'function') TEMPLATE = require('./hueforge-u1-template.json');
    return TEMPLATE;
  }

  const xmlEsc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const num = (n) => { const x = Number(n); return Number.isFinite(x) ? String(Math.round(x * 1e4) / 1e4) : '0'; };

  const CONTENT_TYPES = '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    + '<Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>'
    + '<Default Extension="png" ContentType="image/png"/>'
    + '<Default Extension="gcode" ContentType="text/x.gcode"/></Types>';
  // Root relationships. When a plate thumbnail is present we advertise it exactly as a real
  // Snapmaker-Orca / Bambu export does, so the model shows a picture in the slicer's plate
  // list, in the OS file preview, and on re-open — instead of a blank tile.
  function rootRels(hasThumb) {
    const rels = ['<Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>'];
    if (hasThumb) {
      rels.push('<Relationship Target="/Metadata/plate_1.png" Id="rel-2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"/>');
      rels.push('<Relationship Target="/Metadata/plate_1.png" Id="rel-4" Type="http://schemas.bambulab.com/package/2021/cover-thumbnail-middle"/>');
      rels.push('<Relationship Target="/Metadata/plate_1_small.png" Id="rel-5" Type="http://schemas.bambulab.com/package/2021/cover-thumbnail-small"/>');
    }
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
      + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + rels.join('') + '</Relationships>';
  }
  const MODEL_RELS = '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    + '<Relationship Target="/3D/Objects/object_1.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>';

  /**
   * The mesh, as a Bambu/Orca object part file (core-spec geometry; object id=1).
   *
   * Vertices MUST be shared by index: coincident corners are welded to a single vertex so
   * adjacent triangles reference the same index. Orca builds connectivity from the vertex
   * INDICES, not from coordinates — an un-welded "triangle soup" (3 private vertices per
   * triangle) reads as thousands of disconnected triangles, which it then reports as
   * "floating regions" / "empty initial layer" and refuses to print, even though the
   * geometry is coincident-watertight. Welding here is what makes the model a real solid.
   */
  /** Weld one triangle list into indexed `<vertices>` / `<triangles>` markup. */
  function weldMesh(triangles) {
    const verts = [];
    const tris = [];
    const index = new Map();
    const vidx = (p) => {
      const x = num(p[0]), y = num(p[1]), z = num(p[2]);
      const key = x + ' ' + y + ' ' + z;
      let i = index.get(key);
      if (i === undefined) {
        i = verts.length;
        index.set(key, i);
        verts.push('<vertex x="' + x + '" y="' + y + '" z="' + z + '"/>');
      }
      return i;
    };
    for (const tri of triangles) {
      if (!tri || tri.length < 3) continue;
      const a = vidx(tri[0] || [0, 0, 0]), b = vidx(tri[1] || [0, 0, 0]), c = vidx(tri[2] || [0, 0, 0]);
      if (a === b || b === c || a === c) continue; // drop degenerate (zero-area) faces
      tris.push('<triangle v1="' + a + '" v2="' + b + '" v3="' + c + '"/>');
    }
    return { verts: verts.join(''), tris: tris.join(''), triangleCount: tris.length };
  }

  const MODEL_OPEN = '<?xml version="1.0" encoding="UTF-8"?>\n'
    + '<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021">';

  function objectModelXml(triangles) {
    const m = weldMesh(triangles);
    // The trailing <build/> is REQUIRED, not decoration. The 3MF core spec gives every model part
    // a <build> element, including a geometry part that is only referenced by <component p:path>
    // and has nothing of its own to place. Without it lib3mf — the 3MF Consortium's own reader —
    // refuses to load the part, the root object referencing it never resolves, and the failure
    // surfaces one level up as the misleading "Build item not found". Found by bedready.io
    // validating its output against lib3mf (src/lib/hueforge-3mf.ts, ported here).
    return MODEL_OPEN
      + '<resources><object id="1" type="model"><mesh><vertices>' + m.verts + '</vertices><triangles>' + m.tris + '</triangles></mesh></object></resources><build/></model>';
  }

  /**
   * The FLAT mode's part file: one `<object>` per colour region, all in one member.
   *
   * The relief encodes colour by HEIGHT — one mesh, swapped at Z. Flat mode encodes it by
   * REGION: the plate is cut into a base slab plus one cap part per colour, and each part is
   * assigned a toolhead. So the geometry has to arrive as several objects that the root model
   * references as components and model_settings tags with an extruder each — the layout a
   * real multi-part U1 export uses (verified against ToyCarRoad_V2.u1.3mf: 75 parts, each
   * `<part id>` matching a `<component objectid>` and carrying its own extruder).
   *
   * @param {Array<{triangles:Array}>} parts
   * @param {number} firstId  object id of the first part; ids run consecutively from here
   */
  function flatPartsModelXml(parts, firstId) {
    const objs = parts.map((p, i) => {
      const m = weldMesh(p.triangles || []);
      return '<object id="' + (firstId + i) + '" type="model"><mesh><vertices>' + m.verts
        + '</vertices><triangles>' + m.tris + '</triangles></mesh></object>';
    });
    // <build/> is required in every model part — see objectModelXml.
    return MODEL_OPEN + '<resources>' + objs.join('') + '</resources><build/></model>';
  }

  /** Root model for flat mode: the assembly (id=2) referencing every part as a component. */
  function flatRootModelXml(parts, firstId, tx, ty) {
    const t = '1 0 0 0 1 0 0 0 1 ' + num(tx) + ' ' + num(ty) + ' 0';
    const comps = parts.map((_p, i) =>
      '<component p:path="/3D/Objects/object_1.model" objectid="' + (firstId + i) + '" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>').join('');
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
      + '<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">'
      + '<metadata name="Application">BedReady-HueForge</metadata><metadata name="BambuStudio:3mfVersion">1</metadata>'
      + '<resources><object id="2" type="model"><components>' + comps + '</components></object></resources>'
      + '<build><item objectid="2" transform="' + t + '" printable="1"/></build></model>';
  }

  /** model_settings for flat mode: every part names the head that prints it. */
  function flatModelSettingsXml(name, parts, firstId, tx, ty, hasThumb, baseExtruder) {
    const n = xmlEsc(name || 'HueForge');
    const mtx = '1 0 0 ' + num(tx) + ' 0 1 0 ' + num(ty) + ' 0 0 1 0 0 0 0 1';
    const partXml = parts.map((p, i) =>
      '    <part id="' + (firstId + i) + '" subtype="normal_part">\n'
      + '      <metadata key="name" value="' + xmlEsc(p.name || (i === 0 ? 'base' : 'colour ' + ((p.head | 0) + 1))) + '"/>\n'
      + '      <metadata key="matrix" value="' + mtx + '"/>\n'
      // The whole point: this part prints in this head, whatever height it sits at.
      + '      <metadata key="extruder" value="' + ((p.head | 0) + 1) + '"/>\n'
      + '    </part>\n').join('');
    return '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n'
      + '  <object id="2">\n'
      + '    <metadata key="name" value="' + n + '"/>\n'
      + '    <metadata key="bottom_surface_pattern" value="alignedrectilinear"/>\n'
      + '    <metadata key="enable_support" value="0"/>\n'
      + '    <metadata key="extruder" value="' + baseExtruder + '"/>\n'
      + '    <metadata key="internal_solid_infill_pattern" value="alignedrectilinear"/>\n'
      + '    <metadata key="seam_position" value="back"/>\n'
      + '    <metadata key="sparse_infill_density" value="100%"/>\n'
      + '    <metadata key="sparse_infill_pattern" value="alignedrectilinear"/>\n'
      + '    <metadata key="top_surface_pattern" value="alignedrectilinear"/>\n'
      + '    <metadata key="wall_generator" value="arachne"/>\n'
      + partXml
      + '  </object>\n'
      + '  <plate>\n'
      + '    <metadata key="plater_id" value="1"/>\n'
      + '    <metadata key="locked" value="false"/>\n'
      + '    <metadata key="filament_map_mode" value="Auto For Flush"/>\n'
      + '    <metadata key="filament_maps" value="1 1 1 1"/>\n'
      + (hasThumb ? '    <metadata key="thumbnail_file" value="Metadata/plate_1.png"/>\n' : '')
      + '    <model_instance>\n'
      + '      <metadata key="object_id" value="2"/>\n'
      + '      <metadata key="instance_id" value="0"/>\n'
      + '    </model_instance>\n'
      + '  </plate>\n</config>\n';
  }

  /** Root model: an assembly object (id=2) referencing the mesh, placed centred on the bed. */
  function rootModelXml(tx, ty) {
    const t = '1 0 0 0 1 0 0 0 1 ' + num(tx) + ' ' + num(ty) + ' 0';
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
      + '<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">'
      + '<metadata name="Application">BedReady-HueForge</metadata><metadata name="BambuStudio:3mfVersion">1</metadata>'
      + '<resources><object id="2" type="model"><components>'
      + '<component p:path="/3D/Objects/object_1.model" objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>'
      + '</components></object></resources>'
      + '<build><item objectid="2" transform="' + t + '" printable="1"/></build></model>';
  }

  function modelSettingsXml(name, tx, ty, hasThumb) {
    const n = xmlEsc(name || 'HueForge');
    const mtx = '1 0 0 ' + num(tx) + ' 0 1 0 ' + num(ty) + ' 0 0 1 0 0 0 0 1';
    const thumbMeta = hasThumb
      ? '    <metadata key="thumbnail_file" value="Metadata/plate_1.png"/>\n'
      : '';
    return '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n'
      + '  <object id="2">\n'
      + '    <metadata key="name" value="' + n + '"/>\n'
      + '    <metadata key="bottom_surface_pattern" value="alignedrectilinear"/>\n'
      + '    <metadata key="enable_support" value="0"/>\n'
      + '    <metadata key="extruder" value="1"/>\n'
      + '    <metadata key="internal_solid_infill_pattern" value="alignedrectilinear"/>\n'
      + '    <metadata key="seam_position" value="back"/>\n'
      + '    <metadata key="sparse_infill_density" value="100%"/>\n'
      + '    <metadata key="sparse_infill_pattern" value="alignedrectilinear"/>\n'
      + '    <metadata key="top_surface_pattern" value="alignedrectilinear"/>\n'
      + '    <metadata key="wall_generator" value="arachne"/>\n'
      + '    <part id="1" subtype="normal_part">\n'
      + '      <metadata key="name" value="' + n + '"/>\n'
      + '      <metadata key="matrix" value="' + mtx + '"/>\n'
      + '    </part>\n'
      + '  </object>\n'
      + '  <plate>\n'
      + '    <metadata key="plater_id" value="1"/>\n'
      + '    <metadata key="locked" value="false"/>\n'
      + '    <metadata key="filament_map_mode" value="Auto For Flush"/>\n'
      + '    <metadata key="filament_maps" value="1 1 1 1"/>\n'
      + thumbMeta
      + '    <model_instance>\n'
      + '      <metadata key="object_id" value="2"/>\n'
      + '      <metadata key="instance_id" value="0"/>\n'
      + '    </model_instance>\n'
      + '  </plate>\n</config>\n';
  }

  /**
   * The swap encoding: one Z-range per band → its U1 head (extruder, 1-based).
   * `firstLayerH` (optional) states the base range's layer height outright; without it the
   * coarse base below is derived.
   */
  function layerRangesXml(bands, layerH, firstLayerH) {
    // The TOP range must be open-ended, and a real export is how we know.
    //
    // A Snapmaker-Orca HueForge 3MF ends its last range at max_z="1000" rather
    // than at the model's height. Khayt closed the top band at exactly
    // endLayer x layerH — the model's maximum Z — so any layer landing at or
    // fractionally above that boundary falls outside EVERY range and takes the
    // object's default extruder, which model_settings.config sets to 1: the
    // base colour. On a relief the top layers are the picture, so the failure
    // is a visibly wrong print rather than an error.
    //
    // Matching the reference exactly (1000) rather than inventing a margin:
    // that value is what a working file uses, and this is not the place to be
    // original.
    const TOP_OPEN_Z = 1000;

    // The BASE band prints coarse, and the same reference is why.
    //
    // That export runs its opaque base at 0.24 mm and every colour band at
    // 0.12 — half. The base exists only to stop the bed showing through, so its
    // layer height is invisible in the finished piece, while the bands above it
    // are where the blending happens and need fine layers.
    //
    // Khayt wrote the per-range layer_height key from the start and always gave
    // every range the same number, so the mechanism was there and unused. For
    // the piece that reference file was printing, that is 57 layers instead of
    // 28 — twice the time, for no visible gain on the half of the print nobody
    // can see into.
    //
    // Doubling matches the reference's 0.24/0.12. Capped because doubling a
    // coarse setting can leave a layer no 0.4 nozzle can lay down: 0.3 is
    // 0.75x a standard nozzle, and above the 0.24 the reference actually used.
    const BASE_MULTIPLE = 2;
    const MAX_BASE_LAYER_MM = 0.3;
    // The outer max matters: a shop already printing at 0.5 would otherwise get
    // a base capped to 0.3 while its colour bands stayed at 0.5 — a base FINER
    // than the bands, which is the opposite of the point. Above the cap there is
    // simply no coarsening to be had, so the base matches the rest.
    const baseLayerH = Math.max(layerH, Math.min(MAX_BASE_LAYER_MM, layerH * BASE_MULTIPLE));

    // Flat mode builds its own foundation — a single solid slab — and knows the height it
    // wants for it, so a caller may state one outright. When nobody does, the relief path's
    // computed coarse base above still applies: an explicit setting overrides a derived one,
    // and the absence of a setting is not an instruction to print the base fine.
    const baseH = firstLayerH > 0 ? firstLayerH : baseLayerH;

    const last = bands.length - 1;
    const ranges = bands.map((b, i) =>
      '  <range min_z="' + num(b.z0) + '" max_z="' + num(i === last ? TOP_OPEN_Z : b.z1) + '">\n'
      + '   <option opt_key="extruder">' + ((b.head | 0) + 1) + '</option>\n'
      + '   <option opt_key="layer_height">' + num(i === 0 ? baseH : layerH) + '</option>\n'
      + '  </range>').join('\n');
    return '<?xml version="1.0" encoding="utf-8"?>\n<objects>\n <object id="1">\n' + ranges + '\n </object>\n</objects>\n';
  }

  function pad4(arr, fill) { const out = arr.slice(0, 4); while (out.length < 4) out.push(fill); return out; }

  /**
   * @param {{ triangles:Array, bands:Array<{z0,z1,head,hex}>, layerH:number, name?:string,
   *           bed?:{x,y}, sizeMm?:{x,y,z},
   *           thumbnailPng?:Buffer|Uint8Array, thumbnailSmallPng?:Buffer|Uint8Array }} o
   *   thumbnailPng — the achievable-colour preview as PNG bytes; embedded as the plate
   *   thumbnail so the model shows a picture in the slicer / file preview (optional).
   * @returns {Buffer|null}
   */
  function buildU1_3mf(o) {
    const tpl = template();
    if (!tpl || !o || !Array.isArray(o.triangles) || !o.triangles.length || !Array.isArray(o.bands) || !o.bands.length) return null;
    const layerH = +o.layerH > 0 ? +o.layerH : 0.12;
    const bed = o.bed && o.bed.x ? o.bed : { x: 270, y: 270 };

    // model spans 0..sizeX, 0..sizeY → centre on the bed via the build item translation.
    let sx = o.sizeMm && o.sizeMm.x, sy = o.sizeMm && o.sizeMm.y;
    if (!sx || !sy) {
      let maxX = 0, maxY = 0;
      for (const t of o.triangles) for (const p of t) { if (p[0] > maxX) maxX = p[0]; if (p[1] > maxY) maxY = p[1]; }
      sx = maxX; sy = maxY;
    }
    const tx = bed.x / 2 - sx / 2, ty = bed.y / 2 - sy / 2;

    const cfg = JSON.parse(JSON.stringify(tpl));
    // filament_colour is indexed by extruder (head+1). With the optimised engine a filament
    // recurs across many bands, so derive the 4 slot colours from the explicit filament list
    // (index = head). Fall back to band order for the legacy 4-band path.
    const filHex = Array.isArray(o.filaments) && o.filaments.length
      ? o.filaments.map((f) => String((f && f.hex) || f || '#FFFFFF').toUpperCase())
      : o.bands.map((b) => String(b.hex || '#FFFFFF').toUpperCase());
    cfg.filament_colour = pad4(filHex, '#FFFFFF');
    // 0 = nobody asked; layerRangesXml then derives the coarse base itself.
    const firstLayerH = +o.firstLayerH > 0 ? +o.firstLayerH : 0;
    cfg.layer_height = String(layerH);
    cfg.initial_layer_print_height = String(firstLayerH || layerH);
    // The U1's SnapSwap heads need no purge, so the prime tower must stay off. Orca honours a
    // preset-linked setting only if it's listed in different_settings_to_system — without it,
    // enable_prime_tower reconciles back to the system default (tower ON). Keep the real file's
    // entry and add the layer keys we override so those stick too.
    cfg.enable_prime_tower = '0';
    cfg.different_settings_to_system = ['enable_prime_tower;support_type;layer_height;initial_layer_print_height', '', '', '', '', ''];

    const thumb = o.thumbnailPng;
    const thumbSmall = o.thumbnailSmallPng || thumb;
    const thumbLen = thumb ? (Buffer.isBuffer(thumb) ? thumb.length : (thumb.byteLength || (thumb.length | 0))) : 0;
    const hasThumb = thumbLen > 0;

    const name = o.name || 'HueForge';
    const members = [
      { name: '[Content_Types].xml', data: CONTENT_TYPES },
      { name: '_rels/.rels', data: rootRels(hasThumb) },
      { name: '3D/3dmodel.model', data: rootModelXml(tx, ty) },
      { name: '3D/_rels/3dmodel.model.rels', data: MODEL_RELS },
      { name: '3D/Objects/object_1.model', data: objectModelXml(o.triangles) },
      { name: 'Metadata/project_settings.config', data: JSON.stringify(cfg) },
      { name: 'Metadata/model_settings.config', data: modelSettingsXml(name, tx, ty, hasThumb) },
      { name: 'Metadata/layer_config_ranges.xml', data: layerRangesXml(o.bands, layerH, firstLayerH) },
    ];
    if (hasThumb) {
      // PNGs are already-compressed — STORE them (deflate can't help and just burns time).
      members.push({ name: 'Metadata/plate_1.png', data: thumb, store: true });
      members.push({ name: 'Metadata/plate_1_small.png', data: thumbSmall, store: true });
    }
    return zipWrite.writeZip(members);
  }

  /**
   * FLAT multicolor → Snapmaker U1 3MF. The counterpart to buildU1_3mf, for the mode that
   * paints by REGION instead of by height.
   *
   * The relief's colour plan is a stack of Z-ranges, so its 3MF is one mesh plus
   * `layer_config_ranges.xml`. Flat mode has no such stack — the plate is a base slab with
   * one cap part per colour, side by side at the same heights — so this file carries NO
   * layer ranges at all. Writing them would be worse than useless: a Z-range applies to
   * everything at that height, which for a flat plate is every colour at once.
   *
   * What it writes instead is what a real multi-part U1 export writes: one object per part,
   * referenced as components, each tagged with its own extruder in model_settings.
   *
   * @param {{ parts:Array<{head:number, hex?:string, triangles:Array, name?:string}>,
   *           filaments:Array<string>, sizeMm?:{x,y,z}, layerH?:number, firstLayerH?:number,
   *           name?:string, bed?:{x,y}, baseHead?:number,
   *           thumbnailPng?:Buffer, thumbnailSmallPng?:Buffer }} o
   *   parts      — bottom slab first, then a cap part per colour. `head` is 0-based.
   *   filaments  — the slot colours, indexed by head (what actually loads in the machine).
   * @returns {Buffer|null}
   */
  function buildFlatU1_3mf(o) {
    const tpl = template();
    if (!tpl || !o || !Array.isArray(o.parts) || !o.parts.length) return null;
    // A part with no geometry would become an empty <object> that Orca reports as a broken
    // model, so drop those rather than emit them.
    const parts = o.parts.filter((p) => p && Array.isArray(p.triangles) && p.triangles.length);
    if (!parts.length) return null;

    const layerH = +o.layerH > 0 ? +o.layerH : 0.12;
    const bed = o.bed && o.bed.x ? o.bed : { x: 270, y: 270 };

    let sx = o.sizeMm && o.sizeMm.x, sy = o.sizeMm && o.sizeMm.y;
    if (!sx || !sy) {
      let maxX = 0, maxY = 0;
      for (const p of parts) for (const t of p.triangles) for (const v of t) { if (v[0] > maxX) maxX = v[0]; if (v[1] > maxY) maxY = v[1]; }
      sx = maxX; sy = maxY;
    }
    const tx = bed.x / 2 - sx / 2, ty = bed.y / 2 - sy / 2;

    const cfg = JSON.parse(JSON.stringify(tpl));
    // Indexed by head, exactly as the parts reference them — NOT derived from part order,
    // because two parts can share a head and the base usually shares one with a cap.
    const filHex = (Array.isArray(o.filaments) && o.filaments.length ? o.filaments : parts.map((p) => p.hex))
      .map((f) => String((f && f.hex) || f || '#FFFFFF').toUpperCase());
    cfg.filament_colour = pad4(filHex, '#FFFFFF');
    const firstLayerH = +o.firstLayerH > 0 ? +o.firstLayerH : 0;
    cfg.layer_height = String(layerH);
    cfg.initial_layer_print_height = String(firstLayerH || layerH);
    cfg.enable_prime_tower = '0';
    cfg.different_settings_to_system = ['enable_prime_tower;support_type;layer_height;initial_layer_print_height', '', '', '', '', ''];

    const thumb = o.thumbnailPng;
    const thumbSmall = o.thumbnailSmallPng || thumb;
    const thumbLen = thumb ? (Buffer.isBuffer(thumb) ? thumb.length : (thumb.byteLength || (thumb.length | 0))) : 0;
    const hasThumb = thumbLen > 0;

    // Part object ids start above the assembly's own id (2) so nothing collides.
    const FIRST_PART_ID = 10;
    const baseHead = Number.isInteger(o.baseHead) ? o.baseHead : (parts[0].head | 0);
    const name = o.name || 'HueForge';

    const members = [
      { name: '[Content_Types].xml', data: CONTENT_TYPES },
      { name: '_rels/.rels', data: rootRels(hasThumb) },
      { name: '3D/3dmodel.model', data: flatRootModelXml(parts, FIRST_PART_ID, tx, ty) },
      { name: '3D/_rels/3dmodel.model.rels', data: MODEL_RELS },
      { name: '3D/Objects/object_1.model', data: flatPartsModelXml(parts, FIRST_PART_ID) },
      { name: 'Metadata/project_settings.config', data: JSON.stringify(cfg) },
      { name: 'Metadata/model_settings.config', data: flatModelSettingsXml(name, parts, FIRST_PART_ID, tx, ty, hasThumb, (baseHead | 0) + 1) },
    ];
    if (hasThumb) {
      members.push({ name: 'Metadata/plate_1.png', data: thumb, store: true });
      members.push({ name: 'Metadata/plate_1_small.png', data: thumbSmall, store: true });
    }
    return zipWrite.writeZip(members);
  }

  const api = { buildU1_3mf, buildFlatU1_3mf };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  if (typeof globalThis !== 'undefined') global.KhaytHueForge3mf = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
