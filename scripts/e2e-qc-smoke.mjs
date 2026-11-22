/**
 * E2E smoke — QC / reprint / RMA flow in a real Electron window.
 *
 * Drives the actual pass / fail→reprint / RMA modals and asserts the resulting
 * order state, guarding the material-accounting rule that a linked reprint never
 * re-touches the failed job's deduction. See docs/KHAYT-3.0-QC-SPEC.md.
 *
 * Run: npm run test:e2e:qc   (CI wraps it in xvfb-run)
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };

async function setAndSave(window, fills) {
  await window.evaluate((f) => {
    for (const [sel, val] of Object.entries(f)) {
      const el = document.querySelector(sel);
      if (el) { el.value = val; el.dispatchEvent(new Event('change', { bubbles: true })); }
    }
  }, fills);
  await window.click('#modalMount [data-act="save"]');
}

async function waitModal(window, sel) {
  await window.waitForFunction((s) => !!document.querySelector('#modalMount ' + s), sel, { timeout: 10000 });
}

const userData = makeUserDataDir();
const { electronApp, window } = await launchApp(userData);
let failed = false;
try {
  await dismissWizard(window);

  await window.evaluate(() => {
    settings.qc = { enabled: true, requireInspector: false, warrantyDays: 30, requirePhotoOnFail: false };
    const mk = (id, status, extra) => Object.assign({
      id, status, project: id, date: '2026-07-19', timestamp: '2026-07-19T00:00:00Z',
      material: 'PLA', price: 100, parts: [{ id: id + '-p', material: 'PLA', printWeight: 40, baseCost: 5, qty: 1 }],
      statusHistory: [{ status, at: '2026-07-19T00:00:00Z' }], materialDeducted: false,
    }, extra || {});
    printLog.unshift(mk('QC-PASS-1', 'qc'));
    printLog.unshift(mk('QC-FAIL-1', 'qc'));
    // Delivered RELATIVE to now, not on a fixed date. This order has to sit
    // INSIDE the 30-day warranty configured above or the auto-detect assertion
    // below means nothing — and a hardcoded date only means that until it does
    // not. '2026-07-15' stopped meaning it at 00:00 on 2026-08-14, exactly 30
    // days later, and from that moment failed the REQUIRED E2E check on every
    // pull request, including ones that had touched nothing near this code.
    const deliveredAt = new Date(Date.now() - 5 * 86400000).toISOString();
    printLog.unshift(mk('QC-DEL-1', 'delivered', { deliveredAt, completedAt: deliveredAt, materialDeducted: true }));
    saveAll(); renderKanban();
  });

  // Pass
  await window.evaluate(() => qcPassOrder('QC-PASS-1'));
  await waitModal(window, '[data-act="save"]');
  await setAndSave(window, { '#qcNotesInput': 'looks clean' });
  await window.waitForFunction(() => printLog.find(o => o.id === 'QC-PASS-1')?.qcStatus === 'pass', { timeout: 10000 });
  // Passing QC queues the actuals prompt on a setTimeout(…, 0) — deliberately, so
  // it opens after the QC modal closes. qcStatus flips to 'pass' synchronously
  // inside onSave, i.e. BEFORE that timer fires, so the wait above can return with
  // the prompt still pending. Whatever modal is open when it lands gets replaced,
  // because openFormModal assigns over #modalMount. Racing on ahead is what made
  // this suite fail about half its runs: qcFailOrder would open the failure modal,
  // the pending actuals prompt would overwrite it, and waitModal('#qcFailType')
  // timed out. Wait for the prompt the app actually shows, then dismiss it.
  await waitModal(window, '#actTime');
  await window.click('#modalMount [data-act="cancel"]');
  await window.waitForFunction(() => !document.querySelector('#modalMount .modal'), { timeout: 10000 });
  const pass = await window.evaluate(() => printLog.find(o => o.id === 'QC-PASS-1'));
  ok(pass.qcStatus === 'pass', 'pass: qcStatus=pass');
  ok(pass.status === 'completed', 'pass: advanced to completed');
  ok(!!pass.qcAt && !!pass.qcPassedAt, 'pass: qcAt + qcPassedAt set');

  // Fail -> linked reprint (billable)
  await window.evaluate(() => qcFailOrder('QC-FAIL-1'));
  await waitModal(window, '#qcFailType');
  await setAndSave(window, { '#qcFailType': 'warping', '#qcFailSeverity': 'major', '#qcFailReason': 'edge lift', '#qcFailWeight': '30' });
  await waitModal(window, '#qcReprintCost');
  const failMid = await window.evaluate(() => printLog.find(o => o.id === 'QC-FAIL-1'));
  ok(failMid.qcStatus === 'fail', 'fail: qcStatus=fail');
  ok(Array.isArray(failMid.defects) && failMid.defects[0].type === 'warping', 'fail: defect recorded');
  ok(failMid.scrapped === true, 'fail: order marked scrapped (terminal)');
  const wasteN = await window.evaluate(() => wasteLog.filter(w => w.orderId === 'QC-FAIL-1').length);
  ok(wasteN === 1, 'fail: one waste row written');
  await setAndSave(window, { '#qcReprintCost': 'billable' });
  await window.waitForFunction(() => document.getElementById('calculator-tab')?.classList.contains('active'), { timeout: 10000 });
  const build = await window.evaluate(() => currentBuild.length);
  ok(build === 1, 'reprint: parts loaded into calculator cart');
  await window.evaluate(() => { document.querySelector('#clientInput').value = 'QC-FAIL-1'; logPrint(false); });
  const link = await window.evaluate(() => {
    const orig = printLog.find(o => o.id === 'QC-FAIL-1');
    const rep = printLog.find(o => o.reprintOf === 'QC-FAIL-1');
    return { origDeducted: orig.materialDeducted, reprintedInto: orig.reprintedInto || [], rep: rep ? { id: rep.id, reason: rep.reprintReason, cost: rep.reprintCost, chain: rep.reprintChain, noCharge: !!rep.reprintNoCharge } : null };
  });
  ok(link.rep && link.rep.reason === 'qc_fail', 'reprint: new order carries reprintReason=qc_fail');
  ok(link.rep.chain === 'QC-FAIL-1', 'reprint: reprintChain = original');
  ok(link.reprintedInto.includes(link.rep.id), 'reprint: original back-references reprintedInto');
  ok(link.origDeducted !== true, 'reprint: original material accounting untouched');
  ok(link.rep.cost === 'billable' && !link.rep.noCharge, 'reprint(billable): not zero-charged');

  // RMA on a delivered order
  await window.evaluate(() => openRmaModal('QC-DEL-1'));
  await waitModal(window, '#rmaReason');
  await setAndSave(window, { '#rmaReason': 'cracked after a week', '#rmaResolution': 'reprint' });
  await window.waitForFunction(() => !!printLog.find(o => o.id === 'QC-DEL-1')?.rma, { timeout: 10000 });
  const rma = await window.evaluate(() => printLog.find(o => o.id === 'QC-DEL-1').rma);
  ok(rma && rma.resolution === 'reprint', 'rma: recorded with resolution=reprint');
  ok(rma.withinWarranty === true, 'rma: within-warranty auto-detected');

  console.log('\n✅ QC smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
