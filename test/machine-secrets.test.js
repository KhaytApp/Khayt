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
  { id: 'M1', printerApi: { type: 'octoprint', host: 'h', port: 5000, apiKey: 'REAL-KEY' },
    smartPlug: { type: 'homeassistant', host: 'http://ha.local:8123', entity: 'switch.p1', token: 'HA-TOKEN' } },
  { id: 'M2', printerApi: { type: 'bambu', host: '192.168.1.50', serial: '01P00A123456789', accessCode: '12345678' } },
];

test('a masked key is put back from the same machine on disk', () => {
  const m = fillMachineSecrets({ id: 'M1', printerApi: { type: 'octoprint', host: 'h', port: 5000, apiKey: MASK },
    smartPlug: { type: 'homeassistant', host: 'http://ha.local:8123', entity: 'switch.p1', token: MASK } }, disk, isMasked);
  assert.equal(m.printerApi.apiKey, 'REAL-KEY');
  assert.equal(m.printerApi.host, 'h', 'the window\'s other fields are kept');
  assert.equal(m.smartPlug.token, 'HA-TOKEN');
  assert.equal(fillMachineSecrets({ id: 'M2', printerApi: { type: 'bambu', host: '192.168.1.50', serial: '01P00A123456789', accessCode: MASK } }, disk, isMasked).printerApi.accessCode, '12345678');
});

// MED-2: the window chooses the address as well as the id. A real machine's id
// with another LAN box as its host used to be handed the real access code.
const bambu = (over) => ({ id: 'M2', printerApi: { type: 'bambu', host: '192.168.1.50', serial: '01P00A123456789', accessCode: MASK, ...over } });
const octo = (over) => ({ id: 'M1', printerApi: { type: 'octoprint', host: 'h', port: 5000, apiKey: MASK, ...over } });
const plug = (over) => ({ id: 'M1', smartPlug: { type: 'homeassistant', host: 'http://ha.local:8123', entity: 'switch.p1', token: MASK, ...over } });

test('the same id at another address gets no secret', () => {
  assert.equal(fillMachineSecrets(bambu({ host: '192.168.1.66' }), disk, isMasked).printerApi.accessCode, MASK, 'another host');
  assert.equal(fillMachineSecrets(bambu({ serial: '01P00A999999999' }), disk, isMasked).printerApi.accessCode, MASK, 'another Bambu serial');
  assert.equal(fillMachineSecrets(bambu({ serial: undefined }), disk, isMasked).printerApi.accessCode, MASK, 'no serial');
  assert.equal(fillMachineSecrets(bambu({ type: 'octoprint' }), disk, isMasked).printerApi.accessCode, MASK, 'another type');
  assert.equal(fillMachineSecrets(octo({ host: 'evil.lan' }), disk, isMasked).printerApi.apiKey, MASK, 'another host');
  assert.equal(fillMachineSecrets(octo({ port: 8080 }), disk, isMasked).printerApi.apiKey, MASK, 'another port');
  assert.equal(fillMachineSecrets(octo({ port: null }), disk, isMasked).printerApi.apiKey, MASK, 'port dropped');
  assert.equal(fillMachineSecrets(octo({ type: 'moonraker' }), disk, isMasked).printerApi.apiKey, MASK, 'another type');
});

test('the saved address matches however it is written', () => {
  assert.equal(fillMachineSecrets(octo({ host: '  H/ ', port: '5000' }), disk, isMasked).printerApi.apiKey, 'REAL-KEY');
  assert.equal(fillMachineSecrets(bambu({ type: 'Bambu', serial: '01p00a123456789 ' }), disk, isMasked).printerApi.accessCode, '12345678');
  assert.equal(fillMachineSecrets(plug({ host: 'HTTP://HA.local:8123/' }), disk, isMasked).smartPlug.token, 'HA-TOKEN');
});

test('a smart plug gets its token only at its own address and type', () => {
  assert.equal(fillMachineSecrets(plug({}), disk, isMasked).smartPlug.token, 'HA-TOKEN');
  assert.equal(fillMachineSecrets(plug({ host: 'http://10.0.0.9:8123' }), disk, isMasked).smartPlug.token, MASK, 'another host');
  assert.equal(fillMachineSecrets(plug({ type: 'tasmota' }), disk, isMasked).smartPlug.token, MASK, 'another type');
  // the plug and the printer are judged apart: a moved plug does not cost the printer its key
  const both = fillMachineSecrets({ ...octo({}), smartPlug: plug({ host: 'evil.lan' }).smartPlug }, disk, isMasked);
  assert.equal(both.printerApi.apiKey, 'REAL-KEY');
  assert.equal(both.smartPlug.token, MASK);
});

