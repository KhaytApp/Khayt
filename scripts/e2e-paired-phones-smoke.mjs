/**
 * E2E smoke — signing out one paired phone, in a real window.
 *
 * Two phones enrol over the real LAN server (POST /api/devices, the PIN once),
 * then Settings → Online → LAN API lists them and "Sign out…" cuts off one:
 * its next signed request is 401 device-revoked (the phone drops its PIN and
 * asks again), and the other phone still gets in. Then once more in Arabic,
 * for raw keys and RTL.
 *
 * Run: npm run test:e2e:phones   (PHONES_SMOKE_SHOTS=<dir> saves screenshots)
 */
import crypto from 'node:crypto';
import { createRequire } from 'node:module';
import { launchApp, dismissWizard, makeUserDataDir, switchTab, E2E_LAN_PORT, E2E_LAN_PIN } from './e2e/helpers.mjs';

const require_ = createRequire(import.meta.url);
const Devices = require_('../lib/lan-devices.js');
const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const shots = process.env.PHONES_SMOKE_SHOTS || '';
const BASE = `http://127.0.0.1:${E2E_LAN_PORT}`;
const PIN = E2E_LAN_PIN + '-8chars';

// The phone's half, as docs/LAN_API.md describes it.
async function enrol(name) {
  const pair = crypto.generateKeyPairSync('x25519');
  const phonePub = crypto.createPublicKey(pair.privateKey).export({ type: 'spki', format: 'der' }).subarray(12).toString('base64');
  const res = await fetch(`${BASE}/api/devices`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-khayt-pin': PIN }, body: JSON.stringify({ publicKey: phonePub, name }) });
  if (res.status !== 200) throw new Error(`enrol ${name}: HTTP ${res.status}`);
  const out = await res.json();
  const serverPub = crypto.createPublicKey({ key: Buffer.concat([Buffer.from('302a300506032b656e032100', 'hex'), Buffer.from(out.publicKey, 'base64')]), format: 'der', type: 'spki' });
  return { id: out.deviceId, key: Devices.deriveDeviceKey(crypto.diffieHellman({ privateKey: pair.privateKey, publicKey: serverPub }), out.deviceId) };
}
async function signedGet(dev, target) {
  const time = String(Math.floor(Date.now() / 1000));
  const nonce = crypto.randomBytes(16).toString('hex');
  const mac = Devices.requestMac(dev.key, Devices.canonicalRequest('GET', target, time, nonce));
  const res = await fetch(BASE + target, { headers: { 'x-khayt-device': dev.id, 'x-khayt-time': time, 'x-khayt-nonce': nonce, 'x-khayt-mac': mac } });
  return { status: res.status, body: await res.json().catch(() => null) };
}

async function openLanSettings(window) {
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="online"]');
  await window.evaluate(() => renderLanApiSettings());
  await window.waitForSelector('#lanPairedPhones [data-sign-out], #lanPairedPhones div');
  await window.evaluate(() => document.getElementById('lanPairedPhones')?.scrollIntoView({ block: 'center' }));
  await window.waitForTimeout(150);
}

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate(async ({ port, pin }) => {
    settings.lanApi = { ...(settings.lanApi || {}), enabled: true, port, pin, bindLan: false };
    saveAll();
    await window.hubAPI.startLanServer({ port, pin, bindLan: 'loopback' });
  }, { port: E2E_LAN_PORT, pin: PIN });

  const kept = await enrol('Workshop iPhone');
  const lost = await enrol('Lost iPhone');
  ok((await signedGet(lost, '/api/orders')).status === 200, 'both phones are paired');

  await openLanSettings(window);
  const listed = await window.evaluate(() => document.getElementById('lanPairedPhones').innerText);
  ok(/Workshop iPhone/.test(listed) && /Lost iPhone/.test(listed), 'Settings lists both phones');
  ok(/Last seen/.test(listed), 'each with when it was last seen');
  if (shots) await window.screenshot({ path: shots + '/paired-phones-en.png' });

  let asked = '';
  window.once('dialog', (d) => { asked = d.message(); d.accept(); });
  await window.click(`#lanPairedPhones [data-sign-out="${lost.id}"]`);
  await window.waitForFunction((id) => !document.querySelector(`#lanPairedPhones [data-sign-out="${id}"]`), lost.id, { timeout: 5000 });
  ok(/Sign out “Lost iPhone”\?/.test(asked), `it asks first (${asked.split('\n')[0]})`);
  ok(/other phones stay signed in/.test(asked), 'and says the others stay paired');

  const gone = await signedGet(lost, '/api/orders');
  ok(gone.status === 401 && gone.body?.reason === 'device-revoked', `the signed-out phone is told device-revoked (${gone.status} ${gone.body?.reason})`);
  ok((await signedGet(kept, '/api/orders')).status === 200, 'the other phone still gets in');
  const after = await window.evaluate(() => document.getElementById('lanPairedPhones').innerText);
  ok(/Workshop iPhone/.test(after) && !/Lost iPhone/.test(after), 'the list drops the signed-out phone');

  // A cancelled sign-out changes nothing.
  window.once('dialog', (d) => d.dismiss());
  await window.click(`#lanPairedPhones [data-sign-out="${kept.id}"]`);
  await window.waitForTimeout(300);
  ok((await signedGet(kept, '/api/orders')).status === 200, 'cancelling leaves the phone paired');

  // ---- Arabic ----
  await window.evaluate(() => { settings.lang = 'ar'; i18n.set('ar'); });
  await openLanSettings(window);
  const ar = await window.evaluate(() => ({
    dir: document.documentElement.dir,
    text: document.getElementById('lanPairedPhones').closest('div').parentElement.innerText,
  }));
  ok(ar.dir === 'rtl', 'Arabic lays out right to left');
  ok(!/lan\.phones/.test(ar.text), 'no raw locale key in Arabic');
  ok(/الجوالات المقترنة/.test(ar.text) && /آخر ظهور/.test(ar.text) && /تسجيل الخروج/.test(ar.text), 'the block is translated');
  if (shots) await window.screenshot({ path: shots + '/paired-phones-ar.png' });

  console.log('e2e-paired-phones: ok (two phones enrol → Settings lists them → sign one out → device-revoked, the other stays, en + ar)');
} catch (err) {
  failed = true;
  console.error('e2e-paired-phones FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
