/**
 * E2E smoke — the invoice charges the right tax for the shop's country.
 *
 * lib/tax.js is pure and heavily unit-tested, including a 12,000-case sweep of
 * the rounding invariant. What it cannot tell you is whether the INVOICE uses
 * it. The old arithmetic was written out by hand in ten places, and the total on
 * the rendered document was `fmtMoney(price)` — correct only because price was
 * assumed to already include the tax. Under exclusive pricing that line invoices
 * a US shop for less than it is charging, and no unit test would notice.
 *
 * So this renders the real document under three regimes and reads the money back
 * off the page.
 *
 * Run: npm run test:e2e:tax
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  const render = (patch) => window.evaluate(async (p) => {
    // Reset the profile each time: a leftover `tax` object would silently make
    // the legacy case pass by using the new path.
    delete settings.tax;
    Object.assign(settings, p);
    settings.enableZatca = false;
    settings.invoiceBilingual = 'single';
    clients.length = 0;
    clients.push({ id: 'C1', name: 'Acme' });
    const order = {
      id: 'O1', status: 'completed', clientId: 'C1', project: 'Acme',
      date: '2026-08-11', price: 100, material: 'PLA', printTime: 4,
      parts: [{ name: 'Part', material: 'PLA', printTime: 4, printWeight: 100, baseCost: 100 }],
      extraLines: [],
    };
    await renderInvoiceForOrder(order);
    const txt = document.querySelector('#invoice-print-area').innerText.replace(/\s+/g, ' ');
    const num = (re) => { const m = txt.match(re); return m ? Number(String(m[1]).replace(/,/g, '')) : null; };
    return { total: num(/Total due ([\d.,]+)/), subtotal: num(/Subtotal ([\d.,]+)/), text: txt };
  }, patch);

  // ---- an existing shop must be untouched ----
  // Every shop in the field has these two fields and nothing else. If this moves
  // by a cent, the change has silently re-priced every invoice they issue.
  const legacy = await render({ enableVat: true, vatRate: 15, currency: 'SAR' });
  ok(legacy.total === 100, `a VAT-inclusive shop still invoices the listed price (${legacy.total})`);
  ok(/15/.test(legacy.text), 'and the VAT figure is still shown');

  // ---- the case the old model could not express ----
  const us = await render({
    currency: 'USD',
    tax: { country: 'US', name: 'Sales Tax', mode: 'exclusive', registration: 'EIN',
      rates: [{ id: 'st', label: 'Sales Tax', percent: 8.25 }] },
  });
  ok(us.total === 108.25, `a US shop invoices 100 + 8.25% = 108.25, not 100 (${us.total})`);
  ok(us.subtotal === 100, `and the pre-tax figure is still 100 (${us.subtotal})`);

  // ---- more than one tax ----
  const india = await render({
    currency: 'USD',
    tax: { country: 'IN', name: 'GST', mode: 'exclusive', registration: 'GSTIN',
      rates: [{ id: 'cgst', label: 'CGST', percent: 9 }, { id: 'sgst', label: 'SGST', percent: 9 }] },
  });
  ok(india.total === 118, `two taxes both reach the total: 100 + 9% + 9% = 118 (${india.total})`);

  // ---- no tax at all ----
  const none = await render({ enableVat: false, currency: 'USD' });
  ok(none.total === 100, `a shop that charges no tax invoices exactly the price (${none.total})`);

  console.log('\ntax smoke: all assertions passed');
} catch (err) {
  failed = true;
  console.error('\n' + (err && err.message ? err.message : String(err)));
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
