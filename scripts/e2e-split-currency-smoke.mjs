/**
 * E2E smoke — splitting a job keeps its currency (Windows/Linux).
 *
 * "Split across machines" built each part from a list of fields that left
 * out `currency`, so a EUR job became parts read in the customer's currency,
 * or the shop's: the same numbers, revalued. Here, through the real dialog:
 *   - a EUR job (with an fxRate) for a SAR-billed customer is split across
 *     two machines; every part is EUR at the parent's rate, and the parts'
 *     prices add back up to the parent's;
 *   - a job in the shop's own currency splits into parts that carry none,
 *     so their shape is unchanged.
 *
 * Run: npm run test:e2e:splitcurrency
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
    machines.push({ id: 'M-sc-1', name: 'Left', status: 'idle' }, { id: 'M-sc-2', name: 'Right', status: 'idle' });
    clients.push({ id: 'CLI-sc', nameEn: 'Sami', currency: 'SAR', createdAt: '2026-01-01' });
    const part = (n, cost) => ({ name: n, printTime: 1, printWeight: 10, baseCost: cost });
    printLog.push(
      { id: 'J-sc-eur', project: 'Gears', clientId: 'CLI-sc', currency: 'EUR', fxRate: 4.1, status: 'pending',
        price: 100, paidAmount: 0, date: '2026-11-01', parts: [part('A', 10), part('B', 30)] },
      { id: 'J-sc-sar', project: 'Hooks', clientId: 'CLI-sc', status: 'pending',
        price: 50, paidAmount: 0, date: '2026-11-01', parts: [part('C', 5), part('D', 5)] },
    );
    saveAll();
  });

  const split = async (id) => {
    await window.evaluate((i) => { splitOrderAcrossMachines(i); }, id);
    await window.waitForSelector('.split-mach-sel[data-pi="1"]', { timeout: 10000 });
    await window.selectOption('.split-mach-sel[data-pi="0"]', 'M-sc-1');
    await window.selectOption('.split-mach-sel[data-pi="1"]', 'M-sc-2');
    await window.click('#modalMount [data-act="save"]');
    await window.waitForFunction((i) => printLog.filter((o) => o.parentOrderId === i).length === 2, id, { timeout: 10000 });
    return window.evaluate((i) => printLog.filter((o) => o.parentOrderId === i), id);
  };

  const eur = await split('J-sc-eur');
  ok(eur.every((o) => o.currency === 'EUR'), `every part of the EUR job is EUR (${eur.map((o) => o.currency)})`);
  ok(eur.every((o) => o.fxRate === 4.1), 'at the parent\'s rate');
  const sum = eur.reduce((s, o) => s + o.price, 0);
  ok(Math.abs(sum - 100) < 0.005, `and the parts add back up to the parent's price (${sum})`);
  const read = await window.evaluate(() => printLog.filter((o) => o.parentOrderId === 'J-sc-eur')
    .map((o) => KhaytOrderMoney.orderCurrency(o, { clients, settings })));
  ok(read.every((c) => c === 'EUR'), `and the money reads them in EUR, not the customer's SAR (${read})`);

  const sar = await split('J-sc-sar');
  ok(sar.every((o) => !('currency' in o) && !('fxRate' in o)), 'a shop-currency job splits into parts with no currency, as before');

  console.log('e2e-split-currency: ok');
} catch (err) {
  failed = true;
  console.error('e2e-split-currency FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
