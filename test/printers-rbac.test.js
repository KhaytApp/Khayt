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

test('main reads the active role from the same fields as the renderer, and fails closed', () => {
  const ops = [{ id: 'O1', roleKey: 'viewer' }, { id: 'O2', role: 'Technician' }];
  assert.deepEqual(P.activeRole({ settings: {} }), { lock: false, role: 'owner' });
  // Nothing read at all: refuse (#2592 security review, M2).
  assert.deepEqual(P.activeRole({}), { lock: true, role: null });
  assert.deepEqual(P.activeRole(null), { lock: true, role: null });
  // The lock on and nobody signed in, or an id that names nobody: refuse,
  // where the renderer's screens read the owner.
  assert.deepEqual(P.activeRole({ settings: { operatorLockEnabled: true }, operators: ops }), { lock: true, role: null });
  assert.deepEqual(P.activeRole({ settings: { operatorLockEnabled: true, activeOperatorId: 'GHOST' }, operators: ops }), { lock: true, role: null });
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
  assert.equal(P.printerAllowed({}, 'send').ok, false, 'no store read: refused');
  assert.equal(P.printerAllowed(store('GHOST'), 'send').ok, false, 'an unknown operator is nobody, not the owner');
  assert.equal(P.printerAllowed(store(null), 'send').ok, false, 'nobody signed in under the lock');
});

/* ── The save guard (#2592 security review, M2 and L1) ─────────────────── */

const ops = () => [
  { id: 'OWN', roleKey: 'owner', pinHash: 'h-own' },
  { id: 'VIEW', roleKey: 'viewer', pinHash: 'h-view' },
  { id: 'OPR', roleKey: 'operator', pinHash: 'h-opr' },
  { id: 'FREE', roleKey: 'operator' },
];
const book = (active, extra) => Object.assign({
  settings: { operatorLockEnabled: true, activeOperatorId: active, roleLimits: { operator: { printers: { unlink: false } } } },
  operators: ops(),
  machines: [{ id: 'M1', name: 'U1', printerApi: { type: 'moonraker', host: '192.168.1.5' } }, { id: 'M2', name: 'Shelf' }],
}, extra || {});
const edit = (b, fn) => { const c = JSON.parse(JSON.stringify(b)); fn(c); return c; };

test('a book with the lock OFF on disk saves exactly as today (that is how the lock goes on)', () => {
  const disk = { settings: { operatorLockEnabled: false }, operators: [] };
  const incoming = edit(book('OWN'), () => {});
  assert.equal(P.guardSave(incoming, disk).store, incoming);
});

test('a viewer cannot turn the lock off, loosen limits, raise a role, add an operator or take the owner\'s PIN', () => {
  const disk = book('VIEW');
  for (const [what, fn] of [
    ['lock off', (c) => { c.settings.operatorLockEnabled = false; }],
    ['limits gone', (c) => { delete c.settings.roleLimits; }],
    ['self to owner', (c) => { c.operators[1].roleKey = 'owner'; }],
    ['new operator', (c) => { c.operators.push({ id: 'X', roleKey: 'owner' }); }],
    ['owner PIN', (c) => { c.operators[0].pinHash = 'h-mine-now'; }],
  ]) {
    const g = P.guardSave(edit(disk, fn), disk);
    assert.ok(g.refused.length, what);
    assert.deepEqual(g.store.settings.operatorLockEnabled, true, what);
    assert.deepEqual(g.store.settings.roleLimits, disk.settings.roleLimits, what);
    assert.deepEqual(g.store.operators.map((o) => [o.id, o.roleKey, o.pinHash]), disk.operators.map((o) => [o.id, o.roleKey, o.pinHash]), what);
  }
  // Their own PIN they may change.
  const own = P.guardSave(edit(disk, (c) => { c.operators[1].pinHash = 'h-view-2'; }), disk);
  assert.equal(own.store.operators[1].pinHash, 'h-view-2');
});

