/**
 * E2E smoke — Shipping & fulfillment (manual-first path) in a real Electron window.
 *
 * Ships a completed order by hand (carrier=Manual + typed tracking number), advances the
 * shipping status to delivered, and checks the customer-safe projection. No network.
 *
 * Run: npm run test:e2e:shipping   (CI wraps it in xvfb-run)
 */
import { launchApp, dismissWizard, makeUserDataDir } from './e2e/helpers.mjs';

const ok = (c, m) => { if (!c) throw new Error('ASSERT FAILED: ' + m); console.log('  ✓ ' + m); };
async function clickSave(window) { await window.click('#modalMount [data-act="save"]'); }
async function waitModal(window, sel) {
  await window.waitForFunction((s) => !!document.querySelector('#modalMount ' + s), sel, { timeout: 10000 });
}

const { electronApp, window } = await launchApp(makeUserDataDir());
let failed = false;
try {
  await dismissWizard(window);

  ok(await window.evaluate(() => typeof window.KhaytCarriers === 'object'), 'carriers module loaded in renderer');

  // Seed a completed order.
  await window.evaluate(() => {
    printLog.unshift({
      id: 'SHIP-1', status: 'completed', project: 'SHIP-1', date: '2026-07-19', timestamp: '2026-07-19T00:00:00Z',
      material: 'PLA', price: 100, parts: [{ id: 'p', material: 'PLA', printWeight: 40, baseCost: 5, qty: 1 }],
      statusHistory: [{ status: 'completed', at: '2026-07-19T00:00:00Z' }], completedAt: '2026-07-19T00:00:00Z',
      shippingHistory: [],
    });
    saveAll(); renderKanban();
  });

  // Ship it manually.
  await window.evaluate(() => openShipModal('SHIP-1'));
  await waitModal(window, '#shipCarrier');
  await window.evaluate(() => {
    const cs = document.querySelector('#shipCarrier'); cs.value = 'manual'; cs.dispatchEvent(new Event('change', { bubbles: true }));
    const tn = document.querySelector('#shipTracking'); tn.value = 'HAND-123'; tn.dispatchEvent(new Event('input', { bubbles: true }));
  });
  await clickSave(window);
  await window.waitForFunction(() => printLog.find(o => o.id === 'SHIP-1')?.shippingStatus === 'label_created', { timeout: 10000 });
  const s1 = await window.evaluate(() => printLog.find(o => o.id === 'SHIP-1'));
  ok(s1.carrier === 'manual', 'ship: carrier=manual');
  ok(s1.trackingNumber === 'HAND-123', 'ship: tracking number recorded');
  ok(s1.shippingStatus === 'label_created', 'ship: status label_created');
  ok(!!s1.shippedAt, 'ship: shippedAt set');
  ok(Array.isArray(s1.shippingHistory) && s1.shippingHistory[0].status === 'label_created', 'ship: history appended');
  ok(s1.labelUrl === null && s1.shipmentMeta === null, 'ship: manual path has no label/meta, zero network');

  // Re-open the (now shipped) modal and advance to delivered.
  await window.evaluate(() => openShipModal('SHIP-1'));
  await waitModal(window, '#shipStatus');
  await window.evaluate(() => {
    const st = document.querySelector('#shipStatus'); st.value = 'delivered'; st.dispatchEvent(new Event('change', { bubbles: true }));
  });
  await clickSave(window);
  await window.waitForFunction(() => printLog.find(o => o.id === 'SHIP-1')?.shippingStatus === 'delivered', { timeout: 10000 });
  const s2 = await window.evaluate(() => printLog.find(o => o.id === 'SHIP-1'));
  ok(s2.shippingStatus === 'delivered', 'update: advanced to delivered');
  ok(!!s2.deliveredAt, 'update: delivered set order.deliveredAt');

  // Customer-safe projection never leaks internal fields.
  const proj = await window.evaluate(() => {
    printLog.find(o => o.id === 'SHIP-1').shipmentMeta = { cost: 25 };
    return window.KhaytCarriers.projectShipping(printLog.find(o => o.id === 'SHIP-1'));
  });
  ok(proj.trackingNumber === 'HAND-123' && proj.shippingStatus === 'delivered', 'projection: status + tracking present');
  ok(JSON.stringify(proj).includes('cost') === false, 'projection: never leaks shipmentMeta/cost');

  console.log('\n✅ Shipping smoke: all assertions passed');
} catch (e) {
  failed = true;
  console.error('\n❌ ' + e.message);
} finally {
  await electronApp.close();
}
process.exit(failed ? 1 : 0);
