/**
 * E2E smoke — automatic customer order updates through WhatsApp Business.
 *
 * The Mac has sent these since alpha; the desktop now does too, by the same
 * shared rule (lib/whatsapp-message.js cloudMessage) and the same log line, so
 * a book shared by both apps tells each step once.
 *
 * Here, with Meta and Khayt Cloud stood in for by replacing the main-process
 * handlers (hubAPI is frozen, so the IPC is what is stubbed):
 *   - the settings save the per-milestone templates, the customer editor the
 *     order-update consent;
 *   - a job walked quote → pending → printing → completed → shipped →
 *     delivered sends exactly one template per milestone, and writes one log
 *     line per send carrying orderId/milestone/messageId;
 *   - a customer who did not agree gets nothing, and nobody does once the
 *     shop's WhatsApp Business account is switched off;
 *   - the delivery reports polled from the cloud show on the job editor.
 *
 * Run: npm run test:e2e:customerupdates
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await electronApp.evaluate(({ ipcMain }) => {
    globalThis.__wabSent = [];
    globalThis.__reports = [];
    ipcMain.removeHandler('hub:send-whatsapp-template');
    ipcMain.handle('hub:send-whatsapp-template', (_e, req) => {
      globalThis.__wabSent.push({ to: req.to, template: req.template, params: req.params });
      return { ok: true, messageId: 'wamid.e2e' + globalThis.__wabSent.length };
    });
    ipcMain.removeHandler('hub:cloud-whatsapp-hook');
    ipcMain.handle('hub:cloud-whatsapp-hook', () => ({ ok: true, status: 200, hook: { configured: true } }));
    ipcMain.removeHandler('hub:cloud-whatsapp-statuses');
    ipcMain.handle('hub:cloud-whatsapp-statuses', (_e, { since } = {}) => ({
      ok: true, status: 200, items: since ? [] : globalThis.__reports, nextSince: 7,
    }));
  });

  await window.evaluate(() => {
    settings.mode = 'professional'; applyMode();
    settings.bizEn = 'Acme Prints';
    clients.push(
      { id: 'CLI-cu-a', nameEn: 'Amal', phone: '0501234567', createdAt: '2026-01-01' },
      { id: 'CLI-cu-b', nameEn: 'Badr', phone: '0501234568', createdAt: '2026-01-01' },
    );
    const job = (id, clientId) => ({ id, clientId, client: '', status: 'quote', price: 100, parts: [],
      date: '2026-11-01', statusHistory: [{ status: 'quote', at: '2026-11-01T08:00:00.000Z' }] });
    printLog.push(job('J-cu-1', 'CLI-cu-a'), job('J-cu-2', 'CLI-cu-b'));
    saveAll();
  });

  // The settings: WhatsApp Business, with a template per milestone.
  await window.evaluate(() => {
    settings.smsConfig = { provider: 'whatsapp_cloud', channel: 'whatsapp', phoneNumberId: '123456789', token: 'EAA' + 'x'.repeat(30) };
    renderSmsNotificationSettings();
  });
  await window.waitForSelector('[data-wab-name="received"]', { state: 'attached' });
  await window.evaluate(() => {
    const set = (sel, v) => { const el = document.querySelector(sel); el.value = v; };
    set('[data-wab-name="received"]', 'order_received'); set('[data-wab-langs="received"]', 'ar, en');
    set('[data-wab-name="ready"]', 'order_ready'); set('[data-wab-langs="ready"]', 'ar, en');
    set('[data-wab-name="shipped"]', 'Order Shipped'); set('[data-wab-langs="shipped"]', 'ar');
    document.getElementById('btnSaveSmsCfg').click();
  });
  ok(/✗/.test(await window.evaluate(() => document.getElementById('smsTestResult').textContent)),
    'a template name WhatsApp would refuse is said, not saved');
  await window.evaluate(() => {
    document.querySelector('[data-wab-name="shipped"]').value = 'order_shipped';
    document.querySelector('[data-wab-name="delivered"]').value = 'order_delivered';
    document.querySelector('[data-wab-langs="delivered"]').value = 'en';
    document.getElementById('btnSaveSmsCfg').click();
  });
  const tpl = await window.evaluate(() => settings.whatsappTemplates);
  ok(tpl && tpl.ready && tpl.ready.name === 'order_ready' && JSON.stringify(tpl.ready.langs) === '["ar","en"]'
    && tpl.delivered.name === 'order_delivered', `templates saved in the Mac's shape (${JSON.stringify(tpl)})`);

  // The customer editor: Amal agrees to order updates; Badr does not.
  await window.evaluate(() => openClientEditor('CLI-cu-a'));
  await window.waitForSelector('#ceWabUpdates');
  await window.check('#ceWabUpdates');
  await window.selectOption('#ceWabUpdatesHow', 'form');
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(200);
  const consent = await window.evaluate(() => clients.find((c) => c.id === 'CLI-cu-a').whatsappOptIn);
  ok(consent && consent.how === 'form' && !Number.isNaN(Date.parse(consent.at)), `order-update consent saved (${JSON.stringify(consent)})`);
  ok(await window.evaluate(() => !clients.find((c) => c.id === 'CLI-cu-a').whatsappMarketingOptIn), 'and it is not consent to offers');

  // Walk both jobs through every stage, the way the board moves them.
  const completeJob = async (id) => {
    await window.evaluate((jid) => updateStatus(jid, 'completed'), id);
    await window.waitForSelector('#actTime');
    await window.evaluate(() => document.querySelector('.modal [data-act="save"]').click());
    await window.waitForSelector('#actTime', { state: 'detached' }).catch(() => {});
  };
  for (const id of ['J-cu-1', 'J-cu-2']) {
    await window.evaluate((jid) => { updateStatus(jid, 'pending'); updateStatus(jid, 'printing'); }, id);
    await window.waitForTimeout(150);
    await completeJob(id);
    await window.waitForTimeout(150);
    await window.evaluate((jid) => markShipped(jid), id);
    await window.waitForTimeout(150);
    await window.evaluate((jid) => markDelivered(jid), id);
    await window.waitForTimeout(150);
  }
  await window.waitForTimeout(300);
  const sent = await electronApp.evaluate(() => globalThis.__wabSent);
  ok(sent.length === 4, `exactly one message per milestone (${sent.map((s) => s.template.name).join(', ')})`);
  ok(JSON.stringify(sent.map((s) => s.template.name)) === JSON.stringify(['order_received', 'order_ready', 'order_shipped', 'order_delivered']),
    'received, ready, shipped, delivered — in that order');
  ok(sent.every((s) => s.to === '966501234567'), 'all to the consenting customer; none to the one who did not agree');
  ok(JSON.stringify(sent[0].params) === JSON.stringify(['Amal', 'J-cu-1', 'Acme Prints']), `the template's values in the fixed order (${JSON.stringify(sent[0].params)})`);
  const log = await window.evaluate(() => clients.find((c) => c.id === 'CLI-cu-a').commLog);
  ok(log.length === 4 && log.every((l) => l.type === 'whatsapp' && l.orderId === 'J-cu-1' && l.via === 'whatsapp_cloud' && /^wamid\./.test(l.messageId)),
    'each send wrote the shared log line (type/orderId/milestone/messageId/via)');

  // Moving it back and forward again does not tell the customer twice.
  await window.evaluate(() => { updateStatus('J-cu-1', 'printing'); });
  await window.waitForTimeout(150);
  await completeJob('J-cu-1');
  await window.waitForTimeout(300);
  ok((await electronApp.evaluate(() => globalThis.__wabSent.length)) === 4, 'a step already sent is not sent again after a reopen');

  // With the account switched off, nothing is sent at all.
  await window.evaluate(() => {
    settings.smsConfig = { provider: 'none' };
    printLog.push({ id: 'J-cu-3', clientId: 'CLI-cu-a', client: '', status: 'quote', price: 1, parts: [], date: '2026-11-01',
      statusHistory: [{ status: 'quote', at: '2026-11-01T08:00:00.000Z' }] });
    updateStatus('J-cu-3', 'pending');
  });
  await window.waitForTimeout(300);
  ok((await electronApp.evaluate(() => globalThis.__wabSent.length)) === 4, 'notifications off: nothing sent');

  // Delivery reports from the cloud show on the job.
  await electronApp.evaluate(() => {
    globalThis.__reports = [
      { messageId: 'wamid.e2e1', status: 'read', at: '2026-11-07T10:00:00.000Z' },
      { messageId: 'wamid.e2e2', status: 'delivered', at: '2026-11-07T10:00:00.000Z' },
      { messageId: 'wamid.e2e3', status: 'failed', at: '2026-11-07T10:00:00.000Z', errorCode: 131026, errorTitle: 'Message undeliverable' },
    ];
  });
  await window.evaluate(async () => {
    settings.cloud = Object.assign({}, settings.cloud, { enabled: true, url: 'https://cloud.e2e.invalid', shopId: 'shop_e2e', token: 'tok' });
    await pollWhatsappReports();
  });
  const states = await window.evaluate(() => Object.fromEntries(
    clients.find((c) => c.id === 'CLI-cu-a').commLog.map((l) => [l.messageId, l.status])));
  ok(states['wamid.e2e1'] === 'read' && states['wamid.e2e2'] === 'delivered' && states['wamid.e2e3'] === 'failed' && states['wamid.e2e4'] === 'sent',
    `the reports moved the lines (${JSON.stringify(states)})`);
  await window.evaluate(() => openOrderEditor('J-cu-1'));
  await window.waitForSelector('#oeCustomerUpdates .cu-line');
  const box = await window.evaluate(() => ({
    lines: document.querySelectorAll('#oeCustomerUpdates .cu-line').length,
    states: [...document.querySelectorAll('#oeCustomerUpdates [data-cu-state]')].map((b) => b.dataset.cuState).sort(),
    text: document.getElementById('oeCustomerUpdates').innerText,
  }));
  ok(box.lines === 4, `the job editor lists the four updates (${box.lines})`);
  ok(JSON.stringify(box.states) === JSON.stringify(['delivered', 'failed', 'read', 'sent']), `each with its delivery state (${box.states.join(', ')})`);
  ok(/Message undeliverable/i.test(box.text), 'a failure says Meta\'s reason');
  await window.evaluate(() => document.querySelector('.modal [data-act="cancel"]')?.click());

  console.log('e2e-customer-updates: ok (one template per milestone to the consenting customer only; none when off; delivery reports on the job)');
} catch (err) {
  failed = true;
  console.error('e2e-customer-updates FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
