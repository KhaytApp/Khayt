const { test } = require('node:test');
const assert = require('node:assert/strict');
const A = require('../lib/assembly.js');

const asm = (parts, extra) => Object.assign({
  id: 'O1', components: [{ consumableId: 'c1', qtyPerUnit: 2 }], parts,
}, extra || {});

test('isAssembly only for orders with components', () => {
  assert.equal(A.isAssembly(asm([{}])), true);
  assert.equal(A.isAssembly({ id: 'O', parts: [{}, {}] }), false, 'multi-part alone is NOT an assembly');
  assert.equal(A.isAssembly({ id: 'O', components: [] }), false);
  assert.equal(A.isAssembly(null), false);
});

test('partStatusOf defaults unknown/missing to pending', () => {
  assert.equal(A.partStatusOf({}), 'pending');
  assert.equal(A.partStatusOf({ partStatus: 'bogus' }), 'pending');
  assert.equal(A.partStatusOf({ partStatus: 'qc_pass' }), 'qc_pass');
});

test('deriveAssemblyStatus: null for non-assemblies', () => {
  assert.equal(A.deriveAssemblyStatus({ id: 'O', parts: [{}] }), null);
});

test('deriveAssemblyStatus: pending while any part is unfinished or failed', () => {
  assert.equal(A.deriveAssemblyStatus(asm([{ partStatus: 'pending' }, { partStatus: 'qc_pass' }])), 'pending');
  assert.equal(A.deriveAssemblyStatus(asm([{ partStatus: 'printing' }, { partStatus: 'qc_pass' }])), 'pending');
  assert.equal(A.deriveAssemblyStatus(asm([{ partStatus: 'qc_fail' }, { partStatus: 'qc_pass' }])), 'pending',
    'a failed part blocks the rollup');
});

test('deriveAssemblyStatus: printed when all made but not all QC-passed', () => {
  assert.equal(A.deriveAssemblyStatus(asm([{ partStatus: 'printed' }, { partStatus: 'qc_pass' }])), 'printed');
});

test('deriveAssemblyStatus: assembled only when all pass AND the gate is ticked', () => {
  const allPass = [{ partStatus: 'qc_pass' }, { partStatus: 'qc_pass' }];
  assert.equal(A.deriveAssemblyStatus(asm(allPass)), 'printed', 'no tick → not assembled');
  assert.equal(A.deriveAssemblyStatus(asm(allPass, { assembledAt: '2026-07-20' })), 'assembled');
});

test('canCompleteAssembly: non-assemblies always pass (no behaviour change)', () => {
  const r = A.canCompleteAssembly({ id: 'O', parts: [{ partStatus: 'pending' }, { partStatus: 'pending' }] });
  assert.deepEqual(r, { ok: true, reason: null, remaining: [] });
});

test('canCompleteAssembly: blocks with the outstanding parts named', () => {
  const r = A.canCompleteAssembly(asm([{ name: 'body', partStatus: 'printing' }, { name: 'lid', partStatus: 'qc_pass' }]));
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'parts_incomplete');
  assert.deepEqual(r.remaining, [{ name: 'body', status: 'printing' }]);
});

test('canCompleteAssembly: all parts pass but not ticked → not_assembled', () => {
  const r = A.canCompleteAssembly(asm([{ partStatus: 'qc_pass' }]));
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'not_assembled');
  assert.deepEqual(r.remaining, []);
});

test('canCompleteAssembly: passes once all parts pass and it is ticked', () => {
  const r = A.canCompleteAssembly(asm([{ partStatus: 'qc_pass' }], { assembledAt: '2026-07-20' }));
  assert.equal(r.ok, true);
});

test('failedParts returns only qc_fail parts with their index', () => {
  const o = asm([{ name: 'a', partStatus: 'qc_pass' }, { name: 'b', partStatus: 'qc_fail' }]);
  const f = A.failedParts(o);
  assert.equal(f.length, 1);
  assert.equal(f[0].index, 1);
  assert.equal(f[0].part.name, 'b');
});
