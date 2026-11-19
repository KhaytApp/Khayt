'use strict';
/**
 * P5 (Prusa batch 1): the `printers` area in lib/rbac.js, canPrinter with the
 * shop's tightening, and the desktop's main-process gate on every printer IPC
 * that sends or controls (lib/main/printer-permission.js).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const R = require('../lib/rbac.js');
const P = require('../lib/main/printer-permission.js');

const VERBS = ['send', 'control', 'connection', 'unlink'];
const WANT = {
  owner: { send: true, control: true, connection: true, unlink: true },
  manager: { send: true, control: true, connection: true, unlink: true },
  operator: { send: true, control: true, connection: true, unlink: false },
  viewer: { send: false, control: false, connection: false, unlink: false },
};

test('the defaults: owner/manager everything, operator all but unlink (as orders/edit allowed), viewer none', () => {
  for (const role of R.ROLES) for (const v of VERBS) assert.equal(R.canPrinter(role, v), WANT[role][v], `${role} ${v}`);
  for (const role of R.ROLES) assert.equal(R.can(role, 'printers', 'view'), true, role + ' sees printers');
});

test('the lock off: everyone may, as RBAC has always said', () => {
  for (const role of R.ROLES) for (const v of VERBS) assert.equal(R.canPrinter(role, v, { lockEnabled: false }), true);
});

test('the shop can tighten a role, never loosen one, and never the owner', () => {
  const limits = { operator: { printers: { connection: false } }, viewer: { printers: { send: true } }, owner: { printers: { send: false } } };
  assert.equal(R.canPrinter('operator', 'connection', { limits }), false);
  assert.equal(R.canPrinter('operator', 'send', { limits }), true);
  assert.equal(R.canPrinter('viewer', 'send', { limits }), false, 'a limit gives nothing');
  assert.equal(R.canPrinter('owner', 'send', { limits }), true, 'the owner is never locked out');
  for (const junk of ['x', 7, null, { operator: 'no' }, { operator: { printers: 'no' } }]) assert.equal(R.canPrinter('operator', 'send', { limits: junk }), true);
});

test('unknown verbs and roles are refused (least privilege)', () => {
  assert.equal(R.canPrinter('owner', 'reflash'), false);
  assert.equal(R.canPrinter('intern', 'send'), false);
});

test('main reads the active role exactly as the renderer does', () => {
  const ops = [{ id: 'O1', roleKey: 'viewer' }, { id: 'O2', role: 'Technician' }];
  assert.deepEqual(P.activeRole({ settings: {} }), { lock: false, role: 'owner' });
  assert.deepEqual(P.activeRole({}), { lock: false, role: 'owner' });
  assert.deepEqual(P.activeRole({ settings: { operatorLockEnabled: true }, operators: ops }), { lock: true, role: 'owner' });
  assert.deepEqual(P.activeRole({ settings: { operatorLockEnabled: true, activeOperatorId: 'O1' }, operators: ops }), { lock: true, role: 'viewer' });
  assert.deepEqual(P.activeRole({ settings: { operatorLockEnabled: true, activeOperatorId: 'O2' }, operators: ops }), { lock: true, role: 'operator' });
  // The renderer's own function, read out of its source, agrees on each.
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'ops-locations.js'), 'utf8');
  assert.match(src, /function currentOperatorRoleKey\(\) \{\n  if \(!settings\.operatorLockEnabled\) return 'owner';\n  const activeOp = settings\.activeOperatorId \? operators\.find\(o => o\.id === settings\.activeOperatorId\) : null;\n  if \(!activeOp\) return 'owner';/);
});

test('a viewer with the lock on is refused send and control; an operator is not', () => {
  const store = (id) => ({ settings: { operatorLockEnabled: true, activeOperatorId: id }, operators: [{ id: 'V', roleKey: 'viewer' }, { id: 'OP', roleKey: 'operator' }] });
  assert.deepEqual(P.printerAllowed(store('V'), 'send'), { ok: false, error: 'not_permitted', verb: 'send', role: 'viewer' });
  assert.equal(P.printerAllowed(store('V'), 'control').ok, false);
  assert.equal(P.printerAllowed(store('OP'), 'send').ok, true);
  assert.equal(P.printerAllowed(store('OP'), 'control').ok, true);
  const tight = store('OP'); tight.settings.roleLimits = { operator: { printers: { control: false } } };
  assert.equal(P.printerAllowed(tight, 'control').ok, false);
  assert.equal(P.printerAllowed({ settings: {} }, 'control').ok, true, 'no lock: as today');
});

test('every printer IPC that sends or controls goes through printerGate first (ratchet)', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const GATED = { 'hub:printer-send-gcode': 'send', 'hub:slice-and-print': 'send', 'hub:printer-exclude-object': 'control',
    'hub:printer-command': 'control', 'hub:printer-control': 'control' };
  for (const [ch, verb] of Object.entries(GATED)) {
    const at = src.indexOf(`ipcMain.handle('${ch}'`);
    assert.ok(at !== -1, ch);
    const head = src.slice(at, at + 300);
    assert.ok(head.includes(`printerGate('${verb}')`), `${ch} checks ${verb} first`);
  }
  // A new printer channel must be listed here (gated) or as read-only.
  const READ_ONLY = ['hub:printer-plate', 'hub:printer-history', 'hub:probe-printer', 'hub:get-printer-status',
    'hub:start-printer-polling', 'hub:stop-printer-polling', 'hub:relocate-printers', 'hub:orca-printers'];
  const all = [...src.matchAll(/ipcMain\.handle\('(hub:[^']*printer[^']*)'/g)].map((m) => m[1]);
  for (const ch of all) assert.ok(GATED[ch] || READ_ONLY.includes(ch), `${ch} is neither gated nor listed read-only`);
});
