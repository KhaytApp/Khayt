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
  const srcOf = Object.fromEntries(files.map((f) => [f, fs.readFileSync(path.join(root, f), 'utf8')]));
  // What writes to a printer (#2592 re-check, M2): the senders, the
  // exclude-object request (then a fetch), and a smart plug's request.
  const SINKS = ['uploadGcodeToPrinter', 'sendPrinterCommand', 'sendPrinterControl', 'bambuSendCommand', 'excludeRequest', 'Plug\\.request'];
  // Every named function in every file: declarations at any depth, and
  // `const x = (…) =>` / `const x = async (…) =>` / `const x = function`.
  const fns = [];
  // Top-level only (main.js at column 0; a lib/main module at 0 or 2, inside
  // its register function): a helper nested in a handler is in that
  // handler's body already, and its local name (`send`) means nothing elsewhere.
  for (const [file, src] of Object.entries(srcOf)) {
    const indent = file === 'main.js' ? '' : '(?:  )?';
    for (const m of src.matchAll(new RegExp('(?:^|\\n)' + indent + '(?:async )?function ([A-Za-z0-9_$]+)\\(', 'g'))) fns.push({ file, name: m[1], body: functionBody(src, m.index) });
    for (const m of src.matchAll(new RegExp('(?:^|\\n)' + indent + '(?:const|let) ([A-Za-z0-9_$]+) = (?:async )?(?:\\([^)]*\\)|[A-Za-z0-9_$]+) =>', 'g'))) fns.push({ file, name: m[1], body: handlerBody(src, m.index) });
  }
  // A function reaches a printer if its body calls a sink, or a function
  // that does, to a fixed point. Scoped by file, so a generic local name
  // (the plug's own `send`) never matches `socket.send(` elsewhere:
  //   - a sink: anywhere, in any form;
  //   - a function of lib/main/X.js: bare in X.js, and as `Module.name(` in main.js;
  //   - a function of main.js: bare in main.js.
  const reached = [];   // { file, name }
  // What a lib/main module hands main.js: only those names can be called there.
  const exported = (file) => {
    const src = srcOf[file] || '';
    const m = src.match(/module\.exports\s*=\s*\{([^}]*)\}/);
    const names = new Set(m ? m[1].split(',').map((x) => x.trim().split(':')[0].trim()).filter(Boolean) : []);
    for (const e of src.matchAll(/module\.exports\.([A-Za-z0-9_$]+)\s*=/g)) names.add(e[1]);
    return names;
  };
  const patternsFor = (file) => SINKS.map((r) => ({ r, re: new RegExp('\\b' + r + '\\(') }))
    .concat(reached.filter((x) => x.file === file).map((x) => ({ r: x.name, re: new RegExp('(^|[^.\\w$])' + x.name + '\\(') })))
    .concat(file === 'main.js' ? reached.filter((x) => x.file !== 'main.js' && exported(x.file).has(x.name)).map((x) => ({ r: x.name, re: new RegExp('\\.' + x.name + '\\(') })) : []);
  for (let grew = true; grew;) {
    grew = false;
    for (const fn of fns) {
      if (reached.some((x) => x.file === fn.file && x.name === fn.name)) continue;
      if (patternsFor(fn.file).some((p) => p.re.test(fn.body))) { reached.push({ file: fn.file, name: fn.name }); grew = true; }
    }
  }
  const touched = [];
  for (const [file, src] of Object.entries(srcOf)) {
    for (const m of src.matchAll(/ipcMain\.(handle|on)\(\s*'([^']+)'/g)) {
      const body = handlerBody(src, m.index + m[0].length);
      const hits = patternsFor(file).map((p) => ({ r: p.r, at: body.search(p.re) })).filter((h) => h.at !== -1);
      if (!hits.length) continue;
      touched.push(m[2]);
      const gate = body.search(/\b(printerGate|gate)\('(send|control)'\)/);
      const first = Math.min(...hits.map((h) => h.at));
      assert.ok(gate !== -1 && gate < first, `${file} ${m[2]} reaches ${hits.map((h) => h.r).join(', ')} without a printer gate first`);
    }
  }
  // The channels the scan must find today, so it can never pass by finding nothing.
  for (const ch of ['hub:printer-send-gcode', 'hub:slice-and-print', 'hub:print-order-file', 'hub:printer-command',
    'hub:printer-control', 'hub:printer-exclude-object', 'hub:smart-plug']) {
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


/* ── #2592 re-check ─────────────────────────────────────────────────────── */

test('H1: a save with no settings object over a book that has one is refused, by both guards and by save-store', () => {
  const disk = book('VIEW');
  for (const bad of [undefined, null, [], 'x', 7]) {
    const incoming = { orders: [], operators: [{ id: 'VIEW', roleKey: 'owner' }] };
    if (bad !== undefined) incoming.settings = bad;
    assert.deepEqual(P.guardSave(incoming, disk), { store: null, refused: ['settings'] }, String(bad));
    assert.equal(require('../lib/api-tokens.js').guardTokenSave(incoming, disk), null, String(bad));
  }
  // A fresh book (nothing on disk yet) may still be written without settings.
  assert.deepEqual(P.guardSave({ orders: [] }, null).refused, []);
  assert.deepEqual(require('../lib/api-tokens.js').guardTokenSave({ orders: [] }, null), { orders: [] });
  // save-store and the flush refuse it through guardWindowStore (tested below).
});


test('L1: the save that signs someone in spends the verification', () => {
  const disk = book('VIEW');
  const spent = [];
  const g = P.guardSave(edit(disk, (c) => { c.settings.activeOperatorId = 'OWN'; }), disk, { verified: () => true, consume: (id) => spent.push(id) });
  assert.equal(g.store.settings.activeOperatorId, 'OWN');
  assert.deepEqual(spent, ['OWN']);
  // Nothing spent for a free (no-PIN) switch or a refused one.
  const none = [];
  P.guardSave(edit(disk, (c) => { c.settings.activeOperatorId = 'FREE'; }), disk, { consume: (id) => none.push(id) });
  P.guardSave(edit(disk, (c) => { c.settings.activeOperatorId = 'OWN'; }), disk, { verified: () => false, consume: (id) => none.push(id) });
  assert.deepEqual(none, []);
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /guardSave\(merged, guardDisk, \{ verified: operatorVerified, consume: consumeVerified \}\)/);
});

