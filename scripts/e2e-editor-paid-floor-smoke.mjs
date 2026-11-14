/**
 * E2E: the job editor never drops a bill below what was paid (Figma 95:596),
 * with real clicks. Sample data only.
 *
 * A job priced 340 with 300 already paid: raising the discount to 50 % would
 * bill 170. The editor used to save it and quietly cap the payment at 170;
 * now Save is refused with the reason, the sheet stays open, and the job and
 * its payment are unchanged. Taking the discount back to 0 saves.
 *
 * Run: npm run test:e2e:paidfloor
 */
import { launchApp, dismissWizard, makeUserDataDir, switchTab } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
const job = () => window.evaluate(() => { const o = printLog.find((x) => x.id === 'PF-1'); return { price: o.price, paid: o.paidAmount, disc: o.discountPct || 0 }; });

try {
  await dismissWizard(window);
  await window.evaluate(() => {
    settings.mode = 'professional'; settings.currency = 'SAR'; settings.enableVat = false;
    KhaytShell.applyMode();
    printLog.unshift({
      id: 'PF-1', jobNumber: 'PF-1', status: 'pending', currency: 'SAR', date: '2026-11-12', project: 'Paid floor',
      price: 340, paidAmount: 300, paidAt: '2026-11-12T09:00:00Z', discountPct: 0, material: 'PLA',
      statusHistory: [{ status: 'pending', at: '2026-11-12T08:00:00Z' }],
      parts: [{ name: 'part.stl', material: 'PLA', qty: 1, printWeight: 100, baseCost: 40 }],
    });
    saveAll();
    return flushSave();
  });

  await switchTab(window, 'logs-tab');
  await window.click('[data-act="edit-log"][data-id="PF-1"]');
  await window.waitForSelector('#modalMount .modal-form [data-f="discountPct"]', { state: 'visible', timeout: 5_000 });
  await window.fill('#modalMount [data-f="discountPct"]', '50');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForSelector('#modalMount .oe-refused', { state: 'visible', timeout: 5_000 });
  const why = await window.textContent('#modalMount .oe-refused');
  ok(/already paid/.test(why) && /300/.test(why), `a 50 % discount on a job with 300 paid is refused, with the reason (${why.trim()})`);
  ok(await window.isVisible('#modalMount .modal-form'), 'the editor stays open');
  const after = await job();
  ok(after.price === 340 && after.paid === 300 && after.disc === 0, `the job and its payment are unchanged (${JSON.stringify(after)})`);

  await window.fill('#modalMount [data-f="discountPct"]', '0');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForFunction(() => !document.querySelector('#modalMount .modal-form'), null, { timeout: 5_000 });
  ok(true, 'with the discount back at 0, Save goes through and the editor closes');
  ok((await job()).paid === 300, 'the 300 paid is still on the record');

  console.log('e2e-editor-paid-floor: ok');
} catch (err) {
  failed = true;
  console.error('e2e-editor-paid-floor FAILED:', err && err.message);
} finally {
  await electronApp.close();
  process.exit(failed ? 1 : 0);
}
