/**
 * Shared Electron screenshot capture: boot the app on the demo store, then
 * photograph each tab.
 *
 * Extracted from capture-screenshots.mjs so the README shots and the Microsoft
 * Store shots come from one boot sequence. They need different viewports and
 * output directories but identical seeding — and the seeding is the fiddly part
 * (the store has to round-trip through disk before the reload, or the app renders
 * empty states).
 */
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { _electron as electron } from 'playwright-core';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const root = path.join(__dirname, '..');

export const SHOTS = [
  { tab: 'dashboard-tab', file: 'screenshot-1-dashboard.png', wait: '#dashboard-tab .dash-grid, #dashboard-tab .kpi-grid, #dashboard-tab' },
  { tab: 'calculator-tab', file: 'screenshot-2-calculator.png', wait: '#calculator-tab #buildTableBody tr', setup: 'calculator' },
  { tab: 'queue-tab', file: 'screenshot-3-production-queue.png', wait: '#queue-tab .kanban-col, #queue-tab .kanban-board' },
  { tab: 'logs-tab', file: 'screenshot-4-orders-log.png', wait: '#logs-tab table tbody tr, #logs-tab .log-table' },
  { tab: 'analytics-tab', file: 'screenshot-5-analytics.png', wait: '#analytics-tab .analytics-grid, #analytics-tab' },
  { tab: 'inventory-tab', file: 'screenshot-6-inventory.png', wait: '#inventory-tab table tbody tr, #inventory-tab' },
  { tab: 'clients-tab', file: 'screenshot-7-clients.png', wait: '#clients-tab table tbody tr, #clients-tab' },
  { tab: 'gift-cards-tab', file: 'screenshot-8-gift-cards.png', wait: '#giftCardsContainer table tbody tr, #gift-cards-tab' },
  { tab: 'catalog-tab', file: 'screenshot-9-catalog.png', wait: '#catalogGrid .product-card, #catalogGrid' },
  { tab: 'waste-tab', file: 'screenshot-10-waste.png', wait: '#wasteTable tbody tr, #waste-tab' },
  { tab: 'settings-tab', file: 'screenshot-11-settings-invoice.png', wait: '#zatcaPhase2Section, #settings-panel-invoices', setup: 'settings-invoice' },
  { tab: 'portfolio-tab', file: 'screenshot-12-portfolio.png', wait: '#portfolioGrid .portfolio-cell, #portfolioGrid' },
];

export const README_VIEWPORT = { width: 1440, height: 940 };

async function seedCalculator(page) {
  await page.evaluate(() => {
    window.KhaytShell?.switchTab?.('calculator-tab');
    const parts = [
      { name: 'Gearbox housing', qty: 2, printWeight: 148, printTime: 4.37, spoolCost: 75, spoolWeight: 1000, wearRate: 0.05, powerDraw: 120, elecRate: 0.18, prepTime: 0.25, postTime: 0.5, laborRate: 45, failureRate: 5 },
      { name: 'Mounting bracket', qty: 4, printWeight: 62, printTime: 1.8, spoolCost: 82, spoolWeight: 1000, wearRate: 0.05, powerDraw: 120, elecRate: 0.18, prepTime: 0.15, postTime: 0.3, laborRate: 45, failureRate: 5 },
      { name: 'Cable clip', qty: 10, printWeight: 8, printTime: 0.4, spoolCost: 130, spoolWeight: 1000, wearRate: 0.05, powerDraw: 120, elecRate: 0.18, prepTime: 0.05, postTime: 0.1, laborRate: 45, failureRate: 8 },
    ];
    for (const p of parts) {
      $('#partName').value = p.name;
      $('#partQty').value = String(p.qty);
      $('#printWeight').value = String(p.printWeight);
      $('#printTime').value = String(p.printTime);
      $('#spoolCost').value = String(p.spoolCost);
      $('#spoolWeight').value = String(p.spoolWeight);
      $('#wearRate').value = String(p.wearRate);
      $('#powerDraw').value = String(p.powerDraw);
      $('#elecRate').value = String(p.elecRate);
      $('#prepTime').value = String(p.prepTime);
      $('#postTime').value = String(p.postTime);
      $('#laborRate').value = String(p.laborRate);
      $('#failureRate').value = String(p.failureRate);
      if ($('#margin')) $('#margin').value = '35';
      addPart();
    }
    renderBuild();
    calculateLivePartCost?.();
    window.KhaytBedReadyUI?.initStudioCalculatorLayout?.();
  });
}