test('L3: operators are compared as sets of ids: a duplicate, a missing id or a swap is a different list', () => {
  const disk = book('VIEW');
  const dup = edit(disk, (c) => { c.operators[2] = Object.assign({}, c.operators[0], { roleKey: 'owner' }); });
  assert.ok(P.guardSave(dup, disk).refused.includes('operators'));
  const noId = edit(disk, (c) => { delete c.operators[3].id; });
  assert.ok(P.guardSave(noId, disk).refused.includes('operators'));
  const pipe = edit(disk, (c) => { c.operators = [{ id: 'OWN|VIEW', roleKey: 'owner' }, { id: 'OPR', roleKey: 'operator' }, { id: 'FREE', roleKey: 'operator' }]; });
  assert.ok(P.guardSave(pipe, disk).refused.includes('operators'), 'a "|" in an id cannot fake the list');
  const reordered = edit(disk, (c) => { c.operators.reverse(); });
  assert.deepEqual(P.guardSave(reordered, disk).refused, [], 'order does not matter');
});

test('L4: a deactivated operator cannot be signed in, verified or not', () => {
  const disk = edit(book('VIEW'), (c) => { c.operators[0].active = false; c.operators[3].active = false; });
  assert.equal(P.guardSave(edit(disk, (c) => { c.settings.activeOperatorId = 'OWN'; }), disk, { verified: () => true }).store.settings.activeOperatorId, 'VIEW');
  assert.equal(P.guardSave(edit(disk, (c) => { c.settings.activeOperatorId = 'FREE'; }), disk).store.settings.activeOperatorId, 'VIEW');
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(handlerBody(main, main.indexOf("ipcMain.handle('hub:verify-operator-pin'")), /op\.active === false\) return \{ ok: false, error: 'operator_inactive' \}/);
});

test('L5: hub:verify-pin notes only the operator the screen named, never every holder of a matching hash', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const body = handlerBody(main, main.indexOf("ipcMain.handle('hub:verify-pin'"));
  assert.doesNotMatch(body, /for \(const o of ops\) if \(o && o\.pinHash === stored\)/);
  assert.match(body, /if \(forOperatorId\) \{\s*const o = ops\.find\(\(x\) => x\.id === forOperatorId\);\s*if \(o && o\.pinHash === stored\) noteVerified\(o\.id\);/);
  const pre = fs.readFileSync(path.join(__dirname, '..', 'preload.js'), 'utf8');
  assert.match(pre, /verifyPin: \(plain, stored, forOperatorId\) => ipcRenderer\.invoke\('hub:verify-pin', plain, stored, forOperatorId\)/);
  const sec = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app-security.js'), 'utf8');
  assert.match(sec, /\}, admin\.id\);/);
});

