/**
 * E2E smoke — a campaign through the shop's WhatsApp Business account.
 *
 * Owner's decisions (2026-10-24): a WhatsApp Business campaign sends an
 * approved template, never free text (Meta refuses free text to anyone quiet
 * for 24 hours), and it goes only to customers who agreed to OFFERS on
 * WhatsApp — a consent of its own, apart from agreeing to order updates.
 *
 * Here: the customer editor records the offers consent (date kept, "how"
 * editable, unticking withdraws it); the campaign offers the WhatsApp
 * Business channel, counts only the consenting customer, refuses to send
 * without a template, and sends the template with one value per line. Meta is
 * stood in for by replacing the main-process handler.
 *
 * Run: npm run test:e2e:wabcampaign
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  // Stand in for Meta: record what the window asked main to send.
  await electronApp.evaluate(({ ipcMain }) => {
    globalThis.__wabSent = [];
    ipcMain.removeHandler('hub:send-whatsapp-template');
    ipcMain.handle('hub:send-whatsapp-template', (_e, req) => {
      globalThis.__wabSent.push({ to: req.to, template: req.template, params: req.params });
      return { ok: true, messageId: 'wamid.e2e' + globalThis.__wabSent.length };
    });
  });
  await window.evaluate(() => {
    settings.mode = 'professional'; applyMode();
    settings.smsConfig = { provider: 'whatsapp_cloud', channel: 'whatsapp', phoneNumberId: '123456789', token: 'EAA' + 'x'.repeat(30) };
    clients.push(
      { id: 'CLI-wa-a', nameEn: 'Amal', phone: '0501234567', createdAt: '2026-01-01' },
      { id: 'CLI-wa-b', nameEn: 'Badr', phone: '0501234568', createdAt: '2026-01-01', whatsappOptIn: { at: '2026-10-01T09:00:00.000Z', how: 'asked' } },
    );
    saveAll();
  });

  // The customer editor records the offers consent.
  await window.evaluate(() => openClientEditor('CLI-wa-a'));
  await window.waitForSelector('#ceWabOffers');
  ok(await window.evaluate(() => getComputedStyle(document.getElementById('ceWabOffersHow')).display === 'none'), '"how" is hidden until the box is ticked');
  await window.check('#ceWabOffers');
  ok(await window.evaluate(() => getComputedStyle(document.getElementById('ceWabOffersHow')).display !== 'none'), 'ticking shows "how"');
  await window.selectOption('#ceWabOffersHow', 'form');
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(200);
  const a = await window.evaluate(() => clients.find((c) => c.id === 'CLI-wa-a').whatsappMarketingOptIn);
  ok(a && a.how === 'form' && !Number.isNaN(Date.parse(a.at)), `saved with its date and how (${JSON.stringify(a)})`);
  const b = await window.evaluate(() => clients.find((c) => c.id === 'CLI-wa-b'));
  ok(!b.whatsappMarketingOptIn && b.whatsappOptIn, 'order-update consent is left as it was, and is not offers consent');

  // Changing only "how" keeps the date.
  await window.evaluate(() => openClientEditor('CLI-wa-a'));
  await window.waitForSelector('#ceWabOffersHow');
  await window.selectOption('#ceWabOffersHow', 'customer_wrote');
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(200);
  const a2 = await window.evaluate(() => clients.find((c) => c.id === 'CLI-wa-a').whatsappMarketingOptIn);
  ok(a2.at === a.at && a2.how === 'customer_wrote', 'changing "how" keeps the day it was given');

  // The campaign.
  await window.evaluate(() => openCampaignModal());
  await window.waitForSelector('#campChannel');
  const opts = await window.evaluate(() => [...document.querySelectorAll('#campChannel option')].map((o) => o.value));
  ok(opts.includes('whatsapp_business') && !opts.includes('sms'), `the channel is WhatsApp Business, with no free-text path (${opts.join(', ')})`);
  await window.selectOption('#campChannel', 'whatsapp_business');
  await window.fill('#campBody', '{{name}}\n{{orders}}');
  await window.waitForTimeout(400);
  const view = await window.evaluate(() => ({
    count: document.getElementById('campCount').textContent,
    fields: getComputedStyle(document.getElementById('campWabFields')).display,
    preview: document.getElementById('campPreview').textContent,
  }));
  ok(view.count === '1', `only the customer who agreed to offers is counted (${view.count})`);
  ok(view.fields !== 'none' && /\{\{1\}\} Amal/.test(view.preview) && /966501234567/.test(view.preview), `the template fields show, and the preview fills slot 1 (${view.preview.replace(/\n/g, ' | ')})`);

  await window.fill('#campWabName', '');
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(200);
  ok(/template/i.test(await window.evaluate(() => document.getElementById('campResult').textContent)), 'no template name: refused before anything is sent');

  await window.fill('#campWabName', 'spring_offer');
  await window.fill('#campWabLang', 'ar');
  await window.click('.modal [data-act="save"]');
  await window.waitForSelector('.confirm-modal-overlay [data-act="ok"]');
  await window.click('.confirm-modal-overlay [data-act="ok"]');
  await window.waitForFunction(() => /✓/.test(document.getElementById('campResult')?.textContent || ''), null, { timeout: 10000 });
  const sent = await electronApp.evaluate(() => globalThis.__wabSent);
  ok(sent.length === 1 && sent[0].to === '966501234567', `one send, to the consenting customer's WhatsApp number (${JSON.stringify(sent.map((s) => s.to))})`);
  ok(sent[0].template.name === 'spring_offer' && sent[0].template.language === 'ar', 'the approved template, by name and language');
  ok(JSON.stringify(sent[0].params) === JSON.stringify(['Amal', '0']), `one value per line, merged (${JSON.stringify(sent[0].params)})`);
  ok(await window.evaluate(() => settings.campaignWaTemplate && settings.campaignWaTemplate.name === 'spring_offer'), 'the template is remembered for next time');
  await window.click('.modal [data-act="cancel"]');

  // Unticking withdraws it.
  await window.evaluate(() => openClientEditor('CLI-wa-a'));
  await window.waitForSelector('#ceWabOffers');
  await window.uncheck('#ceWabOffers');
  await window.click('.modal [data-act="save"]');
  await window.waitForTimeout(200);
  ok(await window.evaluate(() => !('whatsappMarketingOptIn' in clients.find((c) => c.id === 'CLI-wa-a'))), 'unticking removes the consent');

  // Arabic.
  await window.evaluate(() => { settings.lang = 'ar'; i18n.set('ar'); openClientEditor('CLI-wa-b'); });
  await window.waitForSelector('#ceWabOffers');
  const ar = await window.evaluate(() => document.getElementById('ceWabOffers').closest('label').innerText);
  ok(/وافق على تلقي العروض عبر واتساب/.test(ar), `the checkbox is translated (${ar.trim()})`);

  console.log('e2e-wab-campaign: ok (offers consent recorded and withdrawn; campaign counts only consenting customers; sends the approved template with merged values)');
} catch (err) {
  failed = true;
  console.error('e2e-wab-campaign FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
