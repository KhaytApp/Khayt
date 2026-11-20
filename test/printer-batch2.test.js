'use strict';
/**
 * Batch 2 of ~/Khayt-proposals/prusa-ideas-plan.md, the shared rules:
 *   C3 lib/printer-problems.js     one problem list for every protocol
 *   C5 lib/printer-capabilities.js what a card draws, per model
 *   C6 lib/poll-yield.js           the poll steps aside for a person's command
 * Each through its JSON vectors (the Mac and iPhone run the same files in
 * JSC), plus the closed sets, JSC loading, and the desktop's wiring.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const vm = require('node:vm');
const ROOT = path.join(__dirname, '..');
for (const f of ['printer-activity', 'bambu-faults', 'moonraker-problems', 'printer-commands', 'printer-problems', 'printer-capabilities', 'poll-yield']) require('../lib/' + f + '.js');
const P = globalThis.KhaytPrinterProblems, C = globalThis.KhaytPrinterCapabilities, Y = globalThis.KhaytPollYield;
const B = globalThis.KhaytBambuFaults;
const vec = (n) => require('./fixtures/' + n + '-vectors.json');

for (const c of vec('printer-problems').cases) test('C3 ' + c.why, () => assert.deepEqual(P.problemsFor(c.type, c.report), c.want));
for (const c of vec('printer-capabilities').cases) test('C5 ' + c.why, () => {
  assert.deepEqual(C.cardControls(c.machine, c.opts || undefined), c.want);
  assert.deepEqual(C.capability(c.machine, 'light', c.opts || undefined), c.light);
});
for (const c of vec('poll-yield').cases) test('C6 ' + c.why, () => {
  const y = Y.createPollYield(c.opts || {});
  for (const s of c.steps) {
    if (s.op === 'begin') y.begin(s.id, s.at);
    else if (s.op === 'end') y.end(s.id, s.at);
    else assert.equal(y[s.op](s.id, s.at), s.want, `${s.op} ${s.id} at ${s.at}`);
  }
});

test('C3: every bundled Bambu code has a meaning, and every finding is from the closed sets', () => {
  for (const [k, v] of Object.entries(Object.assign({}, B.PRINT_ERRORS, B.HMS))) assert.ok(P.bambuMeaning(v), k);
  for (const c of vec('printer-problems').cases) for (const f of c.want) {
    assert.ok(P.CODES.includes(f.code), f.code); assert.ok(P.ACTIONS.includes(f.action), f.action); assert.ok(P.SEVERITIES.includes(f.severity), f.severity);
  }
  for (const [code, d] of Object.entries(P.DEFAULTS)) { assert.ok(P.CODES.includes(code)); assert.ok(P.ACTIONS.includes(d.action)); }
  assert.deepEqual(Object.keys(P.DEFAULTS).sort(), P.CODES.slice().sort(), 'every code has an action');
});

test('C3: junk in, nothing out, nothing thrown; the printer\'s words are cleaned', () => {
  for (const t of ['bambu', 'moonraker', 'octoprint', 'sdcp', '', null]) for (const r of [null, 'x', [], {}]) assert.deepEqual(P.problemsFor(t, r), [], `${t} ${JSON.stringify(r)}`);
  const f = P.problemsFor('octoprint', { state: 'Error', message: 'a\u0000b' + 'z'.repeat(400) })[0];
  assert.ok(!/\u0000/.test(f.message) && f.message.length <= 200);
  assert.equal(P.worst([]), null);
});

test('C5: a model row never hides what it does not mention; the controls are a closed set', () => {
  for (const [id, row] of Object.entries(C.MODELS)) for (const k of Object.keys(row)) assert.ok(C.CONTROLS.includes(k), `${id}.${k}`);
  const catalog = require('../lib/printer-catalog.js');
  const ids = new Set((catalog.PRINTERS || catalog.CATALOG || catalog.printers || []).map((p) => p.id));
  if (ids.size) for (const id of Object.keys(C.MODELS)) assert.ok(ids.has(id), `${id} is a lib/printer-catalog.js id`);
  assert.equal(C.capability({ catalogId: 'nope', printerApi: { type: 'bambu' } }, 'speed').state, 'unknown');
  assert.equal(C.capability({ catalogId: 'bambu-x1c', printerApi: { type: 'bambu' } }, 'fly').state, 'no');
});

test('each rule loads without require, as JavaScriptCore loads it', () => {
  const ctx = {}; vm.createContext(ctx);
  for (const f of ['printer-activity', 'bambu-faults', 'moonraker-problems', 'printer-commands', 'printer-problems', 'printer-capabilities', 'poll-yield']) {
    vm.runInContext(fs.readFileSync(path.join(ROOT, 'lib', f + '.js'), 'utf8'), ctx);
  }
  assert.equal(vm.runInContext("KhaytPrinterProblems.problemsFor('bambu', {gcode_state:'PAUSE', print_error: 50364420})[0].code", ctx), 'filament-runout');
  assert.equal(vm.runInContext("KhaytPrinterCapabilities.cardControls({catalogId:'bambu-p1p', printerApi:{type:'bambu'}}).includes('light')", ctx), false);
  assert.equal(vm.runInContext("(() => { const y = KhaytPollYield.createPollYield(); y.begin('M', 0); return y.yielding('M', 1); })()", ctx), true);
});

test('C6 desktop: every send and control path yields, and the poll skips a printer that is yielding', () => {
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  const calls = main.match(/(?<!function )\b(uploadGcodeToPrinter|sendPrinterCommand|sendPrinterControl)\(machine/g) || [];
  const wrapped = main.match(/yieldingFor\(machine, \(\) => (uploadGcodeToPrinter|sendPrinterCommand|sendPrinterControl)\(machine/g) || [];
  assert.ok(calls.length >= 6, `${calls.length} calls`);
  assert.equal(wrapped.length, calls.length, 'each call goes through yieldingFor');
  const ex = main.slice(main.indexOf("ipcMain.handle('hub:printer-exclude-object'"));
  const body = ex.slice(0, ex.indexOf('\n});'));
  assert.match(body, /pollYield\.begin\(machine && machine\.id/);
  assert.match(body, /finally \{ pollYield\.end\(machine && machine\.id/);
  assert.match(main, /if \(pollYield\.yielding\(machine\.id, Date\.now\(\)\)\) continue;/);
});
