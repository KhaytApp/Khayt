/**
 * E2E smoke — marketplace fee presets, and a low-stock colour of your own.
 *
 * Both come from issue #364. Both are UI wiring, which is exactly the class a
 * unit test cannot vouch for: lib/platform-fees.js can be perfect while the
 * dropdown appends nothing, and the CSS token can exist while no code sets it.
 *
 * The two assertions that carry the most weight:
 *   - picking a second marketplace REPLACES the first one's fees rather than
 *     stacking them, which a shop would otherwise discover on a finished invoice;
 *   - recolouring low stock does NOT recolour --warning, which also paints
 *     overdue jobs and spool age.
 *
 * Run: npm run test:e2e:david
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);
  await window.evaluate(() => { settings.mode = 'pro'; applyMode(); saveAll(); });

  // ── marketplace fees ────────────────────────────────────────────────────
  const fees = await window.evaluate(() => {
    currentExtraLines.length = 0;
    currentExtraLines.push({ id: 'EL1', label: 'Rush', amount: 15 });   // the shop's own
    const sel = document.querySelector('#platformFeeSelect');
    sel.value = 'etsy';
    sel.dispatchEvent(new Event('change'));
    const etsy = currentExtraLines.map((l) => ({ label: l.label, pct: l.pct, amount: l.amount }));
    sel.value = 'shopify';
    sel.dispatchEvent(new Event('change'));
    const swapped = currentExtraLines.map((l) => l.label);
    sel.value = '';
    sel.dispatchEvent(new Event('change'));
    return { etsy, swapped, cleared: currentExtraLines.map((l) => l.label) };
  });

  ok(fees.etsy.length === 4, `Etsy adds its fees alongside the shop's own line (${fees.etsy.length} lines)`);
  ok(fees.etsy.filter((l) => l.pct != null).length === 2, 'two percentage fees, as Etsy charges');
  ok(fees.etsy.some((l) => l.amount === 0.20), 'and the 0.20 listing fee he named');
  ok(fees.etsy[0].label === 'Rush', "the shop's own line stays first and untouched");

  ok(!fees.swapped.some((l) => /Etsy/.test(l)), 'switching marketplace REMOVES the previous one’s fees');
  ok(fees.swapped.filter((l) => /Shopify/.test(l)).length === 2, 'and adds the new one’s');
  ok(fees.swapped[0] === 'Rush', "without disturbing the shop's own line");

  ok(fees.cleared.length === 1 && fees.cleared[0] === 'Rush',
    'choosing no marketplace strips the fees and leaves the rest');

  // ── low-stock colour ────────────────────────────────────────────────────
  // Asserted across every theme in BOTH appearances, because the first version
  // of this shipped --low-stock as a literal #f5a623 while every theme darkens
  // --warning for light appearance to clear WCAG AA. Low stock renders as text,
  // so on the seven light themes it sat at 1.77–2.03:1 where --warning measured
  // 4.71–5.93:1 — and a single-theme test could not see it.
  const colour = await window.evaluate(() => {
    const read = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
    const rows = [];
    for (const id of ['khayt', 'workbench', 'blueprint', 'command', 'foreman', 'meridian', 'nocturne', 'vivid']) {
      for (const appearance of ['light', 'dark']) {
        settings.designTheme = id;
        settings.theme = appearance;
        settings.lowStockColor = '';
        if (typeof applyTheme === 'function') applyTheme(appearance);
        applyDesignSettings();
        if (typeof loadSettingsIntoForm === 'function') loadSettingsIntoForm();
        const untouched = { warning: read('--warning'), lowStock: read('--low-stock'),
                            swatch: document.querySelector('#set_lowStockColor')?.value };
        settings.lowStockColor = '#e11d48';
        applyDesignSettings();
        rows.push({ id, appearance, ...untouched,
                    overridden: read('--low-stock'), warningAfter: read('--warning') });
        settings.lowStockColor = '';
        applyDesignSettings();
      }
    }
    return rows;
  });

  ok(colour.length === 16, `checked every theme in both appearances (${colour.length})`);
  ok(colour.every((r) => r.lowStock === r.warning),
    'an untouched shop gets the THEME\'s low-stock colour, not a fixed amber');
  ok(colour.every((r) => r.swatch === r.lowStock),
    'and the settings swatch shows the colour actually in force');
  ok(colour.every((r) => r.overridden === '#e11d48'),
    "the shop's own choice wins in every theme");
  ok(colour.every((r) => r.warningAfter === r.warning),
    '--warning is NOT dragged along — it still paints overdue jobs and spool age');
  ok(new Set(colour.map((r) => r.lowStock)).size > 1,
    'and the colours genuinely differ between themes (so this is not passing vacuously)');

  // ── product documents ───────────────────────────────────────────────────
  // The split between the two sheets IS the feature, and it is only observable
  // by rendering both. The first version of this shipped the documents inside
  // the courier/tracking block, so an order handed over in person listed
  // nothing — and every unit test still passed.
  const docs = await window.evaluate(async () => {
    settings.invoiceBilingual = 'single';
    settings.enableZatca = false;
    products.length = 0;
    products.push({ id: 'PROD-1', nameEn: 'Bracket', docs: [
      { filename: 'a.pdf', originalName: 'Assembly.pdf', packWithOrder: true },
      { filename: 'c.pdf', originalName: 'Machine setup.pdf', packWithOrder: false },
    ] });
    clients.length = 0;
    clients.push({ id: 'C1', name: 'Acme' });
    printLog.length = 0;
    // Deliberately NO courier, tracking or address.
    const order = { id: 'O1', status: 'completed', clientId: 'C1', project: 'Acme',
      productId: 'PROD-1', date: '2026-08-12', price: 100, material: 'PLA', printTime: 4,
      parts: [{ name: 'Bracket', material: 'PLA', printTime: 4, printWeight: 100, baseCost: 100 }],
      extraLines: [] };
    printLog.push(order);
    saveAll();
    await generateWorkOrder('O1');
    const wo = document.querySelector('#work-order-print-area').innerText;
    await generateDeliveryNote('O1');
    const dn = document.querySelector('#invoice-print-area').innerText;
    return { wo, dn };
  });

  ok(docs.wo.includes('Assembly.pdf'), 'the work order lists the assembly instructions');
  ok(docs.wo.includes('Machine setup.pdf'),
    'and the setup sheet too — whoever makes it should see everything');
  ok(docs.dn.includes('Assembly.pdf'), 'the delivery note lists what goes in the box');
  ok(!docs.dn.includes('Machine setup.pdf'),
    'but NOT the setup sheet — that one is for the floor, not the customer');

  console.log('\ndavid items smoke: all assertions passed');
} catch (err) {
  failed = true;
  console.error('\n' + (err && err.message ? err.message : String(err)));
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