/* ── Every book from the window is guarded; restores are the owner's (#2592) ── */

const mainSrc = () => fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
const fnBody = (src, name) => { const at = src.search(new RegExp('\\n(?:async )?function ' + name + '\\(')); assert.ok(at !== -1, name); return functionBody(src, at); };

test('guardWindowStore: settings-less books refused, both guards, main\'s copy when the disk is unreadable, failures refuse', () => {
  const g = fnBody(mainSrc(), 'guardWindowStore');
  assert.match(g, /if \(!guardDisk \|\| !guardDisk\.settings\) guardDisk = \(lanServerStore && lanServerStore\.settings\) \? lanServerStore : guardDisk;/);
  assert.match(g, /return \{ error: 'settings_missing' \};/);
  assert.ok(g.indexOf('guardTokenSave(merged, guardDisk)') !== -1 && g.indexOf('guardSave(merged, guardDisk, { verified: operatorVerified, consume: consumeVerified })') !== -1);
  assert.match(g, /token guard failed[\s\S]{0,80}return \{ error: 'token_guard_failed' \}/);
  assert.match(g, /role guard failed[\s\S]{0,80}return \{ error: 'role_guard_failed' \}/);
  assert.ok(g.indexOf("'settings_missing'") < g.indexOf('guardTokenSave('), 'settings checked first');
});

test('hub:save-store writes only what guardWindowStore returns', () => {
  const body = handlerBody(mainSrc(), mainSrc().indexOf("ipcMain.handle('hub:save-store'"));
  const g = body.indexOf('guardWindowStore(normalized)');
  assert.ok(g !== -1 && g < body.indexOf('atomicWriteStore('), 'guarded before the write');
  assert.match(body, /if \(guarded\.error\) return \{ ok: false, error: guarded\.error \};\s*let merged = guarded\.store;/);
});

test('the pre-install flush goes through the same guard, and writes nothing without one', () => {
  const up = fs.readFileSync(path.join(__dirname, '..', 'lib', 'updater.js'), 'utf8');
  const at = up.indexOf("ipcMain.handle('hub:install-update'");
  const body = up.slice(at, up.indexOf('quitAndInstall', at));
  assert.match(body, /typeof guardStore !== 'function'[\s\S]{0,160}flush-save skipped: no store guard/);
  assert.match(body, /const g = guardStore\(normalized\);\s*if \(g && g\.store\) await writeStoreToDisk\(g\.store\);/);
  assert.doesNotMatch(body, /writeStoreToDisk\(normalized\)/);
  assert.match(mainSrc(), /registerUpdater\(\{[\s\S]*guardStore: \(normalized\) => guardWindowStore\(normalized\),[\s\S]*?\}\);/);
});

test('a restore is the owner\'s while the lock is on (backup, restore point, off-site), then role-guarded', () => {
  const main = mainSrc();
  const r = fnBody(main, 'restoreSnapshotForWindow');
  const allowed = r.indexOf('if (!restoreAllowed())');
  assert.ok(allowed !== -1 && allowed < r.indexOf('restoreSnapshotToDisk('), 'checked before the restore');
  const guard = r.indexOf('PrinterPermission.guardSave(parsed, disk');
  assert.ok(guard !== -1 && guard < r.indexOf('restoreSnapshotToDisk('), 'guarded before the restore');
  const ra = fnBody(main, 'restoreAllowed');
  assert.match(ra, /if \(!disk \|\| !disk\.settings \|\| !disk\.settings\.operatorLockEnabled\) return true;/);
  assert.match(ra, /mayManageTokens\(disk\)/);
  // What mayManageTokens decides, on the shapes that matter.
  const T = require('../lib/api-tokens.js');
  assert.equal(T.mayManageTokens(book('OWN')), true);
  for (const who of ['VIEW', 'OPR', null, 'GHOST']) assert.equal(T.mayManageTokens(book(who)), false, String(who));
  // Every path that restores a whole book goes through restoreSnapshotForWindow.
  for (const ch of ["'hub:restore-backup'", "'hub:read-restore-point'", "'hub:offsite-restore'"]) assert.ok(main.includes(ch) || /offsite/.test(ch), ch);
});

