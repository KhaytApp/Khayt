'use strict';
/**
 * The 4.11.0 pre-cut review's three LOW items (Dev Hub, Nov 20):
 *
 *  1. A legacy (btoa) PIN at the pad is not CLEARED: under the lock main puts
 *     a cleared pinHash back (P5), so the pad said "PIN reset" over nothing;
 *     and had it gone through, the person would have had no PIN at all.
 *  2. A restore the role guard kept only in part says so in the window,
 *     instead of reporting success over what it put back.
 *  3. A printer whose address changed and is not saved is refused as
 *     'connection_unsaved' ("save the new address first"), not sent out with
 *     the mask for a key and reported as a wrong access code (#2600).
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const { createMachineSecrets } = require('../lib/main/machine-secrets.js');

const read = (f) => fs.readFileSync(path.join(__dirname, '..', f), 'utf8');
const LANGS = ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh'];
const MASK = '__KHAYT_MASKED__';

test('LOW 1: the pad never clears a legacy PIN; it says so in the shop\'s language', () => {
  const src = read('renderer/ops-locations.js');
  const at = src.indexOf('if (isLegacyPin(op.pinHash))');
  const legacyBranch = src.slice(at, src.indexOf('return;', at));
  assert.ok(at > 0);
  assert.doesNotMatch(legacyBranch, /pinHash\s*=\s*''/, 'the btoa branch clears nothing');
  const at2 = src.indexOf("verified?.error === 'legacy_pin'");
  const mainBranch = src.slice(at2, src.indexOf('return;', at2));
  assert.ok(at2 > 0);
  assert.doesNotMatch(mainBranch, /pinHash\s*=\s*''/, 'nor the branch main reports');
  assert.doesNotMatch(src, /PIN reset for security upgrade/, 'the English-only sentence is gone');
  for (const l of LANGS) assert.match(read(`renderer/locales/${l}.js`), /"op\.pin_legacy":/, l);
});

test('LOW 2: a restore main kept only in part reaches the window', () => {
  const main = read('main.js');
  const fn = main.slice(main.indexOf('async function restoreSnapshotForWindow'), main.indexOf("ipcMain.handle('hub:restore-backup'"));
  assert.match(fn, /g\.refused && g\.refused\.length/);
  assert.match(fn, /event\.sender\.send\('hub:restore-refused'/);
  assert.match(read('preload.js'), /onRestoreRefused:.*'hub:restore-refused'/);
  assert.match(read('renderer/app-boot.js'), /onRestoreRefused\?\.\(/);
  const state = read('renderer/app-state.js');
  assert.match(state, /function _restoreRefused\(/);
  assert.match(state, /\n\s+_restoreRefused,\n/, 'exported for app-boot.js');
});

test('LOW 3: an unsaved printer address is "connection_unsaved", and the saved one is not', () => {
  const book = { machines: [{ id: 'M1', printerApi: { type: 'bambu', host: '10.0.0.5', port: '', serial: 'AB1', accessCode: 'real-code' } }] };
  const ms = createMachineSecrets({ readDisk: () => book, isMasked: (v) => v === MASK });
  const win = (over) => ({ id: 'M1', printerApi: { type: 'bambu', host: '10.0.0.5', port: '', serial: 'AB1', accessCode: MASK, ...over } });

  const same = ms.fill(win());
  assert.equal(same.printerApi.accessCode, 'real-code');
  assert.equal(ms.unsaved(same), false, 'the saved address: filled, not refused');

  const moved = ms.fill(win({ host: '10.0.0.9' }));
  assert.equal(moved.printerApi.accessCode, MASK, 'another address keeps the mask (#2600)');
  assert.equal(ms.unsaved(moved), true, 'and is refused as unsaved, not sent');

  assert.equal(ms.unsaved(ms.fill(win({ accessCode: 'typed-new' }))), false, 'a code typed for the new address is the shop\'s own');
  assert.equal(ms.unsaved({ id: 'NEW', printerApi: { type: 'bambu', host: '10.0.0.9', accessCode: MASK } }), false, 'a machine not in the book is not this case');
  assert.equal(ms.unsaved(null), false);
});

test('LOW 3: every printer call that fills secrets refuses an unsaved address first, and the window says it in words', () => {
  const main = read('main.js');
  const fills = main.split("machine = machineSecrets.fill(machine);").length - 1;
  const guarded = (main.match(/machine = machineSecrets\.fill\(machine\);[^\n]*\n\s*if \(machineSecrets\.unsaved\(machine\)\) return \{ ok: false, error: 'connection_unsaved' \};/g) || []).length;
  assert.ok(fills >= 6, `${fills} printer calls fill secrets`);
  assert.equal(guarded, fills, 'each one checks unsaved straight after');
  assert.match(read('renderer/app-state.js'), /c === 'connection_unsaved'\) return t\('err\.connection_unsaved'\)/);
  assert.match(read('renderer/machines.js'), /t\('mach\.api_fail'\) \+ ': ' \+ explainRefusal\(s\.error\)/);
  for (const l of LANGS) assert.match(read(`renderer/locales/${l}.js`), /"err\.connection_unsaved":/, l);
});

test('security review: the first releases\' btoa PINs become real hashes in main, once', () => {
  const PinHash = require('../lib/pin-hash.js');
  const { upgradeLegacyPins } = require('../lib/main/printer-permission.js');
  const b = (s) => Buffer.from(s, 'utf8').toString('base64');
  assert.equal(PinHash.decodeLegacyBtoaPin(b('1234')), '1234');
  assert.equal(PinHash.decodeLegacyBtoaPin(b('٤٥٦٧')), '4567', 'Arabic-Indic digits, as the pad normalises');
  for (const v of ['', null, '__KHAYT_MASKED__', b('hello'), b('12'), 'a'.repeat(64), PinHash.hashPin('1234'), 'MTIzNA']) {
    assert.equal(PinHash.decodeLegacyBtoaPin(v), null, String(v));
  }
  const store = { operators: [{ id: 'a', pinHash: b('1234') }, { id: 'b', pinHash: PinHash.hashPin('9999') }, { id: 'c' }, { id: 'd', pinHash: 'junk!' }] };
  const r = upgradeLegacyPins(store, PinHash.hashPin);
  assert.equal(r.changed, true);
  assert.equal(r.count, 1);
  assert.ok(PinHash.isPbkdf2Hash(r.store.operators[0].pinHash));
  assert.equal(PinHash.verifyPin('1234', r.store.operators[0].pinHash), true);
  assert.equal(r.store.operators[1], store.operators[1]);
  assert.equal(r.store.operators[3].pinHash, 'junk!', 'what does not decode is left for the owner');
  assert.equal(store.operators[0].pinHash, b('1234'), 'the input is not mutated');
  assert.equal(upgradeLegacyPins(r.store, PinHash.hashPin).changed, false, 'once');
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  assert.match(main, /upgradedPins = await upgradeLegacyPinsOnDisk\(\)/);
});

test('correctness review: a restore with refused parts does not also say "Restore successful"', () => {
  const main = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');
  const fn = main.slice(main.indexOf('async function restoreSnapshotForWindow'), main.indexOf("ipcMain.handle('hub:restore-backup'"));
  assert.match(fn, /refused = g\.refused\.slice\(\);/);
  assert.match(fn, /Object\.assign\(\{\}, r\.masked, \{ __refused: refused \}\)/);
  const set = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'settings.js'), 'utf8');
  assert.match(set, /if \(!\(Array\.isArray\(data && data\.__refused\) && data\.__refused\.length\)\) toast\(t\('set\.restore_success'\)/);
  assert.match(set, /if \(!\(Array\.isArray\(point && point\.__refused\) && point\.__refused\.length\)\) toast\(t\('set\.restore_success'\)/);
  assert.match(set, /if \(!\(Array\.isArray\(data && data\.__refused\) && data\.__refused\.length\)\) toast\(t\('offsite\.restored'/, 'the offsite restore too (re-review)');
  assert.match(set, /if \(!\(Array\.isArray\(data && data\.__refused\) && data\.__refused\.length\)\) toast\(t\('offsite\.restored'/, 'the offsite restore too (re-review)');
  // The marker never becomes part of the book.
  const V = require('../lib/store-validate.js');
  const { normalized } = V.normalizeStoreSnapshot({ settings: { bizName: 'x' }, printLog: [], __refused: ['operators'] });
  assert.equal(normalized.__refused, undefined);
});
