/**
 * E2E smoke — BOM / assembly in a real Electron window.
 *
 * Defines a product with a printed part + 2 non-printed components, quotes it into the
 * calculator (carrying the BOM), and confirms the components' consumable stock is deducted
 * when the resulting order completes.
 *
 * Run: npm run test:e2e:bom   (CI wraps it in xvfb-run)
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  // Seed consumables + a product with a part and two components.
  await window.evaluate(() => {
    consumables.push({ id: 'CNS-MAG', name: 'Magnet 6mm', stock: 100, minStock: 20, cost: 0.5, unit: 'pcs' });
    consumables.push({ id: 'CNS-INS', name: 'M3 insert', stock: 40, minStock: 10, cost: 0.2, unit: 'pcs' });
    products.push({
      id: 'PROD-ASM', nameEn: 'Widget assembly', defaultMargin: 50,
      parts: [{ name: 'body', filamentId: (inventory[0] && inventory[0].id) || '', spoolCost: 100, spoolWeight: 1000, printWeight: 100, printTime: 1, wearRate: 0, powerDraw: 0, elecRate: 0, prepTime: 0, postTime: 0, laborRate: 0, failureRate: 0, qty: 1 }],
      components: [{ id: 'a', consumableId: 'CNS-MAG', qtyPerUnit: 4 }, { id: 'b', consumableId: 'CNS-INS', qtyPerUnit: 6 }],
    });
    saveAll();
  });

  // Components cost folds into the assembly price (2 magnets-worth + inserts = 2 + 1.2 = 3.2).
  const compCost = await window.evaluate(() =>
    computeComponentsCost(products.find(p => p.id === 'PROD-ASM').components, consumables));
  ok(Math.abs(compCost - 3.2) < 0.01, `components cost computed in renderer (${compCost})`);

  // Quote the product → the BOM carries into the build.
  await window.evaluate(() => quoteFromProduct('PROD-ASM'));
  const carried = await window.evaluate(() => ({ comps: currentComponents.length, aq: currentAssemblyQty }));
  ok(carried.comps === 2, 'quote carried 2 components into the build');

  // Save the order (logPrint persists components + assemblyQty).
  await window.evaluate(() => { document.querySelector('#clientInput').value = 'ASM client'; logPrint(false); });
  const order = await window.evaluate(() => printLog.find(o => (o.components || []).length === 2));
  ok(order && order.components.length === 2, 'order persisted components[]');
  ok(order.assemblyQty === 1, 'order assemblyQty defaulted to 1');

  // Bump assemblyQty to 3 and complete → deduct qtyPerUnit × assemblyQty.
  await window.evaluate(() => {
    const o = printLog.find(x => (x.components || []).length === 2);
    o.assemblyQty = 3; o.status = 'qc'; o.materialDeducted = false;
    saveAll();
    deductFilamentForOrder(o);
  });
  const stock = await window.evaluate(() => ({
    mag: consumables.find(c => c.id === 'CNS-MAG').stock,
    ins: consumables.find(c => c.id === 'CNS-INS').stock,
  }));
  ok(stock.mag === 100 - 12, `magnets deducted 4×3 (${stock.mag})`);
  ok(stock.ins === 40 - 18, `inserts deducted 6×3 (${stock.ins})`);

  // Re-run deduction is a no-op (materialDeducted guard).
  await window.evaluate(() => deductFilamentForOrder(printLog.find(x => (x.components || []).length === 2)));
  const stock2 = await window.evaluate(() => consumables.find(c => c.id === 'CNS-MAG').stock);
  ok(stock2 === 100 - 12, 'no double-deduct on re-run');

  console.log('\n✅ BOM smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