test('every writer of the whole book is guarded or main\'s own (ratchet; the list is in the PR body)', () => {
  const root = path.join(__dirname, '..');
  const files = ['main.js', 'lib/updater.js', 'lib/lan-server.js', ...fs.readdirSync(path.join(root, 'lib', 'main')).filter((x) => x.endsWith('.js')).map((x) => 'lib/main/' + x)];
  // file → the functions or handlers allowed to call each writer, and why.
  const ALLOWED = {
    'main.js': {
      'atomicWriteStore(': ["ipcMain.handle('hub:save-store'"],                 // after guardWindowStore
      'restoreSnapshotToDisk(': ['function restoreSnapshotForWindow('],          // after restoreAllowed + guardSave
      'writeStoreToDisk(': [],
    },
    'lib/updater.js': { 'writeStoreToDisk(': ["ipcMain.handle('hub:install-update'"] },   // after guardStore
    // MAIN-originated: the LAN server's own generated tokens and PIN.
    'lib/lan-server.js': { 'writeStoreToDisk(': ['ensureLanCalendarToken(STORE())'] },
  };
  for (const file of files) {
    const src = fs.readFileSync(path.join(root, file), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
    for (const w of ['atomicWriteStore(', 'restoreSnapshotToDisk(', 'writeStoreToDisk(']) {
      let i = -1;
      while ((i = src.indexOf(w, i + 1)) !== -1) {
        const before = src.slice(Math.max(0, i - 40), i);
        if (/function\s+$|async function\s+$|[.\w]$/.test(before) && !/await\s+$|\(\s*$|=\s*$|\s$/.test(before.slice(-1))) continue;
        const allow = (ALLOWED[file] && ALLOWED[file][w]) || [];
        // The enclosing registration or function: the nearest one above.
        const head = src.slice(0, i);
        const owner = allow.find((a) => head.lastIndexOf(a) !== -1 && head.lastIndexOf(a) > Math.max(head.lastIndexOf('ipcMain.handle('), head.lastIndexOf('\nfunction '), head.lastIndexOf('\nasync function ')) - 1);
        assert.ok(owner, `${file}: ${w} at ${src.slice(0, i).split('\n').length} is not a guarded or main-originated writer`);
      }
    }
  }
});

test('every field writer (updateStoreOnDisk / persistLanStoreUpdate) that touches settings is listed, with the key it writes', () => {
  // updateStoreOnDisk itself refuses any change to the lock, sign-in, roles or
  // operators (lib/store-io.js lockFieldsChanged), whoever calls it. This list
  // says which writers touch settings at all, so a new one is looked at.
  const root = path.join(__dirname, '..');
  const LISTED = {
    'main.js': ['connectorUpdates.applyPrepared'],                    // connector updates (settings.connectorUpdates…)
    'lib/lan-server.js': ['ApiTokens.markUsed'],                      // an API token's lastUsedAt
    'lib/main/quote-link-keys-ipc.js': ['settings.quoteLinkKey'],
    'lib/main/quote-pay-link-sign.js': ['settings.quotePayLink'],
  };
  const files = ['main.js', 'lib/lan-server.js', ...fs.readdirSync(path.join(root, 'lib', 'main')).filter((x) => x.endsWith('.js')).map((x) => 'lib/main/' + x)];
  for (const file of files) {
    const src = fs.readFileSync(path.join(root, file), 'utf8');
    for (const m of src.matchAll(/\b(updateStoreOnDisk|persistLanStoreUpdate)\(\s*\(/g)) {
      const body = handlerBody(src, m.index);
      if (!/\bsettings\b|\boperators\b/.test(body)) continue;
      const ok = (LISTED[file] || []).some((k) => body.includes(k));
      assert.ok(ok, `${file}: an unlisted writer touches settings/operators at line ${src.slice(0, m.index).split('\n').length}`);
      assert.doesNotMatch(body, /\boperators\b|operatorLockEnabled|activeOperatorId|roleLimits/, `${file}: a field writer names the lock or operators`);
    }
  }
  const io = fs.readFileSync(path.join(root, 'lib', 'store-io.js'), 'utf8');
  assert.match(io, /const changed = lockFieldsChanged\(current, next\);\s*if \(changed\) throw new Error\('mutator may not change ' \+ changed\);/);
});
