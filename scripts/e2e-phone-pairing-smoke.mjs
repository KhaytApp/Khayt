/**
 * E2E smoke — pairing a phone by a code, with a role, in the real window
 * (frames P1–P6, signed off by Turki on Nov 22; renderer/phone-pairing.js over
 * lib/lan-server.js hub:phone-pair-*). The phone's half is played here, as
 * docs/LAN_API.md describes it: commit, offer, reveal, the same 6-digit number
 * on both sides, then Approve with a role, the role in Paired phones, and the
 * owner changing it. English, then Arabic (right to left).
 *
 * Run: npm run test:e2e:phonepair   (PHONEPAIR_SHOTS=<dir> also saves pictures)
 */
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { launchApp, dismissWizard, makeUserDataDir, switchTab, E2E_LAN_PORT, E2E_LAN_PIN } from './e2e/helpers.mjs';

const require_ = createRequire(import.meta.url);
const PP = require_('../lib/main/phone-pairing.js');
const Devices = require_('../lib/lan-devices.js');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shots = process.env.PHONEPAIR_SHOTS || '';
const BASE = `http://127.0.0.1:${E2E_LAN_PORT}`;
const PIN = E2E_LAN_PIN + '-8chars';
process.env.KHAYT_PHONE_PAIRING_BY_CODE = '1';   // the switch, off by default

const rawPub = (priv) => crypto.createPublicKey(priv).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');
const x25519Public = (b64) => crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(b64, 'base64')]), format: 'der', type: 'spki' });
async function post(p, body, headers = {}) {
  const res = await fetch(BASE + p, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body) });
  return { status: res.status, json: await res.json().catch(() => null) };
}
/** The phone: commit, offer, reveal. Returns what it shows and the key it will sign with. */
async function phoneAsks(name) {
  const pair = crypto.generateKeyPairSync('x25519');
  const publicKey = rawPub(pair.privateKey);
  const nonce = crypto.randomBytes(16).toString('base64');
  const o = await post('/api/devices/pair', { v: 2, commit: PP.commitment(publicKey, nonce).toString('base64'), name, app: 'Khayt iPhone', version: '1.2.0' });
  if (o.status !== 200) throw new Error('offer: ' + o.status + ' ' + JSON.stringify(o.json));
  const r = await post(`/api/devices/pair/${o.json.pairId}/reveal`, { publicKey, nonce }, { 'x-khayt-poll': o.json.pollSecret });
  if (r.status !== 200) throw new Error('reveal: ' + r.status);
  const check = PP.checkNumber(o.json.deviceId, o.json.identity, o.json.publicKey, publicKey, nonce);
  const key = Devices.deriveDeviceKey(crypto.diffieHellman({ privateKey: pair.privateKey, publicKey: x25519Public(o.json.publicKey) }), o.json.deviceId);
  return { check, id: o.json.deviceId, key };
}
async function signedGet(dev, target) {
  const time = String(Math.floor(Date.now() / 1000)), nonce = crypto.randomBytes(16).toString('hex');
  const mac = Devices.requestMac(dev.key, Devices.canonicalRequest('GET', target, time, nonce));
  const res = await fetch(BASE + target, { headers: { 'x-khayt-device': dev.id, 'x-khayt-time': time, 'x-khayt-nonce': nonce, 'x-khayt-mac': mac } });
  return { status: res.status, json: await res.json().catch(() => null) };
}
async function openLan(window) {
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="connections"]');
  await window.evaluate(() => renderLanApiSettings());
  await window.waitForSelector('#lanPairedPhonesFoot [data-pp-open]');
  await window.evaluate(() => document.getElementById('lanPairedPhones')?.scrollIntoView({ block: 'center' }));
}
const shot = async (window, sel, name) => { if (!shots) return; const el = await window.$(sel); if (el) await el.screenshot({ path: `${shots}/${name}.png` }); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate(async ({ port, pin }) => {
    settings.lanApi = { ...(settings.lanApi || {}), enabled: true, port, pin, bindLan: false };
    const portEl = document.querySelector('#lanApiSection #lan_port'); if (portEl) portEl.value = String(port);
    const bindEl = document.querySelector('#lanApiSection #lan_bind_lan'); if (bindEl) bindEl.checked = false;
    await startLanServer();
  }, { port: E2E_LAN_PORT, pin: PIN });

  for (const lang of ['en', 'ar']) {
    await window.evaluate((l) => { i18n.set(l); document.documentElement.dir = l === 'ar' ? 'rtl' : 'ltr'; }, lang);
    await openLan(window);
    ok(true, `${lang}: Paired phones offers Pair a phone to the owner`);
    await window.click('#lanPairedPhonesFoot [data-pp-open]');
    await window.waitForSelector('#phonePairOverlay .pp-wait');
    ok(true, `${lang}: P1 waiting for a phone`);
    await shot(window, '#phonePairOverlay .modal', `${lang}-P1-waiting`);
    const phone = await phoneAsks(lang === 'ar' ? 'جوال ريم' : 'Reem’s iPhone');
    await window.waitForSelector('#phonePairOverlay .pp-check', { timeout: 5000 });
    const shown = (await window.textContent('#phonePairOverlay .pp-check')).replace(/\s/g, '');
    ok(shown === phone.check, `${lang}: P2 the same number on both screens (${shown})`);
    const roles = await window.$$eval('#phonePairOverlay input[name="ppRole"]', (els) => els.map((e) => [e.value, e.checked]));
    ok(roles.length === 4 && roles.find(([r, c]) => r === 'operator' && c), `${lang}: the owner may give any role; Operator by default`);
    await shot(window, '#phonePairOverlay .modal', `${lang}-P2-approve`);
    await window.click('#phonePairOverlay [data-pp-act="approve"]');
    await window.waitForSelector('#phonePairOverlay .pp-end', { timeout: 5000 });
    ok(/Operator|مشغّل/.test(await window.textContent('#phonePairOverlay .pp-end')), `${lang}: P4 paired as Operator, in words`);
    await shot(window, '#phonePairOverlay .modal', `${lang}-P4-paired`);
    await window.click('#phonePairOverlay [data-pp-act="done"]');
    const self = await signedGet(phone, '/api/devices/self');
    ok(self.status === 200 && self.json.role === 'operator', `${lang}: the phone is an operator (${self.json && self.json.role})`);
    await window.waitForSelector(`#lanPairedPhones [data-pp-role="${phone.id}"]`);
    await window.selectOption(`#lanPairedPhones [data-pp-role="${phone.id}"]`, 'viewer');
    await window.waitForTimeout(400);
    ok((await signedGet(phone, '/api/devices/self')).json.role === 'viewer', `${lang}: P5 the owner changes its role, on its next request`);
    await window.evaluate(() => document.getElementById('lanPairedPhones')?.parentElement?.scrollIntoView({ block: 'center' }));
    await shot(window, '#lanPairedPhones', `${lang}-P5-list`);
  }
  console.log('\ne2e-phone-pairing: ok');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + (e && e.message || e));
} finally {
  try { await electronApp.close(); } catch { /* gone */ }
}
process.exit(failed ? 1 : 0);
