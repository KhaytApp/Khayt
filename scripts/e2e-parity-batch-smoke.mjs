#!/usr/bin/env node
/**
 * E2E: the desktop parity batch — five things the Mac already did.
 *
 *   1. The failure allowance the shop's history suggests (lib/failure-rate.js),
 *      with "Use this" setting the field — clicked for real.
 *   2. Analytics draws "Best use of the printer" and "What gets scrapped".
 *   3. Inventory ▸ Import from Spoolman, against a stubbed hub:spoolman-fetch:
 *      a preview, then the spools added — and a second run adds nothing.
 *   4. The automatic portal check: coming to the front asks the cloud ONCE
 *      for every waiting job (stubbed hub:cloud-published-list), moves an
 *      approved quote to Pending and records a paid deposit, once.
 *   5. A Bambu fault reason on the machine card.
 *
 *   node scripts/e2e-parity-batch-smoke.mjs
 */
import { launchApp, makeUserDataDir, dismissWizard, switchTab } from './e2e/helpers.mjs';
import fs from 'node:fs';

const userData = makeUserDataDir();
const fail = (m) => { throw new Error(m); };
let electronApp;
try {
  const launched = await launchApp(userData);
  electronApp = launched.electronApp;
  const window = launched.window;
  await dismissWizard(window);

  // hubAPI is frozen, so the stubs are the main-process handlers.
  await electronApp.evaluate(({ ipcMain }) => {
    globalThis.__listCalls = 0;
    ipcMain.removeHandler('hub:cloud-published-list');
    ipcMain.handle('hub:cloud-published-list', () => {
      globalThis.__listCalls += 1;
      return { ok: true, items: [
        { token: 'tok-quote', action: { type: 'approve' } },
        { token: 'tok-dep', payment: { status: 'paid', amount: 30, ref: 'pay_e2e', at: '2026-11-01T10:00:00Z' } },
      ] };
    });
    ipcMain.removeHandler('hub:spoolman-fetch');
    ipcMain.handle('hub:spoolman-fetch', (_e, { url } = {}) => {
      if (url !== '192.168.1.20:7912') return { ok: false, code: 'not_lan', host: String(url) };
      return { ok: true, spools: [
        { id: 1, filament: { name: 'Galaxy Black', material: 'PLA', vendor: { name: 'Sunlu' }, color_hex: '111111', weight: 1000 }, remaining_weight: 640, price: 80 },
        { id: 2, filament: { material: 'PETG', vendor: { name: 'Elegoo' }, color_hex: 'ff0000', weight: 1000 }, remaining_weight: 1000 },
        { id: 3, archived: true, filament: { material: 'ABS' } },
      ] };
    });
  });

  // ---- the book ----
  await window.evaluate(() => {
    const today = localDateStr();
    machines.push({ id: 'M-e2e', name: 'Bench X1', color: '#3a7', printerApi: { type: 'bambu', host: '192.168.1.60' } });
    inventory.push({ id: 'INV-pla', material: 'PLA', cost: 75, weight: 1000, spoolWeight: 1000, color: '#ffffff', materialType: 'fdm' });
    // 20 finished prints and 5 failed attempts at them, on this machine and material.
    for (let i = 0; i < 20; i++) {
      printLog.push({ id: 'ORD-f' + i, project: 'F' + i, date: today, completedAt: today, status: 'completed',
        machineId: 'M-e2e', material: 'PLA', parts: [{ printWeight: 50, printTime: 2, qty: 1 }] });
    }
    for (let i = 0; i < 5; i++) {
      wasteLog.push({ id: 'W' + i, orderId: 'ORD-f' + i, machineId: 'M-e2e', material: 'PLA', date: today,
        weight: 40, cost: 3, failureType: 'warping' });
    }
    // Three catalogue products with a price and print hours, so an average exists.
    products.push(
      { id: 'P1', name: 'Keyring', basePrice: 20, baseCost: 4, parts: [{ printTime: 0.5, qty: 1 }] },
      { id: 'P2', name: 'Vase', basePrice: 60, baseCost: 20, parts: [{ printTime: 8, qty: 1 }] },
      { id: 'P3', name: 'Stand', basePrice: 35, baseCost: 10, parts: [{ printTime: 2, qty: 1 }] },
    );
    // Two published jobs waiting on the portal, and one that is not.
    printLog.push(
      { id: 'ORD-quote', project: 'Portal quote', date: today, status: 'quote', price: 100, total: 100,
        cloudPublished: true, trackingToken: 'tok-quote', parts: [] },
      { id: 'ORD-dep', project: 'Portal deposit', date: today, status: 'pending', price: 100, total: 100,
        cloudPublished: true, trackingToken: 'tok-dep', cloudDeposit: 30, parts: [] },
      { id: 'ORD-quiet', project: 'Not published', date: today, status: 'quote', trackingToken: 'tok-x', parts: [] },
    );
    settings.cloud = { ...(settings.cloud || {}), enabled: true, shopId: 'shop-e2e', url: 'https://cloud.example', token: 't' };
    saveAll();
  });

  // ---- 1. failure allowance: suggestion + "Use this" ----
  await switchTab(window, 'calculator-tab');
  await window.evaluate(() => { renderMachineDropdown(); populateFilamentDropdown(); });
  await window.selectOption('#partMachineId', 'M-e2e');
  await window.selectOption('#filamentSelect', 'INV-pla');
  await window.fill('#failureRate', '10');
  await window.evaluate(() => updateFailureRateHint());
  await window.waitForSelector('#btnUseFailureRate', { state: 'visible', timeout: 10_000 });
  const hint = await window.$eval('#failureRateHint', (el) => el.textContent.replace(/\s+/g, ' '));
  if (!/20/.test(hint) || !/25/.test(hint)) fail(`failure hint says "${hint}", wanted 20% over 25 prints`);
  await window.click('#btnUseFailureRate');
  const rate = await window.$eval('#failureRate', (el) => el.value);
  if (rate !== '20') fail(`"Use this" left the field at ${rate}, wanted 20`);
  if (await window.$('#btnUseFailureRate')) fail('"Use this" still offered once the field holds the figure');

  // ---- 2. analytics sections ----
  await switchTab(window, 'analytics-tab');
  const an = await window.evaluate(() => {
    KhaytAnalytics.renderBestUseOfPrinter();
    KhaytAnalytics.renderMachineReliability();
    return {
      pph: [...document.querySelectorAll('#bestUseOfPrinterSection .pph-row')].map((r) => r.textContent.replace(/\s+/g, ' ').trim()),
      mr: [...document.querySelectorAll('#machineReliabilitySection .mr-row')].map((r) => r.textContent.replace(/\s+/g, ' ').trim()),
      mrText: document.querySelector('#machineReliabilitySection')?.textContent || '',
    };
  });
  if (an.pph.length !== 3) fail(`best use of the printer drew ${an.pph.length} rows, wanted 3`);
  // Ranked by the rule (live part costs included), not re-derived here: the
  // screen must list exactly what lib/profit-per-hour.js ranked, in its order.
  const ranked = await window.evaluate(() => KhaytProfitPerHour.productRates({ products, orders: printLog,
    expenses, inventory, consumables, settings }, { revenueOf: orderEarnedBase, partCostOf: partTotalCost })
    .rows.filter((r) => r.perHour != null).map((r) => r.name));
  an.pph.forEach((row, i) => { if (!row.includes(ranked[i]) || !/\/h/.test(row)) fail(`best use row ${i} is "${row}", wanted ${ranked[i]} with a rate`); });
  if (!an.mr.some((r) => /Bench X1/.test(r))) fail(`machine reliability has no row for the bench: ${JSON.stringify(an.mr)}`);
  if (!/Warping/i.test(an.mrText)) fail('machine reliability does not name the fault it keeps making');

  // ---- 3. Spoolman import ----
  await switchTab(window, 'inventory-tab');
  await window.click('#btnImportSpoolman');
  await window.waitForSelector('#smAddress', { timeout: 10_000 });
  await window.fill('#smAddress', '192.168.1.20:7912');
  await window.click('#modalMount [data-act="save"]');
  await window.waitForFunction(() => /2/.test(document.querySelector('#smStatus')?.textContent || ''), null, { timeout: 10_000 });
  const before = await window.evaluate(() => inventory.length);
  await window.click('#modalMount [data-act="save"]');
  await window.waitForFunction(() => !document.querySelector('#smAddress'), null, { timeout: 10_000 });
  const added = await window.evaluate(() => inventory.filter((i) => i.spoolmanId != null).map((i) => ({ m: i.material, w: i.weight, c: i.color })));
  if (added.length !== 2) fail(`Spoolman import added ${added.length} spools, wanted 2 (one archived)`);
  if (!added.some((a) => a.m === 'Sunlu PLA' && a.w === 640 && a.c === '#111111')) fail(`Spoolman spool mapped wrong: ${JSON.stringify(added)}`);
  if ((await window.evaluate(() => inventory.length)) !== before + 2) fail('inventory did not grow by two');
  // Again: everything is already on the shelf.
  await window.click('#btnImportSpoolman');
  await window.waitForSelector('#smAddress', { timeout: 10_000 });
  await window.click('#modalMount [data-act="save"]');
  await window.waitForFunction(() => /2/.test(document.querySelector('#smStatus')?.textContent || ''), null, { timeout: 10_000 });
  await window.click('#modalMount [data-act="save"]');
  await window.waitForTimeout(300);
  if ((await window.evaluate(() => inventory.filter((i) => i.spoolmanId != null).length)) !== 2) fail('a second Spoolman import added spools again');
  await window.keyboard.press('Escape');

  // ---- 4. the automatic portal check ----
  await window.evaluate(() => window.dispatchEvent(new Event('focus')));
  await window.waitForFunction(() => printLog.find((o) => o.id === 'ORD-quote')?.status === 'pending', null, { timeout: 15_000 });
  await window.evaluate(() => window.dispatchEvent(new Event('focus')));   // within the minute: no second look
  await window.waitForTimeout(500);
  const calls = await electronApp.evaluate(() => globalThis.__listCalls);
  if (calls !== 1) fail(`the portal was asked ${calls} times, wanted once for both jobs`);
  const dep = await window.evaluate(() => {
    const o = printLog.find((x) => x.id === 'ORD-dep');
    return { paid: o.paidAmount, notes: (o.portalPayments || []).length };
  });
  if (dep.notes !== 1) fail(`deposit noted ${dep.notes} times, wanted once`);
  if (!(dep.paid >= 30)) fail(`deposit not recorded: paidAmount=${dep.paid}`);
  // A forced second look records nothing new.
  await window.evaluate(() => checkPortalNow({ force: true }));
  const dep2 = await window.evaluate(() => (printLog.find((x) => x.id === 'ORD-dep').portalPayments || []).length);
  if (dep2 !== 1) fail(`a second look noted the deposit again (${dep2})`);

  // ---- 5. the Bambu fault reason on the machine card ----
  const card = await window.evaluate(() => {
    machineStatusCache['M-e2e'] = { state: 'Paused', fault: 'Filament ran out. Please load new filament. (0300_8004)', lastUpdated: Date.now() };
    KhaytMachines.renderMachines();
    const el = document.querySelector('#machinesList [data-machine-detail="M-e2e"]');
    return el ? el.textContent : '(no machine card)';
  });
  if (!/Filament ran out/.test(card) || !/0300_8004/.test(card)) fail(`machine card has no fault line: ${card}`);

  console.log('parity batch smoke: ok');
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  try { fs.rmSync(userData, { recursive: true, force: true }); } catch (_) {}
}
