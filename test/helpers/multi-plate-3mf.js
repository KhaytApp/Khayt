'use strict';
/**
 * A Bambu Studio–shaped multi-plate project, built in memory.
 *
 * Laid out the way Bambu/Orca write one (production extension: a root model of
 * components, one 3D/Objects/object_N.model per object, plates in
 * model_settings.config, plates on one world grid with a bed-and-a-fifth
 * stride), with the members that name plates or objects that a split has to keep
 * straight: per-plate thumbnails, slice_info, custom G-code per plate, the
 * filament sequence, and the two position-keyed files (layer heights, cut info).
 *
 *   plate 1 "Base"    object 2 (one part, unpainted, filament 1)
 *                     object 5 (two parts: filament 1 and filament 2)
 *   plate 2 "Dragon"  object 7 (painted with filaments 3 and 4 over filament 1)
 *                     object 9 (unpainted, filament 2, TWO copies)
 *   plate 3 "Sign"    object 11 (unpainted, filament 4)
 *
 * Root ids deliberately differ from object_N.model numbers, so a reader that
 * mixes the two up cannot pass by accident.
 */
const zlib = require('zlib');
const { writeZip, crc32 } = require('../../lib/zip-write');

const BED = 256;
const STRIDE = BED * 1.2;
const COLOURS = ['#FFFFFF', '#1A1A1A', '#E02020', '#2050E0'];

/** A small solid-colour PNG — a real one, so anything that sniffs the signature is satisfied. */
function png(hex, size = 8) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
  const row = Buffer.alloc(1 + size * 3);
  for (let x = 0; x < size; x++) { row[1 + x * 3] = r; row[2 + x * 3] = g; row[3 + x * 3] = b; }
  const raw = Buffer.concat(Array.from({ length: size }, () => row));
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0); ihdr.writeUInt32BE(size, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

/** A 10 mm cube as a mesh object; `paint(i)` may return a paint_color code for facet i. */
function cube(id, size = 10, paint) {
  const s = size / 2;
  const v = [[-s, -s, 0], [s, -s, 0], [s, s, 0], [-s, s, 0], [-s, -s, size], [s, -s, size], [s, s, size], [-s, s, size]];
  const f = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [1, 2, 6], [1, 6, 5], [2, 3, 7], [2, 7, 6], [3, 0, 4], [3, 4, 7]];
  return `  <object id="${id}" p:UUID="0000000${id}-81cb-4c03-9d28-80fed5dfa1dc" type="model">\n   <mesh>\n    <vertices>\n`
    + v.map((p) => `     <vertex x="${p[0]}" y="${p[1]}" z="${p[2]}"/>`).join('\n')
    + '\n    </vertices>\n    <triangles>\n'
    + f.map((t, i) => { const pc = paint && paint(i); return `     <triangle v1="${t[0]}" v2="${t[1]}" v3="${t[2]}"${pc ? ` paint_color="${pc}"` : ''}/>`; }).join('\n')
    + '\n    </triangles>\n   </mesh>\n  </object>\n';
}

function partFile(objects) {
  return '<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">\n <metadata name="BambuStudio:3mfVersion">1</metadata>\n <resources>\n'
    + objects.join('') + ' </resources>\n <build/>\n</model>\n';
}

const tr = (x, y, z = 0) => `1 0 0 0 1 0 0 0 1 ${x} ${y} ${z}`;

/**
 * @param {object} [o]
 * @param {boolean} [o.sharedObject]  put a copy of object 9 on plate 3 as well (cannot be split)
 * @returns {Buffer}
 */
