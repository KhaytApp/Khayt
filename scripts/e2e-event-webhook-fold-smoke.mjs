#!/usr/bin/env node
/**
 * E2E: the event webhook goes out through the bus's one fan-out.
 *
 * `settings.eventWebhooks` is a subscription the bus derives at read time
 * (lib/webhook-bus.js effectiveSubscriptions). What only the running desktop
 * can show:
 *   - the body that leaves is still `buildWebhookEvent`'s envelope, byte for
 *     byte (`order.status`, not the bus's `status_changed` body);
 *   - a URL that the subscriptions list also points at for the same moment is
 *     posted to once, by the subscription;
 *   - a failed delivery is queued with the whole envelope and survives a
 *     restart — before the fold, its retry was dropped at boot;
 *   - nothing is written into `settings.webhooks.subscriptions`.
 *
 *   node scripts/e2e-event-webhook-fold-smoke.mjs
 */
import fs from 'node:fs';
import { dismissWizard, launchApp, makeUserDataDir } from './e2e/helpers.mjs';

const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
const HOOK = 'https://erp.example.com/hook';

const stub = (electronApp, status) => electronApp.evaluate(({ ipcMain }, st) => {
  globalThis.__posts = [];
  ipcMain.removeHandler('hub:fire-webhook');
  ipcMain.handle('hub:fire-webhook', (_e, req) => {
    globalThis.__posts.push({ url: req.url, event: req.event, body: JSON.stringify(req.payload), secret: req.secret });
    return st === 200 ? { ok: true, status: 200 } : { ok: false, status: st, error: 'HTTP ' + st };
  });
}, status);
const posts = (electronApp) => electronApp.evaluate(() => globalThis.__posts);

let electronApp;
try {
  // ── session 1 ──
  let launched = await launchApp(userData);
  electronApp = launched.electronApp;
  let window = launched.window;
  await dismissWizard(window);
  await stub(electronApp, 200);

  const expected = await window.evaluate((url) => {
    settings.eventWebhooks = { enabled: true, url, secret: 'ev-secret', events: { created: true, status: true, paid: true } };
    settings.webhooks = { enabled: true, subscriptions: [
      { id: 's1', url: url + '/', events: ['status_changed'], enabled: true },
    ], deliveries: [], pending: [] };
    saveAll();
    const order = { id: 'ORD-ev1', project: 'Vase', status: 'printing', price: 90, date: localDateStr(), parts: [] };
    printLog.push(order);
    fireOrderWebhook('created', order);
    fireOrderWebhook('status', order);           // shadowed: s1 listens to status_changed at this URL
    fireStatusWebhook('status_changed', order, 'printing');
    return { subs: settings.webhooks.subscriptions.map((s) => s.id) };
  }, HOOK);
  await window.waitForTimeout(800);
  let sent = await posts(electronApp);
  const created = sent.filter((p) => p.event === 'order.created');
  const statusPosts = sent.filter((p) => /status/.test(p.event));
  if (created.length !== 1) fail(`order.created not sent once: ${JSON.stringify(sent)}`);
  const env = JSON.parse(created[0].body);
  if (Object.keys(env).join() !== 'id,event,at,shop,order' || env.order.id !== 'ORD-ev1') fail(`envelope changed: ${created[0].body}`);
  if (created[0].secret !== '__KHAYT_MASKED__' && created[0].secret !== 'ev-secret') fail(`event webhook secret: ${created[0].secret}`);
  if (statusPosts.length !== 1 || statusPosts[0].event !== 'status_changed') fail(`status moment not sent exactly once, by the subscription: ${JSON.stringify(statusPosts)}`);
  const stored = await window.evaluate(() => settings.webhooks.subscriptions.map((s) => s.id));
  if (stored.join() !== expected.subs.join()) fail(`the event webhook was persisted into subscriptions: ${stored}`);

  // ── a failed event-webhook delivery queues the whole envelope ──
  await stub(electronApp, 503);
  await window.evaluate(() => {
    settings.webhooks.subscriptions = [];
    fireOrderWebhook('paid', printLog.find((o) => o.id === 'ORD-ev1'));
  });
  await window.waitForFunction(() => ((settings.webhooks || {}).pending || []).some((p) => p.subscriptionId === 'event:legacy'), null, { timeout: 15000 });
  const pending = await window.evaluate(() => settings.webhooks.pending.find((p) => p.subscriptionId === 'event:legacy'));
  if (!pending.payload || pending.payload.event !== 'order.paid') fail(`retry lost its envelope: ${JSON.stringify(pending)}`);
  const firstBody = (await posts(electronApp)).find((p) => p.event === 'order.paid').body;
  await window.evaluate(() => flushSave());
  await window.waitForTimeout(800);
  await electronApp.close();

  // ── session 2: the retry resumes with the same bytes ──
  launched = await launchApp(userData);
  electronApp = launched.electronApp;
  window = launched.window;
  await dismissWizard(window);
  await stub(electronApp, 200);
  await window.evaluate(async () => {
    settings.webhooks.pending = settings.webhooks.pending.map((p) => ({ ...p, nextAttemptAt: '2020-01-01T00:00:00Z' }));
    resumePendingWebhooks();
    await new Promise((r) => setTimeout(r, 1500));
  });
  sent = await posts(electronApp);
  const resumed = sent.filter((p) => p.event === 'order.paid');
  if (resumed.length !== 1) fail(`retry did not survive the restart: ${JSON.stringify(sent)}`);
  if (resumed[0].body !== firstBody) fail('the resumed retry sent different bytes than the first attempt');
  if (resumed[0].url !== HOOK) fail(`resumed to the wrong URL: ${resumed[0].url}`);

  console.log('event webhook fold smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}
