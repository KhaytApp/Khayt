'use strict';
/**
 * lib/orca-db.js against fixture profile trees, whatever slicer this machine has installed.
 *
 *   - A machine whose declared default process does not exist ("0.20 Standard @X" where the file is
 *     "0.20mm Standard @X", as Snapmaker's own U1 machines ship) resolves to the real one.
 *   - A profile file with a UTF-8 byte-order mark (as Snapmaker ships the U1 default and its base)
 *     resolves to its settings, not to nothing.
 *   - A vendor kept only in a packed OrcaSlicer 2.5 archive (`<Vendor>.opc`, starting "ZCRO") is
 *     reported as such; one that is also present as loose files elsewhere is not; a stray .opc that
 *     is not that format is ignored.
 *
 * The .opc here is a synthetic header only: no OrcaSlicer data is copied.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const db = require('../lib/orca-db');

const BOM = '﻿';
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'orca-db-fixture-'));
const write = (rel, text) => { const f = path.join(tmp, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, text); };
const json = (o, bom) => (bom ? BOM : '') + JSON.stringify(o, null, 2);
// A packed archive's first bytes: magic, version 2, then (here) nothing real.
const opc = () => Buffer.concat([Buffer.from('ZCRO', 'latin1'), Buffer.from([2, 0, 0, 0]), Buffer.alloc(24)]);

// Loose tree, as Snapmaker Orca ships it.
const loose = path.join(tmp, 'loose');
write('loose/Acme/machine/Acme X (0.4 nozzle).json', json({
  name: 'Acme X (0.4 nozzle)', nozzle_diameter: ['0.4'], printable_area: ['0x0', '200x0', '200x200', '0x200'],
  default_print_profile: '0.20 Standard @Acme X (0.4 nozzle)',
}));
write('loose/Acme/process/fdm_process_common.json', json({ name: 'fdm_process_common', wall_loops: '2', layer_height: '0.2' }, true));
write('loose/Acme/process/0.20mm Standard @Acme X (0.4 nozzle).json', json({
  name: '0.20mm Standard @Acme X (0.4 nozzle)', inherits: 'fdm_process_common', sparse_infill_density: '15%',
}, true));
write('loose/Acme/process/0.08mm Standard @Acme X (0.4 nozzle).json', json({
  name: '0.08mm Standard @Acme X (0.4 nozzle)', inherits: 'fdm_process_common', layer_height: '0.08',
}));

// Packed tree, as upstream OrcaSlicer 2.5 ships it: archives, and image-only vendor folders.
const packed = path.join(tmp, 'packed');
write('packed/Acme.opc', opc());
write('packed/Zed.opc', opc());
write('packed/Zed/Zed One_cover.png', 'png');
write('packed/NotOrca.opc', 'PK\u0003\u0004 not an Orca archive');

test.after(() => { db.useRoots(null); fs.rmSync(tmp, { recursive: true, force: true }); });

test('a declared default that does not exist resolves to the preset the vendor really ships', () => {
  db.useRoots([loose]);
  assert.equal(db.defaultProcessFor('Acme X (0.4 nozzle)'), '0.20mm Standard @Acme X (0.4 nozzle)');
});

test('a profile with a byte-order mark resolves, with its inherited settings', () => {
  db.useRoots([loose]);
  const s = db.resolvePreset('process', '0.20mm Standard @Acme X (0.4 nozzle)');
  assert.equal(s.sparse_infill_density, '15%');
  assert.equal(s.wall_loops, '2', 'from the BOM-marked base');
  assert.equal(s.layer_height, '0.2');
});

test('the processes listed for a machine are its own, finest first', () => {
  db.useRoots([loose]);
  assert.deepEqual(db.listProcessesFor('Acme X (0.4 nozzle)').map((p) => p.layer), ['0.08', '0.2']);
});

test('packed-only vendors are named; readable and foreign archives are not', () => {
  db.useRoots([loose, packed]);
  assert.deepEqual(db.packedOnlyVendors(), ['Zed'], 'Acme is readable from the loose tree; NotOrca is not an Orca archive');
  db.useRoots([packed]);
  assert.deepEqual(db.packedOnlyVendors(), ['Acme', 'Zed']);
  assert.equal(db.defaultProcessFor('Acme X (0.4 nozzle)'), null, 'nothing readable: no default to offer');
  assert.deepEqual(db.listProcessesFor('Acme X (0.4 nozzle)'), []);
});
