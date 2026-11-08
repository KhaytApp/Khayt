#!/usr/bin/env node
/**
 * E2E: a connector on the desktop, from the file to the job.
 *
 * Settings › Automation › Connectors installs a manifest file: the main
 * process checks it (stubbed here — only Khayt can sign one), the shop is
 * shown each host and the fields that go there, and Agree stores the entry
 * granted exactly that. Its keys are saved, sealed, and come back to the
 * window as the mask. The job editor then shows the connector's field and
 * buttons; pressing one goes to the main process with a fresh delivery id
 * and the job, and a reply fills the connector's own field. A status move
 * the connector listens to sends an event. A plain unsigned file is refused.
 *
 *   node scripts/e2e-connectors-smoke.mjs
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { dismissWizard, launchApp, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
const MANIFEST = {
  khayt: { manifest: 1 },
  id: 'sa.lamha.ship', name: { en: 'Lamha shipping' }, publisher: 'Lamha', version: '1.0.0',
  domains: ['api.lamha.sa'],
  secrets: [{ name: 'apiKey', label: { en: 'API key' }, kind: 'apiKey' }],
  fields: [{ key: 'awb', label: { en: 'Air waybill' }, type: 'text', attach: 'order' }],
  actions: [{ id: 'ship', label: { en: 'Ship with Lamha' }, placement: 'order', kind: 'post',
    url: 'https://api.lamha.sa/v1/shipments', send: ['order.id', 'customer.phone'],
    auth: { header: 'Authorization', scheme: 'Bearer', secret: 'apiKey' },
    response: { fields: { awb: 'shipment.awb' } } }],
  events: [{ event: 'order_shipped', url: 'https://api.lamha.sa/v1/events', send: ['order.id'] }],
  scopes: ['fields.write'],
  signature: 'A'.repeat(86) + '==',
};
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-conn-'));
const file = path.join(dir, 'lamha.khaytplugin');
fs.writeFileSync(file, JSON.stringify(MANIFEST));

let electronApp;
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  // Main's verdicts, stubbed: reviewed for this id only; sends are recorded.
  await electronApp.evaluate(({ ipcMain }) => {
    globalThis.__sends = [];
    for (const h of ['hub:plugin-check', 'hub:plugin-reviewed', 'hub:plugin-send']) ipcMain.removeHandler(h);
    ipcMain.handle('hub:plugin-check', (_e, m) => (m && m.signature ? { ok: true, reviewedBy: 'stub' } : { ok: false, error: 'unreviewed' }));
    ipcMain.handle('hub:plugin-reviewed', (_e, list) => Object.fromEntries((list || []).map((m) => [m.id, !!m.signature])));
    ipcMain.handle('hub:plugin-send', (_e, req) => {
      globalThis.__sends.push(req);
      return req.action ? { ok: true, status: 200, reply: { shipment: { awb: 'AWB-77' } } } : { ok: true, status: 200, reply: null };
    });
  });

  await window.evaluate(() => { settings.mode = 'professional'; applyMode(); saveAll(); });
  await switchTab(window, 'settings-tab');
  await window.click('.settings-nav-item[data-settings-section="automation"]');
  await window.waitForSelector('#btnPluginInstall', { timeout: 10000 });

  // ── an unsigned file is refused ──
  const unsigned = path.join(dir, 'unsigned.json');
  fs.writeFileSync(unsigned, JSON.stringify({ ...MANIFEST, signature: undefined }));
  await window.setInputFiles('#pluginFile', unsigned);
  await window.waitForTimeout(500);
  if (await window.evaluate(() => (settings.plugins || []).length)) fail('an unreviewed connector was installed');

  // ── install: consent shows each host and its fields ──
  await window.setInputFiles('#pluginFile', file);
  await window.waitForSelector('#plgConsentTitle', { timeout: 10000 });
  const consent = await window.evaluate(() => ({
    hosts: [...document.querySelectorAll('.plg-consent-host')].map((h) => h.dataset.host),
    fields: [...document.querySelectorAll('.plg-consent-host [data-field]')].map((f) => f.dataset.field),
    text: document.querySelector('.plg-consent-host').textContent,
  }));
  if (consent.hosts.join() !== 'api.lamha.sa') fail(`consent hosts: ${consent.hosts}`);
  if (consent.fields.sort().join() !== 'customer.phone,order.id') fail(`consent fields: ${consent.fields}`);
  if (!/phone number/.test(consent.text)) fail(`consent does not name the kind of data: ${consent.text}`);
  await window.click('.modal [data-act="ok"]');
  await window.waitForSelector('.plg-row[data-plugin="sa.lamha.ship"]', { timeout: 10000 });
  const stored = await window.evaluate(() => settings.plugins[0]);
  if (stored.granted.domains.join() !== 'api.lamha.sa' || !stored.granted.scopes.includes('fields.write')) fail(`grant: ${JSON.stringify(stored.granted)}`);
  if ('reviewed' in stored) fail('a reviewed flag was stored');

  // ── keys: saved, sealed on disk, masked in the window after a reload ──
  await window.fill('.plg-row [data-plugin-secret="apiKey"]', 'live-key-123');
  await window.click('.plg-row [data-plugin-act="save-keys"]');
  await window.evaluate(() => flushSave());
  await window.waitForTimeout(600);
  const onDisk = fs.readFileSync(path.join(userData, 'khayt-store.json'), 'utf8');
  // Sealed wherever the platform can seal (a CI Linux runner has no keyring,
  // and every secret there is stored as it is); kept on disk either way.
  const canSeal = await electronApp.evaluate(({ safeStorage }) => safeStorage.isEncryptionAvailable());
  if (canSeal && onDisk.includes('live-key-123')) fail('the connector key is on disk in the clear');
  const diskKey = JSON.parse(onDisk).settings.plugins[0].secrets?.apiKey;
  if (typeof diskKey !== 'string' || !diskKey) fail('the connector key was not saved');
  const windowKey = await window.evaluate(() => window.hubAPI.loadStore().then((j) => (typeof j === 'string' ? JSON.parse(j) : j).settings.plugins[0].secrets?.apiKey).catch(() => null));
  if (windowKey && windowKey.includes('live-key-123')) fail('the window was handed the connector key');

  // ── the job editor: its field and button; a press fills the field ──
  await window.evaluate(() => {
    clients.push({ id: 'C-1', nameEn: 'Sara', phone: '+966500000000' });
    printLog.push({ id: 'ORD-c1', project: 'Vase', status: 'printing', price: 90, clientId: 'C-1', date: localDateStr(), parts: [] });
    saveAll();
    openOrderEditor('ORD-c1');
  });
  await window.waitForSelector('.plg-editor [data-plugin-action="sa.lamha.ship|ship"]', { timeout: 10000 });
  await window.click('.plg-editor [data-plugin-action="sa.lamha.ship|ship"]');
  await window.waitForFunction(() => document.querySelector('[data-plugin-field="sa.lamha.ship|awb"]')?.value === 'AWB-77', null, { timeout: 10000 });
  const press = (await electronApp.evaluate(() => globalThis.__sends)).find((s) => s.action === 'ship');
  if (!press) fail('the button sent nothing');
  if (!/^dlv_[0-9a-f-]{36}$/.test(press.delivery)) fail(`delivery id: ${press.delivery}`);
  if (press.records.order.id !== 'ORD-c1' || press.records.customer.id !== 'C-1') fail(`records: ${JSON.stringify(press.records)}`);
  const filled = await window.evaluate(() => printLog.find((o) => o.id === 'ORD-c1').plugins);
  if (!filled || filled['sa.lamha.ship'].awb !== 'AWB-77') fail(`reply not written to the job: ${JSON.stringify(filled)}`);
  await window.click('#modalMount [data-act="save"]');

  // ── an event it listens to ──
  await window.evaluate(() => fireStatusWebhook('order_shipped', printLog.find((o) => o.id === 'ORD-c1')));
  await window.waitForTimeout(500);
  const ev = (await electronApp.evaluate(() => globalThis.__sends)).filter((s) => s.event === 'order_shipped');
  if (ev.length !== 1 || ev[0].delivery === press.delivery) fail(`event delivery: ${JSON.stringify(ev)}`);

  // ── off means off ──
  await window.evaluate(() => { settings.plugins[0].enabled = false; saveAll(); });
  await window.evaluate(() => fireStatusWebhook('order_shipped', printLog.find((o) => o.id === 'ORD-c1')));
  await window.waitForTimeout(400);
  if ((await electronApp.evaluate(() => globalThis.__sends)).filter((s) => s.event).length !== 1) fail('a switched-off connector still sent');

  console.log('connectors smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
}
