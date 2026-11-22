/**
 * `lib/printer-upload.js` — what a printer is asked when a sliced file is sent
 * to it. Lifted out of `uploadGcodeToPrinter` in main.js so the Mac app can
 * send too.
 *
 * The request shapes are held to what main.js sent before the lift, written
 * out below as literals. The two things that DID change are tested for what
 * they now do: the remote name keeps the file's kind, and a file the printer
 * cannot run is refused before anything is sent.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const U = require('../lib/printer-upload.js');

test('the requests are the ones main.js sent before the lift', () => {
  const name = 'khayt-abc.gcode';
  // OctoPrint: multipart to /api/files/local, file then select and print, key always sent.
  assert.deepEqual(U.request('octoprint', { apiKey: 'K', name, startPrint: true }), {
    method: 'POST', path: '/api/files/local', headers: { 'X-Api-Key': 'K' },
    body: { kind: 'multipart', file: { field: 'file', contentType: 'text/plain' },
      fields: [['select', 'true'], ['print', 'true']] },
  });
  assert.equal(U.request('octoprint', { name }).headers['X-Api-Key'], '', 'OctoPrint was always sent the header');
  // Moonraker: root=gcodes, and the key only when there is one.
  assert.deepEqual(U.request('moonraker', { name, startPrint: false }), {
    method: 'POST', path: '/server/files/upload', headers: {},
    body: { kind: 'multipart', file: { field: 'file', contentType: 'text/plain' },
      fields: [['root', 'gcodes'], ['print', 'false']] },
  });
  assert.deepEqual(U.request('moonraker', { apiKey: 'M', name }).headers, { 'X-Api-Key': 'M' });
  // PrusaLink: PUT the raw bytes to USB storage; the header starts it.
  assert.deepEqual(U.request('prusalink', { apiKey: 'P', name: 'khayt a.bgcode', startPrint: true }), {
    method: 'PUT', path: '/api/v1/files/usb/khayt%20a.bgcode',
    headers: { 'X-Api-Key': 'P', 'Content-Type': 'application/octet-stream', 'Print-After-Upload': '1' },
    body: { kind: 'raw', contentType: 'application/octet-stream' },
  });
  assert.equal(U.request('bambu', { name }), null, 'Bambu is not spoken over HTTP');
  assert.equal(U.request('duet', { name }), null);
});

test('the remote name keeps what the file is', () => {
  const t = 1_800_000_000_000;
  assert.equal(U.remoteName('/x/Dragon.gcode', t), `khayt-${t.toString(36)}.gcode`);
  assert.equal(U.remoteName('Plate_1.bgcode', t).endsWith('.bgcode'), true,
    'a Prusa binary G-code sent as .gcode is read as text and refused by the printer');
  assert.equal(U.remoteName('a.gcode.3mf', t).endsWith('.3mf'), true);
  assert.equal(U.remoteName('part.gco', t).endsWith('.gcode'), true);
});

test('a file the printer cannot run is refused before anything is sent', () => {
  assert.deepEqual(U.check('moonraker', 'a.gcode'), { ok: true, kind: 'gcode' });
  assert.deepEqual(U.check('prusalink', 'a.bgcode'), { ok: true, kind: 'bgcode' });
  assert.deepEqual(U.check('bambu', 'a.gcode.3mf'), { ok: true, kind: '3mf' });
  assert.equal(U.check('moonraker', 'a.3mf').code, 'wrong_kind', 'Klipper cannot print a 3MF');
  assert.equal(U.check('octoprint', 'a.bgcode').code, 'wrong_kind');
  assert.equal(U.check('prusalink', 'dragon.stl').code, 'not_sliced');
  assert.equal(U.check('duet', 'a.gcode').code, 'unsupported');
  assert.equal(U.check('sdcp', 'a.gcode').code, 'unsupported');
  assert.equal(U.check(undefined, 'a.gcode').code, 'unsupported');
});

test('only 2xx is taken as the printer saying yes', () => {
  for (const s of [200, 201, 204]) assert.equal(U.accepted(s), true);
  for (const s of [301, 400, 401, 403, 409, 415, 500]) assert.equal(U.accepted(s), false);
});

test('main.js sends through the rule, not a copy of it', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const at = main.indexOf('async function uploadGcodeToPrinter(');
  const fn = main.slice(at, main.indexOf('\n}\n', at));
  assert.match(fn, /printerUpload\.check\(type, gcodePath\)/);
  assert.match(fn, /printerUpload\.remoteName\(gcodePath/);
  assert.match(fn, /printerUpload\.request\(type,/);
  assert.ok(!/\/api\/files\/local|\/server\/files\/upload|Print-After-Upload/.test(fn),
    'a request shape was written back into main.js');
});

test('it loads without require, as JavaScriptCore loads it', () => {
  const vm = require('node:vm');
  const ctx = {};
  vm.createContext(ctx);
  vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'lib', 'printer-upload.js'), 'utf8'), ctx);
  assert.equal(vm.runInContext("KhaytPrinterUpload.check('prusalink','x.bgcode').ok", ctx), true);
});
