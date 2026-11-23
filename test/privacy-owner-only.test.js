'use strict';
/**
 * Turki, Nov 22: under the staff lock, the anonymous install count
 * (hub:active-count-set) and the crash-report and usage-statistics opt-ins
 * (settings.telemetry) are the owner's to change, like settings.network.
 * Lock off: anyone, as today.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
const PP = require('../lib/main/printer-permission.js');

const ROOT = path.join(__dirname, '..');
const ops = [
  { id: 'o', roleKey: 'owner' }, { id: 'm', roleKey: 'manager' },
  { id: 'p', roleKey: 'operator' }, { id: 'v', roleKey: 'viewer' },
];
const book = (lock, who, telemetry) => ({
  settings: { operatorLockEnabled: lock, activeOperatorId: who, telemetry: telemetry || { crashOptIn: false, usageOptIn: false, installId: '', consentAt: '' } },
  operators: ops,
});
const ON = { crashOptIn: true, usageOptIn: true, installId: 'abcdef0123456789', consentAt: '2026-11-22T10:00:00Z' };

test('mayChangePrivacy: the owner under the lock, anyone with it off, nobody unknown', () => {
  assert.equal(PP.mayChangePrivacy(book(true, 'o')), true, 'owner');
  for (const who of ['m', 'p', 'v', null, 'gone']) assert.equal(PP.mayChangePrivacy(book(true, who)), false, String(who));
  for (const who of ['o', 'm', 'p', 'v', null]) assert.equal(PP.mayChangePrivacy(book(false, who)), true, 'lock off ' + who);
  assert.equal(PP.mayChangePrivacy(null), false, 'no book read: refused');
});

test('the save guard puts the opt-ins back for every role but the owner, both ways', () => {
  for (const who of ['m', 'p', 'v']) {
    // Switching sharing ON for the shop.
    let g = PP.guardSave(book(true, who, ON), book(true, who), { verified: () => true });
    assert.equal(g.store.settings.telemetry.crashOptIn, false, who + ' on');
    assert.ok(g.refused.includes('settings.telemetry'), who);
    // And switching it OFF.
    g = PP.guardSave(book(true, who), book(true, who, ON), { verified: () => true });
    assert.deepEqual(g.store.settings.telemetry, ON, who + ' off');
  }
  const owner = PP.guardSave(book(true, 'o', ON), book(true, 'o'), { verified: () => true });
  assert.deepEqual(owner.store.settings.telemetry, ON);
  assert.ok(!owner.refused.includes('settings.telemetry'));
  const off = PP.guardSave(book(false, 'm', ON), book(false, 'm'), {});
  assert.deepEqual(off.store.settings.telemetry, ON, 'lock off: saved as today');
});

test('main\'s own writers may not change the opt-ins either, and the install-count IPC asks the rule', () => {
  const io = fs.readFileSync(path.join(ROOT, 'lib', 'store-io.js'), 'utf8');
  assert.match(io, /const LOCK_SETTINGS = \[[^\]]*'telemetry'\]/);
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  const h = main.slice(main.indexOf("ipcMain.handle('hub:active-count-set'"));
  assert.match(h.slice(0, h.indexOf('\n});')), /if \(!PrinterPermission\.mayChangePrivacy\(bookForPrivacyCheck\(\)\)\) return \{ ok: false, error: 'not_permitted' \};\s*\n[\s\S]*writeActiveCount/);
});

test('the window says it in its own words, in every language', () => {
  const st = fs.readFileSync(path.join(ROOT, 'renderer', 'app-state.js'), 'utf8');
  assert.match(st, /s === 'settings\.telemetry'\) parts\.add\(t\('err\.refused_telemetry'\)\)/);
  const set = fs.readFileSync(path.join(ROOT, 'renderer', 'settings.js'), 'utf8');
  assert.match(set, /t\('err\.refused', \{ what: t\('err\.refused_telemetry'\) \}\)/);
  assert.match(set, /t\('err\.refused', \{ what: t\('err\.refused_active_count'\) \}\)/);
  assert.match(set, /else if \(r && r\.error === 'not_permitted'\) refuse\(\);/);
  for (const l of ['en', 'ar', 'de', 'es', 'fr', 'ja', 'pt-BR', 'tr', 'zh']) {
    const s = fs.readFileSync(path.join(ROOT, 'renderer', 'locales', l + '.js'), 'utf8');
    for (const k of ['err.refused_telemetry', 'err.refused_active_count']) assert.match(s, new RegExp(`"${k.replace(/\./g, '\\.')}": "[^"]+"`), `${l} ${k}`);
  }
});

test('a book saved before the opt-ins existed: the window\'s all-off default is no change, never refused', () => {
  const disk = { settings: { operatorLockEnabled: true, activeOperatorId: 'm' }, operators: ops };
  const inc = book(true, 'm');   // the renderer's default telemetry object, all off
  const g = PP.guardSave(inc, disk, {});
  assert.ok(!g.refused.includes('settings.telemetry'), JSON.stringify(g.refused));
  assert.equal(g.store.settings.telemetry, undefined, 'and the disk stays as it was');
  // But turning one on over a missing record IS a change.
  const on = PP.guardSave(book(true, 'm', ON), disk, {});
  assert.ok(on.refused.includes('settings.telemetry'));
  assert.equal(on.store.settings.telemetry, undefined);
});

test('security review of #2636: no empty-book refusal, guarded backups and restore points, no "saved" after a refusal', () => {
  const main = fs.readFileSync(path.join(ROOT, 'main.js'), 'utf8');
  assert.match(main, /mayChangePrivacy\(bookForPrivacyCheck\(\)\)/);
  assert.match(main, /mayChangeNetwork\(bookForPrivacyCheck\(\)\)/);
  for (const h of ["ipcMain.handle('hub:write-backup'", "ipcMain.handle('hub:create-restore-point'"]) {
    const body = main.slice(main.indexOf(h), main.indexOf('\n});', main.indexOf(h)));
    assert.match(body, /parsed = guardedSnapshot\(parsed\);/, h);
  }
  const set = fs.readFileSync(path.join(ROOT, 'renderer', 'settings.js'), 'utf8');
  assert.match(set, /if \(await setTelemetryConsent\(!!el\.querySelector\('#tel_crash'\)\?\.checked, !!el\.querySelector\('#tel_usage'\)\?\.checked\) === false\) return;/);
});
