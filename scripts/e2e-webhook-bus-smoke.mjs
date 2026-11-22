/**
 * E2E smoke — outbound webhook event bus (PUBLIC-API-SPEC §2).
 *
 * Proves that:
 *   - one event fans out to EVERY enabled subscription listening for it,
 *   - a disabled subscription and a non-listening one are skipped,
 *   - the delivery log records each attempt.
 *
 * The transport is the real hardened main-process POST, so the target hosts do not resolve
 * and every delivery legitimately fails — that is fine and intentional: what we assert is
 * the bus's *fan-out decisions* and its delivery log, which are recorded either way.
 * (hubAPI is a contextBridge object and cannot be stubbed from the page.)
 *
 * Run: npm run test:e2e:webhooks   (CI wraps it in xvfb-run)
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  await window.evaluate(() => {
    settings.webhooks = {
      enabled: true,
      subscriptions: [
        { id: 's1', url: 'https://a.example/hook', events: ['order_shipped', 'order_created'], enabled: true, secret: 'k1' },
        { id: 's2', url: 'https://b.example/hook', events: ['order_shipped'], enabled: true, secret: '' },
        { id: 's3', url: 'https://c.example/hook', events: ['order_shipped'], enabled: false, secret: '' },
        { id: 's4', url: 'https://d.example/hook', events: ['payment_received'], enabled: true, secret: '' },
      ],
      deliveries: [],
    };
    saveAll();
  });

  await window.evaluate(() => fireWebhook('order_shipped', { orderId: 'O-1' }));
  // Each attempted subscription writes a delivery-log row, whatever the transport result.
  await window.waitForFunction(() => ((settings.webhooks || {}).deliveries || []).length >= 2, { timeout: 15000 });
  await new Promise(r => setTimeout(r, 400));

  const log = await window.evaluate(() => settings.webhooks.deliveries);
  const subs = log.map(d => d.subscriptionId).sort();
  ok(log.length === 2, `one event fanned out to exactly 2 listeners (${log.length})`);
  ok(subs[0] === 's1' && subs[1] === 's2', 'to the right two subscriptions');
  ok(!subs.includes('s3'), 'disabled subscription skipped');
  ok(!subs.includes('s4'), 'non-listening subscription skipped');
  ok(log.every(d => d.event === 'order_shipped'), 'logged against the right event');
  ok(new Set(log.map(d => d.id)).size === 2, 'each delivery carries its own idempotency id');

  // An event with no listeners is a silent no-op (no new log rows).
  const before = log.length;
  await window.evaluate(() => fireWebhook('printer_alert', {}));
  await new Promise(r => setTimeout(r, 800));
  const after = await window.evaluate(() => settings.webhooks.deliveries.length);
  ok(after === before, 'event with no subscription is a no-op');

  // Legacy one-URL-per-event config migrates to subscriptions.
  const migrated = await window.evaluate(() => {
    settings.webhooks = { enabled: true, secret: 'legacy', events: { order_created: 'https://old.example/h', status_changed: 'https://old.example/h' } };
    const subs = webhookSubscriptions();
    // What a delivery to it is signed with: the shop's one shared secret.
    return subs.map(s => ({ ...s, signsWith: KhaytWebhookBus.subscriptionSecret(s, settings.webhooks) }));
  });
  ok(migrated.length === 1, 'legacy config collapsed to one subscription per URL');
  ok(migrated[0].events.length === 2, 'both legacy events attached to it');
  // The secret is never copied onto a subscription: that path is not sealed,
  // and it reached paired phones unmasked (lib/store-secret-paths.js DROP_PATHS).
  ok(!migrated[0].secret, 'a migrated subscription carries no secret of its own');
  ok(migrated[0].signsWith === 'legacy', 'it still signs with the shop\'s shared secret');

  console.log('\n✅ Webhook bus smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
