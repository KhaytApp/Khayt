'use strict';
/**
 * Every printer call in main.js takes the machine the WINDOW holds, and the
 * window's credentials are masked. They were sent as `__KHAYT_MASKED__`.
 */
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { fillMachineSecrets, createMachineSecrets } = require('../lib/main/machine-secrets.js');

const MASK = '__KHAYT_MASKED__';
const isMasked = (v) => v === MASK;
const disk = [
  { id: 'M1', printerApi: { type: 'octoprint', apiKey: 'REAL-KEY' }, smartPlug: { type: 'homeassistant', token: 'HA-TOKEN' } },
  { id: 'M2', printerApi: { type: 'bambu', accessCode: '12345678' } },
];

test('a masked key is put back from the same machine on disk', () => {
  const m = fillMachineSecrets({ id: 'M1', printerApi: { type: 'octoprint', host: 'h', apiKey: MASK }, smartPlug: { token: MASK } }, disk, isMasked);
  assert.equal(m.printerApi.apiKey, 'REAL-KEY');
  assert.equal(m.printerApi.host, 'h', 'the window\'s other fields are kept');
  assert.equal(m.smartPlug.token, 'HA-TOKEN');
  assert.equal(fillMachineSecrets({ id: 'M2', printerApi: { type: 'bambu', accessCode: MASK } }, disk, isMasked).printerApi.accessCode, '12345678');
});

test('a value the window really holds is left alone, and nothing is borrowed from another machine', () => {
  assert.equal(fillMachineSecrets({ id: 'M1', printerApi: { apiKey: 'JUST-TYPED' } }, disk, isMasked).printerApi.apiKey, 'JUST-TYPED');
  assert.equal(fillMachineSecrets({ id: 'M9', printerApi: { apiKey: MASK } }, disk, isMasked).printerApi.apiKey, MASK);
  assert.equal(fillMachineSecrets({ printerApi: { apiKey: MASK } }, disk, isMasked).printerApi.apiKey, MASK);
});

test('the book is read once per window of time, and a save makes the next call read it again', () => {
  let reads = 0; let t = 0;
  const ms = createMachineSecrets({ readDisk: () => { reads++; return { machines: disk }; }, isMasked, ttlMs: 1000, now: () => t });
  const m = { id: 'M1', printerApi: { apiKey: MASK } };
  ms.fill(m); ms.fill(m); ms.fill(m);
  assert.equal(reads, 1);
  t = 2000; ms.fill(m);
  assert.equal(reads, 2);
  ms.forget(); ms.fill(m);
  assert.equal(reads, 3);
  // a machine with nothing masked never needs the book at all
  ms.forget(); ms.fill({ id: 'M1', printerApi: { type: 'moonraker' } });
  assert.equal(reads, 3, 'nothing masked, nothing read');
});

test('every printer call in main.js starts by putting the credentials back', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  for (const fn of ['uploadGcodeToPrinter', 'fetchPrinterHistory', 'sendPrinterCommand', 'sendPrinterControl', 'plateObjects', 'fetchPrinterStatus']) {
    const at = src.indexOf(`async function ${fn}(machine`);
    assert.ok(at > 0, fn);
    const head = src.slice(at, src.indexOf('\n', src.indexOf('\n', at) + 1));
    assert.match(head, /machine = machineSecrets\.fill\(machine\);/, `${fn} sends the window's masked credentials`);
  }
  // and a save drops the cached copy
  const save = src.indexOf("ipcMain.handle('hub:save-store'");
  assert.match(src.slice(save, save + 200), /machineSecrets\.forget\(\)/);
});

test('saving a Bambu in the machine editor keeps its stored access code', () => {
  // The field shows blank over a stored code (secretInputValue), and the save
  // read it raw: every edit that did not retype the code saved '' over it.
  const src = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'machines.js'), 'utf8');
  assert.match(src, /accessCode:\s+secretInputSave\(draft\.printerApi\?\.accessCode, document\.getElementById\('machApiAccessCode'\)\?\.value\)/);
  assert.doesNotMatch(src, /accessCode:\s+document\.getElementById\('machApiAccessCode'\)\?\.value\.trim\(\) \|\| ''/);
});
