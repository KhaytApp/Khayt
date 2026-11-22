#!/usr/bin/env node
/**
 * Capture the full app screen set across every design theme (Khayt-4).
 * Output: assets/themes/<theme>/screenshot-N-*.png  (12 screens × N themes)
 * Linux: xvfb-run -a node scripts/capture-theme-screenshots.mjs
 */
import { _electron as electron } from 'playwright-core';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';
import { buildScreenshotDemoStore } from './screenshot-demo-store.mjs';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(__dirname, '..');
// Language for the captured UI (e.g. KHAYT_LANG=ar for Arabic/RTL). Non-English
// sets land in assets/themes-<lang>/ so they sit alongside the English set.
const LANG = process.env.KHAYT_LANG || 'en';
const assetsRoot = path.join(root, 'assets', LANG === 'en' ? 'themes' : `themes-${LANG}`);
const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'khayt-theme-shots-'));

// Current default trio. Legacy theme galleries already exist under assets/themes/;
// override with KHAYT_THEME_SET to re-capture any of them.
const THEMES = [
  { id: 'workbench', appearance: 'light' },
  { id: 'command', appearance: 'light' },
  { id: 'vivid', appearance: 'light' },
];

// Optional override, e.g. KHAYT_THEME_SET='[{"id":"studio","appearance":"light","dir":"studio-light"}]'
// Each entry: { id, appearance, dir? } — `dir` defaults to the theme id.
const themeSet = (() => {
  if (!process.env.KHAYT_THEME_SET) return THEMES;
  try {
    const parsed = JSON.parse(process.env.KHAYT_THEME_SET);
    if (Array.isArray(parsed) && parsed.length) return parsed;
  } catch (e) {
    console.warn('Invalid KHAYT_THEME_SET, using defaults:', e.message);
  }
  return THEMES;
})();

const SHOTS = [
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

const VIEWPORT = { width: 1440, height: 940 };

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

async function prepareShot(page, shot, calcSeeded) {
  if (shot.setup === 'calculator') {
    if (!calcSeeded.done) { await seedCalculator(page); calcSeeded.done = true; }
    else {
      await page.evaluate(() => {
        window.KhaytShell?.switchTab?.('calculator-tab');
        if (typeof renderBuild === 'function') renderBuild();
        window.KhaytBedReadyUI?.initStudioCalculatorLayout?.();
      });
    }
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

async function applyTheme(page, theme) {
  await page.evaluate(({ id, appearance }) => {
    settings.designTheme = id;
    settings.theme = appearance;
    if (typeof applyTheme === 'function') applyTheme(appearance);
    if (typeof applyDesignSettings === 'function') applyDesignSettings();
    window.KhaytShell?.switchTab?.('dashboard-tab');
    const wiz = document.querySelector('#setup-wizard');
    if (wiz) wiz.style.display = 'none';
    document.querySelector('#toastContainer')?.replaceChildren();
    document.querySelector('#modalMount')?.replaceChildren();
  }, theme);
}

let electronApp;
let total = 0;
try {
  const demoStore = buildScreenshotDemoStore();
  demoStore.settings = demoStore.settings || {};
  demoStore.settings.firstRun = false;
  demoStore.settings.firstRunDone = true;
  demoStore.settings.designTheme = 'studio';
  demoStore.settings.lang = LANG;

  electronApp = await electron.launch({
    args: ['.', '--no-sandbox', `--user-data-dir=${userData}`],
    cwd: root,
    env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1' },
    timeout: 120_000,
  });

  const page = await electronApp.firstWindow();
  await page.setViewportSize(VIEWPORT);
  await page.waitForSelector('.khayt-app', { timeout: 90_000 });
  await page.waitForFunction(
    () => typeof window.hubAPI?.loadStore === 'function' && typeof window.KhaytShell?.switchTab === 'function',
    { timeout: 90_000 },
  );

  const saveResult = await page.evaluate(async (store) => window.hubAPI.saveStore(store), demoStore);
  if (!saveResult?.ok) throw new Error(`saveStore failed: ${JSON.stringify(saveResult)}`);

  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.khayt-app', { timeout: 90_000 });
  await page.waitForFunction(
    () => document.querySelector('#setup-wizard')?.style.display === 'none' && typeof window.KhaytShell?.switchTab === 'function',
    { timeout: 90_000 },
  );
  await page.waitForTimeout(800);

  // loadAll() applies the disk store asynchronously after reload; wait for the
  // demo data to land so the first (dashboard) shot per theme isn't empty.
  await page.evaluate(() => window.KhaytShell?.switchTab?.('logs-tab'));
  await page.waitForSelector('#logs-tab table tbody tr', { timeout: 30_000 });

  // Ensure the UI language (and RTL direction for Arabic) is applied.
  await page.evaluate((lang) => {
    if (typeof settings !== 'undefined') settings.lang = lang;
    if (typeof i18n !== 'undefined' && typeof i18n.set === 'function') i18n.set(lang, { silent: true });
  }, LANG);
  await page.waitForTimeout(500);

  for (const theme of themeSet) {
    const outDir = path.join(assetsRoot, theme.dir || theme.id);
    fs.mkdirSync(outDir, { recursive: true });
    await applyTheme(page, theme);
    await page.waitForTimeout(900);
    const calcSeeded = { done: false };
    console.log(`\n[${theme.id}] (${theme.appearance})`);

    for (const shot of SHOTS) {
      await prepareShot(page, shot, calcSeeded);
      await page.waitForTimeout(600);
      try {
        await page.waitForSelector(shot.wait, { timeout: 12_000 });
      } catch {
        console.warn(`  selector timeout for ${shot.file}, capturing anyway`);
      }
      await page.waitForTimeout(400);
      const out = path.join(outDir, shot.file);
      await page.locator('.khayt-app').screenshot({ path: out, type: 'png' });
      total += 1;
      console.log(`  ${theme.id}/${shot.file}`);
    }
  }

  console.log(`\nDone — ${total} screenshots saved to assets/themes/ (${themeSet.length} themes × ${SHOTS.length} screens)`);
} finally {
  if (electronApp) await electronApp.close().catch(() => {});
  fs.rmSync(userData, { recursive: true, force: true });
}