test('the owner signed in on disk may change all of it', () => {
  const disk = book('OWN');
  const incoming = edit(disk, (c) => { c.settings.roleLimits = {}; c.operators[1].roleKey = 'manager'; c.operators.push({ id: 'NEW', roleKey: 'operator' }); });
  const g = P.guardSave(incoming, disk);
  assert.deepEqual(g.refused, []);
  assert.equal(g.store, incoming);
});

test('a save cannot sign someone in whom main has not verified (unless they have no PIN)', () => {
  const disk = book('VIEW');
  const toOwner = edit(disk, (c) => { c.settings.activeOperatorId = 'OWN'; });
  assert.equal(P.guardSave(toOwner, disk).store.settings.activeOperatorId, 'VIEW', 'not verified: stays the viewer');
  assert.equal(P.guardSave(toOwner, disk, { verified: (id) => id === 'OWN' }).store.settings.activeOperatorId, 'OWN', 'verified: allowed');
  assert.equal(P.guardSave(edit(disk, (c) => { c.settings.activeOperatorId = 'FREE'; }), disk).store.settings.activeOperatorId, 'FREE', 'no PIN: a free switch');
  assert.equal(P.guardSave(edit(disk, (c) => { c.settings.activeOperatorId = 'GHOST'; }), disk, { verified: () => true }).store.settings.activeOperatorId, 'VIEW', 'nobody by that id');
  assert.equal(P.guardSave(edit(disk, (c) => { c.settings.activeOperatorId = null; }), disk).store.settings.activeOperatorId, null, 'signing out');
});

test('L1: a printer\'s connection and unlinking follow the printers rights', () => {
  const viewer = book('VIEW');
  const moved = P.guardSave(edit(viewer, (c) => { c.machines[0].printerApi.host = '10.0.0.66'; c.machines[0].printerApi.apiKey = 'stolen'; }), viewer);
  assert.deepEqual(moved.store.machines[0].printerApi, viewer.machines[0].printerApi, 'a viewer cannot repoint a printer');
  assert.ok(moved.refused.includes('machines.M1:connection'));
  const gone = P.guardSave(edit(viewer, (c) => { c.machines = c.machines.filter((m) => m.id !== 'M1'); }), viewer);
  assert.ok(gone.store.machines.some((m) => m.id === 'M1'), 'a viewer cannot unlink');
  const added = P.guardSave(edit(viewer, (c) => { c.machines.push({ id: 'M9', printerApi: { type: 'octoprint', host: '1.2.3.4' } }); }), viewer);
  assert.equal(added.store.machines.find((m) => m.id === 'M9').printerApi, undefined, 'nor link a new one');
  const opr = book('OPR');
  const ok = P.guardSave(edit(opr, (c) => { c.machines[0].printerApi.host = '192.168.1.9'; }), opr);
  assert.equal(ok.store.machines[0].printerApi.host, '192.168.1.9', 'an operator edits the connection, as today');
  const unlink = P.guardSave(edit(opr, (c) => { c.machines = c.machines.filter((m) => m.id !== 'M1'); }), opr);
  assert.ok(unlink.store.machines.some((m) => m.id === 'M1'), 'operators may not unlink');
  // A machine with no printer link is not a printer: anyone may remove it.
  const shelf = P.guardSave(edit(viewer, (c) => { c.machines = c.machines.filter((m) => m.id !== 'M2'); }), viewer);
  assert.ok(!shelf.store.machines.some((m) => m.id === 'M2'));
  // Renaming is not the connection.
  assert.deepEqual(P.guardSave(edit(viewer, (c) => { c.machines[0].name = 'Big U1'; }), viewer).refused, []);
});

/* ── The ratchet, on CALLS (#2592 security review, H1 and M3) ─────────────── */

/** Brace-match from `open` (the index of a '{'). */
function braceFrom(src, open) {
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    const c = src[i];
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return src.slice(open, i + 1); }
  }
  return src.slice(open);
}

/** A handler's body: after its `=>`, a block, or an expression up to the registration's `);`. */
function handlerBody(src, from) {
  const arrow = src.indexOf('=>', from);
  const rest = src.slice(arrow + 2);
  const lead = rest.match(/^\s*/)[0].length;
  if (rest[lead] === '{') return braceFrom(src, arrow + 2 + lead);
  return src.slice(arrow, src.indexOf(');', arrow) + 2);
}

