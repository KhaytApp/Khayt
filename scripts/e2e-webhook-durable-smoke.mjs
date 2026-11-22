/**
 * E2E smoke — durable webhook retry queue.
 *
 * The property that matters: a delivery still mid-backoff when the app quits is RESUMED on
 * the next launch, rather than silently lost. Proven across two real Electron sessions
 * sharing one userData dir.
 *
 * Run: npm run test:e2e:webhookretry   (CI wraps it in xvfb-run)
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const userData = makeUserDataDir();   // shared across both sessions
let failed = false;
try {
  // ── Session 1: a delivery fails and schedules a durable retry ──────────
  {
    const { electronApp, window } = await launchApp(userData);
    await dismissWizard(window);
    await window.evaluate(() => {
      settings.webhooks = {
        enabled: true,
        subscriptions: [{ id: 's1', url: 'https://unreachable.invalid/hook', events: ['order_shipped'], enabled: true, secret: '' }],
        deliveries: [], pending: [],
      };
      saveAll();
      return fireWebhook('order_shipped', { orderId: 'O-DUR' });
    });
    // The host cannot resolve, so the delivery fails and must be queued for retry.
    await window.waitForFunction(() => ((settings.webhooks || {}).pending || []).length >= 1, { timeout: 15000 });
    const pending = await window.evaluate(() => settings.webhooks.pending);
    ok(pending.length === 1, 'failed delivery persisted a pending retry');
    ok(pending[0].subscriptionId === 's1', 'pending retry knows its subscription');
    ok(pending[0].attempt >= 2, `retry recorded as attempt ${pending[0].attempt}`);
    ok(!!Date.parse(pending[0].nextAttemptAt), 'pending retry carries an absolute due time');
    // Force the store to disk, then quit mid-backoff.
    await window.evaluate(() => flushSave());
    await new Promise(r => setTimeout(r, 800));
    await electronApp.close();
    console.log('  … app quit while the retry was still pending');
  }

  // ── Session 2: relaunch — the pending retry must survive and resume ────
  {
    const { electronApp, window } = await launchApp(userData);
    await dismissWizard(window);
    const survived = await window.evaluate(() => ((settings.webhooks || {}).pending || []).length);
    ok(survived >= 1, 'pending retry survived the restart (durable, not lost)');

    // Make it due in the past so boot-resume fires it immediately, then resume.
    const fired = await window.evaluate(async () => {
      settings.webhooks.pending = settings.webhooks.pending.map(p => ({ ...p, nextAttemptAt: '2020-01-01T00:00:00Z' }));
      saveAll();
      const before = (settings.webhooks.deliveries || []).length;
      resumePendingWebhooks();
      await new Promise(r => setTimeout(r, 2500));
      return { before, after: (settings.webhooks.deliveries || []).length };
    });
    ok(fired.after > fired.before, 'boot-resume re-attempted the overdue delivery');

    // A pending retry whose subscription was deleted is dropped, not retried forever.
    await window.evaluate(async () => {
      settings.webhooks.subscriptions = [];
      settings.webhooks.pending = [{ id: 'orphan', subscriptionId: 'gone', event: 'order_shipped', payload: {}, attempt: 2, nextAttemptAt: '2020-01-01T00:00:00Z' }];
      saveAll();
      resumePendingWebhooks();
      await new Promise(r => setTimeout(r, 800));
    });
    const orphans = await window.evaluate(() => (settings.webhooks.pending || []).filter(p => p.id === 'orphan').length);
    ok(orphans === 0, 'retry for a deleted subscription is dropped, not retried forever');

    await electronApp.close();
  }

  console.log('\n✅ Durable webhook retry smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
}
process.exit(failed ? 1 : 0);