async function prepareShot(page, shot) {
  if (shot.setup === 'calculator') {
    await seedCalculator(page);
    return;
  }
  if (shot.setup === 'settings-invoice') {
    await page.evaluate(() => window.KhaytShell.switchTab('settings-tab'));
    await page.evaluate(() => {
      document.querySelector('.settings-nav-item[data-settings-section="invoices"]')?.click();
    });
    return;
  }
  await page.evaluate((tabId) => window.KhaytShell.switchTab(tabId), shot.tab);
}

/**
 * Boot the app on demo data and write one PNG per shot into `outDir`.
 * Returns the list of files written.
 */
export async function captureShots({ viewport, outDir, shots = SHOTS, onShot } = {}) {
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-shots-'));
  fs.mkdirSync(outDir, { recursive: true });
  const written = [];
  let electronApp;

  try {
    const demoStore = buildScreenshotDemoStore();

    electronApp = await electron.launch({
      args: ['.', `--user-data-dir=${userData}`],
      cwd: root,
      env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1' },
      timeout: 120_000,
    });

    const page = await electronApp.firstWindow();
    await page.setViewportSize(viewport);
    await page.waitForSelector('.khayt-app', { timeout: 90_000 });
    await page.waitForFunction(
      () => typeof window.hubAPI?.loadStore === 'function' && typeof window.KhaytShell?.switchTab === 'function',
      { timeout: 90_000 },
    );

    const saveResult = await page.evaluate(async (store) => window.hubAPI.saveStore(store), demoStore);
    if (!saveResult?.ok) throw new Error(`saveStore failed: ${JSON.stringify(saveResult)}`);
    // Round-trip the store back from disk before reloading — forces the write to
    // flush so loadAll() reads the demo data (not the pre-save empty snapshot).
    await page.evaluate(async () => { await window.hubAPI.loadStore(); });

    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.waitForSelector('.khayt-app', { timeout: 90_000 });
    await page.waitForFunction(
      () => document.querySelector('#setup-wizard')?.style.display === 'none' && typeof window.KhaytShell?.switchTab === 'function',
      { timeout: 90_000 },
    );

    // Gate on the demo data actually landing in the app global — loadAll() applies
    // the disk store asynchronously after reload. The global printLog length is an
    // unambiguous, theme-independent signal (an empty-state <tr> is not).
    await page.waitForFunction(
      () => typeof printLog !== 'undefined' && Array.isArray(printLog) && printLog.length > 5,
      { timeout: 30_000 },
    );
    await page.evaluate(() => window.KhaytShell?.switchTab?.('dashboard-tab'));
    await page.waitForTimeout(800);

    await page.evaluate(() => {
      const wiz = document.querySelector('#setup-wizard');
      if (wiz) wiz.style.display = 'none';
      document.querySelector('#toastContainer')?.replaceChildren();
      document.querySelector('#modalMount')?.replaceChildren();
    });

    for (const shot of shots) {
      await prepareShot(page, shot);
      await page.waitForTimeout(600);
      try {
        await page.waitForSelector(shot.wait, { timeout: 15_000 });
      } catch {
        console.warn(`capture: selector timeout for ${shot.file}, capturing anyway`);
      }
      await page.waitForTimeout(400);

      const out = path.join(outDir, shot.file);
      await page.locator('.khayt-app').screenshot({ path: out, type: 'png' });
      written.push(out);
      onShot?.(shot, out);
    }
  } finally {
    if (electronApp) await electronApp.close().catch(() => {});
    fs.rmSync(userData, { recursive: true, force: true });
  }

  return written;
}