function buildMultiPlate3mf(o = {}) {
  // Plate origins on the Bambu grid: 3 plates → 2 columns.
  const origin = [[0, 0], [STRIDE, 0], [0, -STRIDE]];
  const at = (plate, x, y) => [origin[plate][0] + x, origin[plate][1] + y];

  // root id → { file, meshIds, items: [[x,y]], plate, name, parts:[{id, extruder, name}], extruder }
  // Ids are numbered across the whole project, parts first and then the object
  // that holds them, the way Bambu Studio numbers them — so part ids never collide.
  const objs = [
    { id: 2, file: 'object_1.model', plate: 0, name: 'Base', extruder: 1, parts: [{ id: 1, extruder: 1, name: 'Base' }], items: [at(0, 100, 128)] },
    { id: 5, file: 'object_2.model', plate: 0, name: 'Two-part', extruder: 1, parts: [{ id: 3, extruder: 1, name: 'Body' }, { id: 4, extruder: 2, name: 'Lid' }], items: [at(0, 160, 128)] },
    { id: 7, file: 'object_3.model', plate: 1, name: 'Dragon', extruder: 1, parts: [{ id: 6, extruder: 1, name: 'Dragon' }], items: [at(1, 128, 100)], paint: (i) => (i < 4 ? '0C' : i < 8 ? '1C' : null) },
    { id: 9, file: 'object_4.model', plate: 1, name: 'Peg', extruder: 2, parts: [{ id: 8, extruder: 2, name: 'Peg' }], items: [at(1, 100, 160), at(1, 150, 160)] },
    { id: 11, file: 'object_5.model', plate: 2, name: 'Sign', extruder: 4, parts: [{ id: 10, extruder: 4, name: 'Sign' }], items: [at(2, 128, 128)] },
  ];
  if (o.sharedObject) objs[3].items.push(at(2, 60, 60));

  const files = [];
  const add = (name, data) => files.push({ name, data });

  add('[Content_Types].xml', '<?xml version="1.0" encoding="UTF-8"?>\n<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\n <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\n <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>\n <Default Extension="png" ContentType="image/png"/>\n <Default Extension="gcode" ContentType="text/x.gcode"/>\n</Types>\n');
  add('_rels/.rels', '<?xml version="1.0" encoding="UTF-8"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
    + ' <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\n'
    + ' <Relationship Target="/Metadata/plate_1.png" Id="rel-2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/thumbnail"/>\n'
    + ' <Relationship Target="/Metadata/plate_1.png" Id="rel-4" Type="http://schemas.bambulab.com/package/2021/cover-thumbnail-middle"/>\n'
    + ' <Relationship Target="/Metadata/plate_1_small.png" Id="rel-5" Type="http://schemas.bambulab.com/package/2021/cover-thumbnail-small"/>\n'
    + '</Relationships>\n');

  const root = '<?xml version="1.0" encoding="UTF-8"?>\n<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:BambuStudio="http://schemas.bambulab.com/package/2021" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06" requiredextensions="p">\n'
    + ' <metadata name="Application">BambuStudio-01.10.02.76</metadata>\n'
    + ' <metadata name="BambuStudio:3mfVersion">1</metadata>\n'
    + ' <metadata name="Thumbnail_Middle">/Metadata/plate_1.png</metadata>\n'
    + ' <metadata name="Thumbnail_Small">/Metadata/plate_1_small.png</metadata>\n'
    + ' <resources>\n'
    + objs.map((ob) => `  <object id="${ob.id}" p:UUID="000${ob.id}0000-61cb-4c03-9d28-80fed5dfa1dc" type="model">\n   <components>\n`
      + ob.parts.map((pt, i) => `    <component p:path="/3D/Objects/${ob.file}" objectid="${pt.id}" p:UUID="000${ob.id}000${i}-b206-40ff-9872-83e8017abed1" transform="${tr(i * 12, 0, 0)}"/>\n`).join('')
      + '   </components>\n  </object>\n').join('')
    + ' </resources>\n <build p:UUID="2c7c17d8-22b5-4d84-8835-1976022ea369">\n'
    + objs.flatMap((ob) => ob.items.map((p, i) => `  <item objectid="${ob.id}" p:UUID="000${ob.id}000${i}-b1ec-4553-aec9-835e5b724bb4" transform="${tr(p[0], p[1], 0)}" printable="1"/>\n`)).join('')
    + ' </build>\n</model>\n';
  add('3D/3dmodel.model', root);
  add('3D/_rels/3dmodel.model.rels', '<?xml version="1.0" encoding="UTF-8"?>\n<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\n'
    + objs.map((ob, i) => ` <Relationship Target="/3D/Objects/${ob.file}" Id="rel-${i + 1}" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>\n`).join('')
    + '</Relationships>\n');
  for (const ob of objs) add(`3D/Objects/${ob.file}`, partFile(ob.parts.map((pt) => cube(pt.id, 10, ob.paint))));

  const plateNames = ['Base', 'Dragon', 'Sign'];
  const ms = '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n'
    + objs.map((ob) => `  <object id="${ob.id}">\n    <metadata key="name" value="${ob.name}"/>\n    <metadata key="extruder" value="${ob.extruder}"/>\n`
      + ob.parts.map((pt) => `    <part id="${pt.id}" subtype="normal_part">\n      <metadata key="name" value="${pt.name}"/>\n      <metadata key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>\n      <metadata key="extruder" value="${pt.extruder}"/>\n      <mesh_stat face_count="12" edges_fixed="0" degenerate_facets="0" facets_removed="0" facets_reversed="0" backwards_edges="0"/>\n    </part>\n`).join('')
      + '  </object>\n').join('')
    + plateNames.map((pn, pi) => {
      const insts = objs.flatMap((ob) => ob.items.map((p, i) => ({ ob, i, plate: i >= 2 && o.sharedObject && ob.id === 9 ? 2 : ob.plate })))
        .filter((x) => x.plate === pi);
      return `  <plate>\n    <metadata key="plater_id" value="${pi + 1}"/>\n    <metadata key="plater_name" value="${pn}"/>\n    <metadata key="locked" value="false"/>\n`
        + `    <metadata key="thumbnail_file" value="Metadata/plate_${pi + 1}.png"/>\n    <metadata key="thumbnail_no_light_file" value="Metadata/plate_no_light_${pi + 1}.png"/>\n`
        + `    <metadata key="top_file" value="Metadata/top_${pi + 1}.png"/>\n    <metadata key="pick_file" value="Metadata/pick_${pi + 1}.png"/>\n    <metadata key="pattern_bbox_file" value="Metadata/plate_${pi + 1}.json"/>\n`
        + insts.map((x) => `    <model_instance>\n      <metadata key="object_id" value="${x.ob.id}"/>\n      <metadata key="instance_id" value="${x.i}"/>\n      <metadata key="identify_id" value="${x.ob.id * 100 + x.i}"/>\n    </model_instance>\n`).join('')
        + '  </plate>\n';
    }).join('')
    + '  <assemble>\n'
    + objs.flatMap((ob) => ob.items.map((p, i) => `   <assemble_item object_id="${ob.id}" instance_id="${i}" transform="${tr(p[0], p[1], 0)}" offset="0 0 0" />\n`)).join('')
    + '  </assemble>\n</config>\n';
  add('Metadata/model_settings.config', ms);

  add('Metadata/project_settings.config', JSON.stringify({
    printer_model: 'Bambu Lab X1 Carbon', printer_settings_id: 'Bambu Lab X1 Carbon 0.4 nozzle',
    nozzle_diameter: ['0.4'], layer_height: '0.2',
    printable_area: ['0x0', `${BED}x0`, `${BED}x${BED}`, `0x${BED}`], printable_height: '250',
    filament_colour: COLOURS, filament_type: ['PLA', 'PLA', 'PLA', 'PETG'],
    filament_settings_id: ['Bambu PLA Basic @BBL X1C', 'Bambu PLA Basic @BBL X1C', 'Bambu PLA Basic @BBL X1C', 'Bambu PETG HF @BBL X1C'],
    nozzle_temperature: ['220', '220', '220', '250'],
  }, null, 4));
  add('Metadata/slice_info.config', '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n  <header>\n    <header_item key="X-BBL-Client-Type" value="slicer"/>\n    <header_item key="X-BBL-Client-Version" value="01.10.02.76"/>\n  </header>\n'
    + '  <plate>\n    <metadata key="index" value="3"/>\n    <metadata key="prediction" value="1200"/>\n    <metadata key="weight" value="3.10"/>\n    <object identify_id="1000" name="Sign" skipped="false" />\n    <filament id="4" tray_info_idx="GFG99" type="PETG" color="#2050E0" used_m="1.02" used_g="3.10" />\n  </plate>\n</config>\n');
  add('Metadata/custom_gcode_per_layer.xml', '<?xml version="1.0" encoding="utf-8"?>\n<custom_gcodes_per_layer>\n'
    + '<plate>\n<plate_info id="2"/>\n<layer top_z="4" type="1" extruder="1" color="" extra="" gcode="M400 U1"/>\n<mode value="SingleExtruder"/>\n</plate>\n'
    + '</custom_gcodes_per_layer>\n');
  add('Metadata/filament_sequence.json', JSON.stringify({ plate_1: { sequence: [] }, plate_2: { sequence: [3, 1] }, plate_3: { sequence: [] } }));
  // Position-keyed (1-based, model order 2,5,7,9,11): object 5 is position 2, object 11 is 5,
  // object 7 (on plate 2) is 3.
  add('Metadata/layer_heights_profile.txt', 'object_id=2|0;0.2;4;0.2;4;0.12;10;0.12\nobject_id=5|0;0.2;10;0.28\n');
  add('Metadata/cut_information.xml', '<?xml version="1.0" encoding="utf-8"?>\n<objects>\n <object id="3">\n  <cut_id id="0" check_sum="1" connectors_cnt="0"/>\n </object>\n</objects>\n');
  const plateHex = ['#C0C0C0', '#E02020', '#2050E0'];
  for (let pi = 0; pi < 3; pi++) {
    const n = pi + 1;
    add(`Metadata/plate_${n}.png`, png(plateHex[pi], 32));
    add(`Metadata/plate_${n}_small.png`, png(plateHex[pi], 16));
    add(`Metadata/plate_no_light_${n}.png`, png(plateHex[pi], 16));
    add(`Metadata/top_${n}.png`, png('#000000', 8));
    add(`Metadata/pick_${n}.png`, png('#FFFFFF', 8));
    add(`Metadata/plate_${n}.json`, JSON.stringify({ bbox_objects: [], bed_type: 'textured_plate', version: 2 }));
  }
  add('Auxiliaries/.thumbnails/thumbnail_3mf.png', png('#808080', 8));
  return writeZip(files);
}

module.exports = { buildMultiPlate3mf, png, COLOURS, BED, STRIDE };
