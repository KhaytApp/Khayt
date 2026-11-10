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
  settings: [{ key: 'senderCity', label: { en: 'Sender city' }, type: 'text' }],
  scopes: ['fields.write'],
  signature: 'A'.repeat(86) + '==',
};
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-conn-'));
const file = path.join(dir, 'lamha.khaytplugin');
fs.writeFileSync(file, JSON.stringify(MANIFEST));

let electronApp;
try {
  // ── switched off by default: no card, no fields or buttons, nothing sent ──
  // Connectors ship on one day on every device; until then a build shows
  // none and the main process refuses, whatever the window asks.
  {
    delete process.env.KHAYT_CONNECTORS;
    const off = await launchApp(userData);
    electronApp = off.electronApp;
    await dismissWizard(off.window);
    const seen = await off.window.evaluate(async () => {
      await loadPluginsEnabled();
      settings.plugins = [{ id: 'x', manifest: { id: 'x', fields: [{ key: 'k', attach: 'order', type: 'text', label: 'K' }], actions: [] } }];
      const r = {
        enabled: await window.hubAPI.pluginsEnabled(),
        cardHidden: document.getElementById('pluginCard')?.hidden,
        editor: pluginEditorHtml('order', {}),
        send: await window.hubAPI.pluginSend({ id: 'x', action: 'a', delivery: 'dlv_x', records: {} }),
        check: await window.hubAPI.pluginCheck({ id: 'x', signature: 'A' }),
      };
      settings.plugins = [];
      return r;
    });
    if (seen.enabled !== false || seen.cardHidden !== true || seen.editor !== '') fail(`connectors are not switched off: ${JSON.stringify(seen)}`);
    if (seen.send?.refused !== 'off' || seen.check?.ok !== false) fail(`main does not refuse while off: ${JSON.stringify(seen)}`);
    await electronApp.close();
    electronApp = null;
  }

  // ── a developer's build: KHAYT_CONNECTORS=1 ──
  process.env.KHAYT_CONNECTORS = '1';
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);
  if (!(await window.evaluate(() => loadPluginsEnabled()))) fail('KHAYT_CONNECTORS=1 did not switch connectors on');

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
  if (await window.$('.plg-consent-updates')) fail('a first install said it updates a version');
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

  // ── its settings: saved by the shared rule, and the toast says Saved ──
  await window.fill('.plg-row [data-plugin-config="senderCity"]', '  Riyadh ');
  await window.click('.plg-row [data-plugin-act="save-config"]');
  const cfg = await window.evaluate(() => ({ config: settings.plugins[0].config, toast: [...document.querySelectorAll('#toastContainer .toast')].map((x) => x.textContent).pop() }));
  if (cfg.config.senderCity !== 'Riyadh') fail(`settings not saved: ${JSON.stringify(cfg.config)}`);
  if (cfg.toast !== 'Saved') fail(`save-config toast: ${cfg.toast}`);

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

  // ── a 2xx the service turned down (Lamha E2E, Nov 10): not "Sent" ──
  const setReply = (reply) => electronApp.evaluate(({ ipcMain }, reply) => {
    ipcMain.removeHandler('hub:plugin-send');
    ipcMain.handle('hub:plugin-send', (_e, req) => { globalThis.__sends.push(req); return { ok: true, status: 200, reply }; });
  }, reply);
  const lastToast = () => window.evaluate(() => [...document.querySelectorAll('#toastContainer .toast')].map((x) => x.textContent).pop() || '');
  const press2 = async () => {
    await window.evaluate(() => { document.querySelectorAll('#toastContainer .toast').forEach((x) => x.remove()); openOrderEditor('ORD-c1'); });
    await window.waitForSelector('.plg-editor [data-plugin-action="sa.lamha.ship|ship"]', { timeout: 10000 });
    await window.click('.plg-editor [data-plugin-action="sa.lamha.ship|ship"]');
    await window.waitForFunction(() => document.querySelector('#toastContainer .toast'), null, { timeout: 10000 });
    const said = await lastToast();
    await window.click('#modalMount [data-act="save"]');
    return said;
  };
  await setReply({ success: false, msg: 'Customer   phone\nis required' });
  const declined = await press2();
  if (declined !== 'Lamha shipping said: Customer phone is required') fail(`refusal toast: ${declined}`);
  if ((await window.evaluate(() => printLog.find((o) => o.id === 'ORD-c1').plugins['sa.lamha.ship'].awb)) !== 'AWB-77') fail('a refusal wrote to the job');
  await setReply({ success: true, data: {} });
  const unconfirmed = await press2();
  if (!/accepted it but sent back no Air waybill/.test(unconfirmed)) fail(`unconfirmed toast: ${unconfirmed}`);
  // A numeric status (Lamha's order status 1) is not a refusal.
  await setReply({ status: 1, shipment: { awb: 'AWB-78' } });
  if ((await press2()) !== 'Sent') fail('a numeric status was read as a refusal');

  // ── an event turned down: failed, shown, never retried on its own; Retry sends it again ──
  await setReply({ success: false, msg: 'Duplicate order' });
  const before = (await electronApp.evaluate(() => globalThis.__sends)).length;
  await window.evaluate(() => fireStatusWebhook('order_shipped', printLog.find((o) => o.id === 'ORD-c1')));
  await window.waitForFunction(() => (settings.pluginOutbox || []).some((p) => p.failed), null, { timeout: 10000 });
  const box = await window.evaluate(() => settings.pluginOutbox.find((p) => p.failed));
  if (box.failed.message !== 'Duplicate order' || 'nextAttemptAt' in box) fail(`failed item: ${JSON.stringify(box)}`);
  await window.evaluate(() => resumePluginOutbox());
  await window.waitForTimeout(800);
  if ((await electronApp.evaluate(() => globalThis.__sends)).length !== before + 1) fail('a turned-down event was sent again on its own');
  await switchTab(window, 'settings-tab');
  await window.evaluate(() => { openSettingsSection('automation'); renderPluginSettings(); });
  await window.waitForSelector('.plg-failed [data-act="retry"]', { timeout: 10000 });
  const shown = await window.evaluate(() => document.querySelector('.plg-failed').textContent);
  if (!/Duplicate order/.test(shown) || !/Lamha shipping/.test(shown)) fail(`failed list: ${shown}`);
  await setReply({ success: true });
  await window.click('.plg-failed [data-act="retry"]');
  await window.waitForFunction(() => !(settings.pluginOutbox || []).length, null, { timeout: 10000 });
  const retried = (await electronApp.evaluate(() => globalThis.__sends)).slice(-1)[0];
  if (retried.delivery !== box.delivery) fail('Retry did not keep the delivery id');

  // ── a job with no customer: a button that sends the customer is greyed out ──
  await window.evaluate(() => { printLog.push({ id: 'ORD-c2', project: 'Cup', status: 'printing', price: 20, date: localDateStr(), parts: [] }); saveAll(); openOrderEditor('ORD-c2'); });
  await window.waitForSelector('.plg-editor [data-plugin-action="sa.lamha.ship|ship"]', { timeout: 10000 });
  const blocked = await window.evaluate(() => {
    const b = document.querySelector('.plg-editor [data-plugin-action="sa.lamha.ship|ship"]');
    return { disabled: b.disabled, why: b.parentElement.textContent };
  });
  if (!blocked.disabled || !/This job has no customer/.test(blocked.why)) fail(`no-customer button: ${JSON.stringify(blocked)}`);
  await window.click('#modalMount [data-act="save"]').catch(() => {});

  // ── a refusal names the setting or key by its label, in the shop's language ──
  const said = await window.evaluate(() => {
    const entry = { manifest: { settings: [{ key: 'senderPhone', label: { en: 'Sender phone', ar: 'جوال المرسل' }, type: 'text' }],
      secrets: [{ name: 'apiKey', label: { en: 'API key' }, kind: 'apiKey' }] } };
    return [pluginRefusalText(entry, 'setting senderPhone is not set'), pluginRefusalText(entry, 'secret "apiKey" is not set'), pluginRefusalText(entry, 'host')];
  });
  if (!said[0].includes('Sender phone') || said[0].includes('senderPhone')) fail(`setting refusal: ${said[0]}`);
  if (!said[1].includes('API key')) fail(`secret refusal: ${said[1]}`);
  if (!said[2].includes('host')) fail(`other refusal: ${said[2]}`);

  // ── installing over another version says so; the same version, or the read-only view, does not ──
  const updates = await window.evaluate(async () => {
    const m = Object.assign({}, settings.plugins[0].manifest, { version: '1.1.1' });
    const seen = [];
    for (const opts of [{ replacing: '1.0.0' }, { replacing: '1.1.1' }, { replacing: '1.0.0', readOnly: true }]) {
      const p = pluginConsent(m, opts);
      await new Promise((r) => setTimeout(r, 50));
      const el = document.querySelector('.plg-consent-updates');
      seen.push(el ? el.textContent : '');
      document.querySelector('.modal [data-act="cancel"], .modal [data-act="ok"]').click();
      await p;
    }
    return seen;
  });
  if (!/Updates version 1\.0\.0/.test(updates[0])) fail(`updates line: ${updates[0]}`);
  if (updates[1] || updates[2]) fail(`updates line where none belongs: ${JSON.stringify(updates)}`);

  // ── off means off ──
  const eventsBeforeOff = (await electronApp.evaluate(() => globalThis.__sends)).filter((s) => s.event).length;
  await window.evaluate(() => { settings.plugins[0].enabled = false; saveAll(); });
  await window.evaluate(() => fireStatusWebhook('order_shipped', printLog.find((o) => o.id === 'ORD-c1')));
  await window.waitForTimeout(400);
  if ((await electronApp.evaluate(() => globalThis.__sends)).filter((s) => s.event).length !== eventsBeforeOff) fail('a switched-off connector still sent');

  console.log('connectors smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); fs.rmSync(dir, { recursive: true, force: true }); } catch (_) {}
}
