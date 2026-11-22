/**
 * The desktop's delete question, after the Mac's (#1828): by default a model
 * with a proven online copy leaves THIS computer only and stays in the library;
 * "Delete completely" removes the online copy first, and a model whose online
 * delete fails keeps its record and files. A model only on this computer is
 * deleted only when its box is ticked.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const T = require('../lib/print-library-tier.js');

const read = (p) => fs.readFileSync(path.join(__dirname, '..', p), 'utf8');

test('a record folder is sorted into online, online-only and local models', () => {
  const c = T.classifyForDelete(
    ['a.3mf', 'b.stl', 'c.stl.cloud', 'd.3mf.online', 'thumb.png', 'meta.json', 'notes.txt'], ['a.3mf']);
  assert.deepEqual({ online: c.online, onlineOnly: c.onlineOnly, local: c.local }, { online: 1, onlineOnly: 2, local: 1 });
  assert.deepEqual(c.files.find((f) => f.filename === 'b.stl').kind, 'local');
  // A model still on disk next to a leftover sidecar is on disk: its own proof decides.
  assert.equal(T.classifyForDelete(['e.stl', 'e.stl.cloud'], []).local, 1);
  assert.equal(T.classifyForDelete(['e.stl', 'e.stl.cloud'], []).onlineOnly, 0);
  assert.equal(T.isModelFile('x.png'), false);
  assert.equal(T.isModelFile('x.stl.cloud'), false);
  assert.equal(T.isModelFile('x.3mf'), true);
  assert.deepEqual(T.classifyForDelete(null, null), { online: 0, onlineOnly: 0, local: 0, files: [] });
});

test('the question is offered only when some model has an online copy', () => {
  assert.deepEqual(T.deleteChoice([{ id: 'a', local: 2 }]), { offer: false, keepable: [], localOnly: ['a'] });
  assert.deepEqual(T.deleteChoice([{ id: 'a', online: 1, local: 1 }, { id: 'b', onlineOnly: 1 }, { id: 'c', local: 1 }]),
    { offer: true, keepable: ['a', 'b'], localOnly: ['c'] });
  assert.equal(T.deleteChoice(null).offer, false);
});

test('main proves before it trashes, writes the sidecar first, and confirms an online delete', () => {
  const main = read('main.js');
  const prove = main.slice(main.indexOf('async function printLibProveInBucket'), main.indexOf('async function printLibModelNames'));
  assert.ok(prove.length > 0);
  assert.ok(!/\.put\(/.test(prove), 'proving never uploads');
  const rl = main.slice(main.indexOf("ipcMain.handle('hub:printlib-remove-local'"), main.indexOf("ipcMain.handle('hub:printlib-delete-remote'"));
  const iProve = rl.indexOf('printLibProveInBucket(remote, id, n, full)');
  const iSide = rl.indexOf('fs.promises.writeFile(sidePath');
  const iTrash = rl.indexOf('shell.trashItem(full)');
  assert.ok(iProve > 0 && iProve < iSide && iSide < iTrash, 'prove, then sidecar, then Trash');
  assert.ok(!/fs\.promises\.unlink\(full\)/.test(rl), 'the model is never unlinked');
  assert.match(rl, /catch \(e\) \{\s*try \{ await fs\.promises\.unlink\(sidePath\)/, 'a refused Trash takes the sidecar back');
  const dr = main.slice(main.indexOf("ipcMain.handle('hub:printlib-delete-remote'"), main.indexOf('// Save a generated thumbnail'));
  const iDel = dr.indexOf('t.remote.client.del(t.key)');
  const iAfter = dr.indexOf('const after = await t.remote.client.head(t.key)');
  assert.ok(iDel > 0 && iAfter > iDel, 'every delete is checked by a second HEAD');
  assert.ok(!/externalPath/.test(dr), 'an in-place file is never a target');
  const pre = read('preload.js');
  for (const ch of ['hub:printlib-delete-plan', 'hub:printlib-remove-local', 'hub:printlib-delete-remote']) assert.ok(pre.includes(`'${ch}'`), ch);
});

test('both entry pages load the rule the question asks', () => {
  for (const p of ['renderer/index.html', 'renderer/bedready.html']) {
    const html = read(p);
    assert.ok(html.indexOf('../lib/print-library-tier.js') > 0 && html.indexOf('../lib/print-library-tier.js') < html.indexOf('src="printfiles.js"'), p);
  }
});

/* ── The window: the real deletePrintFile, through a stubbed modal ────────── */

