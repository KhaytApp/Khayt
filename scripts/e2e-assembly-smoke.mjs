/**
 * E2E smoke — assembly production tracking (BOM spec §5) in a real Electron window.
 *
 * The critical property: the completion gate blocks a BOM assembly until every part
 * passes QC and it is marked assembled — WITHOUT changing behaviour for ordinary
 * single-part and multi-part orders.
 *
 * Run: npm run test:e2e:assembly   (CI wraps it in xvfb-run)
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  // Seed: an assembly (2 parts + a component) and a plain multi-part order (no components).
  await window.evaluate(() => {
    const mkPart = (name) => ({ name, filamentId: '', spoolCost: 100, spoolWeight: 1000, printWeight: 10, printTime: 0, wearRate: 0, powerDraw: 0, elecRate: 0, prepTime: 0, postTime: 0, laborRate: 0, failureRate: 0, qty: 1, partStatus: 'pending' });
    consumables.push({ id: 'CNS-X', name: 'Magnet', stock: 100, minStock: 5, cost: 0.5, unit: 'pcs' });
    printLog.unshift({
      id: 'ASM-1', status: 'qc', project: 'Assembly order', date: '2026-07-20', price: 100, material: 'PLA',
      parts: [mkPart('body'), mkPart('lid')], components: [{ id: 'k', consumableId: 'CNS-X', qtyPerUnit: 2 }],
      assemblyQty: 1, statusHistory: [], materialDeducted: false,
    });
    printLog.unshift({
      id: 'PLAIN-1', status: 'qc', project: 'Plain multi-part', date: '2026-07-20', price: 50, material: 'PLA',
      parts: [mkPart('a'), mkPart('b')], statusHistory: [], materialDeducted: false,
    });
    saveAll();
  });

  // A plain multi-part order (no components) is NOT an assembly and must complete freely.
  await window.evaluate(() => updateStatus('PLAIN-1', 'completed'));
  await new Promise(r => setTimeout(r, 600));
  // promptActuals opens a modal for the normal path — confirm it, then assert completion.
  await window.evaluate(() => { const b = document.querySelector('#modalMount [data-act="save"]'); if (b) b.click(); });
  await window.waitForFunction(() => printLog.find(o => o.id === 'PLAIN-1')?.status === 'completed', { timeout: 8000 });
  ok(true, 'plain multi-part order completes unchanged (no gate regression)');

  // The assembly is blocked while parts are pending.
  await window.evaluate(() => updateStatus('ASM-1', 'completed'));
  await new Promise(r => setTimeout(r, 500));
  let asm = await window.evaluate(() => printLog.find(o => o.id === 'ASM-1'));
  ok(asm.status === 'qc', 'assembly blocked from completing while parts are pending');

  // Pass every part — still blocked until the assembled gate is ticked.
  await window.evaluate(() => {
    const o = printLog.find(x => x.id === 'ASM-1');
    o.parts.forEach(p => { p.partStatus = 'qc_pass'; });
    saveAll();
  });
  const rollup1 = await window.evaluate(() => KhaytAssembly.deriveAssemblyStatus(printLog.find(o => o.id === 'ASM-1')));
  ok(rollup1 === 'printed', `all parts passed → rollup 'printed', not yet assembled (${rollup1})`);
  await window.evaluate(() => updateStatus('ASM-1', 'completed'));
  await new Promise(r => setTimeout(r, 500));
  asm = await window.evaluate(() => printLog.find(o => o.id === 'ASM-1'));
  ok(asm.status === 'qc', 'still blocked until the assembled gate is ticked');

  // Tick assembled → rollup flips and completion is allowed.
  await window.evaluate(() => {
    const o = printLog.find(x => x.id === 'ASM-1');
    o.assembledAt = new Date().toISOString();
    saveAll();
  });
  const rollup2 = await window.evaluate(() => KhaytAssembly.deriveAssemblyStatus(printLog.find(o => o.id === 'ASM-1')));
  ok(rollup2 === 'assembled', 'rollup → assembled once ticked');
  await window.evaluate(() => updateStatus('ASM-1', 'completed'));
  await new Promise(r => setTimeout(r, 600));
  await window.evaluate(() => { const b = document.querySelector('#modalMount [data-act="save"]'); if (b) b.click(); });
  await window.waitForFunction(() => printLog.find(o => o.id === 'ASM-1')?.status === 'completed', { timeout: 8000 });
  ok(true, 'assembly completes once all parts pass and it is assembled');

  // A failed part blocks the rollup again (and is reprint-eligible).
  const failed2 = await window.evaluate(() => {
    const o = printLog.find(x => x.id === 'ASM-1');
    o.parts[0].partStatus = 'qc_fail';
    return { rollup: KhaytAssembly.deriveAssemblyStatus(o), failed: KhaytAssembly.failedParts(o).length };
  });
  ok(failed2.rollup === 'pending', 'a failed part drops the rollup back to pending');
  ok(failed2.failed === 1, 'the failed part is reprint-eligible');

  console.log('\n✅ Assembly smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