test('a Home Assistant token reads or switches only the entity it was saved for', () => {
  assert.equal(fillMachineSecrets(plug({ entity: 'switch.p1' }), disk, isMasked).smartPlug.token, 'HA-TOKEN', 'full match');
  assert.equal(fillMachineSecrets(plug({ entity: ' switch.p1 ' }), disk, isMasked).smartPlug.token, 'HA-TOKEN', 'trimmed, as the request trims it');
  for (const entity of ['switch.front_door', 'lock.front_door', 'switch.P1', '', undefined]) {
    assert.equal(fillMachineSecrets(plug({ entity }), disk, isMasked).smartPlug.token, MASK, String(entity));
  }
});

test('a plug at another scheme, port or path gets no secret', () => {
  for (const host of ['https://ha.local:8123', 'http://ha.local:8124', 'http://ha.local', 'ha.local', 'http://ha.local:8123/proxy',
    'http://user:pw@ha.local:8123']) {
    assert.equal(fillMachineSecrets(plug({ host }), disk, isMasked).smartPlug.token, MASK, host);
  }
  // a host written without its scheme is the http one, as the request reads it
  const bare = [{ id: 'P', smartPlug: { type: 'homeassistant', host: 'ha.local:8123', entity: 'switch.p1', token: 'T' } }];
  assert.equal(fillMachineSecrets({ id: 'P', smartPlug: { type: 'homeassistant', host: 'http://ha.local:8123', entity: 'switch.p1', token: MASK } }, bare, isMasked).smartPlug.token, 'T');
  assert.equal(fillMachineSecrets({ id: 'P', smartPlug: { type: 'homeassistant', host: 'https://ha.local:8123', entity: 'switch.p1', token: MASK } }, bare, isMasked).smartPlug.token, MASK);
});

test('a Tasmota password goes only with the user it was saved beside', () => {
  const book = [{ id: 'T', smartPlug: { type: 'tasmota', host: '192.168.1.9', user: 'admin', password: 'PW' } }];
  const tas = (over) => ({ id: 'T', smartPlug: { type: 'tasmota', host: '192.168.1.9', user: 'admin', password: MASK, ...over } });
  assert.equal(fillMachineSecrets(tas({}), book, isMasked).smartPlug.password, 'PW');
  assert.equal(fillMachineSecrets(tas({ user: 'other' }), book, isMasked).smartPlug.password, MASK);
  assert.equal(fillMachineSecrets(tas({ host: 'https://192.168.1.9' }), book, isMasked).smartPlug.password, MASK);
  assert.equal(fillMachineSecrets(tas({ type: 'shelly' }), book, isMasked).smartPlug.password, MASK);
});

test('a printer has no scheme of its own: one written into the host is another host', () => {
  assert.equal(fillMachineSecrets(octo({ host: 'https://h' }), disk, isMasked).printerApi.apiKey, MASK);
  assert.equal(fillMachineSecrets(octo({ host: 'http://h' }), disk, isMasked).printerApi.apiKey, MASK);
  assert.equal(fillMachineSecrets(bambu({ host: 'https://192.168.1.50' }), disk, isMasked).printerApi.accessCode, MASK);
  assert.equal(fillMachineSecrets(octo({}), disk, isMasked).printerApi.apiKey, 'REAL-KEY', 'full match');
});

test('a missing or bad host fills nothing', () => {
  for (const host of [undefined, null, '', '   ']) {
    assert.equal(fillMachineSecrets(octo({ host }), disk, isMasked).printerApi.apiKey, MASK, String(host));
    assert.equal(fillMachineSecrets(plug({ host }), disk, isMasked).smartPlug.token, MASK, String(host));
  }
  assert.equal(fillMachineSecrets(octo({ host: 'h@evil.lan' }), disk, isMasked).printerApi.apiKey, MASK);
  // and a book record with no host of its own never hands its key out
  const noHost = [{ id: 'M1', printerApi: { type: 'octoprint', apiKey: 'REAL-KEY' } }];
  assert.equal(fillMachineSecrets({ id: 'M1', printerApi: { type: 'octoprint', apiKey: MASK } }, noHost, isMasked).printerApi.apiKey, MASK);
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
  for (const fn of ['uploadGcodeToPrinter', 'fetchPrinterHistory', 'sendPrinterCommand', 'sendPrinterControl', 'plateObjects', 'fetchPrinterStatus', 'moonrakerRead']) {
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