function loadWindow(hub) {
  let modal = null;
  global.window = global.window || {};
  global.window.hubAPI = hub;
  global.window.KhaytPrintLibraryTier = T;
  global.t = (k, v) => k + (v ? ' ' + JSON.stringify(v) : '');
  global.escapeHtml = (s) => String(s);
  global.toasts = [];
  global.toast = (m, kind) => global.toasts.push([m, kind]);
  global.saveAll = () => {};
  global.openFormModal = (o) => { modal = o; };
  global.document = global.document || { querySelector: () => null, querySelectorAll: () => [], getElementById: () => null, createElement: () => ({ style: {}, appendChild() {}, setAttribute() {} }), addEventListener() {} };
  global.$ = global.$ || (() => null);
  delete require.cache[require.resolve('../renderer/printfiles.js')];
  const pf = require('../renderer/printfiles.js');
  return { pf, modal: () => modal };
}
function fakeModal(how, alsoLocal) {
  return { querySelector: (sel) => {
    if (sel === 'input[name="pfDelHow"]:checked') return { value: how };
    if (sel === '#pfDelLocal') return { checked: !!alsoLocal };
    return null;
  }, querySelectorAll: () => [] };
}

test('the default removes from this computer and keeps the record', async () => {
  const calls = [];
  const hub = {
    printLibDeletePlan: async (ids) => ({ ok: true, configured: true, items: ids.map((id) => ({ id, online: 1, onlineOnly: 0, local: 0 })) }),
    printLibRemoveLocal: async (id) => { calls.push(['remove', id]); return { ok: true, removed: 1, kept: [] }; },
    printLibDeleteRemote: async (id) => { calls.push(['remote', id]); return { ok: true }; },
    printLibList: async () => [], printLibDelete: async () => true,
  };
  const w = loadWindow(hub);
  global.printFiles = [{ id: 'PF1', name: 'Dragon' }];
  await w.pf.deletePrintFile('PF1');
  const m = w.modal();
  assert.ok(m, 'the question was asked');
  assert.match(m.bodyHtml, /value="remove" checked/, 'Remove from this computer is the default');
  assert.equal(m.saveLabel, 'plib.del_remove_btn');
  await m.onSave(fakeModal('remove'));
  assert.deepEqual(calls, [['remove', 'PF1']]);
  assert.equal(global.printFiles.length, 1, 'the record stays');
});

test('a complete delete keeps a model whose online copy would not go', async () => {
  const hub = {
    printLibDeletePlan: async (ids) => ({ ok: true, configured: true, items: ids.map((id) => ({ id, online: 1 })) }),
    printLibRemoveLocal: async () => assert.fail('not under complete'),
    printLibDeleteRemote: async (id) => (id === 'PF2' ? { ok: false, failed: [{ filename: 'b.stl', error: 'x' }] } : { ok: true }),
    printLibList: async () => [{ fullPath: '/v/x' }], printLibDelete: async () => true,
  };
  const w = loadWindow(hub);
  global.printFiles = [{ id: 'PF1', name: 'A' }, { id: 'PF2', name: 'B' }];
  // The bulk path goes through the same question.
  await w.pf.deletePrintFile('PF1');
  await w.modal().onSave(fakeModal('complete'));
  assert.deepEqual(global.printFiles.map((r) => r.id), ['PF2']);
  await w.pf.deletePrintFile('PF2');
  await w.modal().onSave(fakeModal('complete'));
  assert.deepEqual(global.printFiles.map((r) => r.id), ['PF2'], 'kept, record and files');
  assert.ok(global.toasts.some(([m, k]) => /plib\.del_remote_failed/.test(m) && k === 'error'));
});

test('with no online copy anywhere, the plain question is asked as before', async () => {
  const hub = {
    printLibDeletePlan: async (ids) => ({ ok: true, configured: true, items: ids.map((id) => ({ id, local: 1 })) }),
    printLibRemoveLocal: async () => ({}), printLibDeleteRemote: async () => ({}),
    printLibList: async () => [], printLibDelete: async () => true,
  };
  const w = loadWindow(hub);
  global.printFiles = [{ id: 'PF1', name: 'A' }];
  await w.pf.deletePrintFile('PF1');
  assert.equal(w.modal().saveLabel, 'common.delete');
  assert.match(w.modal().bodyHtml, /plib\.delete_confirm/);
});