/** A function declaration's body: the '{' after the parameter list's ')'. */
function functionBody(src, from) {
  const m = /\)\s*\{/g; m.lastIndex = from;
  const hit = m.exec(src);
  return hit ? braceFrom(src, hit.index + hit[0].length - 1) : '';
}

test('every handler that can reach a printer calls printerGate before it does (main.js and lib/main, handle and on)', () => {
  const root = path.join(__dirname, '..');
  const files = ['main.js', ...fs.readdirSync(path.join(root, 'lib', 'main')).filter((f) => f.endsWith('.js')).map((f) => 'lib/main/' + f)];
  // What reaches a printer, then every top-level function in main.js that calls one, to a fixed point.
  const SINKS = ['uploadGcodeToPrinter', 'sendPrinterCommand', 'sendPrinterControl', 'bambuSendCommand'];
  const main = fs.readFileSync(path.join(root, 'main.js'), 'utf8');
  const fns = {};
  for (const m of main.matchAll(/^(?:async )?function ([A-Za-z0-9_$]+)\(/gm)) fns[m[1]] = functionBody(main, m.index);
  const reach = new Set(SINKS);
  for (let grew = true; grew;) {
    grew = false;
    for (const [name, body] of Object.entries(fns)) {
      if (reach.has(name)) continue;
      if ([...reach].some((r) => new RegExp('\\b' + r + '\\(').test(body))) { reach.add(name); grew = true; }
    }
  }
  const touched = [];
  for (const file of files) {
    const src = fs.readFileSync(path.join(root, file), 'utf8');
    for (const m of src.matchAll(/ipcMain\.(handle|on)\(\s*'([^']+)'/g)) {
      const body = handlerBody(src, m.index + m[0].length);
      const hits = [...reach].map((r) => ({ r, at: body.search(new RegExp('\\b' + r + '\\(')) })).filter((h) => h.at !== -1);
      if (!hits.length) continue;
      touched.push(m[2]);
      const gate = body.search(/printerGate\('(send|control)'\)/);
      const first = Math.min(...hits.map((h) => h.at));
      assert.ok(gate !== -1 && gate < first, `${file} ${m[2]} reaches ${hits.map((h) => h.r).join(', ')} without printerGate first`);
    }
  }
  // The channels this finds today, so a scan that silently finds nothing fails too.
  for (const ch of ['hub:printer-send-gcode', 'hub:slice-and-print', 'hub:print-order-file', 'hub:printer-command', 'hub:printer-control']) {
    assert.ok(touched.includes(ch), ch + ' found by the scan');
  }
});

test('the smart plug switches only through the gate it is handed (on/off), and main hands it printerGate', () => {
  const sp = fs.readFileSync(path.join(__dirname, '..', 'lib', 'main', 'smart-plug.js'), 'utf8');
  const at = sp.indexOf("ipcMain.handle('hub:smart-plug'");
  const body = handlerBody(sp, at);
  assert.ok(body.indexOf("gate('control')") !== -1 && body.indexOf("gate('control')") < body.indexOf('return send('), 'gated before send');
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /registerSmartPlug\(\{[\s\S]{0,200}gate: \(verb\) => printerGate\(verb\)/);
});

test('hub:print-order-file is gated (#2592 security review, H1: kanban starts prints through it)', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const body = handlerBody(main, main.indexOf("ipcMain.handle('hub:print-order-file'"));
  assert.ok(body.indexOf("printerGate('send')") !== -1 && body.indexOf("printerGate('send')") < body.indexOf('uploadGcodeToPrinter('));
});

test('every save goes through guardSave, and a guard failure refuses the save', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const body = handlerBody(main, main.indexOf("ipcMain.handle('hub:save-store'"));
  const g = body.indexOf('PrinterPermission.guardSave(');
  assert.ok(g !== -1 && g < body.indexOf('atomicWriteStore('), 'guarded before the write');
  assert.match(body, /role guard failed[\s\S]{0,120}return \{ ok: false, error: 'role_guard_failed' \}/);
});
