'use strict';

/**
 * Writes test/fixtures/two-plate-bambu.gcode.3mf — a Bambu Studio "export all
 * sliced plates" project cut down to what the readers look at:
 *
 *   Metadata/slice_info.config     one <plate> per plate, each with its own
 *                                  prediction (s) and per-filament used_g/used_m
 *   Metadata/model_settings.config the shop's plate names, by plater_id
 *   Metadata/plate_1.gcode         each plate's own G-code header
 *   Metadata/plate_2.gcode
 *   3D/3dmodel.model               a 20 mm tetrahedron
 *
 * Plate 1 "Body": 1 h 30 min, slot 1 #000000 PLA 30.5 g + slot 2 #FFFFFF PLA 4.25 g
 * Plate 2 "Lid":  2 h 3 min,  slot 1 #000000 PLA 12 g   + slot 3 #C12E1F PETG 20.75 g
 * The project:    3 h 33 min (213 min), 67.5 g; slot 1 = 42.5 g over both plates.
 *
 * Both apps' tests read the SAME bytes (test/extract-meta-plates.test.js and
 * mac/KhaytCore/Tests/KhaytAppTests/SlicerFiguresTests.swift), so the two
 * readers are held to one answer. Re-run with `node test/fixtures/make-two-plate-3mf.js`.
 */
const fs = require('node:fs');
const path = require('node:path');
const { writeZip } = require('../../lib/zip-write.js');

const TETRA = '<?xml version="1.0"?><model unit="millimeter"><resources>'
  + '<object id="1" type="model"><mesh><vertices>'
  + '<vertex x="0" y="0" z="0"/><vertex x="20" y="0" z="0"/>'
  + '<vertex x="0" y="20" z="0"/><vertex x="0" y="0" z="20"/>'
  + '</vertices><triangles>'
  + '<triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/>'
  + '<triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/>'
  + '</triangles></mesh></object></resources>'
  + '<build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/></build></model>';

const SLICE_INFO = `<?xml version="1.0" encoding="UTF-8"?>
<config>
  <header>
    <header_item key="X-BBL-Client-Type" value="slicer"/>
    <header_item key="X-BBL-Client-Version" value="02.02.00.85"/>
  </header>
  <plate>
    <metadata key="index" value="1"/>
    <metadata key="printer_model_id" value="C12"/>
    <metadata key="nozzle_diameters" value="0.4"/>
    <metadata key="prediction" value="5400"/>
    <metadata key="weight" value="34.75"/>
    <object identify_id="101" name="Body" skipped="false" />
    <filament id="1" tray_info_idx="GFA01" type="PLA" color="#000000" used_m="10.23" used_g="30.50" />
    <filament id="2" tray_info_idx="GFA01" type="PLA" color="#FFFFFF" used_m="1.42" used_g="4.25" />
  </plate>
  <plate>
    <metadata key="index" value="2"/>
    <metadata key="printer_model_id" value="C12"/>
    <metadata key="nozzle_diameters" value="0.4"/>
    <metadata key="prediction" value="7380"/>
    <metadata key="weight" value="32.75"/>
    <object identify_id="202" name="Lid" skipped="false" />
    <filament id="1" tray_info_idx="GFA01" type="PLA" color="#000000" used_m="4.02" used_g="12.00" />
    <filament id="3" tray_info_idx="GFG99" type="PETG" color="#C12E1F" used_m="6.55" used_g="20.75" />
  </plate>
</config>
`;

const MODEL_SETTINGS = `<?xml version="1.0" encoding="UTF-8"?>
<config>
  <object id="1"><metadata key="name" value="Body"/></object>
  <plate>
    <metadata key="plater_id" value="1"/>
    <metadata key="plater_name" value="Body"/>
    <model_instance><metadata key="object_id" value="1"/><metadata key="instance_id" value="0"/></model_instance>
  </plate>
  <plate>
    <metadata key="plater_id" value="2"/>
    <metadata key="plater_name" value="Lid"/>
  </plate>
</config>
`;

const gcode = (time, grams, type) => [
  '; HEADER_BLOCK_START',
  '; BambuStudio 02.02.00.85',
  `; model printing time: ${time}; total estimated time: ${time}`,
  '; total layer number: 120',
  `; total filament weight [g] : ${grams}`,
  '; HEADER_BLOCK_END',
  `; filament_type = ${type}`,
  'G28',
].join('\n') + '\n';

const members = [
  ['3D/3dmodel.model', TETRA],
  ['Metadata/slice_info.config', SLICE_INFO],
  ['Metadata/model_settings.config', MODEL_SETTINGS],
  ['Metadata/plate_1.gcode', gcode('1h 30m 0s', '30.50,4.25', 'PLA;PLA')],
  ['Metadata/plate_2.gcode', gcode('2h 3m 0s', '12.00,20.75', 'PLA;PETG')],
];

const out = path.join(__dirname, 'two-plate-bambu.gcode.3mf');
fs.writeFileSync(out, writeZip(members.map(([name, text]) => ({ name, data: Buffer.from(text, 'utf8') }))));
if (require.main === module) console.log('wrote', out);
