/**
 * E2E smoke — a customer's currency never revalues their jobs (Windows/Linux).
 *
 * A job in the shop's currency carries no `currency` and is read in its
 * customer's. So giving a customer EUR in the editor turned their paid
 * 1,000 SAR jobs into 1,000 EUR, and a subscription billed in riyals for a
 * EUR customer read as EUR from the day it was made. Here:
 *   - the customer editor's Save pins each unstamped job at the currency it is
 *     in BEFORE the change; a job that already says its own is left alone;
 *     a save that keeps the currency stamps nothing;
 *   - a subscription bill for a EUR customer says SAR (the amount's currency);
 *     one for a customer in the shop's currency carries none, as before;
 *   - a repeat-order child says the currency its parent is read in.
 *
 * Run: npm run test:e2e:pincurrency
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate(() => {
    settings.mode = 'professional'; applyMode();
    settings.currency = 'SAR';
    settings.exchangeRates = Object.assign({}, settings.exchangeRates, { EUR: 4.1 });
    clients.push(
      { id: 'CLI-pc-a', nameEn: 'Amal', createdAt: '2026-01-01' },
      { id: 'CLI-pc-b', nameEn: 'Badr', currency: 'EUR', createdAt: '2026-01-01' },
    );
    printLog.push(
      { id: 'J-pc-1', project: 'Cup', clientId: 'CLI-pc-a', status: 'completed', price: 1000, paidAmount: 1000, date: '2026-10-01', parts: [] },
      { id: 'J-pc-2', project: 'Mug', clientId: 'CLI-pc-a', currency: 'USD', status: 'completed', price: 50, paidAmount: 50, date: '2026-10-01', parts: [] },
      { id: 'J-pc-3', project: 'Box', clientId: 'CLI-pc-b', status: 'pending', price: 20, paidAmount: 0, date: '2026-10-01', parts: [] },
    );
    saveAll();
  });

  // A save that keeps the currency stamps nothing.
  await window.evaluate(() => openClientEditor('CLI-pc-a'));
  await window.waitForSelector('#ceCurrency', { timeout: 10000 });
  await window.click('#modalMount [data-act="save"]');
  await window.waitForSelector('#ceCurrency', { state: 'detached', timeout: 10000 });
  ok(await window.evaluate(() => !('currency' in printLog.find((o) => o.id === 'J-pc-1'))), 'a save that keeps the currency stamps nothing');

  // Give Amal EUR.
  await window.evaluate(() => openClientEditor('CLI-pc-a'));
  await window.waitForSelector('#ceCurrency', { timeout: 10000 });
  await window.selectOption('#ceCurrency', 'EUR');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForSelector('#ceCurrency', { state: 'detached', timeout: 10000 });
  const after = await window.evaluate(() => ({
    client: clients.find((c) => c.id === 'CLI-pc-a').currency,
    j1: printLog.find((o) => o.id === 'J-pc-1').currency,
    j2: printLog.find((o) => o.id === 'J-pc-2').currency,
    j3: printLog.find((o) => o.id === 'J-pc-3').currency,
    read: orderCurrency(printLog.find((o) => o.id === 'J-pc-1')),
    base: orderRevenueBase(printLog.find((o) => o.id === 'J-pc-1')),
  }));
  ok(after.client === 'EUR', 'the customer bills in EUR now');
  ok(after.j1 === 'SAR' && after.read === 'SAR', `their old riyal job still reads SAR (${after.j1}/${after.read})`);
  ok(Math.abs(after.base - 1000) < 0.005, `and is still 1,000 of revenue, not 4,100 (${after.base})`);
  ok(after.j2 === 'USD', 'a job that said its own currency is left alone');
  ok(after.j3 === undefined, "another customer's job is not touched");

  // Subscriptions.
  const subs = await window.evaluate(() => {
    const due = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    subscriptions.push(
      { id: 'SUB-pc-b', planName: 'Retainer', clientId: 'CLI-pc-b', amount: 300, interval: 'monthly', nextRunAt: due, status: 'active', createdAt: due },
      { id: 'SUB-pc-0', planName: 'Walk-in', clientId: null, amount: 90, interval: 'monthly', nextRunAt: due, status: 'active', createdAt: due },
    );
    checkSubscriptionBilling();
    const of = (id) => printLog.find((o) => o.subscriptionId === id);
    return { b: of('SUB-pc-b'), z: of('SUB-pc-0'), bRead: orderCurrency(of('SUB-pc-b')) };
  });
  ok(subs.b && subs.b.currency === 'SAR' && subs.bRead === 'SAR', `a EUR customer's subscription bill is in riyals, as typed (${subs.b && subs.b.currency})`);
  ok(subs.z && !('currency' in subs.z), 'one in the shop\'s currency carries none, as before');

  // A repeat-order child.
  const rec = await window.evaluate(() => {
    const today = localDateStr();
    printLog.push(
      { id: 'J-pc-rb', project: 'Tray', clientId: 'CLI-pc-b', status: 'completed', price: 40, paidAmount: 0, date: today, parts: [], isRecurring: true, recurringInterval: 'monthly', nextDueDate: today },
      { id: 'J-pc-r0', project: 'Clip', clientId: null, status: 'completed', price: 10, paidAmount: 0, date: today, parts: [], isRecurring: true, recurringInterval: 'monthly', nextDueDate: today },
    );
    processRecurringOrders();
    const of = (id) => printLog.find((o) => o.parentRecurringId === id);
    return { b: of('J-pc-rb'), z: of('J-pc-r0') };
  });
  ok(rec.b && rec.b.currency === 'EUR', `a repeat of a EUR customer's job says EUR (${rec.b && rec.b.currency})`);
  ok(rec.z && !('currency' in rec.z), 'a repeat in the shop\'s currency carries none');

  console.log('e2e-pin-currency: ok');
} catch (err) {
  failed = true;
  console.error('e2e-pin-currency FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
