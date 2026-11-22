'use strict';
/**
 * Gap 5 (desktop parity, Nov 22): /api/machines/live carries each printer's
 * `problems` and `waiting`, worked out by lib/printer-needs.js, the Mac's
 * KhaytEngine+PrinterNeeds composition (#2621) in one shared file.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('node:vm');
const N = require('../lib/printer-needs.js');
const ROOT = path.join(__dirname, '..');

const M = (id, type, extra) => Object.assign({ id, name: id, printerApi: { type } }, extra || {});

test('a printer that answers: problems from its state word; one that does not: only what is stored', () => {
  const out = N.printerNeeds({
    machines: [M('k1', 'moonraker'), M('k2', 'moonraker'), M('none', 'none'), { id: 'x' }],
    cache: { k1: { state: 'error', message: 'Heater extruder not heating at expected rate' }, k2: { state: 'error', error: 'ECONNREFUSED' } },
    polled: N.polledFrom({ k1: { problems: require('../lib/printer-problems.js').problemsFor('moonraker', { print_stats: { state: 'error', message: 'Heater extruder not heating at expected rate' } }) } }),
    completions: { k2: [{ at: '2026-11-22T09:00:00.000Z', result: 'finished' }] },
  });
  assert.deepEqual(Object.keys(out).sort(), ['k1', 'k2'], 'only machines with a printer API');
  assert.ok(out.k1.problems.length >= 1, 'the answering printer\'s error is a problem');
  assert.deepEqual(out.k2.problems, [], 'not answering: no live problems');
  assert.deepEqual(out.k2.waiting.map((w) => w.reason), ['print-to-take-off'], 'but a stored finish still waits');
});

test('a Bambu: problems only from its poll (polled), never from its state word', () => {
  const machines = [M('b', 'bambu')];
  const cache = { b: { state: 'FAILED' } };
  assert.deepEqual(N.printerNeeds({ machines, cache }).b.problems, []);
  const polled = [{ code: 'filament-runout', severity: 'serious', action: 'load-filament', source: 'printer' }];
  assert.deepEqual(N.printerNeeds({ machines, cache, polled: { b: polled } }).b.problems, polled);
  assert.deepEqual(N.polledFrom({ b: { problems: polled }, c: { state: 'idle' } }), { b: polled });
});

test('the book\'s last finished job on the machine counts for waiting; a cleared bed after it does not wait', () => {
  const orders = [{ machineId: 'k', completedAt: '2026-11-22T08:00:00.000Z' }, { machineId: 'k', completedAt: '2026-11-22T09:00:00.000Z' }];
  const w = N.printerNeeds({ machines: [M('k', 'moonraker')], cache: { k: { state: 'idle' } }, orders }).k.waiting;
  assert.deepEqual(w.map((x) => [x.reason, x.since]), [['print-to-take-off', Date.parse('2026-11-22T09:00:00.000Z')]]);
  const cleared = N.printerNeeds({ machines: [M('k', 'moonraker', { bedClearedAt: '2026-11-22T09:30:00.000Z' })], cache: { k: { state: 'idle' } }, orders }).k.waiting;
  assert.deepEqual(cleared, []);
});

test('a Bambu poll carries its problems, decoded from the report (lib/bambu.js statusWithFault)', () => {
  const B = require('../lib/bambu.js');
  const fn = B.statusWithFault || (B._test && B._test.statusWithFault);
  if (typeof fn !== 'function') { const src = fs.readFileSync(path.join(ROOT, 'lib', 'bambu.js'), 'utf8'); assert.match(src, /s\.problems = require\('\.\/printer-problems\.js'\)\.problemsFor\('bambu', print\)/); return; }
  const s = fn(JSON.stringify({ print: { gcode_state: 'PAUSE', print_error: 50364420 } }));
  assert.equal(s.problems[0].code, 'filament-runout');
});

test('loads without require, as JavaScriptCore loads it, beside its rules', () => {
  const ctx = {}; vm.createContext(ctx);
  for (const f of ['printer-activity', 'bambu-faults', 'moonraker-problems', 'printer-commands', 'printer-problems', 'waiting-at-machine', 'printer-needs']) {
    vm.runInContext(fs.readFileSync(path.join(ROOT, 'lib', f + '.js'), 'utf8'), ctx);
  }
  const r = vm.runInContext("JSON.stringify(KhaytPrinterNeeds.printerNeeds({ machines: [{ id: 'k', printerApi: { type: 'octoprint' } }], cache: { k: { state: 'Error', message: 'x' } } }))", ctx);
  assert.ok(JSON.parse(r).k.problems.length >= 1);
});

test('/api/machines/live: every entry has problems and waiting, empty when nothing is needed', async () => {
  const { registerLanServer } = require('../lib/lan-server.js');
  const handlers = new Map();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-needs-'));
  let store = {
    settings: {}, printLog: [{ id: 'o1', machineId: 'k2', completedAt: '2026-11-22T09:00:00.000Z' }], inventory: [], clients: [],
    machines: [M('k1', 'moonraker'), M('k2', 'moonraker'), M('hand', 'none')],
    printerCompletions: {},
  };
  // As the desktop's Moonraker poll leaves it: readStatus carries `problems` (lib/moonraker.js).
  const MK = require('../lib/moonraker.js');
  const k1 = MK.readStatus({ result: { status: { print_stats: { state: 'error', message: 'Thermal runaway' } } } });
  assert.ok(Array.isArray(k1.problems) && k1.problems.length >= 1, 'the poll worked them out');
  const cache = { k1, k2: { state: 'idle' } };
  registerLanServer({
    fs, ipcMain: { handle: (n, f) => handlers.set(n, f) }, BrowserWindow: class { static getAllWindows() { return []; } },
    safeJsonParse: (s, f) => { try { return JSON.parse(s); } catch { return f; } }, syncLanServerStoreFromDisk: () => {},
    resolveStoreSecret: (v) => v, isStoreSecretMasked: () => false, migrateLanApiSecrets: () => {},
    ensureLanIntakeToken: () => ({ token: 'tok', generated: false }), ensureLanIntakePin: () => ({ pin: '1234', generated: false }),
    ensureLanCalendarToken: () => ({ token: 'cal', generated: false }), writeStoreToDisk: async () => {},
    persistLanStoreUpdate: async (s) => { store = s; }, updateStoreOnDisk: async (fn) => { store = fn(store); return store; },
    getLanServerStore: () => store, setLanServerStore: (s) => { store = s; }, getMainWindow: () => null,
    statusPagesDir: dir, appRoot: ROOT, getPrinterStatusCache: () => cache, receiptsDir: () => dir,
  });
  const PORT = 3994, PIN = '43218765';
  const r = await handlers.get('hub:start-lan-server')(null, { port: PORT, pin: PIN, bindLan: 'loopback' });
  assert.ok(r && r.ok, JSON.stringify(r));
  try {
    const res = await fetch(`http://127.0.0.1:${PORT}/api/machines/live`, { headers: { 'x-khayt-pin': PIN } });
    const live = await res.json();
    const by = Object.fromEntries(live.map((e) => [e.id, e]));
    for (const e of live) { assert.ok(Array.isArray(e.problems), e.id); assert.ok(Array.isArray(e.waiting), e.id); }
    assert.ok(by.k1.problems.length >= 1);
    assert.deepEqual(by.k2.waiting.map((w) => w.reason), ['print-to-take-off']);
    assert.deepEqual([by.hand.problems, by.hand.waiting], [[], []]);
  } finally {
    await handlers.get('hub:stop-lan-server')(null, {});
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
