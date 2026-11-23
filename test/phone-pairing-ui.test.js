'use strict';
/**
 * The pairing screens' main-side helpers (frames P5/P6, signed off Nov 22):
 * the owner changes a code-paired phone's role; a PIN-paired phone has none.
 * The screens themselves run in test:e2e:phonepair.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Devices = require('../lib/lan-devices.js');
const ROOT = path.join(__dirname, '..');

test('setRole: a code-paired phone only, a known role only, kept across a restart', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-setrole-'));
  const keyPath = path.join(dir, 'devices.key');
  const mk = () => Devices.createLanDevices({ fs, keyPath });
  const devs = mk();
  const pub = () => crypto.createPublicKey(crypto.generateKeyPairSync('x25519').privateKey).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');
  const pinPhone = devs.enrol({ publicKey: pub(), name: 'PIN phone', pin: '12345678', sign: () => 's' }).deviceId;
  const server = crypto.generateKeyPairSync('x25519');
  const r = devs.admitPhone({ serverPrivate: server.privateKey, phonePublic: pub(), deviceId: 'dev_codePhone0001', name: 'Code phone', role: 'operator', pin: '12345678' });
  assert.ok(!r || !r.error, JSON.stringify(r));
  assert.equal(devs.setRole('dev_codePhone0001', 'viewer'), true);
  assert.equal(mk().list().find((d) => d.deviceId === 'dev_codePhone0001').role, 'viewer', 'after a restart');
  assert.equal(devs.setRole(pinPhone, 'viewer'), false, 'a PIN-paired phone is always the owner');
  assert.equal(devs.setRole('dev_codePhone0001', 'admin'), false, 'an unknown role');
  assert.equal(devs.setRole('dev_nobodyNobody01', 'viewer'), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('hub:lan-device-role is the owner\'s only, by main\'s own reading; the window draws main\'s answer', () => {
  const lan = fs.readFileSync(path.join(ROOT, 'lib', 'lan-server.js'), 'utf8');
  const h = lan.slice(lan.indexOf("ipcMain.handle('hub:lan-device-role'"), lan.indexOf("ipcMain.handle('hub:phone-pair-close'"));
  assert.match(h, /if \(approver\(\)\.role !== 'owner'\) return \{ ok: false, error: 'not_permitted' \};/);
  const ui = fs.readFileSync(path.join(ROOT, 'renderer', 'phone-pairing.js'), 'utf8');
  // The dialog asks through pairApi (a phone, or a slicer without a role): the phone's call passes the request through whole.
  assert.match(ui, /P\.approve\(\{ role: memo\.chosen, pairId: memo\.asked\.pairId, check: memo\.asked\.check \}\)/, 'the exact request shown');
  assert.match(ui, /approve: \(x\) => a\.phonePairApprove\(x\)/, 'a phone is approved with that request, role and all');
  assert.match(ui, /approve: \(x\) => a\.connectorPairApprove\(\{ pairId: x\.pairId, check: x\.check \}\)/, 'a slicer is approved with no role');
  assert.match(ui, /code && owner\s*\n?\s*\? `<label class="pp-role">/, 'only the owner gets a role picker');
  const html = fs.readFileSync(path.join(ROOT, 'renderer', 'index.html'), 'utf8');
  assert.ok(html.indexOf('<script src="phone-pairing.js">') < html.indexOf('<script src="settings.js">'));
});
