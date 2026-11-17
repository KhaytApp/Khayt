'use strict';
/**
 * Writes the synthetic 3MFs in this folder and `expected.json`, what
 * lib/thumbnail-extract.js colours3mf reads from each. Run by hand
 * (`node test/fixtures/library-colours/make.js`) when the cases change;
 * test/library-colours-fixtures.test.js holds the files to what the rule says,
 * and the Mac's ColourReadTests reads the same files through its own path
 * (ColourRead: streamed paint check, the mesh through mf-mesh, the configs).
 * Sample data only.
 */
const fs = require('fs');
const path = require('path');
const Mesh = require('../../../lib/mf-mesh.js');
const T = require('../../../lib/thumbnail-extract.js');
const { writeZip } = require('../../../lib/zip-write.js');

const LOADED8 = ['#111111', '#222222', '#333333', '#444444', '#555555', '#666666', '#777777', '#888888'];
const project = (colours) => JSON.stringify({ filament_colour: colours, filament_type: colours.map(() => 'PLA') });
const settings = (extruder) => '<?xml version="1.0"?>\n<config>\n<object id="1">\n  <metadata key="name" value="obj1"/>\n' +
  `  <metadata key="extruder" value="${extruder}"/>\n</object>\n<plate>\n  <metadata key="plater_id" value="1"/>\n` +
  '  <model_instance><metadata key="object_id" value="1"/></model_instance>\n</plate>\n</config>';
function threeMf({ loaded, extruder, paints, slice }) {
  const tris = paints.map((p, k) => `<triangle v1="0" v2="1" v3="${2 + (k % 2)}"${p != null ? ` paint_color="${p}"` : ''}/>`).join('');
  const model = '<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>' +
    `<object id="1" type="model"><mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="10" y="10" z="0"/></vertices><triangles>${tris}</triangles></mesh></object>` +
    '</resources><build><item objectid="1"/></build></model>';
  const members = [
    { name: '3D/3dmodel.model', data: model },
    { name: 'Metadata/project_settings.config', data: project(loaded) },
    { name: 'Metadata/model_settings.config', data: settings(extruder) },
  ];
  if (slice) members.push({ name: 'Metadata/slice_info.config', data: slice });
  return writeZip(members.map((m) => ({ name: m.name, data: Buffer.from(m.data) })));
}
const SPLIT_0_2 = Mesh.bitsToHex([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
const cases = {
  // Four loaded, the one object on slot 4: one colour, the fourth.
  'unpainted-slot4.3mf': threeMf({ loaded: LOADED8.slice(0, 4), extruder: 4, paints: [null, null] }),
  // Eight loaded, painted with 2 and 5 and a split (own filament 1, and 2): three.
  'painted-1-2-5.3mf': threeMf({ loaded: LOADED8, extruder: 1, paints: [Mesh.encodeSolidPaint(2), Mesh.encodeSolidPaint(5), SPLIT_0_2] }),
  // Sliced: the slice names the colours; one printed at 0 g is dropped.
  'sliced.3mf': threeMf({ loaded: LOADED8.slice(0, 3), extruder: 1, paints: [null],
    slice: '<config><plate><filament id="1" color="#111111" used_g="4.2"/><filament id="2" color="#222222" used_g="0"/><filament id="3" color="#333333" used_g="1.5"/></plate></config>' }),
};
// What an UNSLICED Bambu/Orca project carries as slice_info.config: a header,
// no <filament>. Beta.38's Mac took it for a slice and skipped the paint, so
// a model painted in five kept one dot (reader 3).
const STUB_SLICE = '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n  <header>\n' +
  '    <header_item key="X-BBL-Client-Type" value="slicer"/>\n    <header_item key="X-BBL-Client-Version" value="02.00.00.00"/>\n' +
  '  </header>\n</config>\n';
// Eight loaded, painted with 2 and 5 and a split, and a stub slice: the same three.
cases['painted-stub-slice.3mf'] = threeMf({ loaded: LOADED8, extruder: 1,
  paints: [Mesh.encodeSolidPaint(2), Mesh.encodeSolidPaint(5), SPLIT_0_2], slice: STUB_SLICE });
// The Orca layout: the root model only assembles; each part's mesh is its own
// member. Part 1 is painted with 3 and keeps some faces (object's filament 2);
// part 2 is on filament 6 and painted with 7 all over. The paint's slots are
// 2, 3, 7; the colours add 6, which model_settings names for part 2.
function twoMembers(store) {
  const V = '<vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/></vertices>';
  const part = (id, paints) => '<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"><resources>' +
    `<object id="${id}" type="model"><mesh>${V}<triangles>${paints.map((p) => `<triangle v1="0" v2="1" v3="2"${p != null ? ` paint_color="${p}"` : ''}/>`).join('')}</triangles></mesh></object></resources></model>`;
  const root = '<?xml version="1.0" encoding="UTF-8"?><model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06"><resources>' +
    '<object id="10" type="model"><components><component p:path="/3D/Objects/part_1.model" objectid="1"/><component p:path="/3D/Objects/part_2.model" objectid="2"/></components></object>' +
    '</resources><build><item objectid="10"/></build></model>';
  const ms = '<?xml version="1.0"?>\n<config>\n<object id="10">\n  <metadata key="name" value="assembly"/>\n  <metadata key="extruder" value="2"/>\n' +
    '  <part id="1" subtype="normal_part"><metadata key="name" value="a"/></part>\n' +
    '  <part id="2" subtype="normal_part"><metadata key="name" value="b"/><metadata key="extruder" value="6"/></part>\n</object>\n</config>';
  return writeZip([
    { name: '3D/3dmodel.model', data: root },
    { name: '3D/Objects/part_1.model', data: part(1, [Mesh.encodeSolidPaint(3), null]) },
    { name: '3D/Objects/part_2.model', data: part(2, [Mesh.encodeSolidPaint(7), Mesh.encodeSolidPaint(7)]) },
    { name: 'Metadata/project_settings.config', data: project(LOADED8) },
    { name: 'Metadata/model_settings.config', data: ms },
    { name: 'Metadata/slice_info.config', data: STUB_SLICE },
  ].map((m) => ({ name: m.name, data: Buffer.from(m.data), store: !!store })));
}
cases['painted-two-members.3mf'] = twoMembers();
// The same project with every member STORED (method 0), as some writers leave
// them: a stored member is read at its packed size whatever its entry
// declares, which is what the Mac's size budgets are tested against.
cases['painted-two-members-stored.3mf'] = twoMembers(true);
const expected = {};
for (const [name, buf] of Object.entries(cases)) {
  fs.writeFileSync(path.join(__dirname, name), buf);
  const r = T.colours3mf(buf);
  // The paint's slots as lib/mf-mesh.js decodes them, for the Mac's paint path.
  const mesh = Mesh.extractMeshFromBuffer(buf, 1);
  expected[name] = { hexes: r.colors.map((c) => c.hex), swapCount: r.swapCount, slotsKnown: r.slotsKnown, reader: r.reader,
    paintSlots: mesh && Array.isArray(mesh.slotsUsed) ? mesh.slotsUsed : null };
}
fs.writeFileSync(path.join(__dirname, 'expected.json'), JSON.stringify(expected, null, 2) + '\n');
console.log(JSON.stringify(expected));
