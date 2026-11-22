/**
 * E2E smoke — printer catalog + machine auto-fill + product auto-pricing.
 *
 * 1) Machine editor: pick a catalog model → specs (nozzle, power, colours, bed) fill.
 * 2) Calculator: assign that machine → printer name + power draw auto-fill.
 * 3) Product editor: add a part → basePrice computes from cost × margin on save.
 *
 * Run: npm run test:e2e:printers   (CI wraps it in xvfb-run)
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
async function clickSave(window) { await window.click('#modalMount [data-act="save"]'); }
async function waitModal(window, sel) {
  await window.waitForFunction((s) => !!document.querySelector('#modalMount ' + s), sel, { timeout: 10000 });
}

const userData = makeUserDataDir();
const { electronApp, window } = await launchApp(userData);
let failed = false;
try {
  await dismissWizard(window);

  // Catalog is bundled + loaded in the renderer.
  const catCount = await window.evaluate(() => window.KhaytPrinterCatalog?.list().length || 0);
  ok(catCount >= 40, `printer catalog loaded in renderer (${catCount} models)`);

  // 1) Machine editor: pick a model, save, assert specs filled.
  await window.evaluate(() => openMachineEditor());
  await waitModal(window, '#machPrinterModel');
  await window.evaluate(() => {
    const el = document.querySelector('#machPrinterModel');
    el.value = 'Bambu Lab X1 Carbon';
    el.dispatchEvent(new Event('change', { bubbles: true }));
  });
  // name auto-filled from the model
  await window.waitForFunction(() => document.querySelector('#machName')?.value === 'Bambu Lab X1 Carbon', { timeout: 5000 });
  await clickSave(window);
  await window.waitForFunction(() => machines.some(m => m.printerModel === 'bambu-x1c'), { timeout: 5000 });
  const m = await window.evaluate(() => machines.find(x => x.printerModel === 'bambu-x1c'));
  ok(m.name === 'Bambu Lab X1 Carbon', 'machine: name from catalog');
  ok(m.nozzleDiameter === 0.4, 'machine: nozzle auto-filled');
  ok(m.powerDraw === 120, 'machine: power draw auto-filled');
  // ONE, not four. An X1 Carbon prints one colour; four is what it reaches with
  // an AMS, and the catalog used to auto-fill that ceiling onto a machine the
  // shop had just said it owns. This is the end-to-end half of that fix — the
  // unit is in test/printer-catalog.test.js.
  ok(m.maxColors === 1, 'machine: colour slots auto-filled as sold, not as upgradable');
  ok(m.bed && m.bed.x === 256, 'machine: build volume auto-filled');

  // 2) Calculator: assign the machine, assert printer name + power auto-fill.
  await window.evaluate(() => { switchTab('calculator-tab'); renderMachineDropdown(); });
  await window.waitForFunction(() => !!document.querySelector('#machineAssign'), { timeout: 5000 });
  await window.evaluate(() => {
    const sel = document.querySelector('#machineAssign');
    const mm = machines.find(x => x.printerModel === 'bambu-x1c');
    sel.value = mm.id;
    sel.dispatchEvent(new Event('change', { bubbles: true }));
  });
  const calc = await window.evaluate(() => ({ name: document.querySelector('#printerModel')?.value, power: document.querySelector('#powerDraw')?.value }));
  ok(calc.name === 'Bambu Lab X1 Carbon', 'calculator: printer name auto-filled from machine');
  ok(Number(calc.power) === 120, 'calculator: power draw auto-filled from machine');

  // 3) Product editor: add a part with known cost, assert basePrice on save.
  await window.evaluate(() => openProductEditor());
  await waitModal(window, '[data-act="add-part"]');
  await window.evaluate(() => {
    // name + margin
    const nameEl = document.querySelector('[data-f="nameEn"]'); if (nameEl) { nameEl.value = 'Test widget'; nameEl.dispatchEvent(new Event('input', { bubbles: true })); }
    const mg = document.querySelector('[data-f="defaultMargin"]'); if (mg) { mg.value = '50'; mg.dispatchEvent(new Event('input', { bubbles: true })); }
  });
  await window.click('#modalMount [data-act="add-part"]');
  // set a deterministic part cost: 100g at 100/kg spool = 10 material; everything else 0
  await window.evaluate(() => {
    const rows = document.querySelectorAll('#partsEditor [data-pi]');
    const row = rows[rows.length - 1];
    const setF = (f, v) => { const el = row.querySelector(`[data-f="${f}"]`); if (el) { el.value = String(v); el.dispatchEvent(new Event('input', { bubbles: true })); } };
    setF('spoolCost', 100); setF('spoolWeight', 1000); setF('printWeight', 100);
    setF('printTime', 0); setF('wearRate', 0); setF('powerDraw', 0); setF('elecRate', 0);
    setF('prepTime', 0); setF('postTime', 0); setF('laborRate', 0); setF('failureRate', 0);
  });
  // live summary shows a price
  const liveShown = await window.evaluate(() => (document.querySelector('#prodPriceVal')?.textContent || '').trim());
  ok(liveShown && liveShown !== '—', `product: live default price shown (${liveShown})`);
  await clickSave(window);
  await window.waitForFunction(() => products.some(p => (p.nameEn || '') === 'Test widget'), { timeout: 5000 });
  const prod = await window.evaluate(() => products.find(p => p.nameEn === 'Test widget'));
  ok(prod.baseCost > 0, `product: cost computed from parts (${prod.baseCost})`);
  // margin was 50% → basePrice must equal cost × 1.5 (the calculator's math), and match the live display.
  ok(Math.abs(prod.basePrice - prod.baseCost * 1.5) < 0.02, `product: basePrice = cost × (1+margin) (${prod.basePrice} vs ${prod.baseCost}×1.5)`);

  console.log('\n✅ Printer catalog / auto-fill / product pricing: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
